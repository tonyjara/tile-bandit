import AppKit

/// Performs workspace switches.
///
/// Core invariant (this is the whole trick): switching never moves a window.
/// A switch unhides the target workspace's apps, hides every other regular
/// app, and focuses the workspace's last-focused app (falling back to its
/// first app). An app assigned to both the current and the target workspace
/// (or listed as floating) is left untouched, so it stays visible and keeps
/// its exact position.
///
/// Because we only hide/unhide whole apps (NSRunningApplication) and never
/// touch individual windows, no Accessibility permission is required here.
/// Grid tiling (which *does* move windows, deliberately) lives in
/// LayoutEngine/SnapManager and only runs from explicit user actions.
///
/// Everything here works on the *live display profile's* workspaces
/// (`store.workspaces`); `adoptProfile(_:)` is how a display change swaps
/// which set that is.
final class WorkspaceEngine {
    private let store: ConfigStore
    private(set) var activeWorkspaceID: UUID?
    var onActiveWorkspaceChange: (() -> Void)?

    /// Where the user was in each display profile, so unplugging and replugging
    /// a monitor comes back to the same workspace. In-memory by design, like
    /// `lastFocusedApp`.
    private var lastWorkspaceInProfile: [UUID: UUID] = [:]
    /// Name of the last workspace switched to, in any profile. New profiles are
    /// cloned from the one you were on, so this lets "Code" on the laptop line
    /// up with "Code" at the desk the very first time you plug in.
    private var lastWorkspaceName: String?
    private var profileID: UUID?

    /// Last app the user focused in each workspace, so switching back
    /// restores focus where they left off. In-memory only, by design —
    /// it's volatile UI state, not configuration.
    private var lastFocusedApp: [UUID: String] = [:]
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

    var activeWorkspace: Workspace? {
        store.workspaces.first { $0.id == activeWorkspaceID }
    }

    init(store: ConfigStore) {
        self.store = store
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            self?.recordActivation(note)
        }
    }

    deinit {
        followCheck?.cancel()
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
    }

    func switchTo(_ id: UUID) {
        guard let workspace = store.workspaces.first(where: { $0.id == id }) else { return }

        let running = regularRunningApps()
        let targetIDs = Set(workspace.apps.map(\.bundleId))

        // 1. Reveal the workspace's apps first so the screen is never empty.
        for ref in workspace.apps {
            let instances = running.filter { $0.bundleIdentifier == ref.bundleId }
            if instances.isEmpty {
                if workspace.launchMissingApps { launch(ref) }
            } else {
                for app in instances where app.isHidden { app.unhide() }
            }
        }

        // 2. Hide everything else — only the target's apps and floating apps
        //    stay visible. Apps shared with the previous workspace are in
        //    `targetIDs`, so they're never touched and keep their position.
        hideApps(in: running, keeping: targetIDs.union(floatingIDs()))

        // 3. Focus where the user left off in this workspace, or its first
        //    running app if there's no memory yet.
        focusApp(of: workspace, in: running)

        activeWorkspaceID = id
        if let profileID { lastWorkspaceInProfile[profileID] = id }
        lastWorkspaceName = workspace.name
        onActiveWorkspaceChange?()
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
            switchTo(target.id)
        } else {
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
        switchTo(workspaces[index].id)
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

        let running = regularRunningApps()
        let active = store.workspaces.first { $0.id == activeWorkspaceID }
        let allowed: Set<String>
        if let active {
            allowed = Set(active.apps.map(\.bundleId)).union(floatingIDs())
        } else {
            allowed = Set(store.workspaces.flatMap { $0.apps.map(\.bundleId) }).union(floatingIDs())
        }

        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        hideApps(in: running, keeping: allowed)

        // Only steal focus if the app the user was in just got hidden.
        if let active, let frontmost, !allowed.contains(frontmost) {
            focusApp(of: active, in: running)
        }
    }

    // MARK: - Focus memory

    /// Whenever an app belonging to the active workspace becomes frontmost,
    /// remember it as that workspace's focus target. Floating and unassigned
    /// apps never overwrite the memory. Every activation also restarts the
    /// follow-focus timer, so the decision is taken once the dust settles.
    private func recordActivation(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleId = app.bundleIdentifier
        else { return }

        if let workspace = activeWorkspace,
           workspace.apps.contains(where: { $0.bundleId == bundleId }) {
            lastFocusedApp[workspace.id] = bundleId
        }

        scheduleFollowCheck()
    }

    /// Restart the settle timer. A burst of activations therefore produces one
    /// check, `followSettleDelay` after the last of them.
    private func scheduleFollowCheck() {
        guard store.config.followFocusedApp else { return }
        followCheck?.cancel()
        let check = DispatchWorkItem { [weak self] in self?.followFocus() }
        followCheck = check
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.followSettleDelay, execute: check)
    }

    /// The app the user settled on lives in another workspace: switch there,
    /// so Cmd-Tab / Spotlight / a Dock click bring the whole workspace along
    /// instead of leaving one window stranded over the current one.
    ///
    /// Reads the frontmost app rather than trusting the notification that
    /// scheduled this — by now the churn from any hiding has played out, and
    /// what's in front is what the user meant to reach. Floating apps belong
    /// everywhere, so they never pull you away.
    private func followFocus() {
        guard store.config.followFocusedApp,
              let bundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              !floatingIDs().contains(bundleId)
        else { return }

        // Already where it belongs — this covers the tail of our own switches,
        // which end by focusing an app in the workspace just switched to.
        if let workspace = activeWorkspace,
           workspace.apps.contains(where: { $0.bundleId == bundleId }) { return }

        guard let target = store.workspaces.first(where: { workspace in
            workspace.apps.contains { $0.bundleId == bundleId }
        }), target.id != activeWorkspaceID else { return }

        // Land on the app the user actually reached for rather than wherever
        // focus happened to be the last time this workspace was up.
        lastFocusedApp[target.id] = bundleId
        switchTo(target.id)
    }

    // MARK: - Helpers

    private func regularRunningApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
    }

    private func floatingIDs() -> Set<String> {
        Set(store.config.floatingApps.map(\.bundleId))
    }

    private func hideApps(in running: [NSRunningApplication], keeping allowed: Set<String>) {
        for app in running {
            guard let bundleId = app.bundleIdentifier,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  !allowed.contains(bundleId)
            else { continue }
            if !app.isHidden { app.hide() }
        }
    }

    /// Focuses the workspace's remembered last-focused app if it's still
    /// assigned and running, otherwise the first running app in list order.
    private func focusApp(of workspace: Workspace, in running: [NSRunningApplication]) {
        var order = workspace.apps.map(\.bundleId)
        if let remembered = lastFocusedApp[workspace.id], order.contains(remembered) {
            order.removeAll { $0 == remembered }
            order.insert(remembered, at: 0)
        }
        guard let target = order
            .lazy
            .compactMap({ bundleId in running.first { $0.bundleIdentifier == bundleId } })
            .first
        else { return }
        if #available(macOS 14.0, *) {
            target.activate()
        } else {
            target.activate(options: [.activateIgnoringOtherApps])
        }
    }

    private func launch(_ ref: AppRef) {
        let url = ref.path.map { URL(fileURLWithPath: $0) }
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: ref.bundleId)
        guard let url else {
            NSLog("TileBandit: cannot locate app for \(ref.bundleId)")
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
