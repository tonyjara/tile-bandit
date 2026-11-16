import AppKit
import XCTest
@testable import TileBandit

/// Why an app asked to hide still draws a window: slow, or out of reach.
/// The three readings were measured against scratch apps hidden from another
/// process (docs/audit/workspace-switch.md, finding 10).
final class StillUpTests: XCTestCase {
    /// A busy app reads as not hidden until its windows are down.
    func testAnAppThatHasNotHiddenYetIsAskedAgain() {
        XCTAssertEqual(WorkspaceEngine.stillUp(policy: .regular, isHidden: false), .notHiddenYet)
    }

    /// The reported bug: Kururu read as hidden in M with its main window up.
    func testHiddenAndStillDrawnIsAWindowExemptFromHiding() {
        XCTAssertEqual(WorkspaceEngine.stillUp(policy: .regular, isHidden: true), .exemptWindow)
    }

    /// `hide()` does nothing to an app with no Dock icon, and its flag stays
    /// false, so the policy is what tells it from a slow app.
    func testAnAccessoryAppIsNeverHidden() {
        XCTAssertEqual(WorkspaceEngine.stillUp(policy: .accessory, isHidden: false), .accessory)
        XCTAssertEqual(WorkspaceEngine.stillUp(policy: .accessory, isHidden: true), .accessory)
    }
}
