import Foundation
import IOKit
import IOKit.pwr_mgt
import os
import SleepGuardKit

// Tile Bandit's privileged helper: the one part that runs as root.
//
// It does one thing — `pmset disablesleep`, the switch behind every
// "stay awake with the lid closed" tool on Apple silicon, which only root may
// flip — and it is built around putting that switch *back*:
//
//   - sleep is off only while a caller holds a connection open and the Mac is
//     on the charger. Both are checked here, not by the caller: the helper
//     watches the power source itself, so an app that has hung can't keep a
//     Mac awake on battery.
//   - the caller quitting, crashing or being killed closes its connection,
//     and that is the release.
//   - before sleep is switched off a note is left on disk. Whenever the
//     helper starts — launchd runs it at boot, restarts it if it dies, and
//     starts it for any caller — a note with nobody holding means a run that
//     ended badly, and sleep is put back before anything else happens.
//
// It takes two messages, neither with an argument (SleepGuardXPC), and only
// from Tile Bandit signed by the same team that signed this binary.

let log = Logger(subsystem: "com.twonary.TileBandit", category: "sleepguard")

func note(_ text: String) {
    log.notice("\(text, privacy: .public)")
}

// MARK: - The machine

/// Everything the helper reads from or does to the Mac. A protocol so that a
/// debug build can be pointed at a scratch folder and exercised without root
/// (see `FakeMachine`); a release build has `RealMachine` and nothing else.
protocol Machine {
    var onExternalPower: Bool { get }
    var sleepDisabled: Bool { get }
    var lidClosed: Bool { get }
    var lidCausesSleep: Bool { get }
    /// The note that says the helper switched sleep off.
    var markerPath: String { get }
    /// Returns whether the kernel now says what was asked.
    func setSleepDisabled(_ disabled: Bool) -> Bool
    func sleepNow()
}

struct RealMachine: Machine {
    var onExternalPower: Bool { Power.onExternalPower }
    var sleepDisabled: Bool { Power.sleepDisabled }
    var lidClosed: Bool { Power.lidClosed ?? false }
    var lidCausesSleep: Bool { Power.lidCausesSleep }
    let markerPath = "/var/db/com.twonary.TileBandit.SleepGuard.active"

    /// `/usr/bin/pmset -a disablesleep 0|1` — fixed path, fixed arguments,
    /// empty environment; nothing in the command comes from a caller.
    ///
    /// pmset only writes the preference and tells powerd, which sets the
    /// kernel flag a moment later, so success is the flag reading back as
    /// asked and not pmset's exit status alone.
    func setSleepDisabled(_ disabled: Bool) -> Bool {
        let pmset = Process()
        pmset.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        pmset.arguments = ["-a", "disablesleep", disabled ? "1" : "0"]
        pmset.environment = [:]
        pmset.standardInput = FileHandle.nullDevice
        pmset.standardOutput = FileHandle.nullDevice
        pmset.standardError = FileHandle.nullDevice
        do {
            try pmset.run()
        } catch {
            note("pmset did not start: \(error.localizedDescription)")
            return false
        }
        pmset.waitUntilExit()
        guard pmset.terminationStatus == 0 else {
            note("pmset exited \(pmset.terminationStatus)")
            return false
        }
        let deadline = Date().addingTimeInterval(3)
        while Power.sleepDisabled != disabled, Date() < deadline {
            usleep(50_000)
        }
        return Power.sleepDisabled == disabled
    }

    func sleepNow() {
        let port = IOPMFindPowerManagement(mach_port_t(MACH_PORT_NULL))
        guard port != MACH_PORT_NULL else { return }
        let result = IOPMSleepSystem(port)
        IOServiceClose(port)
        if result != kIOReturnSuccess { note("sleep request refused (\(result))") }
    }
}

#if DEBUG
/// A stand-in machine made of files in a folder, for running the helper as
/// an ordinary user under a user launchd agent: `ac`, `sleepdisabled`, `lid`
/// and `lidsleeps` hold 0 or 1, and `slept` is appended to instead of sleeping.
/// Compiled into debug builds only.
struct FakeMachine: Machine {
    let directory: String

    private func flag(_ name: String) -> Bool {
        let text = try? String(contentsOfFile: "\(directory)/\(name)", encoding: .utf8)
        return text?.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    var onExternalPower: Bool { flag("ac") }
    var sleepDisabled: Bool { flag("sleepdisabled") }
    var lidClosed: Bool { flag("lid") }
    var lidCausesSleep: Bool { flag("lidsleeps") }
    var markerPath: String { "\(directory)/marker" }

    func setSleepDisabled(_ disabled: Bool) -> Bool {
        if flag("refuse") { return false }
        return (try? (disabled ? "1" : "0").write(toFile: "\(directory)/sleepdisabled", atomically: true, encoding: .utf8)) != nil
    }

    func sleepNow() {
        let path = "\(directory)/slept"
        let old = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        try? (old + "sleep\n").write(toFile: path, atomically: true, encoding: .utf8)
    }
}
#endif

// MARK: - The keeper

/// One per connection: the object a caller's message lands on, so the keeper
/// knows *which* connection asked and can let go when that one closes.
final class Session: NSObject, SleepGuardXPC {
    let id = UUID()
    private weak var keeper: Keeper?

    init(keeper: Keeper) {
        self.keeper = keeper
    }

    func hold(reply: @escaping (Bool) -> Void) {
        let id = id
        DispatchQueue.main.async { [keeper] in
            guard let keeper else { return reply(false) }
            keeper.hold(id)
            reply(true)
        }
    }

    func check(reply: @escaping (Bool) -> Void) {
        DispatchQueue.main.async { [keeper] in
            guard let keeper else { return reply(false) }
            keeper.evaluate("asked to check")
            reply(keeper.ours)
        }
    }
}

final class Keeper: NSObject, NSXPCListenerDelegate {
    private let machine: Machine
    /// How often the state is looked at again while something is held, in
    /// case a power notification was missed.
    private let watchInterval: TimeInterval
    private var connections = Set<UUID>()
    private var holders = Set<UUID>()
    private var powerWatcher: Power.Watcher?
    private var watchdog: Timer?
    private var idleExit: DispatchWorkItem?
    private var sleepCheck: DispatchWorkItem?

    init(machine: Machine, watchInterval: TimeInterval) {
        self.machine = machine
        self.watchInterval = watchInterval
    }

    var ours: Bool { FileManager.default.fileExists(atPath: machine.markerPath) }

    func start() {
        // A note with nobody holding: the last run ended without putting
        // sleep back (power loss, a kill). Do it now.
        if ours { note("found a note from an earlier run; putting sleep back") }
        evaluate("start")

        powerWatcher = Power.Watcher { [weak self] in self?.evaluate("power source changed") }
        watchdog = Timer.scheduledTimer(withTimeInterval: watchInterval, repeats: true) { [weak self] _ in
            self?.evaluate("check")
        }
        scheduleIdleExit()
    }

    // MARK: Connections

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let session = Session(keeper: self)
        let id = session.id
        connection.exportedInterface = NSXPCInterface(with: SleepGuardXPC.self)
        connection.exportedObject = session
        let closed: () -> Void = { [weak self] in
            DispatchQueue.main.async { self?.closed(id) }
        }
        connection.invalidationHandler = closed
        connection.interruptionHandler = closed
        DispatchQueue.main.async {
            self.connections.insert(id)
            self.idleExit?.cancel()
        }
        connection.resume()
        return true
    }

    func hold(_ id: UUID) {
        // A message can only arrive on a live connection, but its close may
        // already be queued ahead of it; a hold with no connection behind it
        // would never be let go.
        guard connections.contains(id) else { return }
        if holders.insert(id).inserted { note("hold taken (\(holders.count) holding)") }
        evaluate("hold")
    }

    private func closed(_ id: UUID) {
        connections.remove(id)
        if holders.remove(id) != nil { note("hold released (\(holders.count) holding)") }
        evaluate("connection closed")
        scheduleIdleExit()
    }

    // MARK: The one decision

    /// Reads the machine and brings the setting in line. Safe to call at any
    /// time and as often as anything changes — it acts only on a difference.
    @discardableResult
    func evaluate(_ reason: String, mayAskForSleep: Bool = true) -> Bool {
        let onPower = machine.onExternalPower
        let action = SleepGuardPolicy.action(
            held: !holders.isEmpty,
            onExternalPower: onPower,
            sleepDisabled: machine.sleepDisabled,
            ours: ours
        )
        switch action {
        case .none:
            return true

        case .disable, .adopt:
            // The note goes down first: a crash between the two steps then
            // leaves a note with sleep still on, which costs nothing, and
            // never sleep off with no note.
            guard FileManager.default.createFile(atPath: machine.markerPath, contents: Data(), attributes: [.posixPermissions: 0o600]) else {
                note("\(reason): could not leave the note; sleep left alone")
                return false
            }
            if action == .adopt {
                note("\(reason): sleep was already off; it will be put back when the hold ends")
                return true
            }
            let done = machine.setSleepDisabled(true)
            note("\(reason): on power and held → sleep off \(done ? "(confirmed)" : "FAILED")")
            if !done {
                // Whatever state that left, don't keep a claim on it.
                _ = machine.setSleepDisabled(false)
                if !machine.sleepDisabled { try? FileManager.default.removeItem(atPath: machine.markerPath) }
            }
            return done

        case .restore:
            let why = holders.isEmpty ? "nothing holding" : "off the charger"
            let done = !machine.sleepDisabled || machine.setSleepDisabled(false)
            note("\(reason): \(why) → sleep back on \(done ? "(confirmed)" : "FAILED — will try again")")
            guard done else { return false }
            try? FileManager.default.removeItem(atPath: machine.markerPath)
            if mayAskForSleep { scheduleSleepCheck() }
            return true
        }
    }

    /// Sleep is allowed again; whether the Mac should be *asleep* is asked a
    /// moment later rather than on the spot. A caller whose helper died and
    /// came back takes its hold again within half a second, and a charger
    /// being reseated is back as quickly — neither should find the Mac
    /// already going down.
    private func scheduleSleepCheck() {
        sleepCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.sleepCheck = nil
            let onPower = self.machine.onExternalPower
            guard !self.machine.sleepDisabled, self.holders.isEmpty || !onPower else { return }
            if SleepGuardPolicy.shouldSleepNow(
                lidClosed: self.machine.lidClosed,
                lidCausesSleep: self.machine.lidCausesSleep,
                onExternalPower: onPower
            ) {
                note("lid is closed and macOS would be asleep → sleeping now")
                self.machine.sleepNow()
            }
        }
        sleepCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    // MARK: Leaving

    /// With no caller there is nothing to watch, so the helper exits and
    /// launchd starts it again when someone connects. It only ever leaves
    /// with sleep back on: a failed restore exits non-zero, which is what
    /// makes launchd run it — and the restore — again.
    private func scheduleIdleExit() {
        idleExit?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.connections.isEmpty else { return }
            let clean = self.evaluate("idle") && !self.ours
            // A sleep check still to come is part of the job; wait for it.
            guard self.sleepCheck == nil else { return self.scheduleIdleExit() }
            exit(clean ? 0 : 1)
        }
        idleExit = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    /// SIGTERM: a shutdown, a logout of the last user, or the background item
    /// being switched off in System Settings. Sleep goes back on, but the Mac
    /// isn't sent to sleep on top of whatever is taking the helper down.
    func terminate() {
        holders.removeAll()
        let clean = evaluate("terminating", mayAskForSleep: false) && !ours
        exit(clean ? 0 : 1)
    }
}

// MARK: - Start

var machine: Machine = RealMachine()
var serviceName = SleepGuard.label
var watchInterval: TimeInterval = 10

#if DEBUG
if let directory = ProcessInfo.processInfo.environment["SLEEPGUARD_FAKE_MACHINE"] {
    machine = FakeMachine(directory: directory)
    serviceName = ProcessInfo.processInfo.environment["SLEEPGUARD_SERVICE"] ?? serviceName
    watchInterval = 0.5
    note("DEBUG build on a fake machine at \(directory)")
}
#endif

if machine is RealMachine, geteuid() != 0 {
    note("not running as root; nothing to do")
    exit(0)
}

let keeper = Keeper(machine: machine, watchInterval: watchInterval)

signal(SIGTERM, SIG_IGN)
let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termination.setEventHandler { keeper.terminate() }
termination.resume()

keeper.start()

// Only Tile Bandit, and only the one signed by whoever signed this helper.
// Unsigned or ad-hoc signed there is no team to ask for, so nobody is let in;
// the start-up restore above has still run.
if let team = SleepGuard.ownTeamID(),
   let requirement = SleepGuard.requirement(identifier: SleepGuard.appIdentifier, team: team) {
    let listener = NSXPCListener(machServiceName: serviceName)
    listener.setConnectionCodeSigningRequirement(requirement)
    listener.delegate = keeper
    listener.resume()
    note("listening for \(SleepGuard.appIdentifier) signed by team \(team)")
    withExtendedLifetime(listener) { RunLoop.main.run() }
} else {
    note("no signing team on this build; taking no connections")
    RunLoop.main.run()
}
