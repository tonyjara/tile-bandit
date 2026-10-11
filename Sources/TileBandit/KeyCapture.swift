import AppKit
import Carbon.HIToolbox
import Combine

/// Captures single physical keys for Add Mapping on the Key Modifications tab.
///
/// A *local* NSEvent monitor, like ShortcutRecorder's — it only hears keys while
/// a Tile Bandit window is key, which is exactly when someone has just pressed
/// Add Mapping, and it needs no permission (a global monitor or an event tap
/// would; see HotkeyManager).
///
/// The keys most worth capturing are the ones already remapped, and a remapped
/// key doesn't report itself: caps lock arrives as its carrier (F18), a swapped
/// ⌘ as ⌃. So for as long as a capture is live every modification is paused
/// (`KeyModEngine.beginCapture`), and listening only starts once hidutil has
/// actually handed the keyboards back — before that a press would still
/// arrive remapped. The pause covers the whole add, so the key you pick to
/// send is also the key printed on the keycap.
///
/// Two keys do more than report themselves when pressed, and are handled so
/// that pressing them here does nothing else: fn arrives through a stand-in
/// (`HIDKeys.fnCaptureStandIn`), because on its own it would also fire the
/// Globe action, and caps lock's state is put back the moment it's captured.
///
/// Only single keys count. A modifier is taken on its *release*, if nothing
/// else was pressed while it was down, and any key pressed with ⌃⌥⇧⌘ held is
/// refused — so ⌘W typed out of habit captures nothing, rather than quietly
/// adding a "left ⌘ → W" mapping. Esc cancels, which is why Escape itself is
/// picked from the list.
final class KeyCapture: ObservableObject {
    enum Phase {
        case idle
        /// Waiting for hidutil to hand the keyboards back.
        case pausing
        case listening
    }

    @Published private(set) var phase: Phase = .idle

    var isActive: Bool { phase != .idle }

    /// Wired by AppDelegate to KeyModEngine: pause every modification, and
    /// call back once that's true of the hardware. Resume puts them back.
    var pauseModifications: (@escaping () -> Void) -> Void = { $0() }
    var resumeModifications: () -> Void = {}

    private var monitor: Any?
    private var onKey: ((HIDKey) -> Void)?
    private var onRefused: ((String) -> Void)?
    private var onCancel: (() -> Void)?
    /// Bumped on every begin, so a pause that completes after its capture was
    /// cancelled (or replaced) can't flip a later one to listening.
    private var session = 0
    /// Caps lock's state when the capture began — pressing it to capture it
    /// flips it, and that's undone straight away.
    private var capsLockWasOn: Bool?
    /// A modifier that went down with nothing else held. It's captured when it
    /// comes back up, unless another key arrives first.
    private var pendingModifier: HIDKey?
    /// True while a menu is open — the panel's own "Choose from the list…"
    /// among them. Keys then belong to the menu (type-to-select, Esc to close
    /// it), not to the capture.
    private var menuOpen = false
    private var menuObservers: [NSObjectProtocol] = []

    /// Starts listening. `onKey` fires for every single key pressed until
    /// `finish()` or `cancel()` — the caller decides what each one is for.
    /// `onRefused` explains a press that couldn't be taken; `onCancel` fires
    /// when the capture is abandoned (Esc, or anything calling `cancel()`).
    func begin(
        onKey: @escaping (HIDKey) -> Void,
        onRefused: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        cancel()
        self.onKey = onKey
        self.onRefused = onRefused
        self.onCancel = onCancel
        session += 1
        let current = session
        phase = .pausing
        capsLockWasOn = CapsLock.isOn
        pendingModifier = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            self?.handle(event) ?? event
        }
        menuOpen = false
        menuObservers = [
            (NSMenu.didBeginTrackingNotification, true),
            (NSMenu.didEndTrackingNotification, false),
        ].map { name, open in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.menuOpen = open
                self?.pendingModifier = nil
            }
        }
        pauseModifications { [weak self] in
            guard let self, self.session == current, self.phase == .pausing else { return }
            self.phase = .listening
        }
    }

    /// Ends a capture that got what it came for.
    func finish() {
        stop()
    }

    /// Ends a capture that didn't: Esc, Cancel, the tab or window going away.
    func cancel() {
        guard isActive else { return }
        let callback = onCancel
        stop()
        callback?()
    }

    private func stop() {
        guard isActive else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        menuObservers.forEach { NotificationCenter.default.removeObserver($0) }
        menuObservers = []
        menuOpen = false
        onKey = nil
        onRefused = nil
        onCancel = nil
        pendingModifier = nil
        restoreCapsLock()
        phase = .idle
        resumeModifications()
    }

    /// Every key event is swallowed while a capture is live — it owns the
    /// keyboard, including over a text field that still has focus.
    private func handle(_ event: NSEvent) -> NSEvent? {
        if menuOpen { return event }
        if event.type == .keyDown, event.keyCode == UInt16(kVK_Escape) {
            cancel()
            return nil
        }
        guard phase == .listening else { return nil }

        switch event.type {
        case .keyDown:
            // Anything pressed while a modifier is down makes that modifier
            // part of a combination, not a key on its own.
            pendingModifier = nil
            guard !event.isARepeat else { break }
            if !event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
                onRefused?("That was a combination — press one key on its own.")
            } else if event.keyCode == HIDKeys.fnCaptureStandIn.keyCode {
                onKey?(HIDKeys.fn)
            } else if let key = HIDKeys.withKeyCode(event.keyCode) {
                onKey?(key)
            } else {
                onRefused?("That key (keyCode \(event.keyCode)) isn't one Tile Bandit can remap — choose from the list.")
            }
        case .flagsChanged:
            flagsChanged(event)
        default:
            break
        }
        return nil
    }

    private func flagsChanged(_ event: NSEvent) {
        // Caps lock reports once per press, with nothing for the release.
        if event.keyCode == HIDKeys.capsLock.keyCode {
            // Its state is put back after every capture, so a real press always
            // lands on the opposite of `capsLockWasOn`. One that lands on it is
            // the restore itself coming back around, not a second press.
            if let was = capsLockWasOn, event.modifierFlags.contains(.capsLock) == was { return }
            pendingModifier = nil
            restoreCapsLock()
            onKey?(HIDKeys.capsLock)
            return
        }
        guard let key = HIDKeys.withKeyCode(event.keyCode), let down = Self.isDown(event) else { return }
        if down {
            // A second modifier joining the first is a combination.
            pendingModifier = Self.heldCount(event.modifierFlags) == 1 ? key : nil
        } else if pendingModifier == key {
            pendingModifier = nil
            onKey?(key)
        }
    }

    private func restoreCapsLock() {
        if let capsLockWasOn { CapsLock.set(capsLockWasOn) }
    }

    /// Per-side bits of the modifier flags (IOLLEvent's NX_DEVICE*KEYMASK):
    /// the device-independent ⇧ can't say *which* shift just moved.
    private static let sideMasks: [UInt16: UInt] = [
        UInt16(kVK_Control): 0x01,
        UInt16(kVK_Shift): 0x02,
        UInt16(kVK_RightShift): 0x04,
        UInt16(kVK_Command): 0x08,
        UInt16(kVK_RightCommand): 0x10,
        UInt16(kVK_Option): 0x20,
        UInt16(kVK_RightOption): 0x40,
        UInt16(kVK_RightControl): 0x2000,
    ]

    /// Whether this flagsChanged is its key going down (true) or up (false);
    /// nil for a key that isn't one of the modifiers.
    private static func isDown(_ event: NSEvent) -> Bool? {
        // Reached only if fn's stand-in didn't take — fn then arrives as
        // itself, Globe action and all, and is still worth capturing.
        if event.keyCode == HIDKeys.fn.keyCode { return event.modifierFlags.contains(.function) }
        guard let mask = sideMasks[event.keyCode] else { return nil }
        return event.modifierFlags.rawValue & mask != 0
    }

    /// How many of the side-specific modifier keys are down.
    private static func heldCount(_ flags: NSEvent.ModifierFlags) -> Int {
        sideMasks.values.filter { flags.rawValue & $0 != 0 }.count
            + (flags.contains(.function) ? 1 : 0)
    }
}
