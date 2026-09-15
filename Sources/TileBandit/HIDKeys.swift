import CoreGraphics
import Foundation

/// One key in the three vocabularies this app has to speak at once: a
/// hand-editable `name` for the config, a HID `usage` (page 0x07) for
/// hidutil's UserKeyMapping, and a virtual `keyCode` for the event tap.
///
/// Keeping all three in one table is what lets a mapping be written once and
/// then routed to whichever engine can do it — see KeyMapping.
struct HIDKey: Equatable, Hashable, Identifiable {
    let name: String
    let usage: Int
    let keyCode: CGKeyCode

    var id: String { name }

    /// The full HID usage value hidutil wants: usage page 0x07 in the high word.
    var hidUsage: Int { 0x700000000 | usage }

    /// "capsLock" -> "Caps Lock", "a" -> "A". Derived rather than stored;
    /// the table is long enough without a label column.
    var label: String {
        if name.count == 1 { return name.uppercased() }
        var out = ""
        for character in name {
            if character.isUppercase, !out.isEmpty { out.append(" ") }
            out.append(out.isEmpty ? Character(character.uppercased()) : character)
        }
        return out
    }
}

/// The supported key set, and the lookups over it.
///
/// Deliberately not the whole HID table: these are the keys a remap is
/// plausibly aimed at, each one verified to have a virtual keycode so the
/// event tap can synthesize it.
/// A run of the key table, for the settings pickers — ninety-odd keys in one
/// flat popup is a wall.
struct KeyGroup: Identifiable {
    let name: String
    let keys: [HIDKey]

    var id: String { name }
}

enum HIDKeys {
    static let all: [HIDKey] = letters + digits + punctuation + functionKeys + navigation + modifiers

    /// The same table, grouped the way a picker should show it. Modifiers lead
    /// because they're what most remaps are about.
    static let groups: [KeyGroup] = [
        KeyGroup(name: "Modifiers", keys: modifiers),
        KeyGroup(name: "Letters", keys: letters),
        KeyGroup(name: "Digits", keys: digits),
        KeyGroup(name: "Punctuation", keys: punctuation),
        KeyGroup(name: "Function Keys", keys: functionKeys),
        KeyGroup(name: "Navigation", keys: navigation),
    ]

    /// Lenient on purpose — the config is hand-edited, so "caps_lock",
    /// "CapsLock" and "caps lock" all find the same key.
    static func named(_ name: String) -> HIDKey? { byName[normalize(name)] }

    static func withKeyCode(_ code: CGKeyCode) -> HIDKey? { byKeyCode[code] }

    /// Named because it's the one key whose effect outlives the press, which
    /// makes remapping it away a trap — see CapsLock in KeyRemapper. Spelled
    /// out rather than looked up so a comparison against it can't quietly
    /// become nil == nil.
    static let capsLock = HIDKey(name: "capsLock", usage: 0x39, keyCode: 57)

    /// Keys handed out as carriers for dual-role mappings: hidutil rewrites the
    /// real key to one of these at the HID layer, and the event tap watches for
    /// it. Going through a carrier is what tells the tap *which keyboard* a
    /// press came from — a CGEvent itself can't say, which is the usual reason
    /// this kind of thing needs a kernel driver.
    ///
    /// F18 leads because it's the least likely to exist physically; a keyboard
    /// that really does have these keys would collide, which is why the pool is
    /// ordered rather than a set.
    static let carrierPool: [HIDKey] = ["f18", "f19", "f20", "f17", "f16", "f15", "f14", "f13"]
        .compactMap { named($0) }

    private static let byName: [String: HIDKey] =
        Dictionary(all.map { (normalize($0.name), $0) }, uniquingKeysWith: { first, _ in first })

    private static let byKeyCode: [CGKeyCode: HIDKey] =
        Dictionary(all.map { ($0.keyCode, $0) }, uniquingKeysWith: { first, _ in first })

    private static func normalize(_ name: String) -> String {
        name.lowercased().filter { !" _-".contains($0) }
    }

    private static let letters: [HIDKey] = {
        let codes: [CGKeyCode] = [0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6]
        return zip("abcdefghijklmnopqrstuvwxyz", codes.enumerated()).map { letter, pair in
            HIDKey(name: String(letter), usage: 0x04 + pair.offset, keyCode: pair.element)
        }
    }()

    /// HID orders the digit row 1-9 then 0, which is why this isn't 0-9.
    private static let digits: [HIDKey] = {
        let codes: [CGKeyCode] = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29]
        return zip("1234567890", codes.enumerated()).map { digit, pair in
            HIDKey(name: String(digit), usage: 0x1E + pair.offset, keyCode: pair.element)
        }
    }()

    private static let punctuation: [HIDKey] = [
        HIDKey(name: "return", usage: 0x28, keyCode: 36),
        HIDKey(name: "escape", usage: 0x29, keyCode: 53),
        HIDKey(name: "delete", usage: 0x2A, keyCode: 51),
        HIDKey(name: "tab", usage: 0x2B, keyCode: 48),
        HIDKey(name: "space", usage: 0x2C, keyCode: 49),
        HIDKey(name: "minus", usage: 0x2D, keyCode: 27),
        HIDKey(name: "equal", usage: 0x2E, keyCode: 24),
        HIDKey(name: "leftBracket", usage: 0x2F, keyCode: 33),
        HIDKey(name: "rightBracket", usage: 0x30, keyCode: 30),
        HIDKey(name: "backslash", usage: 0x31, keyCode: 42),
        HIDKey(name: "semicolon", usage: 0x33, keyCode: 41),
        HIDKey(name: "quote", usage: 0x34, keyCode: 39),
        HIDKey(name: "grave", usage: 0x35, keyCode: 50),
        HIDKey(name: "comma", usage: 0x36, keyCode: 43),
        HIDKey(name: "period", usage: 0x37, keyCode: 47),
        HIDKey(name: "slash", usage: 0x38, keyCode: 44),
    ]

    private static let functionKeys: [HIDKey] = {
        let lower: [CGKeyCode] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        let upper: [CGKeyCode] = [105, 107, 113, 106, 64, 79, 80, 90]
        return lower.enumerated().map { HIDKey(name: "f\($0.offset + 1)", usage: 0x3A + $0.offset, keyCode: $0.element) }
            + upper.enumerated().map { HIDKey(name: "f\($0.offset + 13)", usage: 0x68 + $0.offset, keyCode: $0.element) }
    }()

    private static let navigation: [HIDKey] = [
        HIDKey(name: "home", usage: 0x4A, keyCode: 115),
        HIDKey(name: "pageUp", usage: 0x4B, keyCode: 116),
        HIDKey(name: "forwardDelete", usage: 0x4C, keyCode: 117),
        HIDKey(name: "end", usage: 0x4D, keyCode: 119),
        HIDKey(name: "pageDown", usage: 0x4E, keyCode: 121),
        HIDKey(name: "rightArrow", usage: 0x4F, keyCode: 124),
        HIDKey(name: "leftArrow", usage: 0x50, keyCode: 123),
        HIDKey(name: "downArrow", usage: 0x51, keyCode: 125),
        HIDKey(name: "upArrow", usage: 0x52, keyCode: 126),
    ]

    private static let modifiers: [HIDKey] = [
        capsLock,
        HIDKey(name: "leftControl", usage: 0xE0, keyCode: 59),
        HIDKey(name: "leftShift", usage: 0xE1, keyCode: 56),
        HIDKey(name: "leftOption", usage: 0xE2, keyCode: 58),
        HIDKey(name: "leftCommand", usage: 0xE3, keyCode: 55),
        HIDKey(name: "rightControl", usage: 0xE4, keyCode: 62),
        HIDKey(name: "rightShift", usage: 0xE5, keyCode: 60),
        HIDKey(name: "rightOption", usage: 0xE6, keyCode: 61),
        HIDKey(name: "rightCommand", usage: 0xE7, keyCode: 54),
    ]
}
