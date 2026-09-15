import CoreGraphics
import Foundation
import IOKit
import IOKit.hid

/// What the key-modification engines should be doing right now, resolved from
/// the config and the attached keyboards.
///
/// Computing this in one place is what keeps the two halves agreeing: the
/// carrier key hidutil rewrites a dual-role key *to* is the same one the event
/// tap watches *for*, and neither side gets to pick it independently.
struct KeyRemapPlan: Equatable {
    /// A src -> dst rewrite, in full HID usage values (page 0x07 included).
    struct Pair: Equatable, Hashable {
        var src: Int
        var dst: Int
    }

    /// One keyboard's worth of HID-layer rewrites.
    struct Device: Equatable {
        var keyboard: KeyboardRef
        var pairs: [Pair]
    }

    /// A chord rewrite in the terms the tap works in: keycodes and event flags,
    /// resolved once here rather than per keystroke.
    struct Chord: Equatable {
        /// Matched *exactly* against the ⌃⌥⇧⌘ carried by the passing event.
        var require: CGEventFlags
        /// nil swallows the chord.
        var output: HIDKey?
        var send: CGEventFlags
    }

    /// A key that means one thing tapped and another held. By the time the tap
    /// sees it, hidutil has already turned it into `carrier` — which is how the
    /// tap knows which keyboard it came from, since a CGEvent won't say.
    struct DualRole: Equatable {
        var carrier: HIDKey
        var tap: HIDKey?
        var hold: ModifierSet
        var holdMilliseconds: Int
        /// The layer this hold opens. Keys not in here just wear `hold`.
        var chords: [CGKeyCode: [Chord]]
        /// "Raise · Caps Lock" — for logging and the menu.
        var origin: String
    }

    var devices: [Device] = []
    var dualRoles: [CGKeyCode: DualRole] = [:]
    /// Chords with no layer gating them — they apply to every keyboard, because
    /// a plain keypress carries no device identity a tap can read.
    var globalChords: [CGKeyCode: [Chord]] = [:]
    var attachedKeys: Set<String> = []
    /// True when caps lock's own key has been mapped away and nothing else
    /// emits caps lock — i.e. the caps state can no longer be pressed off.
    var capsLockUnreachable = false
    /// Dual-role mappings that found no free carrier key. Surfaced rather than
    /// silently dropped.
    var unassigned: [String] = []

    var needsEventTap: Bool { !dualRoles.isEmpty || !globalChords.isEmpty }

    /// Resolves the config against the hardware.
    ///
    /// Keyboards are walked in `attached` order (which KeyboardIdentity sorts
    /// by key), so carrier assignment is stable from run to run.
    static func resolve(config: Config, attached: [KeyboardRef]) -> KeyRemapPlan {
        var plan = KeyRemapPlan()
        plan.attachedKeys = Set(attached.map(\.key))
        guard config.keyModifications else { return plan }
        plan.globalChords = chords(config.chords)

        // Rewriting caps lock's own key is what strands the caps state;
        // anything that still *emits* caps lock leaves a way to press it off.
        var capsTakenAway = false
        var capsStillEmitted = config.chords.contains { $0.isUsable && $0.to?.key == HIDKeys.capsLock }

        var carriers = HIDKeys.carrierPool[...]
        for ref in attached {
            guard let profile = config.keyboards.first(where: { $0.keyboard?.key == ref.key }) else { continue }
            var pairs: [Pair] = []
            // Two mappings from the same physical key would fight; the first
            // one written wins, the same way a duplicate hotkey would.
            var claimed = Set<Int>()

            for mapping in profile.usableMappings {
                guard let from = mapping.from.key, claimed.insert(from.usage).inserted else { continue }
                if from == HIDKeys.capsLock { capsTakenAway = true }
                if mapping.to?.key == HIDKeys.capsLock { capsStillEmitted = true }
                if mapping.chords.contains(where: { $0.isUsable && $0.to?.key == HIDKeys.capsLock }) {
                    capsStillEmitted = true
                }
                if mapping.isDualRole {
                    guard let carrier = carriers.popFirst() else {
                        plan.unassigned.append("\(profile.name) · \(from.label)")
                        continue
                    }
                    pairs.append(Pair(src: from.hidUsage, dst: carrier.hidUsage))
                    plan.dualRoles[carrier.keyCode] = DualRole(
                        carrier: carrier,
                        tap: mapping.to?.key,
                        hold: mapping.hold ?? [],
                        holdMilliseconds: mapping.holdMilliseconds,
                        chords: chords(mapping.chords),
                        origin: "\(profile.name) · \(from.label)"
                    )
                } else if let to = mapping.to?.key {
                    pairs.append(Pair(src: from.hidUsage, dst: to.hidUsage))
                }
            }

            if !pairs.isEmpty { plan.devices.append(Device(keyboard: ref, pairs: pairs)) }
        }
        plan.capsLockUnreachable = capsTakenAway && !capsStillEmitted
        return plan
    }

    /// The chord that fires for `code` right now, or nil if the key is its
    /// ordinary self. `layers` is the carrier keys currently held, in the order
    /// they should be consulted — a held layer is a more specific statement
    /// than a global chord, so layers are tried first.
    func chord(for code: CGKeyCode, flags: CGEventFlags, layers: [CGKeyCode]) -> Chord? {
        for carrier in layers {
            if let chord = dualRoles[carrier]?.chords[code]?.first(where: { $0.require == flags }) {
                return chord
            }
        }
        return globalChords[code]?.first { $0.require == flags }
    }

    /// Indexes chords by the key that triggers them. Several can share a
    /// trigger as long as they want different modifiers, so each entry is a
    /// list the tap walks looking for an exact modifier match.
    ///
    /// `fn` is stripped from the requirement: it's a send-only modifier, since
    /// the laptop keyboard raises it on its own in ways that would make an
    /// exact match unpredictable.
    private static func chords(_ chords: [KeyChord]) -> [CGKeyCode: [Chord]] {
        var indexed: [CGKeyCode: [Chord]] = [:]
        for chord in chords where chord.isUsable {
            guard let from = chord.from.key else { continue }
            indexed[from.keyCode, default: []].append(
                Chord(
                    require: chord.with.subtracting(.function).eventFlags,
                    output: chord.to?.key,
                    send: chord.send.eventFlags
                )
            )
        }
        return indexed
    }
}

/// Applies the HID-layer half of a plan through `hidutil`.
///
/// `/usr/bin/hidutil property --set` needs no TCC grant and no root (verified:
/// it's how the "Modifier Keys…" pane's own remapping is expressed), and its
/// `--matching` filter is what makes a mapping per-keyboard. It's also below
/// secure input, so a remap applied here keeps working in password fields —
/// unlike anything the event tap does.
///
/// The mapping lives on the HID *service*, which makes it something the world
/// can take away: it dies with an unplug or a reboot, and the Modifier Keys
/// pane, another remapper, or a second copy of this app quitting will all
/// happily overwrite or clear it. So what to write is decided by reading the
/// service back, never by remembering what was written — a cache would go on
/// believing a mapping that is no longer there, and nothing would ever put it
/// back.
final class KeyRemapper {
    /// The keyboards we currently hold a mapping on — what to hand back when
    /// one stops being mapped. Deliberately *not* a record of the pairs: those
    /// are compared against the hardware in `apply`. Dropped as soon as a
    /// keyboard stops being attached, since the mapping went with it.
    private var applied: [String: KeyboardRef] = [:]
    private let queue = DispatchQueue(label: "com.tilebandit.hidutil")

    func apply(_ plan: KeyRemapPlan) {
        // Gone means its mapping is already gone with it. Forget those, so a
        // replug reapplies instead of being skipped as a no-op.
        for key in Array(applied.keys) where !plan.attachedKeys.contains(key) {
            applied.removeValue(forKey: key)
        }

        var wanted: Set<String> = []
        for device in plan.devices {
            wanted.insert(device.keyboard.key)
            applied[device.keyboard.key] = device.keyboard
            // Ask the hardware rather than our own memory: a service that was
            // cleared behind our back reads back empty and gets written again.
            // Unreadable reads as nil, which also writes — a redundant hidutil
            // call is cheaper than a mapping that never comes back.
            guard Self.liveMapping(on: device.keyboard) != Set(device.pairs) else { continue }
            set(device.pairs, on: device.keyboard)
        }

        // Still attached, but nothing maps it any more — hand it back.
        for (key, keyboard) in Array(applied) where !wanted.contains(key) {
            applied.removeValue(forKey: key)
            set([], on: keyboard)
        }
    }

    /// Hands every keyboard back the way it was found. Synchronous on purpose:
    /// it runs from applicationWillTerminate, and an async clear would lose the
    /// race with the process exiting — leaving caps lock rewritten to a
    /// function key with nothing left running to interpret it.
    func clearAll() {
        let keyboards = Array(applied.values)
        applied.removeAll()
        queue.sync {
            for keyboard in keyboards { Self.run(pairs: [], on: keyboard) }
        }
    }

    private func set(_ pairs: [KeyRemapPlan.Pair], on keyboard: KeyboardRef) {
        queue.async { Self.run(pairs: pairs, on: keyboard) }
    }

    private static func run(pairs: [KeyRemapPlan.Pair], on keyboard: KeyboardRef) {
        guard let matching = KeyboardIdentity.matchingJSON(for: keyboard) else { return }
        let entries = pairs
            .map { "{\"HIDKeyboardModifierMappingSrc\":\($0.src),\"HIDKeyboardModifierMappingDst\":\($0.dst)}" }
            .joined(separator: ",")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        process.arguments = ["property", "--matching", matching, "--set", "{\"UserKeyMapping\":[\(entries)]}"]
        let errors = Pipe()
        process.standardOutput = Pipe()
        process.standardError = errors

        do {
            try process.run()
        } catch {
            NSLog("TileBandit: hidutil failed to launch for \(keyboard.name): \(error)")
            return
        }
        // Always waited on. `set` is already off the main thread, and an exit
        // status nobody reads is how a mapping fails to apply in silence.
        let data = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            NSLog("TileBandit: hidutil exited \(process.terminationStatus) for \(keyboard.name): \(String(decoding: data, as: UTF8.self))")
        }
    }

    /// The `UserKeyMapping` actually on this keyboard's HID services right now.
    ///
    /// Reading the registry is permission-free and costs no subprocess, unlike
    /// asking hidutil — and it's the only way to notice a mapping that was
    /// cleared by something other than us. The property hangs off the
    /// IOHIDEventService (nested in `HIDEventServiceProperties`), which is the
    /// same entry hidutil's own `property --get` reports.
    ///
    /// nil means "can't tell": no service matched, or the services a keyboard
    /// publishes disagree with each other — a half-written state that should be
    /// rewritten rather than trusted.
    private static func liveMapping(on keyboard: KeyboardRef) -> Set<KeyRemapPlan.Pair>? {
        guard let wanted = KeyboardIdentity.matchingProperties(for: keyboard) else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("IOHIDEventService"), &iterator
        ) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var mapping: Set<KeyRemapPlan.Pair>?
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var unmanaged: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let properties = unmanaged?.takeRetainedValue() as? [String: Any],
                  matches(properties, wanted)
            else { continue }

            let nested = properties["HIDEventServiceProperties"] as? [String: Any] ?? [:]
            let entries = nested["UserKeyMapping"] as? [[String: Any]] ?? []
            let pairs = Set(entries.compactMap { entry -> KeyRemapPlan.Pair? in
                guard let src = entry["HIDKeyboardModifierMappingSrc"] as? Int,
                      let dst = entry["HIDKeyboardModifierMappingDst"] as? Int
                else { return nil }
                return KeyRemapPlan.Pair(src: src, dst: dst)
            })
            // A keyboard can publish several matching services and hidutil
            // writes them all; if they've drifted apart, say so.
            if let mapping, mapping != pairs { return nil }
            mapping = pairs
        }
        return mapping
    }

    /// Every key in `wanted` present and equal — the registry side of the
    /// dictionary hidutil takes as `--matching`.
    private static func matches(_ properties: [String: Any], _ wanted: [String: Any]) -> Bool {
        wanted.allSatisfy { key, value in
            guard let actual = properties[key] as? NSObject, let expected = value as? NSObject
            else { return false }
            return actual.isEqual(expected)
        }
    }
}

/// The caps lock *state*, as distinct from the caps lock key.
///
/// Caps lock is the one key whose effect outlives the press, which is what
/// makes remapping it away a trap: the state lives in the WindowServer's HID
/// system, and once hidutil has rewritten the key to a carrier (or to escape,
/// or to anything at all) there is nothing left to press it off with. Log in
/// with caps on — or catch it in the seconds before we launch — and the machine
/// stays shouting until the mapping is cleared.
///
/// So whenever a plan takes that key away, the state gets switched off to
/// match. IOHIDSystem's parameter connection is permission-free: no TCC
/// prompt, no root, nothing installed. It's the same door the Keyboard
/// settings pane presses caps lock through.
enum CapsLock {
    /// Switches caps lock off, if it's on. Reading first keeps it from writing
    /// (and blinking the LED) on every keyboard rescan.
    ///
    /// Failure is silent on purpose — a caps lock we couldn't reach is an
    /// annoyance, not something worth an alert on top of it.
    static func turnOff() {
        withParameterConnection { connect in
            var state = false
            guard IOHIDGetModifierLockState(connect, Int32(kIOHIDCapsLockState), &state) == KERN_SUCCESS,
                  state
            else { return }
            IOHIDSetModifierLockState(connect, Int32(kIOHIDCapsLockState), false)
            NSLog("TileBandit: caps lock was on and its key is remapped away — switched it off")
        }
    }

    private static func withParameterConnection(_ body: (io_connect_t) -> Void) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
        guard service != IO_OBJECT_NULL else { return }
        defer { IOObjectRelease(service) }

        var connect: io_connect_t = IO_OBJECT_NULL
        guard IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connect) == KERN_SUCCESS
        else { return }
        defer { IOServiceClose(connect) }

        body(connect)
    }
}

/// The key-modification feature as one switch: resolves the plan, drives
/// hidutil for the plain remaps and the event tap for the dual-role ones.
///
/// The split matters for permissions. A config with nothing but 1:1 remaps
/// never creates a tap, so it needs no Accessibility grant at all; the tap only
/// comes up when something actually has a hold behaviour.
final class KeyModEngine {
    private let remapper = KeyRemapper()
    private let tap = DualRoleTap()
    private(set) var plan = KeyRemapPlan()

    /// True when a dual-role mapping is configured but the tap couldn't be
    /// created — i.e. Accessibility is missing. The plain remaps still work.
    var needsAccessibility: Bool { plan.needsEventTap && !tap.isRunning }

    /// What the tap is currently watching, for the menu and the key debugger.
    var activeDualRoles: [KeyRemapPlan.DualRole] { Array(plan.dualRoles.values) }

    func apply(config: Config, attached: [KeyboardRef]) {
        plan = KeyRemapPlan.resolve(config: config, attached: attached)
        remapper.apply(plan)
        tap.update(plan)
        // Runs on every apply, not just when the plan changes: the caps state
        // is set by the world, not by us, and this is the only moment we're
        // reliably looking (launch, keyboard rescan, wake, config edit).
        if plan.capsLockUnreachable { CapsLock.turnOff() }
        for origin in plan.unassigned {
            NSLog("TileBandit: no carrier key left for \(origin) — at most \(HIDKeys.carrierPool.count) dual-role keys can be live at once")
        }
    }

    /// Leaves no trace on the machine: hidutil mappings cleared, tap torn down.
    func shutDown() {
        tap.stop()
        remapper.clearAll()
        plan = KeyRemapPlan()
    }
}
