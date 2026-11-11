import XCTest
@testable import TileBandit

/// The decisions a workspace switch takes, without a screen: what a workspace
/// remembers, and which windows have to move to put its stack back.
///
/// Letters stand for windows (or apps). "B" is the shared one: the browser
/// that sits in both workspaces and is never hidden.
final class SwitchLogicTests: XCTestCase {
    // MARK: Putting a stack back

    func testNothingMovesWhenTheOrderIsAlreadyRight() {
        XCTAssertEqual(StackPlan.raisesNeeded(desired: ["E", "T", "B"], actual: ["E", "T", "B"]), [])
    }

    /// The reported bug: the shared window was in front when the switch began
    /// and this workspace remembers something else on top.
    func testRememberedFocusComesForwardOverASharedWindowThatWasInFront() {
        XCTAssertEqual(StackPlan.raisesNeeded(desired: ["E", "B"], actual: ["B", "E"]), ["E"])
    }

    /// The whole stack, not just the front window: T was above the shared
    /// window when the workspace was left, so it goes back above it.
    func testASharedWindowDoesNotStayOnTopOfWhatWasAboveIt() {
        // Raised from the back forward; the last one ends up in front.
        XCTAssertEqual(StackPlan.raisesNeeded(desired: ["E", "T", "B"], actual: ["E", "B", "T"]), ["T", "E"])
    }

    func testOnlyTheWindowsOutOfPlaceAreRaised() {
        // C and D already sit in the right order at the bottom.
        XCTAssertEqual(StackPlan.raisesNeeded(desired: ["A", "B", "C", "D"], actual: ["C", "B", "D", "A"]), ["B", "A"])
    }

    func testRaisingInThatOrderProducesTheDesiredStack() {
        let desired = ["A", "B", "C", "D", "E"]
        for actual in [["E", "D", "C", "B", "A"], ["B", "A", "D", "C", "E"], ["C", "E", "A", "D", "B"], desired] {
            var stack = actual
            for item in StackPlan.raisesNeeded(desired: desired, actual: actual) {
                stack.removeAll { $0 == item }
                stack.insert(item, at: 0)
            }
            XCTAssertEqual(stack, desired, "from \(actual)")
        }
    }

    /// A window opened since the workspace was left — the shared app's window
    /// from the other workspace — goes under what is remembered.
    func testWindowsNotRememberedGoUnderTheOnesThatAre() {
        let desired = StackPlan.desired(remembered: ["E", "B1"], actual: ["B2", "B1", "E"])
        XCTAssertEqual(desired, ["E", "B1", "B2"])
        XCTAssertEqual(StackPlan.raisesNeeded(desired: desired, actual: ["B2", "B1", "E"]), ["B1", "E"])
    }

    func testRememberedWindowsThatAreGoneAreLeftOut() {
        XCTAssertEqual(StackPlan.desired(remembered: ["closed", "E", "T"], actual: ["T", "E"]), ["E", "T"])
    }

    func testFirstVisitKeepsTheOrderThatIsThere() {
        XCTAssertEqual(StackPlan.desired(remembered: [String](), actual: ["B", "E"]), ["B", "E"])
    }

    func testPromotingMovesOnlyTheFirstMatch() {
        XCTAssertEqual(StackPlan.promoting(["A", "B1", "C", "B2"]) { $0.hasPrefix("B") }, ["B1", "A", "C", "B2"])
        XCTAssertEqual(StackPlan.promoting(["A", "C"]) { $0 == "Z" }, ["A", "C"])
    }

    // MARK: What a workspace remembers

    private func entry(_ window: CGWindowID, _ app: String) -> WorkspaceSnapshot.Entry {
        WorkspaceSnapshot.Entry(window: window, bundleId: app)
    }

    func testSnapshotKeepsTheOrderAndTheAppInFront() {
        var snapshot = WorkspaceSnapshot()
        snapshot.update(onScreen: [entry(1, "editor"), entry(2, "browser")], frontmost: "editor")
        XCTAssertEqual(snapshot.stack.map(\.window), [1, 2])
        XCTAssertEqual(snapshot.focusBundleId, "editor")
    }

    /// Each workspace has its own snapshot, written only when it is left, so
    /// using the shared browser in one cannot change what the other remembers.
    func testFocusingASharedAppInOneWorkspaceLeavesTheOtherAlone() {
        var code = WorkspaceSnapshot()
        var chat = WorkspaceSnapshot()
        code.update(onScreen: [entry(1, "editor"), entry(9, "browser")], frontmost: "editor")
        // In the chat workspace the browser is used and is in front on leaving.
        chat.update(onScreen: [entry(9, "browser"), entry(5, "messages")], frontmost: "browser")
        XCTAssertEqual(code.focusBundleId, "editor")
        XCTAssertEqual(code.stack.map(\.window), [1, 9])
        XCTAssertEqual(chat.focusBundleId, "browser")
    }

    /// Two windows of the shared app, a different one on top in each workspace.
    func testASharedAppCanHaveADifferentWindowOnTopInEachWorkspace() {
        var code = WorkspaceSnapshot()
        var chat = WorkspaceSnapshot()
        code.update(onScreen: [entry(10, "browser"), entry(1, "editor"), entry(11, "browser")], frontmost: "browser")
        chat.update(onScreen: [entry(11, "browser"), entry(5, "messages"), entry(10, "browser")], frontmost: "browser")
        XCTAssertEqual(code.stack.first?.window, 10)
        XCTAssertEqual(chat.stack.first?.window, 11)
    }

    func testAnAppOutsideTheWorkspaceInFrontFallsBackToTheTopWindow() {
        var snapshot = WorkspaceSnapshot()
        snapshot.update(onScreen: [entry(2, "terminal"), entry(1, "editor")], frontmost: nil)
        XCTAssertEqual(snapshot.focusBundleId, "terminal")
    }

    func testNothingOnScreenKeepsTheFocusAlreadyRemembered() {
        var snapshot = WorkspaceSnapshot()
        snapshot.update(onScreen: [entry(1, "editor")], frontmost: "editor")
        snapshot.update(onScreen: [], frontmost: nil)
        XCTAssertEqual(snapshot.focusBundleId, "editor")
        XCTAssertEqual(snapshot.stack.map(\.window), [1])
    }

    /// An app still on its way back when the workspace is left again keeps its
    /// place, after the windows that are on screen.
    func testWindowsNotOnScreenAtTheMomentAreKeptBehindTheOnesThatAre() {
        var snapshot = WorkspaceSnapshot()
        snapshot.update(onScreen: [entry(1, "editor"), entry(2, "terminal")], frontmost: "editor")
        snapshot.update(onScreen: [entry(2, "terminal")], frontmost: "terminal")
        XCTAssertEqual(snapshot.stack.map(\.window), [2, 1])
    }

    func testTheStackIsCapped() {
        var snapshot = WorkspaceSnapshot()
        for round in 0..<10 {
            let windows = (0..<20).map { entry(CGWindowID(round * 100 + $0), "app") }
            snapshot.update(onScreen: windows, frontmost: "app")
        }
        XCTAssertEqual(snapshot.stack.count, WorkspaceSnapshot.stackLimit)
    }

    // MARK: The placeholder display

    func testThePlaceholderDisplayIsRecognised() {
        // 'unkn' and 'virt' as numbers, the way a display key carries them.
        XCTAssertTrue(DisplayIdentity.isPlaceholder(key: "edid:1970170734-1986622068-0"))
        XCTAssertTrue(DisplayIdentity.isPlaceholder(key: "edid:1970170734-1986622068-0#2"))
    }

    func testRealDisplaysAreNot() {
        XCTAssertFalse(DisplayIdentity.isPlaceholder(key: "builtin"))
        XCTAssertFalse(DisplayIdentity.isPlaceholder(key: "edid:1234-5678-0"))
        XCTAssertFalse(DisplayIdentity.isPlaceholder(key: "name:Projector"))
    }
}
