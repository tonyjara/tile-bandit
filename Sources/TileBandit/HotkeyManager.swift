import Carbon.HIToolbox
import Foundation

/// Global hotkeys via Carbon's RegisterEventHotKey.
///
/// Deliberately not CGEventTap or NSEvent global monitors: those require the
/// Accessibility / Input Monitoring permission. RegisterEventHotKey is old but
/// fully supported and needs no permission at all.
final class HotkeyManager {
    private struct Handlers {
        let pressed: () -> Void
        let released: (() -> Void)?
    }

    private var registered: [EventHotKeyRef] = []
    private var handlers: [UInt32: Handlers] = [:]
    private var nextID: UInt32 = 1
    private var eventHandler: EventHandlerRef?

    init() {
        // Released events too, for hold-style shortcuts (act while held,
        // undo on release). Carbon fires released when the combo breaks,
        // whether the key or the modifier goes up first.
        let specs = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            ),
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyReleased)
            ),
        ]
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return noErr }
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                if GetEventKind(event) == UInt32(kEventHotKeyReleased) {
                    manager.handlers[hotKeyID.id]?.released?()
                } else {
                    manager.handlers[hotKeyID.id]?.pressed()
                }
                return noErr
            },
            specs.count,
            specs,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
    }

    func unregisterAll() {
        registered.forEach { UnregisterEventHotKey($0) }
        registered.removeAll()
        handlers.removeAll()
    }

    /// Returns false for unknown keys or shortcuts without any modifier
    /// (a bare key would swallow normal typing system-wide).
    @discardableResult
    func register(_ shortcut: Shortcut, handler: @escaping () -> Void) -> Bool {
        register(shortcut, pressed: handler, released: nil)
    }

    /// Hold-style variant: `released` fires when the combo is let go.
    @discardableResult
    func register(_ shortcut: Shortcut, pressed: @escaping () -> Void, released: (() -> Void)?) -> Bool {
        guard let keyCode = Self.keyCodes[shortcut.key.lowercased()] else { return false }

        var modifiers: UInt32 = 0
        if shortcut.control { modifiers |= UInt32(controlKey) }
        if shortcut.option { modifiers |= UInt32(optionKey) }
        if shortcut.shift { modifiers |= UInt32(shiftKey) }
        if shortcut.command { modifiers |= UInt32(cmdKey) }
        guard modifiers != 0 else { return false }

        let id = nextID
        nextID += 1

        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            EventHotKeyID(signature: Self.signature, id: id),
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else { return false }

        registered.append(ref)
        handlers[id] = Handlers(pressed: pressed, released: released)
        return true
    }

    private static let signature: OSType = "TBHK".utf8.reduce(0) { ($0 << 8) + OSType($1) }

    // Reverse lookup for ShortcutRecorder (keyCode → key string).
    static let keyNames: [UInt32: String] = Dictionary(uniqueKeysWithValues: keyCodes.map { ($0.value, $0.key) })

    // Also used by KeyDebugger to tell the user whether a pressed key is registerable.
    static let keyCodes: [String: UInt32] = {
        let map: [String: Int] = [
            "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D,
            "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H,
            "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
            "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P,
            "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
            "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
            "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
            "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
            "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7,
            "8": kVK_ANSI_8, "9": kVK_ANSI_9,
            // Punctuation, so ⌥, can be the Settings shortcut (macOS
            // convention) and the recorder isn't limited to alphanumerics.
            ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period, "/": kVK_ANSI_Slash,
            ";": kVK_ANSI_Semicolon, "'": kVK_ANSI_Quote, "-": kVK_ANSI_Minus,
            "=": kVK_ANSI_Equal, "[": kVK_ANSI_LeftBracket,
            "]": kVK_ANSI_RightBracket, "\\": kVK_ANSI_Backslash,
            "`": kVK_ANSI_Grave,
        ]
        return map.mapValues { UInt32($0) }
    }()
}
