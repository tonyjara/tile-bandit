import XCTest
@testable import TileBandit

/// Switching to a workspace none of whose apps is running. Nothing of its own
/// can take focus, and macOS won't hide the active app while nothing replaces
/// it, so the app in front stayed over the empty workspace. Tile Bandit now
/// takes focus itself, which leaves the desktop.
final class EmptyWorkspaceTests: XCTestCase {
    private let whatsApp: pid_t = 501
    private let kuruPanel: pid_t = 502
    private let menuBarUtility: pid_t = 503

    // MARK: - Who takes focus

    /// The reported bug: WhatsApp in front, a switch to a workspace with
    /// nothing running. WhatsApp was asked to hide and nothing replaced it.
    func testTakesFocusWhenNothingOfTheWorkspaceRunsAndTheFrontAppIsLeaving() {
        XCTAssertTrue(WorkspaceEngine.takesFocusItself(focusTarget: nil, frontmost: whatsApp, asked: [whatsApp]))
    }

    /// The workspace has an app to focus: it takes over, as before.
    func testLeavesFocusToTheWorkspaceWhenItHasAnAppRunning() {
        XCTAssertFalse(WorkspaceEngine.takesFocusItself(focusTarget: 600, frontmost: whatsApp, asked: [whatsApp]))
    }

    /// A floating panel (or anything else allowed to stay) is in front: it
    /// wasn't asked to hide, so there's nothing to replace and it keeps focus.
    func testLeavesAFloatingAppInFront() {
        XCTAssertFalse(WorkspaceEngine.takesFocusItself(focusTarget: nil, frontmost: kuruPanel, asked: [whatsApp]))
    }

    /// An unlisted menu bar utility isn't managed, so it is never asked to
    /// hide; taking focus from it would close its popover.
    func testLeavesAnUnmanagedMenuBarUtilityInFront() {
        XCTAssertFalse(WorkspaceEngine.takesFocusItself(focusTarget: nil, frontmost: menuBarUtility, asked: [whatsApp]))
    }

    func testDoesNothingWithNothingInFront() {
        XCTAssertFalse(WorkspaceEngine.takesFocusItself(focusTarget: nil, frontmost: nil, asked: [whatsApp]))
    }

    // MARK: - Leftover or brought back

    /// Tile Bandit took focus, but the app that was in front still is: the
    /// activation hasn't landed. That's a leftover to hide again, not the
    /// user's doing. (A stand-in doesn't count as having moved focus.)
    func testTheFrontAppStillInFrontAfterAStandInIsALeftover() {
        XCTAssertFalse(WorkspaceEngine.wasBroughtBack(whatsApp, front: whatsApp, frontBefore: whatsApp, movedFocus: false))
    }

    /// A workspace app took focus, and the app that was in front is in front
    /// again: only the user can have brought it back.
    func testTheFrontAppInFrontAgainAfterFocusMovedWasBroughtBack() {
        XCTAssertTrue(WorkspaceEngine.wasBroughtBack(whatsApp, front: whatsApp, frontBefore: whatsApp, movedFocus: true))
    }

    /// Another hidden app is in front now: the user reached for it.
    func testAnotherHiddenAppInFrontWasBroughtBack() {
        XCTAssertTrue(WorkspaceEngine.wasBroughtBack(whatsApp, front: whatsApp, frontBefore: 600, movedFocus: false))
    }

    func testAnAppNotInFrontWasNotBroughtBack() {
        XCTAssertFalse(WorkspaceEngine.wasBroughtBack(whatsApp, front: 600, frontBefore: whatsApp, movedFocus: false))
        XCTAssertFalse(WorkspaceEngine.wasBroughtBack(whatsApp, front: nil, frontBefore: whatsApp, movedFocus: true))
    }
}
