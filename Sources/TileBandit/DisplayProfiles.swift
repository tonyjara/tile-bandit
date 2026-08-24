import AppKit
import CoreGraphics

/// Identity and naming for the attached displays.
///
/// Permission-free, like everything outside LayoutEngine/SnapManager: NSScreen
/// and the CGDisplay* metadata functions need no TCC grant.
enum DisplayIdentity {
    /// What we call the laptop panel. AppKit's own `localizedName` for it is
    /// "Built-in Retina Display", which reads badly inside a profile name.
    static let builtInName = "MacBook"

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        let value = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return CGDirectDisplayID(value?.uint32Value ?? 0)
    }

    static func isBuiltIn(_ id: CGDirectDisplayID) -> Bool {
        id != 0 && CGDisplayIsBuiltin(id) != 0
    }

    /// Stable key for one screen — see DisplayRef for why it isn't the display ID.
    static func key(for screen: NSScreen) -> String {
        let id = displayID(of: screen)
        if isBuiltIn(id) { return builtInKey }
        let vendor = CGDisplayVendorNumber(id)
        let model = CGDisplayModelNumber(id)
        let serial = CGDisplaySerialNumber(id)
        if vendor != 0 || model != 0 {
            return "edid:\(vendor)-\(model)-\(serial)"
        }
        return "name:\(screen.localizedName)"
    }

    static func name(for screen: NSScreen) -> String {
        isBuiltIn(displayID(of: screen)) ? builtInName : screen.localizedName
    }

    static let builtInKey = "builtin"

    /// The attached displays as a fingerprint.
    ///
    /// Sorted by key so rearranging displays in System Settings — or macOS
    /// handing them back in a different order after a wake — doesn't look like
    /// a new setup. Two identical panels that report no serial would collide on
    /// one key, so repeats get a "#n" suffix; that keeps *how many* displays
    /// are attached part of the identity.
    static func snapshot() -> [DisplayRef] {
        var counts: [String: Int] = [:]
        var refs: [DisplayRef] = []
        for screen in NSScreen.screens {
            let base = key(for: screen)
            let count = (counts[base] ?? 0) + 1
            counts[base] = count
            refs.append(DisplayRef(key: count == 1 ? base : "\(base)#\(count)", name: name(for: screen)))
        }
        return refs.sorted { $0.key < $1.key }
    }

    /// Name a setup from what's plugged in: "MacBook", "MacBook + M14",
    /// "Studio Display" (lid closed). The built-in panel always leads.
    static func inferredName(for displays: [DisplayRef]) -> String {
        guard !displays.isEmpty else { return "No Displays" }
        let externals = displays.filter { !$0.key.hasPrefix(builtInKey) }.map(\.name)
        guard !externals.isEmpty else { return builtInName }
        let hasBuiltIn = displays.count > externals.count
        return ((hasBuiltIn ? [builtInName] : []) + externals).joined(separator: " + ")
    }
}

/// Keeps the display profile matching the attached screens live, creating
/// profiles for setups Tile Bandit hasn't seen before.
///
/// Detection is `NSApplication.didChangeScreenParametersNotification` plus
/// NSScreen metadata — no permission needed. macOS fires that notification
/// several times through a single connect/disconnect and reports zero screens
/// while the machine sleeps, so resolves are debounced and empty snapshots are
/// ignored (unplugging everything must not invent a profile).
final class DisplayProfileManager {
    /// Long enough to sit out the burst of notifications a single plug/unplug
    /// produces before reading the screens.
    private static let settleDelay: TimeInterval = 1.2
    /// Give up waiting for a stable read eventually, so a display that keeps
    /// flickering can't stall detection forever.
    private static let maxSettleAttempts = 5

    private let store: ConfigStore
    private var observer: NSObjectProtocol?
    private var pendingResolve: DispatchWorkItem?
    private var settleAttempts = 0

    /// Fired whenever the live profile changes, including the first resolve at
    /// launch. The handler owns re-registering hotkeys, rebuilding the menu and
    /// telling WorkspaceEngine to adopt the profile.
    var onActiveProfileChange: ((UUID) -> Void)?

    init(store: ConfigStore) {
        self.store = store
    }

    deinit {
        pendingResolve?.cancel()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Resolves once for the current setup, then follows display changes.
    func start() {
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.scheduleResolve() }
        resolve()
    }

    private func scheduleResolve() {
        pendingResolve?.cancel()
        let observed = DisplayIdentity.snapshot()
        let work = DispatchWorkItem { [weak self] in self?.resolveIfSettled(matching: observed) }
        pendingResolve = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay, execute: work)
    }

    /// Waking a Mac — or closing the lid onto a dock — brings displays up one at
    /// a time, and resolving a half-assembled setup would switch profiles twice,
    /// hiding apps for an arrangement that existed for a second. So only act
    /// once two reads a beat apart agree on what's attached.
    private func resolveIfSettled(matching observed: [DisplayRef]) {
        guard DisplayIdentity.snapshot() == observed || settleAttempts >= Self.maxSettleAttempts else {
            settleAttempts += 1
            scheduleResolve()
            return
        }
        resolve()
    }

    /// Matches the attached displays against the configured profiles and makes
    /// the winner active: an existing profile if the fingerprint is known, the
    /// unbound migration profile if there is one, otherwise a fresh profile
    /// cloned from the one that was live.
    func resolve() {
        pendingResolve?.cancel()
        settleAttempts = 0
        let displays = DisplayIdentity.snapshot()
        // Zero screens means asleep or mid-reconfiguration, not "a new setup
        // with no displays" — hold on to whatever profile is active.
        guard !displays.isEmpty else { return }
        let keys = Set(displays.map(\.key))

        let id: UUID
        if let index = store.config.profiles.firstIndex(where: { $0.displayKeys == keys }) {
            // Keep the stored names fresh — a monitor renamed in System
            // Settings shouldn't keep showing its old name in the menu.
            if store.config.profiles[index].displays != displays {
                store.config.profiles[index].displays = displays
            }
            id = store.config.profiles[index].id
        } else if store.config.profiles.count == 1, !store.config.profiles[0].isBound {
            // A lone unbound profile is a config that predates profiles (or one
            // hand-written without them): adopt it onto this setup so the
            // workspaces already in it survive the upgrade. Deliberately only
            // when it's the *only* profile — an unbound duplicate sitting
            // alongside others must never be silently claimed.
            store.config.profiles[0].displays = displays
            store.config.profiles[0].name = uniqueName(
                DisplayIdentity.inferredName(for: displays),
                excluding: store.config.profiles[0].id
            )
            id = store.config.profiles[0].id
        } else {
            let profile = DisplayProfile(
                name: uniqueName(DisplayIdentity.inferredName(for: displays)),
                displays: displays,
                // Seeded from the setup you were just on, so plugging in a
                // monitor never drops you into a profile with no workspaces
                // and no hotkeys. Fresh ids: the copies are this profile's
                // own from here on, free to have their own grids.
                workspaces: clonedWorkspaces(of: store.activeProfile ?? store.config.profiles.first)
            )
            store.config.profiles.append(profile)
            id = profile.id
        }

        guard store.activeProfileID != id else { return }
        store.activeProfileID = id
        onActiveProfileChange?(id)
    }

    /// Manual override from the menu — useful to set up a desk you're not
    /// sitting at. The next display change re-resolves and takes it back.
    func activate(_ id: UUID) {
        guard store.config.profiles.contains(where: { $0.id == id }), store.activeProfileID != id else { return }
        store.activeProfileID = id
        onActiveProfileChange?(id)
    }

    private func clonedWorkspaces(of profile: DisplayProfile?) -> [Workspace] {
        (profile?.workspaces ?? []).map { workspace in
            var copy = workspace
            copy.id = UUID()
            return copy
        }
    }

    private func uniqueName(_ name: String, excluding id: UUID? = nil) -> String {
        let taken = Set(store.config.profiles.filter { $0.id != id }.map(\.name))
        guard taken.contains(name) else { return name }
        var suffix = 2
        while taken.contains("\(name) (\(suffix))") { suffix += 1 }
        return "\(name) (\(suffix))"
    }
}
