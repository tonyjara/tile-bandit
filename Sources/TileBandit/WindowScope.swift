import AppKit
import ApplicationServices

/// Per-window workspaces: for the apps the user opted in
/// (`Config.perWindowApps`), each *window* lives in one workspace. This is the
/// side that touches the screen; which window lives where is `WindowHomes`.
///
/// macOS cannot hide one window of an app. What it can do, through
/// Accessibility, is move it: a window that lives elsewhere is parked at a
/// bottom corner of its display, where the system keeps a sliver of it showing
/// (1 × 32 pt, measured), and put back where it was when its workspace returns. No
/// animation and nothing in the Dock, which is why this and not minimising
/// (about 0.55 s each way, measured) — docs/plans/per-window-workspaces.md.
///
/// So this is the one place a *switch* moves windows, and only windows of apps
/// the user opted in. Everything is off (`isOn`) unless an app is opted in
/// and the Accessibility permission is granted, and nothing here ever asks for
/// the permission: a switch must not put up a prompt. Without it an opted-in
/// app is switched as a whole app, like any other.
///
/// Nothing is taken on trust here either. A move is read back (the system
/// decides where a window really ends up), and the engine's checks after a
/// switch call `verify`, which moves again whatever is in the wrong place.
/// Main thread only, like the engine.
final class WindowScope {
    /// One window as a switch found it.
    struct Found {
        let live: LiveWindow
        let element: AXUIElement
    }

    /// The per-window apps' windows, read once per switch and used at both
    /// ends of it: the workspace being left claims from it, the one arrived at
    /// is arranged from it. Once, because every Accessibility call waits on
    /// the app, and a busy one should cost the switch a second at most.
    struct Scan {
        var windows: [pid_t: [Found]] = [:]
        /// Apps that did not answer. Left exactly as they are.
        var silent: [String] = []

        var all: [Found] { windows.values.flatMap { $0 } }
    }

    struct Arranged {
        var parked = 0
        var shown = 0
        var failed = 0

        var summary: String {
            "\(parked) parked, \(shown) brought back" + (failed > 0 ? ", \(failed) WOULD NOT MOVE" : "")
        }
    }

    private let store: ConfigStore
    private(set) var homes = WindowHomes()
    private var written = WindowHomes()
    /// The focused window of a per-window app changed (Cmd-`, a click on a
    /// parked corner): the engine takes it as it takes an app coming forward.
    var onFocusedWindowChange: (() -> Void)?
    private var observers: [pid_t: AXObserver] = [:]
    private var saidWhyOff = false

    static let stateFile = ConfigStore.configDir.appendingPathComponent("windows.json")

    init(store: ConfigStore) {
        self.store = store
        guard isConfigured || FileManager.default.fileExists(atPath: Self.stateFile.path) else { return }
        load()
    }

    deinit {
        for observer in observers.values {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
    }

    // MARK: - Whether any of this runs

    /// A floating app is in every workspace by definition, so it is never
    /// scoped by window, whatever the list says.
    var scopedIDs: Set<String> {
        Set(store.config.perWindowApps.map(\.bundleId))
            .subtracting(store.config.floatingApps.map(\.bundleId))
    }

    private var isConfigured: Bool { !store.config.perWindowApps.isEmpty }

    /// False for everyone who has not opted an app in, which is what keeps
    /// every line of this out of their switches.
    var isOn: Bool {
        guard isConfigured, !scopedIDs.isEmpty else { return false }
        guard AccessibilityPermission.isGranted, AX.canIdentifyWindows else {
            if !saidWhyOff {
                saidWhyOff = true
                Log.windows.failure(
                    AccessibilityPermission.isGranted
                        ? "per-window apps are set, but this macOS gives no window ids: they are switched as whole apps"
                        : "per-window apps are set, but Accessibility is not granted: they are switched as whole apps"
                )
            }
            return false
        }
        saidWhyOff = false
        return true
    }

    func covers(_ bundleId: String) -> Bool { scopedIDs.contains(bundleId) }

    private var places: [WindowHomes.Place] {
        store.workspaces.map { WindowHomes.Place(id: $0.id, name: $0.name, apps: Set($0.apps.map(\.bundleId))) }
    }

    private func place(_ workspace: Workspace) -> WindowHomes.Place {
        WindowHomes.Place(id: workspace.id, name: workspace.name, apps: Set(workspace.apps.map(\.bundleId)))
    }

    /// The displays in Accessibility's space, the main one first.
    private static func screens() -> [CGRect] {
        NSScreen.screens.map { AX.axRect(fromCocoa: $0.frame) }
    }

    // MARK: - Reading

    /// Reads the windows of every running per-window app, and tidies the
    /// books while it has them: windows that are gone are retired, and windows
    /// never seen before are matched against what their app had when it last
    /// quit.
    func scan(_ running: [NSRunningApplication]) -> Scan {
        let scoped = scopedIDs
        let screens = Self.screens()
        let onScreen = Set(WindowList.onScreen().map(\.id))
        var scan = Scan()
        var pids = Set<pid_t>()
        for app in running {
            guard let bundleId = app.bundleIdentifier, scoped.contains(bundleId) else { continue }
            let pid = app.processIdentifier
            pids.insert(pid)
            guard let found = AX.ownWindows(pid: pid) else {
                scan.silent.append(app.localizedName ?? bundleId)
                continue
            }
            scan.windows[pid] = found.map { window in
                Found(
                    live: LiveWindow(
                        id: window.id, pid: pid, bundleId: bundleId, frame: window.frame, title: window.title,
                        inSight: onScreen.contains(window.id) && Parking.isInSight(window.frame, on: screens)
                    ),
                    element: window.element
                )
            }
        }
        if !scan.silent.isEmpty {
            Log.windows.failure("did not answer, windows left as they are: \(scan.silent.joined(separator: ", "))")
        }

        let owners = WindowList.everyOwner()
        let now = Date()
        homes.retire(now: now) { window, pid in owners[window] == pid }
        for adoption in homes.adopt(scan.all.map(\.live), now: now) {
            Log.windows.line(
                "window \(adoption.window) recognised after its app restarted (same \(adoption.matchedOn)):"
                    + " it lives in \(adoption.homeName)"
            )
        }
        watch(pids)
        return scan
    }

    func home(of window: CGWindowID) -> UUID? {
        homes.home(of: window, among: places)
    }

    /// Windows that live in a workspace other than `active`: left out of its
    /// snapshot, its stack and its layout.
    func windowsElsewhere(than active: UUID?) -> Set<CGWindowID> {
        homes.elsewhere(than: active, among: places)
    }

    // MARK: - The two ends of a switch

    /// The workspace being left takes the windows in sight that have no home.
    func claim(for workspace: Workspace, scan: Scan) {
        let taken = homes.claim(scan.all.map(\.live), for: place(workspace), among: places, now: Date())
        for window in taken {
            Log.windows.line("\(workspace.name) takes window \(window.id) of \(window.bundleId): it was opened or left there")
        }
        save()
    }

    /// Puts the per-window apps' windows where `workspace` wants them: its own
    /// back where they were, the others' in a corner. Only for apps the
    /// workspace lists — one it doesn't is hidden whole by the switch, and its
    /// windows are not touched.
    ///
    /// - Parameter stack: the workspace's remembered order, to pick which of
    ///   an app's windows becomes its main one.
    @discardableResult
    func arrange(for workspace: Workspace, scan: Scan, preferring stack: [CGWindowID] = []) -> Arranged {
        let places = places
        let screens = Self.screens()
        let listed = Set(workspace.apps.map(\.bundleId))
        var result = Arranged()

        for (pid, windows) in scan.windows {
            guard let bundleId = windows.first?.live.bundleId, listed.contains(bundleId) else { continue }
            var here: [Found] = []
            for window in windows {
                let id = window.live.id
                switch homes.wanted(id, active: workspace.id, among: places) {
                case .parked:
                    if let at = homes.record(of: id)?.parkedAt, Parking.near(at, window.live.frame.origin) { continue }
                    if park(id, window.element, from: window.live.frame, screens: screens) {
                        result.parked += 1
                    } else {
                        result.failed += 1
                    }
                case .shown:
                    here.append(window)
                    guard homes.record(of: id)?.parkedAt != nil else { continue }
                    if Parking.isInSight(window.live.frame, on: screens) {
                        // Already back by some other hand (dragged out of its
                        // corner, or moved by macOS after a display change).
                        homes.unparked(id)
                    } else if show(id, window.element, size: window.live.frame.size, screens: screens) {
                        result.shown += 1
                    } else {
                        result.failed += 1
                    }
                case .free:
                    here.append(window)
                    // Not one we know, and sitting in a corner: its app quit
                    // with it parked and brought it back where it was.
                    if !Parking.isInSight(window.live.frame, on: screens), homes.leftParkedWindows(of: bundleId) {
                        let to = Parking.comeBack(to: nil, size: window.live.frame.size, on: screens)
                        AX.setPosition(window.element, toAX: to)
                        Log.windows.line("window \(id) of \(bundleId) came back from a restart in a corner and matched nothing: put on the main display")
                    }
                }
            }
            // With its main window in a corner, the app would take focus
            // there on the next Cmd-Tab — and the workspace would follow it.
            if let main = AX.mainWindowID(pid: pid),
               windows.contains(where: { $0.live.id == main }),
               !here.contains(where: { $0.live.id == main }),
               let best = stack.lazy.compactMap({ id in here.first { $0.live.id == id } }).first ?? here.first {
                AX.makeMain(best.element)
            }
        }
        save()
        return result
    }

    /// The check after a switch: anything of a per-window app that is in sight
    /// and lives elsewhere is parked again, anything that lives here and is
    /// still in its corner is brought back again.
    func verify(_ workspace: Workspace, windows: [WindowRef]) -> (strays: Int, stillParked: Int) {
        let places = places
        let screens = Self.screens()
        var wrong: [(window: WindowRef, park: Bool)] = []
        for window in windows {
            guard let record = homes.record(of: window.id) else { continue }
            let inSight = Parking.isInSight(window.bounds, on: screens)
            switch homes.wanted(window.id, active: workspace.id, among: places) {
            case .parked where inSight:
                wrong.append((window, true))
            case .shown where !inSight && record.parkedAt != nil:
                wrong.append((window, false))
            default:
                break
            }
        }
        guard !wrong.isEmpty else { return (0, 0) }

        var elements: [pid_t: [CGWindowID: AXUIElement]] = [:]
        var strays = 0
        var stillParked = 0
        for (window, shouldPark) in wrong {
            if elements[window.pid] == nil {
                elements[window.pid] = AX.windowsByID(pid: window.pid, among: windows) ?? [:]
            }
            guard let element = elements[window.pid]?[window.id] else { continue }
            if shouldPark {
                strays += 1
                park(window.id, element, from: window.bounds, screens: screens)
            } else {
                stillParked += 1
                show(window.id, element, size: window.bounds.size, screens: screens)
            }
        }
        save()
        return (strays, stillParked)
    }

    // MARK: - By hand

    /// The focused window of `app`, if it is one this could place.
    func focusedWindow(of app: NSRunningApplication) -> Found? {
        guard let bundleId = app.bundleIdentifier,
              let id = AX.focusedWindowID(pid: app.processIdentifier),
              let window = AX.ownWindows(pid: app.processIdentifier)?.first(where: { $0.id == id })
        else { return nil }
        let live = LiveWindow(
            id: id, pid: app.processIdentifier, bundleId: bundleId, frame: window.frame, title: window.title,
            inSight: Parking.isInSight(window.frame, on: Self.screens())
        )
        return Found(live: live, element: window.element)
    }

    /// Sends a window to live in `target`. When that is not the workspace on
    /// screen, the window leaves for its corner at once.
    func move(_ window: Found, to target: Workspace, active: UUID?) {
        homes.assign(window.live, to: place(target), now: Date())
        let screens = Self.screens()
        if let active, target.id != active {
            park(window.live.id, window.element, from: window.live.frame, screens: screens)
        } else if homes.record(of: window.live.id)?.parkedAt != nil {
            // Sent to the workspace on screen from its corner: it comes out.
            show(window.live.id, window.element, size: window.live.frame.size, screens: screens)
        }
        save()
    }

    /// Makes one of `app`'s windows that lives in `workspace` its main one and
    /// raises it. False when it has none here.
    @discardableResult
    func putHomeWindowForward(of app: NSRunningApplication, in workspace: Workspace, preferring stack: [CGWindowID] = []) -> Bool {
        guard let windows = AX.ownWindows(pid: app.processIdentifier) else { return false }
        let places = places
        let here = windows.filter { homes.wanted($0.id, active: workspace.id, among: places) != .parked }
        guard let best = stack.lazy.compactMap({ id in here.first { $0.id == id } }).first ?? here.first else { return false }
        AX.makeMain(best.element)
        AX.raise(best.element)
        return true
    }

    /// Brings every parked window back to where it was.
    ///
    /// When no workspace is active nothing says a window should be out of the
    /// way: at launch, on quitting (a parked window must not outlive the app
    /// that parked it), after a display change that landed nowhere, and from
    /// the menu. The homes are kept, so the next switch parks again.
    func releaseAll(because why: String) {
        release(homes.records.filter { $0.parkedAt != nil }, because: why)
    }

    private func release(_ records: [WindowHomes.Record], because why: String) {
        guard !records.isEmpty else { return }
        guard AccessibilityPermission.isGranted else {
            Log.windows.failure("\(records.count) parked window(s) cannot be brought back (\(why)): Accessibility is not granted")
            return
        }
        let screens = Self.screens()
        var back = 0
        var lost = 0
        for (pid, group) in Dictionary(grouping: records, by: \.pid) {
            guard let windows = AX.ownWindows(pid: pid) else {
                lost += group.count
                continue
            }
            for record in group {
                guard let window = windows.first(where: { $0.id == record.window }) else {
                    lost += 1
                    continue
                }
                if show(record.window, window.element, size: window.frame.size, screens: screens) { back += 1 } else { lost += 1 }
            }
        }
        if lost == 0 {
            Log.windows.line("\(back) parked window(s) brought back (\(why))")
        } else {
            Log.windows.failure("\(back) parked window(s) brought back, \(lost) could not be reached (\(why))")
        }
        save()
    }

    /// The config changed. An app taken off the list gets its windows back
    /// and is forgotten; the watchers follow the list.
    func reconcile() {
        let scoped = scopedIDs
        let dropped = homes.records.filter { !scoped.contains($0.bundleId) && $0.parkedAt != nil }
        release(dropped, because: "the app is no longer per-window")
        _ = homes.forget(keeping: scoped)
        if scoped.isEmpty { watch([]) }
        save()
    }

    // MARK: - Moving

    /// Parks one window and says whether it left. Where it landed is read
    /// back, because the system decides that, not the request.
    @discardableResult
    private func park(_ id: CGWindowID, _ element: AXUIElement, from frame: CGRect, screens: [CGRect]) -> Bool {
        guard let spot = Parking.spot(for: frame, on: screens) else { return false }
        AX.setPosition(element, toAX: spot.ask)
        guard let landed = AX.axFrame(of: element), !Parking.isInSight(landed, on: screens) else {
            Log.windows.failure("window \(id) would not leave for its corner (asked for \(Self.point(spot.ask)))")
            return false
        }
        homes.parked(id, at: landed.origin, from: Parking.isInSight(frame, on: screens) ? frame : nil)
        return true
    }

    @discardableResult
    private func show(_ id: CGWindowID, _ element: AXUIElement, size: CGSize, screens: [CGRect]) -> Bool {
        let to = Parking.comeBack(to: homes.record(of: id)?.shown, size: size, on: screens)
        AX.setPosition(element, toAX: to)
        guard let landed = AX.axFrame(of: element), Parking.isInSight(landed, on: screens) else {
            Log.windows.failure("window \(id) would not come back from its corner (asked for \(Self.point(to)))")
            return false
        }
        homes.unparked(id)
        return true
    }

    // MARK: - Watching the focused window

    /// Cmd-` moves focus between an app's windows without any app coming
    /// forward, so no activation is posted. An Accessibility observer on each
    /// running per-window app (and on nothing else) tells us instead.
    private func watch(_ pids: Set<pid_t>) {
        for (pid, observer) in observers where !pids.contains(pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
            observers[pid] = nil
        }
        for pid in pids where observers[pid] == nil {
            var created: AXObserver?
            guard AXObserverCreate(pid, focusedWindowChanged, &created) == .success, let observer = created else { continue }
            let app = AXUIElementCreateApplication(pid)
            let context = Unmanaged.passUnretained(self).toOpaque()
            // An app still starting up refuses this; the next switch tries again.
            guard AXObserverAddNotification(observer, app, kAXFocusedWindowChangedNotification as CFString, context) == .success
            else { continue }
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
            observers[pid] = observer
        }
    }

    fileprivate func focusedWindowDidChange() {
        onFocusedWindowChange?()
    }

    // MARK: - State file

    /// What is saved: the homes, and the boot they belong to. Window ids start
    /// over at login, so a file from an earlier boot describes windows that
    /// are all gone — its records become orphans, to be matched by title and
    /// frame like any app restart.
    private struct Saved: Codable {
        var boot: Int
        var homes: WindowHomes
    }

    private static func bootTime() -> Int {
        var time = timeval()
        var size = MemoryLayout<timeval>.stride
        var name: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&name, 2, &time, &size, nil, 0) == 0 else { return 0 }
        return Int(time.tv_sec)
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.stateFile) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let saved = try? decoder.decode(Saved.self, from: data) else {
            Log.windows.failure("could not read \(Self.stateFile.path): starting with no window homes")
            return
        }
        homes = saved.homes
        written = saved.homes
        if saved.boot != Self.bootTime() {
            homes.retireAll(now: Date())
        }
    }

    private func save() {
        guard homes != written else { return }
        written = homes
        do {
            try FileManager.default.createDirectory(at: ConfigStore.configDir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(Saved(boot: Self.bootTime(), homes: homes)).write(to: Self.stateFile, options: .atomic)
        } catch {
            Log.windows.failure("could not save window homes: \(error.localizedDescription)")
        }
    }

    // MARK: - Words

    /// Windows are named by id and app in the log, never by title: the log is
    /// kept on disk for days and a title is whatever page was open.
    private static func point(_ point: CGPoint) -> String {
        "\(Int(point.x)), \(Int(point.y))"
    }
}

/// A C callback cannot capture, so the scope comes in through the context.
private func focusedWindowChanged(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    Unmanaged<WindowScope>.fromOpaque(context).takeUnretainedValue().focusedWindowDidChange()
}
