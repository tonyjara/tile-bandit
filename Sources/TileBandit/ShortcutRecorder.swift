import AppKit
import Combine

/// Captures the next key combo pressed, for the "Reassign" buttons in
/// Settings.
///
/// Uses a *local* NSEvent monitor (permission-free, same trick as
/// KeyDebugger) — it only sees keys while a Tile Bandit window is focused,
/// which is exactly when the user has just clicked "Reassign".
///
/// While recording, AppDelegate unregisters every Carbon hotkey (a registered
/// combo would be consumed before any NSEvent monitor could see it) and
/// KeyDebugger passes events through via `shouldPassThrough`. Both are
/// restored the moment recording ends.
final class ShortcutRecorder: ObservableObject {
    /// Identifier of the field currently recording; nil when idle.
    @Published private(set) var activeID: String?

    var isRecording: Bool { activeID != nil }

    private var monitor: Any?
    private var completion: ((Shortcut) -> Void)?

    /// Only one recording at a time — starting a new one cancels the old.
    func begin(id: String, completion: @escaping (Shortcut) -> Void) {
        cancel()
        self.completion = completion
        activeID = id
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
        }
    }

    func cancel() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        completion = nil
        activeID = nil
    }

    /// Swallows every key while recording. Esc cancels; a supported key
    /// (0-9, a-z) with at least one modifier completes; anything else is
    /// ignored and we keep listening.
    private func handle(_ event: NSEvent) -> NSEvent? {
        if event.keyCode == 53 { // esc
            cancel()
            return nil
        }
        // keyCode-based lookup, so ⇧5 records as "5" and ⌥n as "n".
        guard let key = HotkeyManager.keyNames[UInt32(event.keyCode)] else { return nil }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let shortcut = Shortcut(
            key: key,
            control: flags.contains(.control),
            option: flags.contains(.option),
            shift: flags.contains(.shift),
            command: flags.contains(.command)
        )
        guard shortcut.control || shortcut.option || shortcut.shift || shortcut.command else { return nil }

        let done = completion
        done?(shortcut) // write the config first, so re-registration sees it
        cancel()
        return nil
    }
}
