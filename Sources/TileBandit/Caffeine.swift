import Foundation
import IOKit.pwr_mgt

/// Keeps the Mac awake — `caffeinate -di`, held by this process.
///
/// Two power assertions, because they answer different idle timers: the
/// display one keeps the screen on (and with it the screen saver off — it
/// waits on the same idle the display does), the system one keeps the machine
/// itself from idle-sleeping. Both are the *user-idle* kind on purpose: they
/// hold on battery as well as on AC, unlike `PreventSystemSleep` (`caffeinate
/// -s`), which macOS only honours on mains power. Neither overrides closing
/// the lid or a critically low battery, and nothing should.
///
/// Session-only, never written to the config: an assertion belongs to the
/// process and dies with it, so a quit or a crash can't leave the machine
/// awake for good, and a relaunch starts sleeping normally again.
/// Permission-free — IOKit power assertions need no TCC grant.
final class Caffeine {
    private(set) var isActive = false
    private var assertions: [IOPMAssertionID] = []

    func toggle() {
        isActive ? stop() : start()
    }

    func start() {
        guard !isActive else { return }
        let reason = "Tile Bandit: Caffeinate" as CFString
        for type in [kIOPMAssertionTypePreventUserIdleDisplaySleep, kIOPMAssertionTypePreventUserIdleSystemSleep] {
            var id = IOPMAssertionID(0)
            let status = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &id)
            if status == kIOReturnSuccess {
                assertions.append(id)
            } else {
                NSLog("Tile Bandit: power assertion \(type) failed (\(status))")
            }
        }
        // Only claim to be awake if macOS actually agreed to something —
        // a coffee cup over a machine that will sleep anyway is a lie.
        isActive = !assertions.isEmpty
    }

    func stop() {
        for id in assertions { IOPMAssertionRelease(id) }
        assertions.removeAll()
        isActive = false
    }
}
