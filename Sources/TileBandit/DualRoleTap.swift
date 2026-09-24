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
///
/// Everything here is about one hazard: this object remembers keys the machine
/// believes are *down*, and every one of those memories is a promise to put
/// them back up. A carrier left in `held` dresses every later keystroke in the
/// hold's modifiers, so the keyboard goes dead; a chord left in `rewritten` has
/// had its replacement posted down and never released, so that key auto-repeats
/// forever. Both look to the user like the keyboard broke. So the tap runs on a
/// thread of its own (the main run loop shares a queue with the settings window
/// and every rescan, and macOS switches a tap off the instant it blocks), and
/// every path that drops the bookkeeping — a disabled tap, a re-plan, a
/// shutdown, a release that never arrived — goes through `drain` or `prune` and
/// pays out what it owes.
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
        let since: CFAbsoluteTime
    }

    /// A replacement keyUp still owed to whoever was shown the keyDown.
    private struct Pending {
        let key: HIDKey
        let flags: CGEventFlags
    }

    /// The modifiers a chord is matched on — `fn` and the device-dependent bits
    /// are deliberately out of it. See `KeyChord.with`.
    private static let matchMask: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]

    /// Stamped on the releases posted from off the tap thread, where there's no
    /// proxy to inject through and `CGEvent.post` therefore comes back around
    /// to this callback. What we made is already exactly what the app should
    /// see, so it passes straight through.
    private static let injectedMarker: Int64 = 0x7B17_BA11

    /// How long a press has to be outstanding before we'll take the window
    /// server's word over our own bookkeeping. A hold is done in well under a
    /// second; this only has to outlast a press we could still legitimately be
    /// in the middle of, and a wrong guess costs one early release rather than
    /// a key stuck down for the rest of the session.
    private static let stuckGrace: CFAbsoluteTime = 5

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
    private var worker: Thread?
    private var workerRunLoop: CFRunLoop?
    private let eventSource = CGEventSource(stateID: .hidSystemState)
    /// The callback runs on the tap's own thread while `update` and `stop` come
    /// from the main one, so everything above is shared. Private helpers below
    /// all assume it's already held.
    private let lock = NSLock()

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return tap != nil
    }

    /// Starts, stops or re-points the tap. Called on every config change and
    /// keyboard rescan, which is also what retries a tap that couldn't be
    /// created because Accessibility hadn't been granted yet.
    func update(_ plan: KeyRemapPlan) {
        lock.lock()
        self.plan = plan
        let owed = drain()
        lock.unlock()
        // A rescan fires on every plug and on wake, so this lands mid-press
        // sooner or later. Dropping `rewritten` without paying it out is what
        // used to leave a chord's replacement key held down and repeating.
        payOut(owed)
        if plan.needsEventTap {
            start()
        } else {
            stop()
        }
    }

    func stop() {
        lock.lock()
        let owed = drain()
        let port = tap
        let runLoop = workerRunLoop
        let thread = worker
        tap = nil
        source = nil
        worker = nil
        workerRunLoop = nil
        lock.unlock()

        // Cancelled before the port dies: the thread removes its own source and
        // exits, and a run loop with nothing left to wait on would otherwise
        // spin through the gap.
        thread?.cancel()
        if let runLoop { CFRunLoopWakeUp(runLoop) }
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        payOut(owed)
    }

    private func start() {
        lock.lock()
        let alreadyRunning = tap != nil
        lock.unlock()
        guard !alreadyRunning else { return }
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
        guard let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port)
            NSLog("TileBandit: could not schedule the key modification event tap")
            return
        }

        // A thread of its own, and not a detail. On the main run loop the tap
        // queued behind the settings window, the status menu and every display
        // and keyboard rescan; macOS disables a tap that blocks, and it was
        // disabled *between* a key's down and its up — which is exactly how a
        // carrier or a chord ended up stranded.
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            // Signalled on every exit from here, successful or not: the caller
            // is blocked on it, and a keyboard feature must never be the reason
            // the main thread stops.
            guard let runLoop = CFRunLoopGetCurrent() else { ready.signal(); return }
            self?.noteWorkerRunLoop(runLoop)
            CFRunLoopAddSource(runLoop, runLoopSource, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            ready.signal()
            while !Thread.current.isCancelled {
                CFRunLoopRunInMode(.defaultMode, 1, false)
            }
            CFRunLoopRemoveSource(runLoop, runLoopSource, .commonModes)
        }
        thread.name = "com.tilebandit.dual-role-tap"
        thread.qualityOfService = QualityOfService.userInteractive

        lock.lock()
        tap = port
        source = runLoopSource
        worker = thread
        lock.unlock()

        thread.start()
        // Bounded for the same reason. Missing the deadline would mean the tap
        // is late coming up, not that anything is wrong to carry on with.
        if ready.wait(timeout: .now() + 2) == .timedOut {
            NSLog("TileBandit: key modification tap thread was slow to start")
        }
    }

    private func noteWorkerRunLoop(_ runLoop: CFRunLoop) {
        lock.lock()
        defer { lock.unlock() }
        workerRunLoop = runLoop
    }

    fileprivate func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS switches a tap off if it ever blocks. Without this the
            // remaps would silently die partway through a session — but
            // re-enabling is only half of it. While the tap was off, releases
            // flowed straight past us, so everything we think is down may
            // already be up. Keeping that bookkeeping is what left a carrier
            // "held" (hyper on every later keystroke) and a chord's
            // replacement down and repeating.
            lock.lock()
            let owed = drain()
            let port = tap
            lock.unlock()
            payOut(owed, through: proxy)
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            NSLog("TileBandit: key modification tap was disabled mid-stream; re-enabled, "
                + "released \(owed.count) pending key(s)")
            return Unmanaged.passUnretained(event)
        case .keyDown, .keyUp:
            break
        default:
            lock.lock()
            defer { lock.unlock() }
            return Unmanaged.passUnretained(stamp(event, type: type))
        }

        // A release we posted ourselves from off-thread, on its way back in.
        if event.getIntegerValueField(.eventSourceUserData) == Self.injectedMarker {
            return Unmanaged.passUnretained(event)
        }

        lock.lock()
        defer { lock.unlock() }

        // A press whose release never arrived — a Bluetooth keyboard that
        // dropped a report, say — would otherwise stay down for the rest of the
        // session. Checked here rather than on a timer: it costs nothing on the
        // key path and heals within one keystroke, which is the moment the user
        // is asking for it anyway.
        payOut(prune(), through: proxy)

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

    /// Forgets every key we think is down and reports the replacement keyUps
    /// that forgetting them owes. Every teardown path goes through here.
    private func drain() -> [Pending] {
        let owed = rewritten.values.compactMap { rewrite in
            rewrite.output.map { Pending(key: $0, flags: rewrite.send) }
        }
        held.removeAll()
        stamped.removeAll()
        rewritten.removeAll()
        return owed
    }

    /// Drops presses the window server no longer agrees are down. Only presses
    /// old enough that we can't still be in the middle of them are eligible, so
    /// this can never cut a live hold or a held chord short.
    private func prune() -> [Pending] {
        let now = CFAbsoluteTimeGetCurrent()
        var owed: [Pending] = []

        for (code, state) in held where now - state.since > Self.stuckGrace {
            guard !CGEventSource.keyState(.combinedSessionState, key: code) else { continue }
            held.removeValue(forKey: code)
            NSLog("TileBandit: \(state.role.origin) was left held with no release — dropped it")
        }
        for (code, rewrite) in rewritten where now - rewrite.since > Self.stuckGrace {
            guard !CGEventSource.keyState(.combinedSessionState, key: code) else { continue }
            rewritten.removeValue(forKey: code)
            if let output = rewrite.output {
                owed.append(Pending(key: output, flags: rewrite.send))
                NSLog("TileBandit: chord replacement \(output.label) was left down with no release — released it")
            }
        }
        return owed
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
        let rewrite = Rewrite(output: match.output, send: match.send, since: CFAbsoluteTimeGetCurrent())
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

    private func payOut(_ owed: [Pending], through proxy: CGEventTapProxy) {
        for item in owed { post(item.key, flags: item.flags, down: false, through: proxy) }
    }

    /// The same debt settled from off the tap thread, where there is no proxy.
    /// `CGEvent.post` re-enters this tap, so each one is marked on the way out
    /// and waved through on the way back in.
    private func payOut(_ owed: [Pending]) {
        for item in owed {
            guard let event = CGEvent(keyboardEventSource: eventSource, virtualKey: item.key.keyCode, keyDown: false)
            else { continue }
            event.flags = item.flags
            event.setIntegerValueField(.eventSourceUserData, value: Self.injectedMarker)
            event.post(tap: .cghidEventTap)
        }
    }
}

private let dualRoleCallback: CGEventTapCallBack = { proxy, type, event, refcon in
    guard let refcon else { return Unmanaged.passUnretained(event) }
    return Unmanaged<DualRoleTap>.fromOpaque(refcon).takeUnretainedValue()
        .handle(proxy: proxy, type: type, event: event)
}
