import SleepGuardKit
import XCTest

/// The helper behind Stay Awake with Lid Closed runs as root, so the helper
/// itself can't be run here. Its decisions can: they are plain functions of
/// four facts, and every row of that table is worth pinning down, because the
/// rows that matter are the ones that must end with sleep switched back on.
final class SleepGuardTests: XCTestCase {
    private typealias Policy = SleepGuardPolicy

    // MARK: When sleep goes off

    func testSleepGoesOffOnlyWhenHeldAndOnTheCharger() {
        XCTAssertEqual(Policy.action(held: true, onExternalPower: true, sleepDisabled: false, ours: false), .disable)
        XCTAssertEqual(Policy.action(held: true, onExternalPower: false, sleepDisabled: false, ours: false), .none)
        XCTAssertEqual(Policy.action(held: false, onExternalPower: true, sleepDisabled: false, ours: false), .none)
        XCTAssertEqual(Policy.action(held: false, onExternalPower: false, sleepDisabled: false, ours: false), .none)
    }

    func testNothingToDoWhileItHolds() {
        XCTAssertEqual(Policy.action(held: true, onExternalPower: true, sleepDisabled: true, ours: true), .none)
    }

    /// Someone ran `pmset disablesleep 0` under us, or the note survived a
    /// failed write: the hold still stands, so it is switched off again.
    func testSwitchedOffAgainIfSomethingElseTurnedSleepBackOn() {
        XCTAssertEqual(Policy.action(held: true, onExternalPower: true, sleepDisabled: false, ours: true), .disable)
    }

    // MARK: When sleep comes back

    func testUnpluggingPutsSleepBackEvenWhileHeld() {
        XCTAssertEqual(Policy.action(held: true, onExternalPower: false, sleepDisabled: true, ours: true), .restore)
    }

    func testLosingTheCallerPutsSleepBack() {
        XCTAssertEqual(Policy.action(held: false, onExternalPower: true, sleepDisabled: true, ours: true), .restore)
        XCTAssertEqual(Policy.action(held: false, onExternalPower: false, sleepDisabled: true, ours: true), .restore)
    }

    /// The note with sleep already on is a crash between the two steps; the
    /// note still has to go.
    func testALeftoverNoteIsClearedEvenIfSleepIsAlreadyOn() {
        XCTAssertEqual(Policy.action(held: false, onExternalPower: true, sleepDisabled: false, ours: true), .restore)
        XCTAssertEqual(Policy.action(held: true, onExternalPower: false, sleepDisabled: false, ours: true), .restore)
    }

    /// The invariant, over the whole table: whenever nobody holds or the
    /// charger is out, a setting of ours never survives the decision.
    func testNeverLeavesOurSettingInPlaceOffTheChargerOrUnheld() {
        for held in [false, true] {
            for onPower in [false, true] where !(held && onPower) {
                for disabled in [false, true] {
                    XCTAssertEqual(
                        Policy.action(held: held, onExternalPower: onPower, sleepDisabled: disabled, ours: true),
                        .restore,
                        "held=\(held) onPower=\(onPower) disabled=\(disabled)"
                    )
                    // And it never switches sleep off in those rows.
                    XCTAssertEqual(
                        Policy.action(held: held, onExternalPower: onPower, sleepDisabled: disabled, ours: false),
                        .none
                    )
                }
            }
        }
    }

    // MARK: Somebody else's setting

    /// `sudo pmset disablesleep 1` by hand, with nothing of ours asking: not
    /// ours to undo.
    func testASettingMadeElsewhereIsLeftAlone() {
        XCTAssertEqual(Policy.action(held: false, onExternalPower: true, sleepDisabled: true, ours: false), .none)
        XCTAssertEqual(Policy.action(held: false, onExternalPower: false, sleepDisabled: true, ours: false), .none)
        XCTAssertEqual(Policy.action(held: true, onExternalPower: false, sleepDisabled: true, ours: false), .none)
    }

    /// Held on the charger with sleep already off: it is taken over, so the
    /// toggle going off really does bring sleep back.
    func testASettingMadeElsewhereIsTakenOverOnceHeld() {
        XCTAssertEqual(Policy.action(held: true, onExternalPower: true, sleepDisabled: true, ours: false), .adopt)
    }

    // MARK: Sleeping after sleep is allowed again

    func testLidOpenNeverAsksForSleep() {
        for causes in [false, true] {
            for onPower in [false, true] {
                XCTAssertFalse(Policy.shouldSleepNow(lidClosed: false, lidCausesSleep: causes, onExternalPower: onPower))
            }
        }
    }

    func testLidClosedOnBatteryAlwaysSleeps() {
        XCTAssertTrue(Policy.shouldSleepNow(lidClosed: true, lidCausesSleep: true, onExternalPower: false))
        // Even if the kernel's verdict hasn't caught up with the unplug yet.
        XCTAssertTrue(Policy.shouldSleepNow(lidClosed: true, lidCausesSleep: false, onExternalPower: false))
    }

    /// Lid closed at a desk with a display and the charger is an ordinary
    /// clamshell setup. Switching the toggle off there must not sleep it.
    func testLidClosedAsADesktopStaysAwake() {
        XCTAssertFalse(Policy.shouldSleepNow(lidClosed: true, lidCausesSleep: false, onExternalPower: true))
    }

    func testLidClosedOnPowerWithNoDisplaySleeps() {
        XCTAssertTrue(Policy.shouldSleepNow(lidClosed: true, lidCausesSleep: true, onExternalPower: true))
    }

    // MARK: What the menu says

    func testStatusComesFromTheMachineNotTheToggle() {
        typealias Status = LidAwakeStatus
        XCTAssertEqual(Status.resolve(wanted: false, acknowledged: true, onExternalPower: true, sleepDisabled: true), .off)
        XCTAssertEqual(Status.resolve(wanted: true, acknowledged: false, onExternalPower: true, sleepDisabled: true), .starting)
        XCTAssertEqual(Status.resolve(wanted: true, acknowledged: true, onExternalPower: true, sleepDisabled: true), .active)
        XCTAssertEqual(Status.resolve(wanted: true, acknowledged: true, onExternalPower: false, sleepDisabled: false), .waitingForPower)
        // On, on the charger, acknowledged — and the kernel disagrees.
        XCTAssertEqual(Status.resolve(wanted: true, acknowledged: true, onExternalPower: true, sleepDisabled: false), .notApplied)
        // On battery it is never "active", whatever the flag says.
        XCTAssertEqual(Status.resolve(wanted: true, acknowledged: true, onExternalPower: false, sleepDisabled: true), .waitingForPower)
    }

    // MARK: Who may call

    func testRequirementNamesTheIdentifierAndTheTeam() {
        XCTAssertEqual(
            SleepGuard.requirement(identifier: "com.twonary.TileBandit", team: "ABCDE12345"),
            "anchor apple generic and identifier \"com.twonary.TileBandit\" and certificate leaf[subject.OU] = \"ABCDE12345\""
        )
    }

    /// The team is read off a signature, not typed by anyone, but it is
    /// spliced into a requirement — so anything that isn't a plain id is
    /// refused rather than quoted.
    func testRequirementRefusesATeamThatIsNotAPlainID() {
        XCTAssertNil(SleepGuard.requirement(identifier: "com.twonary.TileBandit", team: ""))
        XCTAssertNil(SleepGuard.requirement(identifier: "com.twonary.TileBandit", team: "X\" or anchor apple"))
        XCTAssertNil(SleepGuard.requirement(identifier: "com.twonary.TileBandit", team: "AB CD"))
    }

    /// The readings need no grant and must not crash where there is no
    /// battery, no lid, or (in CI) no power sources at all.
    func testPowerReadingsAreSafeToTake() {
        _ = Power.onExternalPower
        _ = Power.sleepDisabled
        _ = Power.lidCausesSleep
        XCTAssertEqual(Power.hasLid, Power.lidClosed != nil)
    }
}
