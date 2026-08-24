import AppKit
import Carbon.HIToolbox
import Combine

/// Key-press debugger for the Shortcuts tab.
///
/// Uses NSEvent.addLocalMonitorForEvents, which only sees events while Tile
/// Bandit's own window is focused — that's what keeps it permission-free
/// (a *global* key monitor would require the Accessibility permission).
/// Registered global hotkeys are consumed by Carbon before any NSEvent
/// monitor can see them, so the hotkey handlers report their firings here
/// via `recordHotkeyFired` — those show up even when the window isn't focused.
///
/// Once started it stays on until explicitly stopped. Key presses are only
/// swallowed while the Shortcuts tab is visible (to avoid beeps); on other
/// tabs events pass through so typing keeps working.
final class KeyDebugger: ObservableObject {
    struct KeyPress {
        let combo: String
        let keyCode: UInt16
        let verdict: String
        let usable: Bool
    }

    @Published private(set) var isActive = false
    @Published private(set) var heldModifiers = ""
    @Published private(set) var lastPress: KeyPress?

    /// Set by the Shortcuts tab's onAppear/onDisappear.
    var shortcutsTabVisible = false

    /// While ShortcutRecorder is capturing a combo, this debugger passes
    /// events through untouched so the recorder's monitor sees them and
    /// nothing double-handles the press. Wired up by AppDelegate.
    var shouldPassThrough: () -> Bool = { false }

    private var monitor: Any?

    func toggle() {
        isActive ? stop() : start()
    }

    func start() {
        guard !isActive else { return }
        isActive = true
        lastPress = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    func stop() {
        guard isActive else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isActive = false
        heldModifiers = ""
    }

    /// Called from the global hotkey handlers, since Carbon consumes those
    /// events before this monitor can observe them.
    func recordHotkeyFired(_ shortcut: Shortcut, action: String) {
        guard isActive else { return }
        let keyCode = UInt16(HotkeyManager.keyCodes[shortcut.key.lowercased()] ?? 0)
        lastPress = KeyPress(
            combo: shortcut.display,
            keyCode: keyCode,
            verdict: "Global hotkey fired: \(action)",
            usable: true
        )
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard !shouldPassThrough() else { return event }
        switch event.type {
        case .flagsChanged:
            heldModifiers = Self.modifierSymbols(event.modifierFlags)
            return event
        case .keyDown:
            if !event.isARepeat { record(event) }
            // Swallow presses only on the Shortcuts tab (prevents beeps);
            // elsewhere typing keeps working while the debugger observes.
            return shortcutsTabVisible ? nil : event
        default:
            return event
        }
    }

    private func record(_ event: NSEvent) {
        let modifiers = Self.modifierSymbols(event.modifierFlags)
        let keyName = Self.keyName(for: event)
        let baseKey = (event.charactersIgnoringModifiers ?? "").lowercased()
        let supported = HotkeyManager.keyCodes[baseKey] != nil

        let verdict: String
        let usable: Bool
        if modifiers.isEmpty {
            verdict = "Add a modifier (⌃⌥⇧⌘) — bare keys can't be global shortcuts."
            usable = false
        } else if !supported {
            verdict = "Key not in the supported set (0–9, a–z) yet."
            usable = false
        } else {
            verdict = "Usable as a shortcut."
            usable = true
        }

        lastPress = KeyPress(
            combo: modifiers + keyName,
            keyCode: event.keyCode,
            verdict: verdict,
            usable: usable
        )
    }

    static func modifierSymbols(_ flags: NSEvent.ModifierFlags) -> String {
        var symbols = ""
        if flags.contains(.control) { symbols += "⌃" }
        if flags.contains(.option) { symbols += "⌥" }
        if flags.contains(.shift) { symbols += "⇧" }
        if flags.contains(.command) { symbols += "⌘" }
        return symbols
    }

    private static let specialKeys: [UInt16: String] = [
        36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Esc",
        76: "Enter", 117: "Fwd Delete", 115: "Home", 119: "End",
        116: "Page Up", 121: "Page Down",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    private static func keyName(for event: NSEvent) -> String {
        if let special = specialKeys[event.keyCode] { return special }
        let chars = event.charactersIgnoringModifiers ?? ""
        if chars.isEmpty || chars.unicodeScalars.allSatisfy({ CharacterSet.controlCharacters.contains($0) }) {
            return "key \(event.keyCode)"
        }
        return chars.uppercased()
    }
}
