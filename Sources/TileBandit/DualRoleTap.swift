import CoreGraphics
import Foundation

extension ModifierSet {
    var eventFlags: CGEventFlags {
        var flags: CGEventFlags = []
        if contains(.control) { flags.insert(.maskControl) }
        if contains(.option) { flags.insert(.maskAlternate) }
        if contains(.shift) { flags.insert(.maskShift) }
        if contains(.command) { flags.insert(.maskCommand) }
        // Send-only, and never part of `matchMask` — a chord can emit fn+F11
        // (show desktop) but can't ask to be triggered by fn.
        if contains(.function) { flags.insert(.maskSecondaryFn) }
        return flags
    }
}

/// The userspace half of key modifications: keys that mean one thing tapped and
/// another held.
///
/// This is the only part of the feature that needs a permission. A CGEventTap
/// placed at `.cghidEventTap` can rewrite events before anything else sees them
/// — including the WindowServer's hotkey dispatch, so a hold-modifier combo can
/// still fire a Carbon hotkey — but creating one requires Accessibility.
///
/// It never has to ask which keyboard an event came from, which a CGEvent can't
/// answer anyway: hidutil has already rewritten the real key to a carrier
/// function key per device, so the carrier *is* the answer.
///
/// Two deliberate limits. Modifiers are OR'd onto the events that pass through
/// while a carrier is down rather than synthesized as flagsChanged events — an
/// injected modifier that misses its release would leave the machine stuck, and
/// nothing reads modifier state except through these events anyway. And a tap
/// is inert inside secure input (password fields), so a dual-role key goes
/// quiet there; the plain hidutil remaps are below that layer and don't.
final class DualRoleTap {
    private struct Held {
        let role: KeyRemapPlan.DualRole
        let since: CFAbsoluteTime
        var usedAsModifier: Bool
    }

    /// What a chord turned a key into, decided on its keyDown and remembered
    /// so the keyUp follows suit even if the layer key was let go in between.
    private struct Rewrite {
        let output: HIDKey?
        let send: CGEventFlags
    }

    /// The modifiers a chord is matched on — `fn` and the device-dependent bits
    /// are deliberately out of it. See `KeyChord.with`.
    private static let matchMask: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]

    /// The resolved plan, kept whole so chord selection stays where it's
    /// defined rather than being reimplemented on the key path.
    private var plan = KeyRemapPlan()
    private var held: [CGKeyCode: Held] = [:]
    private var rewritten: [CGKeyCode: Rewrite] = [:]
    /// Modifiers stamped onto a key's keyDown, kept so its keyUp carries the
    /// same ones even if the carrier was let go first — an app that saw
    /// hyper-J go down must not see a bare J come up.
    private var stamped: [CGKeyCode: CGEventFlags] = [:]
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let eventSource = CGEventSource(stateID: .hidSystemState)

    var isRunning: Bool { tap != nil }

    /// Starts, stops or re-points the tap. Called on every config change and
    /// keyboard rescan, which is also what retries a tap that couldn't be
    /// created because Accessibility hadn't been granted yet.
    func update(_ plan: KeyRemapPlan) {
        self.plan = plan
        held.removeAll()
        stamped.removeAll()
        rewritten.removeAll()
        if plan.needsEventTap {
            start()
        } else {
            stop()
        }
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        held.removeAll()
        stamped.removeAll()
        rewritten.removeAll()
    }

    private func start() {
        guard tap == nil else { return }
        guard AccessibilityPermission.isGranted else {
            NSLog("TileBandit: dual-role keys need Accessibility; plain remaps are unaffected")
            return
        }
        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        guard let port = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: dualRoleCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            NSLog("TileBandit: could not create the key modification event tap")
            return
        }
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        source = runLoopSource
    }

    fileprivate func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS switches a tap off if it ever blocks. Without this the
            // remaps would silently die partway through a session.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        case .keyDown, .keyUp:
            break
        default:
            return Unmanaged.passUnretained(stamp(event, type: type))
        }

        let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        guard let role = plan.dualRoles[code] else {
            // A chord rewrite beats everything but the carrier keys themselves:
            // replacing the key outright is the point of a layer, so the
            // original never reaches anyone and the hold's modifiers aren't
            // stamped onto it either.
            if let rewrite = chordRewrite(for: code, type: type, event: event) {
                if let output = rewrite.output {
                    post(output, flags: rewrite.send, down: type == .keyDown, through: proxy)
                }
                return nil
            }
            return Unmanaged.passUnretained(stamp(event, type: type))
        }

        // The carrier key itself never reaches anyone: it only exists to be
        // interpreted here.
        if type == .keyDown {
            // Auto-repeat while held would otherwise re-arm the press.
            guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return nil }
            if held[code] == nil {
                held[code] = Held(role: role, since: CFAbsoluteTimeGetCurrent(), usedAsModifier: false)
            }
            return nil
        }

        guard let state = held.removeValue(forKey: code) else { return nil }
        let heldFor = (CFAbsoluteTimeGetCurrent() - state.since) * 1000
        // Using it as a modifier settles the question immediately; the timer
        // only decides what a press with nothing else in it meant.
        if !state.usedAsModifier, heldFor < Double(role.holdMilliseconds), let tapKey = role.tap {
            send(tapKey, flags: event.flags, through: proxy)
        }
        return nil
    }

    /// Picks the chord a key is part of right now. A layer that's actually held
    /// wins over a global chord — the layer is the more specific statement.
    private func chordRewrite(for code: CGKeyCode, type: CGEventType, event: CGEvent) -> Rewrite? {
        if type == .keyUp { return rewritten.removeValue(forKey: code) }

        // Sorted only when it could matter: two layer keys held at once is odd
        // but possible, and which one wins should at least be the same twice.
        let layers = held.count > 1 ? held.keys.sorted() : Array(held.keys)
        guard let match = plan.chord(
            for: code,
            flags: event.flags.intersection(Self.matchMask),
            layers: layers
        ) else { return nil }

        // Firing a chord settles that the layer key was held, not tapped.
        markHeldUsed()
        let rewrite = Rewrite(output: match.output, send: match.send)
        rewritten[code] = rewrite
        return rewrite
    }

    /// Dresses a passing event in whatever modifiers the held carriers stand for.
    private func stamp(_ event: CGEvent, type: CGEventType) -> CGEvent {
        let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

        if type == .keyDown, !held.isEmpty {
            // A key pressed during the hold is what proves it was a hold.
            markHeldUsed()
            let flags = held.values.reduce(into: CGEventFlags()) { $0.formUnion($1.role.hold.eventFlags) }
            stamped[code] = flags
            event.flags = event.flags.union(flags)
        } else if type == .keyUp, let flags = stamped.removeValue(forKey: code) {
            event.flags = event.flags.union(flags)
        } else if !held.isEmpty {
            let flags = held.values.reduce(into: CGEventFlags()) { $0.formUnion($1.role.hold.eventFlags) }
            event.flags = event.flags.union(flags)
        }
        return event
    }

    private func markHeldUsed() {
        for (carrier, var state) in held {
            state.usedAsModifier = true
            held[carrier] = state
        }
    }

    /// A tap-out is a whole press, so it goes out as a pair. Keeps the real
    /// modifiers that were down, so ⇧ plus a tap gives ⇧-Escape, not a bare one.
    private func send(_ key: HIDKey, flags: CGEventFlags, through proxy: CGEventTapProxy) {
        post(key, flags: flags, down: true, through: proxy)
        post(key, flags: flags, down: false, through: proxy)
    }

    /// A chord, by contrast, is posted a half at a time — its down on the
    /// trigger's down and its up on the trigger's up — so holding the chord
    /// holds the replacement, and auto-repeat repeats it.
    private func post(_ key: HIDKey, flags: CGEventFlags, down: Bool, through proxy: CGEventTapProxy) {
        guard let event = CGEvent(keyboardEventSource: eventSource, virtualKey: key.keyCode, keyDown: down)
        else { return }
        event.flags = flags
        // tapPostEvent injects downstream of this tap, so what we make never
        // comes back through our own callback.
        event.tapPostEvent(proxy)
    }
}

private let dualRoleCallback: CGEventTapCallBack = { proxy, type, event, refcon in
    guard let refcon else { return Unmanaged.passUnretained(event) }
    return Unmanaged<DualRoleTap>.fromOpaque(refcon).takeUnretainedValue()
        .handle(proxy: proxy, type: type, event: event)
}
