import Foundation
import IOKit
import IOKit.ps
import notify

/// What the machine says about power, sleep and the lid. All of it is read
/// from IOKit without any grant, so the app can check the helper's work
/// instead of taking its word.
public enum Power {
    /// True only on the charger. A UPS, the battery or a reading that failed
    /// all count as no: every doubt has to end with sleep switched back on.
    public static var onExternalPower: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue()
        else { return false }
        return (type as String) == kIOPMACPowerKey
    }

    /// The kernel's own switch (`pmset disablesleep`, shown as `SleepDisabled`
    /// by `pmset -g`). Read from the power root domain: this is the flag that
    /// refuses sleep, where the preference file is only a request to set it.
    public static var sleepDisabled: Bool { rootDomainFlag("SleepDisabled") ?? false }

    /// nil on a Mac with no lid.
    public static var lidClosed: Bool? { rootDomainFlag("AppleClamshellState") }

    /// Whether macOS would sleep on a closed lid right now — false while an
    /// external display plus the charger make it a desktop.
    public static var lidCausesSleep: Bool { rootDomainFlag("AppleClamshellCausesSleep") ?? false }

    public static var hasLid: Bool { lidClosed != nil }

    private static func rootDomainFlag(_ key: String) -> Bool? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IOPower:/IOPowerConnection/IOPMrootDomain")
        guard entry != MACH_PORT_NULL else { return nil }
        defer { IOObjectRelease(entry) }
        let value = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
        return value as? Bool
    }

    /// Calls back on the main queue whenever the power sources change.
    ///
    /// Two subscriptions for one fact, because this is the signal that puts
    /// sleep back when the charger comes out: IOKit's run-loop source (which
    /// also fires for every battery percent) and the notify key posted only
    /// when the source itself changes. Either may arrive first and both may
    /// arrive, so the handler has to be cheap and to re-read, not assume.
    public final class Watcher {
        private var source: CFRunLoopSource?
        private var token: Int32 = NOTIFY_TOKEN_INVALID
        private let handler: () -> Void

        public init(_ handler: @escaping () -> Void) {
            self.handler = handler
            let context = Unmanaged.passUnretained(self).toOpaque()
            source = IOPSNotificationCreateRunLoopSource({ context in
                guard let context else { return }
                Unmanaged<Watcher>.fromOpaque(context).takeUnretainedValue().handler()
            }, context)?.takeRetainedValue()
            if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode) }
            notify_register_dispatch(kIOPSNotifyPowerSource, &token, .main) { [weak self] _ in
                self?.handler()
            }
        }

        public var isWatching: Bool { source != nil || token != NOTIFY_TOKEN_INVALID }

        deinit {
            if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode) }
            if token != NOTIFY_TOKEN_INVALID { notify_cancel(token) }
        }
    }
}
