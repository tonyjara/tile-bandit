import Foundation
import Security

/// What the app and the privileged helper have to agree on, in one place.
///
/// The helper (`TileBanditSleepGuard`) is the only part of Tile Bandit that
/// runs as root, and this is its whole interface: two messages, neither with
/// an argument. Everything it does beyond that — reading the power source,
/// putting sleep back — it decides for itself, so there is nothing a caller
/// can ask it for except "keep the Mac awake with the lid closed while I'm
/// still here and the charger is in".
@objc public protocol SleepGuardXPC {
    /// Holds sleep off for as long as this connection lives *and* the Mac is
    /// on external power. There is no "release": dropping the connection is
    /// the release, which makes quitting, crashing and switching the toggle
    /// off one and the same path.
    func hold(reply: @escaping (Bool) -> Void)

    /// "Look again now." Changes nothing the helper wouldn't do unasked; its
    /// use is that any message makes launchd start the helper, and starting
    /// is when a setting left behind by a run that died gets put back. The
    /// reply is whether the helper has sleep switched off at this moment.
    func check(reply: @escaping (Bool) -> Void)
}

public enum SleepGuard {
    /// The launchd label, which is also the Mach service the helper answers on.
    public static let label = "com.twonary.TileBandit.SleepGuard"
    /// The launchd plist inside the bundle (Contents/Library/LaunchDaemons).
    public static let plistName = "com.twonary.TileBandit.SleepGuard.plist"
    /// The only code the helper takes a message from.
    public static let appIdentifier = "com.twonary.TileBandit"

    /// A code-signing requirement: this identifier, signed with an
    /// Apple-issued certificate belonging to this team.
    ///
    /// The team is not written down anywhere — each side reads it off its own
    /// signature (`ownTeamID`) and demands the same of the other, so a fork
    /// signed by someone else pairs with its own helper and with nobody
    /// else's. nil for a team that isn't the plain alphanumeric id Apple
    /// issues, so nothing odd can be spliced into the requirement.
    public static func requirement(identifier: String, team: String) -> String? {
        let plain = CharacterSet.alphanumerics
        guard !team.isEmpty, team.unicodeScalars.allSatisfy(plain.contains) else { return nil }
        return "anchor apple generic and identifier \"\(identifier)\""
            + " and certificate leaf[subject.OU] = \"\(team)\""
    }

    /// The team that signed the running code; nil when it is unsigned or
    /// ad-hoc signed, which is every `swift build` and a plain `make app`.
    public static func ownTeamID() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess,
              let dict = info as? [String: Any]
        else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }
}

/// The decisions, kept free of anything that touches the machine so they can
/// be tested — the helper can't be run in a test without being root.
public enum SleepGuardPolicy {
    public enum Action: Equatable {
        case none
        /// Note that the setting is ours, then switch sleep off.
        case disable
        /// Sleep is already off but not by us: take it over, so it is put
        /// back when the hold ends. Leaving it would mean a Mac that stays
        /// awake on battery after the toggle said otherwise.
        case adopt
        /// Switch sleep back on and forget the note.
        case restore
    }

    /// - Parameters:
    ///   - held: a live connection asked for the hold.
    ///   - onExternalPower: the charger is in. Anything else — battery, a UPS,
    ///     a reading that failed — counts as no.
    ///   - sleepDisabled: what the kernel says right now, not what was last written.
    ///   - ours: the note that says the helper switched sleep off.
    public static func action(held: Bool, onExternalPower: Bool, sleepDisabled: Bool, ours: Bool) -> Action {
        if held && onExternalPower {
            if !sleepDisabled { return .disable }
            return ours ? .none : .adopt
        }
        // Not wanted. A setting someone else made (`sudo pmset disablesleep 1`
        // by hand) is theirs to undo; only ours is put back.
        return ours ? .restore : .none
    }

    /// Whether to send the Mac to sleep after putting sleep back.
    ///
    /// Clearing the setting only *allows* sleep again. The lid closed while
    /// it was refused, that moment has passed, and macOS doesn't look at the
    /// lid a second time — with anything holding an idle assertion (an agent,
    /// a download) the Mac would sit awake in a bag. So when the lid is shut
    /// and macOS would normally be asleep, sleep is asked for outright.
    /// `lidCausesSleep` is the kernel's own verdict (false while an external
    /// display and the charger make it a desktop); on battery a closed lid
    /// always sleeps, whatever is attached.
    public static func shouldSleepNow(lidClosed: Bool, lidCausesSleep: Bool, onExternalPower: Bool) -> Bool {
        lidClosed && (lidCausesSleep || !onExternalPower)
    }
}

/// What the menu says about the toggle.
public enum LidAwakeStatus: Equatable {
    case off
    /// Asked, no answer from the helper yet.
    case starting
    /// Sleep is off: the lid can close.
    case active
    /// On battery — sleeping normally until the charger is back.
    case waitingForPower
    /// On power and the helper took the hold, yet sleep is still on.
    case notApplied

    /// Whether the Mac is, right now, being kept from sleeping — what the menu
    /// bar indicator shows. Only `active`: a toggle that is on but waiting for
    /// the charger is a Mac that will sleep, and the indicator exists to be
    /// believed at a glance.
    public var holdsSleepOff: Bool { self == .active }

    /// Derived from what the machine reports, never from what was asked for:
    /// "active" means the kernel says sleep is disabled.
    public static func resolve(wanted: Bool, acknowledged: Bool, onExternalPower: Bool, sleepDisabled: Bool) -> LidAwakeStatus {
        guard wanted else { return .off }
        guard acknowledged else { return .starting }
        guard onExternalPower else { return .waitingForPower }
        return sleepDisabled ? .active : .notApplied
    }
}
