import AppKit
import Foundation
import IOKit
import IOKit.hid

/// Identity and naming for the attached keyboards — the KeyboardRef half of
/// what DisplayIdentity does for screens.
///
/// Permission-free: this reads the IOKit registry (properties only, no device
/// is ever opened), which needs no TCC grant. Opening a HID device for input
/// would prompt for Input Monitoring, so nothing here does.
enum KeyboardIdentity {
    static let builtInKey = "builtin"
    static let builtInName = "MacBook Keyboard"

    /// The attached keyboards, deduplicated and sorted by key.
    ///
    /// Deliberately *not* suffixed the way DisplayIdentity suffixes repeated
    /// screens: one physical keyboard often publishes several HID services
    /// (keyboard, media keys, vendor pages), and they must collapse to one
    /// entry. The cost is that two identical keyboards with no serial number
    /// look like one — hidutil couldn't tell them apart either.
    static func snapshot() -> [KeyboardRef] {
        var seen = Set<String>()
        var refs: [KeyboardRef] = []
        forEachKeyboardService { properties in
            let ref = reference(from: properties)
            if seen.insert(ref.key).inserted { refs.append(ref) }
        }
        return refs.sorted { $0.key < $1.key }
    }

    /// The `--matching` dictionary hidutil needs to single this keyboard out.
    ///
    /// Vendor plus product is the primary handle, deliberately *without* a
    /// usage filter: a keyboard whose keyboard interface is currently seized by
    /// another driver publishes no keyboard-usage service, and a filtered
    /// matcher would quietly select nothing. Landing on the device's other
    /// interfaces instead is harmless — a UserKeyMapping only rewrites
    /// keyboard-page usages.
    ///
    /// The built-in keyboard publishes no vendor or product id, so it falls
    /// back to its registry product string, and that *does* need the usage
    /// filter: the trackpad next to it answers to the same name.
    ///
    /// `BuiltIn` looks like the obvious matcher and isn't — hidutil doesn't
    /// accept it, and silently matches nothing.
    static func matchingJSON(for ref: KeyboardRef) -> String? {
        guard let matching = matchingProperties(for: ref),
              let data = try? JSONSerialization.data(withJSONObject: matching)
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// The same predicate as `matchingJSON`, as registry properties rather than
    /// JSON — so the walk that reads a mapping back off the hardware singles out
    /// exactly the services hidutil wrote it to. One source of truth on purpose:
    /// the two drifting apart would mean rewriting the mapping forever, or
    /// never noticing it had gone.
    static func matchingProperties(for ref: KeyboardRef) -> [String: Any]? {
        if let vendor = ref.vendorID, let product = ref.productID, vendor != 0 || product != 0 {
            return ["VendorID": vendor, "ProductID": product]
        }
        if let product = ref.productName, !product.isEmpty {
            return [
                "Product": product,
                "PrimaryUsagePage": kHIDPage_GenericDesktop,
                "PrimaryUsage": kHIDUsage_GD_Keyboard,
            ]
        }
        return nil
    }

    private static func reference(from properties: [String: Any]) -> KeyboardRef {
        let vendor = properties[kIOHIDVendorIDKey] as? Int
        let product = properties[kIOHIDProductIDKey] as? Int
        let serial = (properties[kIOHIDSerialNumberKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = (properties[kIOHIDProductKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let builtIn = (properties[kIOHIDBuiltInKey] as? Bool) ?? false

        if builtIn {
            return KeyboardRef(
                key: builtInKey,
                name: builtInName,
                productName: name,
                vendorID: vendor,
                productID: product,
                isBuiltIn: true
            )
        }
        var key = "hid:\(vendor ?? 0)-\(product ?? 0)"
        // Plenty of keyboards report no serial, which is fine — vendor and
        // product alone are as specific as hidutil can target anyway.
        if let serial, !serial.isEmpty { key += "-\(serial)" }
        return KeyboardRef(
            key: key,
            name: name?.isEmpty == false ? name! : "Keyboard \(vendor ?? 0):\(product ?? 0)",
            productName: name,
            vendorID: vendor,
            productID: product,
            isBuiltIn: false
        )
    }

    /// Walks every IOHIDDevice that publishes the keyboard usage.
    ///
    /// Devices with no `Transport` are skipped: those are driver-provided
    /// virtual keyboards (Karabiner's, and anything else that re-emits events),
    /// and remapping one is meaningless — the physical board behind it is the
    /// thing a mapping should be attached to.
    private static func forEachKeyboardService(_ body: ([String: Any]) -> Void) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(kIOHIDDeviceKey), &iterator) == KERN_SUCCESS
        else { return }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var unmanaged: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let properties = unmanaged?.takeRetainedValue() as? [String: Any],
                  isKeyboard(properties),
                  properties[kIOHIDTransportKey] != nil
            else { continue }
            body(properties)
        }
    }

    /// Usage page 1 (generic desktop), usage 6 (keyboard). Some devices only
    /// declare it in `DeviceUsagePairs`, so both are checked.
    private static func isKeyboard(_ properties: [String: Any]) -> Bool {
        if properties[kIOHIDPrimaryUsagePageKey] as? Int == kHIDPage_GenericDesktop,
           properties[kIOHIDPrimaryUsageKey] as? Int == kHIDUsage_GD_Keyboard {
            return true
        }
        let pairs = properties[kIOHIDDeviceUsagePairsKey] as? [[String: Int]] ?? []
        return pairs.contains {
            $0[kIOHIDDeviceUsagePageKey] == kHIDPage_GenericDesktop && $0[kIOHIDDeviceUsageKey] == kHIDUsage_GD_Keyboard
        }
    }
}

/// Keeps `config.keyboards` in step with the hardware: adopts keyboards that
/// have never been seen, refreshes the names of ones that have, and re-announces
/// the attached set whenever it changes.
///
/// Unlike DisplayProfileManager there's no "active" profile to resolve — every
/// attached keyboard's map is live at once. What matters instead is *when* to
/// re-announce: a hidutil mapping dies with the device, so a keyboard that is
/// unplugged and plugged back in needs its map applied again from scratch.
final class KeyboardManager {
    /// One plug fires several matching notifications (a keyboard publishes
    /// more than one HID service), so reads are debounced the way display
    /// changes are.
    private static let settleDelay: TimeInterval = 0.8

    private let store: ConfigStore
    private var notifyPort: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private var wakeObserver: NSObjectProtocol?
    private var pendingRescan: DispatchWorkItem?

    private(set) var attached: [KeyboardRef] = []

    /// Fired after every settled rescan, including the first at launch — even
    /// when the set is unchanged, since that's also the signal to reapply.
    var onKeyboardsChange: (([KeyboardRef]) -> Void)?

    init(store: ConfigStore) {
        self.store = store
    }

    deinit {
        pendingRescan?.cancel()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        for iterator in iterators { IOObjectRelease(iterator) }
        if let notifyPort { IONotificationPortDestroy(notifyPort) }
    }

    /// Scans once, then follows connects and disconnects.
    func start() {
        let port = IONotificationPortCreate(kIOMainPortDefault)
        IONotificationPortSetDispatchQueue(port, .main)
        notifyPort = port

        let context = Unmanaged.passUnretained(self).toOpaque()
        for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var iterator: io_iterator_t = 0
            // IOServiceAddMatchingNotification consumes a reference on the
            // matching dictionary, so each registration gets its own.
            guard IOServiceAddMatchingNotification(
                port, type, IOServiceMatching(kIOHIDDeviceKey), keyboardsChanged, context, &iterator
            ) == KERN_SUCCESS else { continue }
            // Draining arms the notification; leaving services in the iterator
            // means it never fires again.
            drain(iterator)
            iterators.append(iterator)
        }

        // Waking can bring a keyboard back without a fresh match notification,
        // and a USB board that lost power lost its mapping with it.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.scheduleRescan() }

        rescan()
    }

    func scheduleRescan() {
        pendingRescan?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rescan() }
        pendingRescan = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay, execute: work)
    }

    /// Reads the attached keyboards, files any new ones, and announces the set.
    func rescan() {
        pendingRescan?.cancel()
        let refs = KeyboardIdentity.snapshot()
        // An empty read means the registry is mid-reconfiguration (or the
        // machine is going to sleep), not "no keyboards" — a Mac always has
        // one. Adopting on that would file a phantom profile.
        if !refs.isEmpty {
            adopt(refs)
            attached = refs
        }
        onKeyboardsChange?(attached)
    }

    /// Files a profile for every keyboard we haven't seen, and keeps the stored
    /// names fresh for the ones we have.
    private func adopt(_ refs: [KeyboardRef]) {
        for ref in refs {
            if let index = store.config.keyboards.firstIndex(where: { $0.keyboard?.key == ref.key }) {
                if store.config.keyboards[index].keyboard != ref {
                    store.config.keyboards[index].keyboard = ref
                }
                continue
            }
            // "Begin from the last edited keymaps": a keyboard that turns up
            // for the first time inherits the map you've most recently been
            // working on rather than arriving blank. With no profiles at all
            // it starts empty — a first run must not invent remappings.
            let source = store.config.keyboards.max { $0.modifiedAt < $1.modifiedAt }
            let name = uniqueName(ref.name)
            let profile = source?.cloned(onto: ref, named: name) ?? KeyboardProfile(name: name, keyboard: ref)
            store.config.keyboards.append(profile)
        }
    }

    private func uniqueName(_ name: String) -> String {
        let taken = Set(store.config.keyboards.map(\.name))
        guard taken.contains(name) else { return name }
        var suffix = 2
        while taken.contains("\(name) (\(suffix))") { suffix += 1 }
        return "\(name) (\(suffix))"
    }

    private func drain(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 { IOObjectRelease(service) }
    }
}

/// C callback for the IOKit match/terminate notifications. Draining the
/// iterator is mandatory — see `drain`.
private let keyboardsChanged: IOServiceMatchingCallback = { context, iterator in
    while case let service = IOIteratorNext(iterator), service != 0 { IOObjectRelease(service) }
    guard let context else { return }
    Unmanaged<KeyboardManager>.fromOpaque(context).takeUnretainedValue().scheduleRescan()
}
