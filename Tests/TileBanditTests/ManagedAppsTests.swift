import AppKit
import XCTest
@testable import TileBandit

/// Which running apps a switch takes charge of, decided from the activation
/// policy and the workspaces' lists.
final class ManagedAppsTests: XCTestCase {
    private let listed: Set<String> = ["io.github.tonyjara.kururu", "net.whatsapp.WhatsApp"]

    func testRegularAppsAreAlwaysManaged() {
        XCTAssertTrue(WorkspaceEngine.isManaged(policy: .regular, bundleId: "net.whatsapp.WhatsApp", listed: listed))
        XCTAssertTrue(WorkspaceEngine.isManaged(policy: .regular, bundleId: "com.example.unlisted", listed: listed))
        // Started from a terminal: no bundle id, hidden like any other.
        XCTAssertTrue(WorkspaceEngine.isManaged(policy: .regular, bundleId: nil, listed: listed))
    }

    /// The reported bug: Kururu drops its Dock icon while only its panel is up.
    /// Filtered out, its workspace looked empty, nothing took focus, and
    /// WhatsApp stayed on screen in K.
    func testAListedAppThatWentAccessoryIsStillManaged() {
        XCTAssertTrue(WorkspaceEngine.isManaged(policy: .accessory, bundleId: "io.github.tonyjara.kururu", listed: listed))
    }

    func testAnUnlistedAccessoryAppIsLeftAlone() {
        // A menu bar utility, or the listed app's own helper.
        XCTAssertFalse(WorkspaceEngine.isManaged(policy: .accessory, bundleId: "io.github.tonyjara.kururu.helper", listed: listed))
        XCTAssertFalse(WorkspaceEngine.isManaged(policy: .accessory, bundleId: nil, listed: listed))
    }

    func testBackgroundOnlyAppsAreNeverManaged() {
        XCTAssertFalse(WorkspaceEngine.isManaged(policy: .prohibited, bundleId: "io.github.tonyjara.kururu", listed: listed))
    }
}
