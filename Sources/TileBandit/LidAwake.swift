import AppKit
import ServiceManagement
import SleepGuardKit

/// Stay Awake with Lid Closed (on Power): the Mac keeps running with the lid
/// shut and no display attached, for as long as the charger is in.
///
/// Caffeinate can't do this — no power assertion an ordinary process may take
/// survives the lid closing. What does is `pmset disablesleep`, the switch
/// Amphetamine's closed-display mode comes down to on Apple silicon, and only
/// root may flip it. So this is the one feature with a privileged helper
/// behind it (`TileBanditSleepGuard`, registered through `SMAppService` and
/// allowed once in System Settings), and this class is deliberately the thin
/// end: it opens a connection to the helper and keeps it open. The rules that
/// matter — only on the charger, back to normal the moment the connection
/// closes — are enforced by the helper, where an app that hangs or dies can't
/// get them wrong.
///
/// Session-only like Caffeinate, and for the same reason turned inside out:
/// here the setting does *not* die with the process, so nothing that outlives
/// one run should be asking for it.
///
/// What the menu shows is read from the machine (`Power`), never from what
/// was asked for.
final class LidAwake {
    enum Availability {
        case available
        /// A Mac with no lid has no use for it; the menu leaves it out.
        case noLid
        /// `swift run`, or a bundle that isn't signed by a team: macOS won't
        /// register a helper for it, and the helper lets nobody in.
        case needsSignedApp
    }

    /// What the menu needs to draw the toggle — see `StatusMenu`.
    struct MenuState {
        var isOn = false
        /// The line under the toggle, when there is something to say.
        var detail: String?
        /// The detail line opens Login Items when clicked.
        var detailOpensLoginItems = false
        /// Set when the toggle can't be used at all.
        var disabledReason: String?
    }

    enum StartResult {
        case started
        /// The helper is registered and waiting for the user to allow it.
        case needsApproval
        case failed(String)
        case unavailable
    }

    let availability: Availability
    /// Called on the main queue when what the menu shows has changed.
    var onChange: (() -> Void)?

    private let team: String?
    private lazy var service = SMAppService.daemon(plistName: SleepGuard.plistName)
    private var client: SleepGuardClient?
    private var wanted = false
    private var needsApproval = false
    private var failure: String?
    private var powerWatcher: Power.Watcher?
    private var ticker: Timer?
    private var approvalDeadline: Date?
    private var lastShown: String?

    init() {
        team = SleepGuard.ownTeamID()
        if !Power.hasLid {
            availability = .noLid
        } else if Bundle.main.bundleURL.pathExtension == "app", team != nil {
            availability = .available
        } else {
            availability = .needsSignedApp
        }
    }

    var isOn: Bool { wanted }

    /// Sleep is off at this moment, by this toggle: on the charger, the helper
    /// holding, and the kernel saying so. What the menu bar indicator follows —
    /// it is gone the moment any of the three stops being true.
    var isHolding: Bool { availability == .available && status.holdsSleepOff }

    var status: LidAwakeStatus {
        LidAwakeStatus.resolve(
            wanted: wanted,
            acknowledged: client?.acknowledged ?? false,
            onExternalPower: Power.onExternalPower,
            sleepDisabled: Power.sleepDisabled
        )
    }

    /// nil on a Mac with no lid.
    var menuState: MenuState? {
        switch availability {
        case .noLid:
            return nil
        case .needsSignedApp:
            return MenuState(disabledReason: "Needs the installed, signed Tile Bandit — it runs a helper macOS only registers for a signed app.")
        case .available:
            break
        }
        var state = MenuState(isOn: wanted)
        if needsApproval {
            state.detail = "Allow the helper in Login Items…"
            state.detailOpensLoginItems = true
        } else if let failure {
            state.detail = "Stopped — \(failure)"
        } else {
            switch status {
            case .off: break
            case .starting: state.detail = "Starting…"
            case .active: state.detail = "On — close the lid, keep the charger in"
            case .waitingForPower: state.detail = "On battery — sleeps as usual until the charger is back"
            case .notApplied: state.detail = "Not in effect — sleep could not be switched off"
            }
        }
        return state
    }

    // MARK: On and off

    @discardableResult
    func start() -> StartResult {
        guard availability == .available else { return .unavailable }
        guard !wanted else { return .started }
        failure = nil

        if service.status != .enabled {
            if service.status != .requiresApproval {
                // Throws for a daemon that still needs allowing, too; the
                // status afterwards is what says which it was.
                do {
                    try service.register()
                } catch {
                    Log.power.line("lid-awake: registering the helper: \(error.localizedDescription)")
                }
            }
            switch service.status {
            case .enabled:
                break
            case .requiresApproval:
                needsApproval = true
                waitForApproval()
                changed()
                return .needsApproval
            default:
                failure = "macOS did not register the helper"
                changed()
                return .failed(failure ?? "")
            }
        }

        needsApproval = false
        approvalDeadline = nil
        wanted = true
        let helper = team.flatMap { SleepGuard.requirement(identifier: SleepGuard.label, team: $0) }
        let client = SleepGuardClient(helperRequirement: helper)
        client.onChange = { [weak self] in self?.clientChanged() }
        self.client = client
        client.hold()

        powerWatcher = Power.Watcher { [weak self] in self?.powerChanged() }
        startTicker()
        changed()
        return .started
    }

    func stop() {
        wanted = false
        needsApproval = false
        approvalDeadline = nil
        failure = nil
        client?.release()
        client = nil
        powerWatcher = nil
        ticker?.invalidate()
        ticker = nil
        changed()
        // The helper puts sleep back within a moment of the connection
        // closing; look once more so the log says whether it did.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, !self.wanted else { return }
            if Power.sleepDisabled {
                Log.power.failure("lid-awake: switched off, but sleep is still disabled (pmset -g shows SleepDisabled)")
            }
        }
    }

    /// A previous run that died with the hold in place is the helper's to
    /// clean up, and it does so the moment that run's connection closes — or,
    /// had the helper died as well, when launchd next starts it. This is the
    /// belt to those braces: sleep found disabled at launch, with nothing of
    /// ours asking for it, gets the helper woken so that its start-up check
    /// runs now rather than at the next boot. A `disablesleep` the user set by
    /// hand carries no note of ours and is left exactly as it is.
    func recoverAtLaunch() {
        guard availability == .available, Power.sleepDisabled else { return }
        guard service.status == .enabled else { return }
        Log.power.line("lid-awake: sleep is disabled at launch; waking the helper to check whether that is left over")
        let connection = NSXPCConnection(machServiceName: SleepGuard.label, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: SleepGuardXPC.self)
        connection.resume()
        // Any message starts the helper, and starting is when it looks for a
        // note left by a run that died. `check` asks for nothing else.
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            Log.power.failure("lid-awake: the helper did not answer — \(error.localizedDescription)")
            connection.invalidate()
        } as? SleepGuardXPC
        proxy?.check { _ in
            connection.invalidate()
            Log.power.line("lid-awake: after the check, sleep is \(Power.sleepDisabled ? "still disabled, and not by Tile Bandit" : "back on")")
        }
    }

    static func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }

    // MARK: Keeping up

    private func clientChanged() {
        guard wanted, let client else { return }
        if let reason = client.failure {
            // The helper can't be reached. Whatever it was holding it has let
            // go of — its hold is the connection — so the toggle goes off
            // rather than claim something nobody is doing.
            Log.power.failure("lid-awake: gave up — \(reason)")
            stop()
            failure = reason
        }
        changed()
    }

    /// The helper hears about the charger at the same moment and acts on its
    /// own; this only brings the menu up to date, once now and again after
    /// the helper has had time to flip the switch.
    private func powerChanged() {
        changed()
        for delay in [1.5, 4.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.changed() }
        }
    }

    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.changed()
            self.restPanelUnderLid()
        }
    }

    /// With sleep refused, closing the lid doesn't switch the built-in panel
    /// off the way sleeping would have, and a lit panel folded against the
    /// keyboard is heat and wear for nothing. So while the lid is shut and
    /// the built-in panel is the only display, it is put to sleep — and again
    /// if a stray mouse nudge wakes it. Needs no privilege.
    private func restPanelUnderLid() {
        guard wanted, Power.lidClosed == true, Power.sleepDisabled else { return }
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success, count > 0 else { return }
        let online = ids.prefix(Int(count))
        guard online.allSatisfy({ CGDisplayIsBuiltin($0) != 0 }),
              online.contains(where: { CGDisplayIsAsleep($0) == 0 })
        else { return }
        Log.power.line("lid-awake: lid closed with no other display → putting the built-in panel to sleep")
        let pmset = Process()
        pmset.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        pmset.arguments = ["displaysleepnow"]
        pmset.standardOutput = FileHandle.nullDevice
        pmset.standardError = FileHandle.nullDevice
        try? pmset.run()
    }

    /// Allowing the helper happens in System Settings, out of our sight. The
    /// user asked for the toggle, so once macOS says yes it switches on by
    /// itself rather than needing a second click — for a few minutes; after
    /// that the next click checks again.
    private func waitForApproval() {
        approvalDeadline = Date().addingTimeInterval(300)
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard let self, self.needsApproval, let deadline = self.approvalDeadline, Date() < deadline else {
                timer.invalidate()
                return
            }
            if self.service.status == .enabled {
                timer.invalidate()
                Log.power.line("lid-awake: the helper was allowed")
                self.needsApproval = false
                self.start()
            }
        }
    }

    /// Tells the menu, and the log, only when what's shown is different.
    private func changed() {
        let state = menuState
        let shown = "\(state?.isOn ?? false)|\(state?.detail ?? "")|\(isHolding)"
        guard shown != lastShown else { return }
        lastShown = shown
        Log.power.line("lid-awake: toggle \(wanted ? "on" : "off")\(state?.detail.map { " · \($0)" } ?? "") [power=\(Power.onExternalPower ? "charger" : "battery") sleepDisabled=\(Power.sleepDisabled) lidClosed=\(Power.lidClosed ?? false)]")
        onChange?()
    }
}
