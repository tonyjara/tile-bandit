import XCTest
@testable import TileBandit

/// Reordering workspaces from the keyboard in Settings (dragging a row goes
/// through `Array.move(fromOffsets:toOffset:)`, which needs no test of ours).
final class WorkspaceOrderTests: XCTestCase {
    private func list(_ names: String...) -> [Workspace] {
        names.enumerated().map { index, name in
            var workspace = Workspace(name: name)
            workspace.shortcut = Shortcut(key: "\(index + 1)")
            return workspace
        }
    }

    func testMovesOneStepEitherWay() {
        var workspaces = list("Code", "Web", "Chat")
        XCTAssertTrue(workspaces.move(workspaces[2].id, by: -1))
        XCTAssertEqual(workspaces.map(\.name), ["Code", "Chat", "Web"])
        XCTAssertTrue(workspaces.move(workspaces[0].id, by: 1))
        XCTAssertEqual(workspaces.map(\.name), ["Chat", "Code", "Web"])
    }

    func testStopsAtEitherEnd() {
        var workspaces = list("Code", "Web")
        let before = workspaces
        XCTAssertFalse(workspaces.move(workspaces[0].id, by: -1))
        XCTAssertFalse(workspaces.move(workspaces[1].id, by: 1))
        XCTAssertEqual(workspaces, before)
    }

    func testUnknownWorkspaceChangesNothing() {
        var workspaces = list("Code", "Web")
        let before = workspaces
        XCTAssertFalse(workspaces.move(UUID(), by: 1))
        XCTAssertEqual(workspaces, before)
    }

    /// The shortcut belongs to the workspace, not its place in the list:
    /// moving "Chat" to the top leaves it on ⌥3, so muscle memory survives.
    func testShortcutsStayWithTheirWorkspace() {
        var workspaces = list("Code", "Web", "Chat")
        workspaces.move(workspaces[2].id, by: -1)
        workspaces.move(workspaces[1].id, by: -1)
        XCTAssertEqual(workspaces.map(\.name), ["Chat", "Code", "Web"])
        XCTAssertEqual(workspaces.map { $0.shortcut?.key }, ["3", "1", "2"])
    }

    /// What Settings writes is what the next launch reads: the order survives
    /// a save and a load.
    func testOrderSurvivesTheConfigFile() throws {
        var workspaces = list("Code", "Web", "Chat")
        workspaces.move(workspaces[2].id, by: -1)
        let data = try JSONEncoder().encode(workspaces)
        let decoded = try JSONDecoder().decode([Workspace].self, from: data)
        XCTAssertEqual(decoded.map(\.name), ["Code", "Chat", "Web"])
        XCTAssertEqual(decoded.map(\.id), workspaces.map(\.id))
    }
}
