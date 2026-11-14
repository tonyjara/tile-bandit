import AppKit

/// Performs workspace switches.
///
/// Core invariant (this is the whole trick): switching never moves a window.
/// A switch unhides the target workspace's apps, hides every other regular
/// app (and any accessory app a workspace lists), and puts the workspace back
/// the way it was left — the same app in front, and its windows in the same
/// order front to back. An app assigned to both the current and the target
/// workspace (or listed as floating) is never hidden, so it keeps its exact
/// position; only its place in the stack changes.
///
/// The one exception is asked for app by app: for the apps in
/// `Config.perWindowApps` a *window* lives in one workspace, and since macOS
/// cannot hide a single window, a switch parks the ones that live elsewhere in
/// a corner and brings this workspace's back (WindowScope). No other app's
/// windows are moved, and none at all unless an app is opted in.
///
/// Hiding and showing whole apps (NSRunningApplication) needs no permission.
/// Putting the *order* back does its best with what it has: with the
/// Accessibility grant it works window by window (so a shared app can have one
/// window on top in one workspace and another in the next); without it, app by
/// app. Grid tiling (which *does* move windows, deliberately) lives in
/// LayoutEngine/SnapManager and only runs from explicit user actions.
///
/// Nothing a switch asks for is taken on trust. Hiding is carried out by each
/// app on its own main thread, so a busy app keeps its windows up until it gets
/// to the request, and `hide()` returns false even when it works. So after the
/// requests go out, a few checks read the screen itself and ask again — see
/// `runPass`. Every switch and every check writes a line to the log (Log.swift).
///
/// Everything here works on the *live display profile's* workspaces
/// (`store.workspaces`); `adoptProfile(_:)` is how a display change swaps
/// which set that is.
final class WorkspaceEngine {
    /// What asked for a switch — for the log, where "why did it switch?" is
    /// the first question.
    enum Trigger: String {
        case hotkey
        case menu
        case cycle = "next/previous"
        case follow = "follow-focus"
        case display = "display change"
    }

    private let store: ConfigStore
    /// Per-window workspaces. Off (`scope.isOn`) unless an app is opted in
    /// and Accessibility is granted; every use below asks first.
    private let scope: WindowScope
    private(set) var activeWorkspaceID: UUID?
    var onActiveWorkspaceChange: (() -> Void)?

    /// Where the user was in each display profile, so unplugging and replugging
    /// a monitor comes back to the same workspace. In-memory by design, like
    /// the snapshots.
    private var lastWorkspaceInProfile: [UUID: UUID] = [:]
    /// Name of the last workspace switched to, in any profile. New profiles are
    /// cloned from the one you were on, so this lets "Code" on the laptop line
    /// up with "Code" at the desk the very first time you plug in.
    private var lastWorkspaceName: String?
    private var profileID: UUID?

    /// How each workspace was when it was last left. Written only by
    /// `remember(_:)`, only about the workspace being left — which is what
    /// keeps one workspace's focus out of another's. In-memory only, by design:
    /// it's volatile UI state (window ids die with their windows), not
    /// configuration.
    private var snapshots: [UUID: WorkspaceSnapshot] = [:]
    /// Most recently used first — how follow-focus picks among several
    /// workspaces that hold the same app.
    private var recentWorkspaces: [UUID] = []

    /// Counts switches (and cleanups). A check or a follow-focus decision
    /// scheduled under one number stands down when it wakes under another.
    private var switchSeq = 0
    private var switchedAt = Date.distantPast
    private var pendingPass: DispatchWorkItem?
    /// The switch whose stack is back in place; later checks leave the order
    /// alone, so a window clicked right after a switch isn't pulled back.
    private var restoredSeq = 0

    private var activationObserver: NSObjectProtocol?

    /// Follow-focus decides a beat *after* an activation rather than on the
    /// notification itself, and asks what is frontmost then. Two reasons:
    /// hiding apps makes macOS hand focus around, so a switch arrives as a
    /// burst of activations that would otherwise be chased; and an app
    /// unhidden by Cmd-Tab or the Dock can still report `isHidden` at the
    /// instant it activates, since that flag reaches us on its own schedule.
    /// Coalescing the burst and reading `frontmostApplication` sidesteps both
    /// races — whatever survives to the end of the burst is what the user is
    /// actually looking at.
    private var followCheck: DispatchWorkItem?
    private static let followSettleDelay: TimeInterval = 0.2

    /// A workspace left sooner than this after arriving isn't remembered again:
    /// its apps may still be on their way back, and a half-restored screen
    /// would overwrite the good memory of it.
    private static let settleTime: TimeInterval = 0.5

    /// For this long after a switch (or after a window was sent away), the
    /// focused window of a per-window app living elsewhere does not move the
    /// workspace: this workspace's window is put forward instead. Without it,
    /// an app that was slow to change its focused window would send a switch
    /// straight back where it came from.
    private static let windowFollowHold: TimeInterval = 1.0
    private var holdWindowFollowUntil = Date.distantPast

    /// When, after a switch, the screen is read back. The first three always
    /// run: 0.1 s is when responsive apps have finished hiding and showing (it
    /// takes them 20–50 ms) and the stack can be put in order; 0.4 s confirms
    /// it and corrects once; 1.2 s is the last look. The rest run only while an
    /// app that was asked to hide is still on screen — a busy one gets to the
    /// request when it is free, and a request that was dropped is asked again.
    private static let passDelays: [TimeInterval] = [0.1, 0.4, 1.2, 3, 6, 12]
    private static let routinePasses = 3

    var activeWorkspace: Workspace? {
        store.workspaces.first { $0.id == activeWorkspaceID }
    }

    init(store: ConfigStore) {
        self.store = store
        scope = WindowScope(store: store)
        // Cmd-` changes an app's focused window without activating anything.
        // For per-window apps that is taken like an app coming forward.
        scope.onFocusedWindowChange = { [weak self] in self?.scheduleFollowCheck() }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Every activation restarts the follow-focus timer, so the decision
            // is taken once the dust settles. It no longer feeds any memory:
            // what a workspace remembers is read off the screen when it is left.
            self?.scheduleFollowCheck()
        }
    }

    deinit {
        followCheck?.cancel()
        pendingPass?.cancel()
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
    }

    // MARK: - Switching

    /// - Parameter pulled: the app whose coming forward caused this switch
    ///   (follow-focus). It is already in front and stays there, ahead of
    ///   whatever the workspace remembers: it is what the user reached for.
    func switchTo(_ id: UUID, trigger: Trigger = .hotkey, bringing pulled: NSRunningApplication? = nil) {
        guard let workspace = store.workspaces.first(where: { $0.id == id }) else {
            // A hotkey keeps the id it was registered with until the config
            // change that removed the workspace has been applied.
            Log.switching.failure("\(trigger.rawValue): asked for a workspace that no longer exists (\(id.uuidString))")
            return
        }

        // A follow-focus check armed before this switch would judge it by the
        // app that was in front then — and switch straight back.
        followCheck?.cancel()
        followCheck = nil
        pendingPass?.cancel()

        // Before anything is hidden or shown: this is the last moment the
        // workspace being left is on screen as the user had it.
        let leaving = activeWorkspace
        let frontBefore = NSWorkspace.shared.frontmostApplication
        let running = managedRunningApps()
        // Per-window apps: one reading of their windows serves both ends of
        // the switch. Nil for everyone who has not opted an app in.
        let scan = scope.isOn ? scope.scan(running) : nil
        if let leaving { remember(leaving, scan: scan) }

        switchSeq += 1
        let allowed = Set(workspace.apps.map(\.bundleId)).union(floatingIDs())

        // 0. Windows of per-window apps go where this workspace wants them
        //    before anything is shown: the ones that live elsewhere to their
        //    corner, its own back where they were.
        let arranged = scan.map {
            scope.arrange(for: workspace, scan: $0, preferring: snapshots[id]?.stack.map(\.window) ?? [])
        }

        // 1. Reveal the workspace's apps first so the screen is never empty.
        var shown = 0
        for ref in workspace.apps {
            let instances = running.filter { $0.bundleIdentifier == ref.bundleId }
            if instances.isEmpty {
                if workspace.launchMissingApps { launch(ref) }
            } else {
                // Unconditional, for the same reason as hideApps: a cached
                // `isHidden` that says "already up" would leave the app hidden.
                for app in instances { app.unhide() }
                shown += instances.count
            }
        }

        // 2. Hide everything else — only the target's apps and floating apps
        //    stay visible. Apps shared with the previous workspace are in
        //    `allowed`, so they're never touched and keep their position.
        let asked = hideApps(in: running, keeping: allowed)

        // 3. Focus where the user left off in this workspace. The rest of the
        //    stack follows in the first check, once the apps are back.
        let snapshot = snapshots[id]
        let (focus, why) = focusTarget(for: workspace, snapshot: snapshot, pulled: pulled, in: running)
        let byWindow = AccessibilityPermission.isGranted
        if let focus, pulled == nil {
            bringForward(focus, snapshot: snapshot, byWindow: byWindow)
        }

        activeWorkspaceID = id
        switchedAt = Date()
        holdWindowFollowUntil = switchedAt.addingTimeInterval(Self.windowFollowHold)
        recentWorkspaces.removeAll { $0 == id }
        recentWorkspaces.insert(id, at: 0)
        if let profileID { lastWorkspaceInProfile[profileID] = id }
        lastWorkspaceName = workspace.name

        Log.switching.line(
            "#\(switchSeq) \(trigger.rawValue): \(leaving?.name ?? "none") → \(workspace.name)"
                + " | in front before: \(label(frontBefore))"
                + " | focus: \(focus.map { label($0) } ?? "nothing") (\(why))"
                + " | asked \(shown) to show, \(asked.count) to hide"
                + " | order restored by \(byWindow ? "window" : "app (no Accessibility grant)")"
                + (arranged.map { " | per-window apps: \($0.summary)" } ?? "")
                + (snapshot == nil ? " | first visit, nothing remembered" : "")
        )
        onActiveWorkspaceChange?()

        schedulePass(Plan(
            seq: switchSeq,
            started: switchedAt,
            workspace: id,
            allowed: allowed,
            members: Set(workspace.apps.map(\.bundleId)),
            asked: asked,
            frontBefore: frontBefore?.processIdentifier,
            movedFocus: focus != nil,
            restore: Restore(remembered: snapshot, focus: focus, pulled: pulled != nil)
        ), index: 0)
    }

    /// The display setup changed, so a different profile — a different set of
    /// workspaces — is live. Picks up where the user left off there: the
    /// workspace last used in this profile, else the same-named workspace as
    /// the one they were just in, else nothing at all (windows untouched).
    func adoptProfile(_ id: UUID) {
        guard profileID != id else { return }
        profileID = id
        activeWorkspaceID = nil

        let workspaces = store.workspaces
        let target = lastWorkspaceInProfile[id].flatMap { remembered in
            workspaces.first { $0.id == remembered }
        } ?? lastWorkspaceName.flatMap { name in
            workspaces.first { $0.name == name }
        }

        if let target {
            switchTo(target.id, trigger: .display)
        } else {
            Log.switching.line("display change: no workspace to land on in this setup, windows left as they are")
            // With no workspace active nothing says a window should be parked.
            scope.releaseAll(because: "no workspace is active in this display setup")
            onActiveWorkspaceChange?()
        }
    }

    /// Cycle through workspaces in config order, wrapping at the ends.
    /// With none active, "next" starts at the first and "previous" at the last.
    func switchToNext() { cycle(offset: 1) }
    func switchToPrevious() { cycle(offset: -1) }

    private func cycle(offset: Int) {
        let workspaces = store.workspaces
        guard !workspaces.isEmpty else { return }
        let index: Int
        if let current = workspaces.firstIndex(where: { $0.id == activeWorkspaceID }) {
            index = (current + offset + workspaces.count) % workspaces.count
        } else {
            index = offset > 0 ? 0 : workspaces.count - 1
        }
        switchTo(workspaces[index].id, trigger: .cycle)
    }

    /// "Clean up": hide every app that isn't supposed to be on screen.
    /// With an active workspace that means everything outside it (plus
    /// floating apps); with none active — e.g. right after launch — apps
    /// assigned to *any* workspace may stay visible.
    ///
    /// Scoped to the live display profile — "assigned" means assigned in the
    /// profile you're plugged into, not in some other setup's workspaces.
    ///
    /// No-op when the profile has no workspaces, so a fresh install (or a
    /// just-created profile) doesn't hide the entire screen.
    func hideUnassignedApps() {
        guard !store.workspaces.isEmpty else { return }

        let running = managedRunningApps()
        let active = activeWorkspace
        let allowed: Set<String>
        if let active {
            allowed = Set(active.apps.map(\.bundleId)).union(floatingIDs())
        } else {
            allowed = Set(store.workspaces.flatMap { $0.apps.map(\.bundleId) }).union(floatingIDs())
        }

        let frontmost = NSWorkspace.shared.frontmostApplication
        pendingPass?.cancel()
        switchSeq += 1
        if let active {
            if scope.isOn { scope.arrange(for: active, scan: scope.scan(running)) }
        } else {
            // Launch, or a display setup with nowhere to land: no workspace is
            // active, so no window has a reason to be in a corner.
            scope.releaseAll(because: "no workspace is active")
        }
        let asked = hideApps(in: running, keeping: allowed)

        // Only steal focus if the app the user was in just got hidden.
        var focus: NSRunningApplication?
        if let active, let frontmost, !mayStay(frontmost, allowed: allowed) {
            focus = focusTarget(for: active, snapshot: snapshots[active.id], pulled: nil, in: running).app
            if let focus { activate(focus, allWindows: !AccessibilityPermission.isGranted) }
        }

        Log.switching.line(
            "#\(switchSeq) clean up: keeping \(active.map { "workspace \($0.name)" } ?? "every workspace's apps")"
                + " | asked \(asked.count) to hide"
                + (focus.map { " | focus: \(label($0))" } ?? "")
        )
        schedulePass(Plan(
            seq: switchSeq,
            started: Date(),
            workspace: active?.id,
            allowed: allowed,
            members: [],
            asked: asked,
            frontBefore: frontmost?.processIdentifier,
            movedFocus: focus != nil,
            restore: nil
        ), index: 0)
    }

    // MARK: - Per-window apps

    /// Windows of per-window apps that live in another workspace than the one
    /// on screen. Apply Grid Layout leaves them in their corner.
    var windowsLivingElsewhere: Set<CGWindowID> {
        scope.isOn ? scope.windowsElsewhere(than: activeWorkspaceID) : []
    }

    /// Sends the focused window of a per-window app to live in another
    /// workspace. The window goes; the user stays.
    ///
    /// - Parameter app: for the menu, which runs after it has closed and so
    ///   cannot ask who is in front (see `AppDelegate.menuWillOpen`).
    func moveFocusedWindow(to id: UUID, of app: NSRunningApplication? = nil) {
        guard let target = store.workspaces.first(where: { $0.id == id }) else { return }
        let refuse = { (why: String) in
            Log.windows.failure("move window to \(target.name): \(why)")
            NSSound.beep()
        }
        guard scope.isOn else { return refuse("per-window apps are off (none set, or no Accessibility grant)") }
        guard let app = app ?? NSWorkspace.shared.frontmostApplication, let bundleId = app.bundleIdentifier else {
            return refuse("nothing is in front")
        }
        guard scope.covers(bundleId) else { return refuse("\(label(app)) is not a per-window app") }
        guard target.apps.contains(where: { $0.bundleId == bundleId }) else {
            return refuse("\(target.name) does not list \(label(app))")
        }
        guard let window = scope.focusedWindow(of: app) else {
            return refuse("\(label(app)) has no focused window that can be moved (minimised, or full screen?)")
        }

        scope.move(window, to: target, active: activeWorkspaceID)
        holdWindowFollowUntil = Date().addingTimeInterval(Self.windowFollowHold)
        Log.windows.line("window \(window.live.id) of \(label(app)) now lives in \(target.name)")

        // Its window has left for a corner: focus should not stay in it.
        guard let active = activeWorkspace, active.id != id else { return }
        let stack = snapshots[active.id]?.stack.map(\.window) ?? []
        if scope.putHomeWindowForward(of: app, in: active, preferring: stack) { return }
        let allowed = Set(active.apps.map(\.bundleId)).union(floatingIDs())
        let running = managedRunningApps()
        let next = WindowList.onScreen().lazy
            .filter { $0.pid != app.processIdentifier }
            .compactMap { window in running.first { $0.processIdentifier == window.pid } }
            .first { self.mayStay($0, allowed: allowed) && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if let next { activate(next, allWindows: false) }
    }

    /// Brings every parked window back, from the menu. The homes are kept, so
    /// the next switch parks again: this is for looking, and for getting out
    /// of trouble.
    func releaseParkedWindows() {
        scope.releaseAll(because: "asked for from the menu")
    }

    /// The config changed: an app taken off the per-window list gets its
    /// windows back.
    func configChanged() {
        scope.reconcile()
    }

    /// Quitting. A parked window must not outlive the app that parked it.
    func shutDown() {
        followCheck?.cancel()
        pendingPass?.cancel()
        scope.releaseAll(because: "Tile Bandit is quitting")
    }

    // MARK: - Memory

    /// Records how `workspace` looks right now, as the state to come back to.
    ///
    /// Called for the workspace being left and nothing else, before the switch
    /// touches anything. Read from the screen rather than collected from
    /// activation notifications: those arrive 40–55 ms late and were credited
    /// to whichever workspace was active *by then*, so an app in two
    /// workspaces could become the remembered focus of one it was never used in.
    ///
    /// For per-window apps this is also where a window gets its home: the
    /// workspace being left takes the ones in sight that have none (`scan` is
    /// nil unless an app is opted in). Windows that live elsewhere stay out of
    /// the snapshot — they are in a corner, not part of this workspace.
    private func remember(_ workspace: Workspace, scan: WindowScope.Scan? = nil) {
        guard Date().timeIntervalSince(switchedAt) >= Self.settleTime else {
            Log.switching.quiet("\(workspace.name) left before it had settled; its memory is kept as it was")
            return
        }
        var elsewhere = Set<CGWindowID>()
        if let scan {
            scope.claim(for: workspace, scan: scan)
            elsewhere = scope.windowsElsewhere(than: workspace.id)
        }
        let members = Set(workspace.apps.map(\.bundleId)).union(floatingIDs())
        var bundleOf: [pid_t: String] = [:]
        for app in managedRunningApps() {
            if let bundleId = app.bundleIdentifier { bundleOf[app.processIdentifier] = bundleId }
        }
        let onScreen = WindowList.onScreen().compactMap { window -> WorkspaceSnapshot.Entry? in
            guard !elsewhere.contains(window.id) else { return nil }
            guard let bundleId = bundleOf[window.pid], members.contains(bundleId) else { return nil }
            return WorkspaceSnapshot.Entry(window: window.id, bundleId: bundleId)
        }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        var snapshot = snapshots[workspace.id] ?? WorkspaceSnapshot()
        snapshot.update(onScreen: onScreen, frontmost: front.flatMap { members.contains($0) ? $0 : nil })
        snapshots[workspace.id] = snapshot
    }

    /// Which app a switch to `workspace` brings to the front, and why — the
    /// why goes in the log.
    private func focusTarget(
        for workspace: Workspace,
        snapshot: WorkspaceSnapshot?,
        pulled: NSRunningApplication?,
        in running: [NSRunningApplication]
    ) -> (app: NSRunningApplication?, why: String) {
        if let pulled { return (pulled, "it came to the front") }

        let allowed = Set(workspace.apps.map(\.bundleId)).union(floatingIDs())
        func instance(_ bundleId: String) -> NSRunningApplication? {
            running.first { $0.bundleIdentifier == bundleId }
        }
        if let snapshot {
            if let remembered = snapshot.focusBundleId, allowed.contains(remembered), let app = instance(remembered) {
                return (app, "remembered")
            }
            // The remembered app has quit or left the workspace: the next
            // thing down its stack is the nearest to how it was.
            for entry in snapshot.stack where allowed.contains(entry.bundleId) {
                if let app = instance(entry.bundleId) { return (app, "next in the remembered stack") }
            }
        }
        for ref in workspace.apps {
            if let app = instance(ref.bundleId) { return (app, "first running app in the list") }
        }
        return (nil, "none of its apps is running")
    }

    // MARK: - Follow-focus

    /// Restart the settle timer. A burst of activations therefore produces one
    /// check, `followSettleDelay` after the last of them.
    private func scheduleFollowCheck() {
        guard store.config.followFocusedApp else { return }
        followCheck?.cancel()
        let armed = switchSeq
        let check = DispatchWorkItem { [weak self] in self?.followFocus(armedAt: armed) }
        followCheck = check
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.followSettleDelay, execute: check)
    }

    /// The app the user settled on lives in another workspace: switch there,
    /// so Cmd-Tab / Spotlight / a Dock click bring the whole workspace along
    /// instead of leaving one window stranded over the current one. An app
    /// that brings *itself* forward is followed the same way, on purpose.
    ///
    /// Reads the frontmost app rather than trusting the notification that
    /// scheduled this — by now the churn from any hiding has played out, and
    /// what's in front is what the user meant to reach. Floating apps belong
    /// everywhere, so they never pull you away.
    private func followFocus(armedAt armed: Int) {
        guard store.config.followFocusedApp else { return }
        // A switch happened while this was waiting. What it was armed for is
        // history; look again once that switch's own activations have landed.
        guard armed == switchSeq else {
            Log.follow.quiet("check armed at #\(armed) woke at #\(switchSeq): waiting again")
            scheduleFollowCheck()
            return
        }
        guard let front = NSWorkspace.shared.frontmostApplication,
              let bundleId = front.bundleIdentifier
        else { return }
        let active = activeWorkspace
        let here = "in front: \(label(front)), workspace: \(active?.name ?? "none")"

        if floatingIDs().contains(bundleId) {
            Log.follow.quiet("\(here) → stay (floating app)")
            return
        }
        // A per-window app is judged by its focused window, not by the app:
        // the app may well belong here while that window lives elsewhere
        // (Cmd-`, a click on a parked corner, a link opened into it).
        if scope.isOn, scope.covers(bundleId),
           let window = AX.focusedWindowID(pid: front.processIdentifier),
           let home = scope.home(of: window) {
            if home == activeWorkspaceID {
                Log.follow.quiet("\(here) → stay (its focused window lives here)")
                return
            }
            guard let target = store.workspaces.first(where: { $0.id == home }) else { return }
            if let active, Date() < holdWindowFollowUntil {
                // Too soon after a switch to be the user's doing. Answer by
                // putting this workspace's window forward, never by going back.
                let stack = snapshots[active.id]?.stack.map(\.window) ?? []
                let put = scope.putHomeWindowForward(of: front, in: active, preferring: stack)
                Log.follow.line(
                    "\(here) → stay: its focused window lives in \(target.name), but \(active.name) was only just arrived at"
                        + (put ? "; its own window put forward" : "; it has no window here to put forward")
                )
                return
            }
            Log.follow.line("\(here) → switch to \(target.name) (its focused window lives there)")
            switchTo(target.id, trigger: .follow, bringing: front)
            return
        }

        // Already where it belongs — this covers the tail of our own switches,
        // which end by focusing an app in the workspace just switched to.
        if let active, active.apps.contains(where: { $0.bundleId == bundleId }) {
            Log.follow.quiet("\(here) → stay (it belongs here)")
            return
        }

        let owners = store.workspaces.filter { workspace in
            workspace.apps.contains { $0.bundleId == bundleId }
        }
        guard !owners.isEmpty else {
            Log.follow.quiet("\(here) → stay (in no workspace)")
            return
        }

        // With no active workspace (fresh launch, or a profile adoption that
        // found nothing to land on), an app assigned to several workspaces is
        // ambiguous — don't guess, or the first click would jump to whichever
        // workspace happens to list it first in config order.
        if active == nil, owners.count != 1 {
            Log.follow.line("\(here) → stay (it is in \(owners.count) workspaces and none is active)")
            return
        }

        // In several workspaces: the one used most recently, not whichever the
        // config happens to list first.
        func recency(_ workspace: Workspace) -> Int {
            recentWorkspaces.firstIndex(of: workspace.id) ?? Int.max
        }
        guard let target = owners.enumerated().min(by: { a, b in
            (recency(a.element), a.offset) < (recency(b.element), b.offset)
        })?.element, target.id != activeWorkspaceID else { return }

        Log.follow.line("\(here) → switch to \(target.name)")
        switchTo(target.id, trigger: .follow, bringing: front)
    }

    // MARK: - Checking the screen after a switch

    private struct Restore {
        let remembered: WorkspaceSnapshot?
        let focus: NSRunningApplication?
        /// The focus app came forward by itself or by the user's hand.
        let pulled: Bool
    }

    private struct Plan {
        let seq: Int
        let started: Date
        /// The workspace on screen after it. Nil for a clean-up with none active.
        let workspace: UUID?
        /// Bundle ids that may be on screen.
        let allowed: Set<String>
        /// The target workspace's own apps, which must come back.
        let members: Set<String>
        /// The processes asked to hide. Only these are ever asked again: an
        /// app opened after the switch is the user's doing, not a leftover.
        let asked: Set<pid_t>
        /// The app in front before, and whether focus was moved off it.
        let frontBefore: pid_t?
        let movedFocus: Bool
        /// Nil for a clean-up, which hides and nothing else.
        let restore: Restore?
    }

    private func schedulePass(_ plan: Plan, index: Int) {
        guard index < Self.passDelays.count else { return }
        let work = DispatchWorkItem { [weak self] in self?.runPass(plan, index: index) }
        pendingPass = work
        let wait = max(0, plan.started.addingTimeInterval(Self.passDelays[index]).timeIntervalSinceNow)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
    }

    /// Reads the screen back and puts right what the switch's requests left
    /// undone: apps still up that were asked to hide, apps still hidden that
    /// belong here, and the order of the windows.
    private func runPass(_ plan: Plan, index: Int) {
        guard plan.seq == switchSeq else { return }

        let running = managedRunningApps()
        let everyWindow = WindowList.onScreen()
        let drawn = Set(everyWindow.map(\.pid))
        let front = NSWorkspace.shared.frontmostApplication

        // Per-window apps: whatever is in the wrong place is moved again, and
        // windows that live elsewhere take no part in this workspace's order.
        var scopeNote = ""
        var windows = everyWindow
        if scope.isOn, let workspace = store.workspaces.first(where: { $0.id == plan.workspace }) {
            if index < Self.routinePasses {
                let fixed = scope.verify(workspace, windows: everyWindow)
                if fixed.strays > 0 {
                    scopeNote += " | STRAY (\(fixed.strays) window(s) that live in another workspace were in sight, parked again)"
                }
                if fixed.stillParked > 0 {
                    scopeNote += " | STILL PARKED (\(fixed.stillParked) window(s) that live here, brought back again)"
                }
            }
            let elsewhere = scope.windowsElsewhere(than: workspace.id)
            windows = everyWindow.filter { !elsewhere.contains($0.id) }
        }

        // Asked to hide and still drawing a window. The app in front is left
        // alone when the switch moved focus elsewhere: it can only be in front
        // now because it was brought back since, and that isn't ours to undo.
        // (When nothing took focus — a workspace with nothing running — the
        // app that was in front and still is simply hasn't hidden yet.)
        var leftovers: [NSRunningApplication] = []
        for app in running where plan.asked.contains(app.processIdentifier) && !mayStay(app, allowed: plan.allowed) {
            let broughtBack = app.processIdentifier == front?.processIdentifier
                && (plan.movedFocus || plan.frontBefore != app.processIdentifier)
            if broughtBack { continue }
            if drawn.contains(app.processIdentifier) {
                leftovers.append(app)
                app.hide()
            } else if !app.isHidden {
                // Nothing of it on the visible desktops, yet not hidden: its
                // windows may be on another Space. Asking again costs nothing.
                app.hide()
            }
        }

        // Belongs here and still hidden. The flag lags the screen by a moment,
        // so the first check asks again without calling it a problem.
        var stillHidden: [NSRunningApplication] = []
        for app in running where app.isHidden && !drawn.contains(app.processIdentifier) {
            guard let bundleId = app.bundleIdentifier, plan.members.contains(bundleId) else { continue }
            app.unhide()
            if index > 0 { stillHidden.append(app) }
        }

        var orderNote = ""
        if let restore = plan.restore, index < Self.routinePasses {
            orderNote = restoreOrder(plan, restore, windows: windows, running: running, front: front, attempt: index)
        }

        let visible = windows.compactMap { window in running.first { $0.processIdentifier == window.pid } }
        let elapsed = String(format: "%.1f", Date().timeIntervalSince(plan.started))
        let summary = "#\(plan.seq) check +\(elapsed)s | in front: \(label(front))"
            + " | windows front to back: \(names(visible))"
            + (orderNote.isEmpty ? "" : " | \(orderNote)")
            + scopeNote
            + (leftovers.isEmpty ? "" : " | LEFTOVER (asked to hide, still on screen, asked again): \(names(leftovers))")
            + (stillHidden.isEmpty ? "" : " | STILL HIDDEN (asked to show again): \(names(stillHidden))")
        if leftovers.isEmpty, stillHidden.isEmpty, scopeNote.isEmpty {
            Log.switching.line(summary)
        } else {
            Log.switching.failure(summary)
        }

        let next = index + 1
        if next < Self.routinePasses {
            schedulePass(plan, index: next)
        } else if !leftovers.isEmpty || !stillHidden.isEmpty {
            if next < Self.passDelays.count {
                schedulePass(plan, index: next)
            } else {
                Log.switching.failure(
                    "#\(plan.seq) giving up after \(elapsed)s: \(names(leftovers + stillHidden)) never did as asked"
                        + " (full screen, or not responding?)"
                )
            }
        }
    }

    /// Puts the windows back in the order the workspace was left in, moving as
    /// few as it takes. Returns what it did, for the log.
    ///
    /// The first attempt (0.1 s) raises windows through Accessibility, which
    /// reorders without making anything active. The second (0.4 s) runs only
    /// if the order is still off, and goes the long way round — make each
    /// window its app's main one and activate the app — for the apps a plain
    /// raise doesn't move. The third only reports. Once the order is right it
    /// is left alone, so a window clicked right after a switch stays clicked.
    private func restoreOrder(
        _ plan: Plan,
        _ restore: Restore,
        windows: [WindowRef],
        running: [NSRunningApplication],
        front: NSRunningApplication?,
        attempt: Int
    ) -> String {
        guard restoredSeq != plan.seq else { return "" }

        var appOf: [pid_t: NSRunningApplication] = [:]
        for app in running where mayStay(app, allowed: plan.allowed) { appOf[app.processIdentifier] = app }
        let visible = windows.filter { appOf[$0.pid] != nil }
        let focusPid = restore.focus?.processIdentifier
        let lastLook = attempt == Self.routinePasses - 1
        let byWindow = AccessibilityPermission.isGranted

        var raised = 0
        var missed = 0
        var needed = 0

        if byWindow {
            let actual = visible.map(\.id)
            var owner: [CGWindowID: pid_t] = [:]
            for window in visible { owner[window.id] = window.pid }
            var desired = StackPlan.desired(remembered: restore.remembered?.stack.map(\.window) ?? [], actual: actual)
            if let focusPid {
                // What the user reached for leads with the window it has in
                // front now; a remembered focus leads with the window it had
                // in front then.
                let lead = (restore.pulled ? actual : desired).first { owner[$0] == focusPid }
                desired = StackPlan.promoting(desired) { $0 == lead }
            }
            let raises = StackPlan.raisesNeeded(desired: desired, actual: actual)
            needed = raises.count

            if !lastLook, !raises.isEmpty {
                // One question per app, and an app that doesn't answer is
                // skipped whole rather than waited on once per window.
                var elements: [pid_t: [CGWindowID: AXUIElement]] = [:]
                var silent = Set<pid_t>()
                func element(_ id: CGWindowID) -> AXUIElement? {
                    guard let pid = owner[id], !silent.contains(pid) else { return nil }
                    if elements[pid] == nil {
                        guard let found = AX.windowsByID(pid: pid, among: visible) else {
                            silent.insert(pid)
                            return nil
                        }
                        elements[pid] = found
                    }
                    return elements[pid]?[id]
                }
                for id in raises {
                    guard let window = element(id), let pid = owner[id], let app = appOf[pid] else {
                        missed += 1
                        continue
                    }
                    if attempt == 0 {
                        AX.raise(window)
                    } else {
                        AX.makeMain(window)
                        AX.raise(window)
                        activate(app, allWindows: false)
                    }
                    raised += 1
                }
                // The last one raised is the one that belongs in front: make
                // it its app's main window so focus lands in it, not in
                // whichever window the app had forward before.
                if let top = desired.first, raises.last == top, let window = element(top) {
                    AX.makeMain(window)
                }
            }
        } else {
            // No Accessibility grant: whole apps, by activating them. Each
            // activation brings all of an app's windows forward together.
            var actual: [pid_t] = []
            for window in visible where !actual.contains(window.pid) { actual.append(window.pid) }
            var remembered: [pid_t] = []
            for entry in restore.remembered?.stack ?? [] {
                for pid in actual where appOf[pid]?.bundleIdentifier == entry.bundleId && !remembered.contains(pid) {
                    remembered.append(pid)
                }
            }
            var desired = StackPlan.desired(remembered: remembered, actual: actual)
            if let focusPid { desired = StackPlan.promoting(desired) { $0 == focusPid } }
            let raises = StackPlan.raisesNeeded(desired: desired, actual: actual)
            needed = raises.count

            if !lastLook {
                for pid in raises {
                    guard let app = appOf[pid] else { continue }
                    activate(app, allWindows: true)
                    raised += 1
                }
            }
        }

        // The focus request goes out with the switch; this is the one re-ask,
        // while it is still certain nobody else has moved focus since.
        var focusNote = ""
        if let focus = restore.focus, front?.processIdentifier != focus.processIdentifier {
            if attempt == 0 {
                activate(focus, allWindows: !byWindow)
                focusNote = ", focus asked again"
            } else {
                focusNote = ", in front is not the focus target \(label(focus))"
            }
        }

        if needed == 0 {
            if focusNote.isEmpty || attempt > 0 { restoredSeq = plan.seq }
            return "order as remembered\(focusNote)"
        }
        if lastLook {
            return "ORDER STILL DIFFERS from what was remembered (\(needed) out of place)\(focusNote)"
        }
        let how = byWindow ? (attempt == 0 ? "raised" : "raised by activating") : "activated"
        return "\(how) \(raised) to restore the order"
            + (missed > 0 ? " (\(missed) not reachable through Accessibility)" : "")
            + focusNote
    }

    // MARK: - Helpers

    /// The apps a switch shows, hides and focuses: every regular app, plus an
    /// accessory app when a workspace of this setup lists it.
    private func managedRunningApps() -> [NSRunningApplication] {
        let listed = Set(store.workspaces.flatMap { $0.apps.map(\.bundleId) }).union(floatingIDs())
        return NSWorkspace.shared.runningApplications.filter {
            Self.isManaged(policy: $0.activationPolicy, bundleId: $0.bundleIdentifier, listed: listed)
        }
    }

    /// Whether a switch takes charge of an app with this activation policy.
    ///
    /// Regular apps always. An *accessory* app only when a workspace lists it:
    /// some apps drop their Dock icon (become accessory) while only a panel of
    /// theirs is up, and are still the app the workspace is for. Kururu does
    /// that when its main window closes and its floating panel stays. Filtering
    /// on `.regular` alone made the workspace look empty ("none of its apps is
    /// running"), so nothing took focus, and the app in front (macOS won't hide
    /// the active app while nothing replaces it) stayed on screen through every
    /// check. An accessory app nobody listed (a menu bar utility) is left alone:
    /// hiding it would close its menus and popovers. A prohibited (background
    /// only) app has nothing to show or hide.
    static func isManaged(policy: NSApplication.ActivationPolicy, bundleId: String?, listed: Set<String>) -> Bool {
        switch policy {
        case .regular: return true
        case .accessory: return bundleId.map(listed.contains) ?? false
        default: return false
        }
    }

    private func floatingIDs() -> Set<String> {
        Set(store.config.floatingApps.map(\.bundleId))
    }

    /// Whether a switch leaves `app` alone. An app with no bundle identifier —
    /// anything with a window started from a terminal — is in no workspace, so
    /// it is hidden like any other; it used to be skipped and sat there through
    /// every switch.
    private func mayStay(_ app: NSRunningApplication, allowed: Set<String>) -> Bool {
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier { return true }
        return app.bundleIdentifier.map(allowed.contains) ?? false
    }

    /// Asks everything outside `allowed` to hide, and returns who was asked.
    ///
    /// Deliberately unconditional. `NSRunningApplication.isHidden` is a cached
    /// property AppKit refreshes asynchronously, so an app the user brought
    /// back by some route we never hear about — a notification banner, the
    /// Dock, Mission Control — can still read `isHidden == true` here long
    /// after it's on screen. Asking first meant that app was skipped and sat
    /// over the grid through switch after switch. `hide()` on an app that
    /// really is hidden is a no-op, so the check bought nothing and cost
    /// correctness.
    ///
    /// The result of `hide()` is not looked at because it says nothing: it
    /// returns false when the app goes on to hide (measured on macOS 27).
    /// `runPass` reads the screen instead.
    @discardableResult
    private func hideApps(in running: [NSRunningApplication], keeping allowed: Set<String>) -> Set<pid_t> {
        var asked = Set<pid_t>()
        for app in running where !mayStay(app, allowed: allowed) {
            app.hide()
            asked.insert(app.processIdentifier)
        }
        return asked
    }

    /// Brings the focus app forward as the switch goes out.
    ///
    /// An app that stayed on screen through the switch (shared, or floating)
    /// may have a different window forward than this workspace remembers — the
    /// one it was used with in the workspace just left. With the Accessibility
    /// grant the remembered window is put forward first, so it is the one that
    /// arrives and the other never flashes by.
    private func bringForward(_ app: NSRunningApplication, snapshot: WorkspaceSnapshot?, byWindow: Bool) {
        if byWindow,
           let bundleId = app.bundleIdentifier,
           let top = snapshot?.stack.first(where: { $0.bundleId == bundleId }) {
            let onScreen = WindowList.onScreen()
            if onScreen.contains(where: { $0.pid == app.processIdentifier }),
               let window = AX.windowsByID(pid: app.processIdentifier, among: onScreen)?[top.window] {
                AX.makeMain(window)
                AX.raise(window)
            }
        }
        activate(app, allWindows: !byWindow)
    }

    /// - Parameter allWindows: bring every window of the app forward, not only
    ///   its main one. Wanted when the order is kept app by app; not when it is
    ///   kept window by window, where it would undo the order just restored.
    private func activate(_ app: NSRunningApplication, allWindows: Bool) {
        var options: NSApplication.ActivationOptions = allWindows ? [.activateAllWindows] : []
        if #available(macOS 14.0, *) {
            // Activation is cooperative from macOS 14 on, and the old
            // "ignoring other apps" flag does nothing.
        } else {
            options.insert(.activateIgnoringOtherApps)
        }
        app.activate(options: options)
    }

    private func launch(_ ref: AppRef) {
        let url = ref.path.map { URL(fileURLWithPath: $0) }
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: ref.bundleId)
        guard let url else {
            Log.switching.failure("cannot find \(ref.name) (\(ref.bundleId)) to launch it")
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error {
                Log.switching.failure("launching \(ref.name) failed: \(error.localizedDescription)")
            }
        }
    }

    private func label(_ app: NSRunningApplication?) -> String {
        guard let app else { return "nothing" }
        return app.localizedName ?? app.bundleIdentifier ?? "pid \(app.processIdentifier)"
    }

    private func names(_ apps: [NSRunningApplication]) -> String {
        apps.isEmpty ? "none" : apps.prefix(16).map { label($0) }.joined(separator: ", ")
    }
}
