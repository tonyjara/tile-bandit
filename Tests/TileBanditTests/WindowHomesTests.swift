import XCTest
@testable import TileBandit

/// Per-window workspaces without a screen: which window lives where, what a
/// switch wants done with it, how a window is recognised after its app
/// restarts, and where a window is parked.
///
/// "browser" is the per-window app, listed in both Chat and Code. Window 1 is
/// the one used in Chat, window 2 the one used in Code.
final class WindowHomesTests: XCTestCase {
    private let chat = WindowHomes.Place(id: UUID(), name: "Chat", apps: ["browser", "messages"])
    private let code = WindowHomes.Place(id: UUID(), name: "Code", apps: ["browser", "editor"])
    private let mail = WindowHomes.Place(id: UUID(), name: "Mail", apps: ["mail"])
    private var places: [WindowHomes.Place] { [chat, code, mail] }
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func window(
        _ id: CGWindowID,
        app: String = "browser",
        frame: CGRect = CGRect(x: 100, y: 100, width: 800, height: 600),
        title: String? = nil,
        inSight: Bool = true,
        pid: pid_t = 500
    ) -> LiveWindow {
        LiveWindow(id: id, pid: pid, bundleId: app, frame: frame, title: title, inSight: inSight)
    }

    /// Window 1 at home in Chat, window 2 in Code.
    private func twoHomes() -> WindowHomes {
        var homes = WindowHomes()
        homes.claim([window(1)], for: chat, among: places, now: now)
        homes.claim([window(2)], for: code, among: places, now: now)
        return homes
    }

    // MARK: A window gets a home

    func testANewWindowJoinsTheWorkspaceItIsLeftIn() {
        var homes = WindowHomes()
        let claimed = homes.claim([window(1)], for: chat, among: places, now: now)
        XCTAssertEqual(claimed.map(\.id), [1])
        XCTAssertEqual(homes.home(of: 1, among: places), chat.id)
    }

    func testAWindowOutOfSightIsNotClaimed() {
        var homes = WindowHomes()
        homes.claim([window(1, inSight: false)], for: chat, among: places, now: now)
        XCTAssertNil(homes.record(of: 1))
    }

    /// The app was opened by hand in a workspace that doesn't list it: the
    /// window waits for a workspace that does.
    func testAWorkspaceThatDoesNotListTheAppClaimsNothing() {
        var homes = WindowHomes()
        homes.claim([window(1)], for: mail, among: places, now: now)
        XCTAssertNil(homes.record(of: 1))
        XCTAssertEqual(homes.wanted(1, active: mail.id, among: places), .free)
    }

    /// Dragged out of its corner while in another workspace: leaving that
    /// workspace does not take it over.
    func testAHomeStandsWhenTheWindowIsInSightSomewhereElse() {
        var homes = twoHomes()
        let claimed = homes.claim([window(1), window(2)], for: chat, among: places, now: now)
        XCTAssertEqual(claimed, [])
        XCTAssertEqual(homes.home(of: 2, among: places), code.id)
    }

    func testLeavingRefreshesWhereAWindowIsShown() {
        var homes = twoHomes()
        let moved = CGRect(x: 40, y: 60, width: 900, height: 700)
        homes.claim([window(1, frame: moved)], for: chat, among: places, now: now)
        XCTAssertEqual(homes.record(of: 1)?.shown, moved)
    }

    // MARK: What a switch wants

    func testAWindowIsShownAtHomeAndParkedElsewhere() {
        let homes = twoHomes()
        XCTAssertEqual(homes.wanted(1, active: chat.id, among: places), .shown)
        XCTAssertEqual(homes.wanted(2, active: chat.id, among: places), .parked)
        XCTAssertEqual(homes.wanted(1, active: code.id, among: places), .parked)
        XCTAssertEqual(homes.wanted(2, active: code.id, among: places), .shown)
    }

    func testAWindowNobodyClaimedIsLeftAlone() {
        XCTAssertEqual(twoHomes().wanted(3, active: chat.id, among: places), .free)
    }

    /// At launch, and in a display setup with nowhere to land.
    func testWithNoWorkspaceActiveNothingIsParked() {
        let homes = twoHomes()
        XCTAssertEqual(homes.wanted(2, active: nil, among: places), .shown)
        XCTAssertEqual(homes.elsewhere(than: nil, among: places), [])
    }

    /// What a snapshot of Chat leaves out, and what Apply Grid Layout skips.
    func testWindowsElsewhereAreTheOtherWorkspacesOwn() {
        let homes = twoHomes()
        XCTAssertEqual(homes.elsewhere(than: chat.id, among: places), [2])
        XCTAssertEqual(homes.elsewhere(than: code.id, among: places), [1])
    }

    func testSendingAWindowToAnotherWorkspace() {
        var homes = twoHomes()
        homes.assign(window(1), to: code, now: now)
        XCTAssertEqual(homes.home(of: 1, among: places), code.id)
        XCTAssertEqual(homes.elsewhere(than: chat.id, among: places), [1, 2])
    }

    func testAWindowNeverSeenCanBeSentToo() {
        var homes = WindowHomes()
        homes.assign(window(7), to: code, now: now)
        XCTAssertEqual(homes.wanted(7, active: chat.id, among: places), .parked)
    }

    // MARK: Display profiles

    /// A new display profile is a clone with new workspace ids. "Code" at the
    /// desk is still where the window lives.
    func testAHomeCarriesOverToTheWorkspaceOfTheSameName() {
        let homes = twoHomes()
        let deskChat = WindowHomes.Place(id: UUID(), name: "Chat", apps: ["browser"])
        let deskCode = WindowHomes.Place(id: UUID(), name: "Code", apps: ["browser"])
        XCTAssertEqual(homes.home(of: 2, among: [deskChat, deskCode]), deskCode.id)
        XCTAssertEqual(homes.wanted(2, active: deskChat.id, among: [deskChat, deskCode]), .parked)
    }

    func testAHomeThatDroppedTheAppIsNoHome() {
        let homes = twoHomes()
        let codeWithoutBrowser = WindowHomes.Place(id: code.id, name: "Code", apps: ["editor"])
        XCTAssertNil(homes.home(of: 2, among: [chat, codeWithoutBrowser]))
        XCTAssertEqual(homes.wanted(2, active: chat.id, among: [chat, codeWithoutBrowser]), .shown)
    }

    func testAWindowWithNoHomeInThisSetupIsTakenLikeANewOne() {
        var homes = twoHomes()
        let other = WindowHomes.Place(id: UUID(), name: "Research", apps: ["browser"])
        let claimed = homes.claim([window(2)], for: other, among: [other], now: now)
        XCTAssertEqual(claimed.map(\.id), [2])
        XCTAssertEqual(homes.home(of: 2, among: [other]), other.id)
    }

    // MARK: Parked and back

    func testParkingKeepsWherTheWindowWasShown() {
        var homes = twoHomes()
        let shown = homes.record(of: 2)?.shown
        homes.parked(2, at: CGPoint(x: 1439, y: 868), from: nil)
        XCTAssertEqual(homes.record(of: 2)?.parkedAt, CGPoint(x: 1439, y: 868))
        XCTAssertEqual(homes.record(of: 2)?.shown, shown)
        homes.unparked(2)
        XCTAssertNil(homes.record(of: 2)?.parkedAt)
        XCTAssertEqual(homes.record(of: 2)?.shown, shown)
    }

    func testParkingFromANewPlaceRemembersIt() {
        var homes = twoHomes()
        let tiled = CGRect(x: 0, y: 25, width: 900, height: 1000)
        homes.parked(2, at: CGPoint(x: 1439, y: 868), from: tiled)
        XCTAssertEqual(homes.record(of: 2)?.shown, tiled)
    }

    // MARK: Windows that are gone

    func testAClosedWindowBecomesAnOrphan() {
        var homes = twoHomes()
        homes.retire(now: now) { window, _ in window == 1 }
        XCTAssertEqual(homes.records.map(\.window), [1])
        XCTAssertEqual(homes.orphans.map(\.window), [2])
    }

    /// A window id handed to another process is not the same window.
    func testAWindowIdUnderAnotherProcessIsGone() {
        var homes = twoHomes()
        homes.retire(now: now) { _, pid in pid == 999 }
        XCTAssertTrue(homes.records.isEmpty)
        XCTAssertEqual(homes.orphans.count, 2)
    }

    func testOrphansAreForgottenInTime() {
        var homes = twoHomes()
        homes.retireAll(now: now)
        homes.retire(now: now.addingTimeInterval(WindowHomes.orphanLife + 60)) { _, _ in true }
        XCTAssertTrue(homes.orphans.isEmpty)
    }

    func testOrphansAreCapped() {
        var homes = WindowHomes()
        let many = (0..<(WindowHomes.orphanLimit + 20)).map { window(CGWindowID(100 + $0)) }
        homes.claim(many, for: chat, among: places, now: now)
        homes.retireAll(now: now)
        XCTAssertEqual(homes.orphans.count, WindowHomes.orphanLimit)
    }

    // MARK: After the app restarts

    private let left = CGRect(x: 0, y: 25, width: 900, height: 1000)
    private let right = CGRect(x: 900, y: 25, width: 900, height: 1000)
    private let corner = CGPoint(x: 1439, y: 868)

    /// The browser quit and came back: new window ids, same titles and frames.
    func testWindowsAreRecognisedByTitleAndFrame() {
        var homes = WindowHomes()
        homes.claim([window(1, frame: left, title: "Inbox")], for: chat, among: places, now: now)
        homes.claim([window(2, frame: right, title: "Pull requests")], for: code, among: places, now: now)
        homes.retireAll(now: now)

        let adopted = homes.adopt([
            window(11, frame: right, title: "Pull requests", pid: 600),
            window(12, frame: left, title: "Inbox", pid: 600),
        ], now: now)
        XCTAssertEqual(Set(adopted.map(\.window)), [11, 12])
        XCTAssertEqual(homes.home(of: 11, among: places), code.id)
        XCTAssertEqual(homes.home(of: 12, among: places), chat.id)
        XCTAssertTrue(homes.orphans.isEmpty)
        XCTAssertEqual(homes.record(of: 11)?.pid, 600)
    }

    func testATitleAloneIsEnoughWhenItIsTheOnlyOne() {
        var homes = WindowHomes()
        homes.claim([window(2, frame: right, title: "Pull requests")], for: code, among: places, now: now)
        homes.retireAll(now: now)
        homes.adopt([window(11, frame: left, title: "Pull requests")], now: now)
        XCTAssertEqual(homes.home(of: 11, among: places), code.id)
    }

    /// Two windows on the same page at the same size: nothing tells them
    /// apart, so neither is guessed at.
    func testTwinsAreNotGuessedAt() {
        var homes = WindowHomes()
        homes.claim([window(1, frame: left, title: "New Tab")], for: chat, among: places, now: now)
        homes.claim([window(2, frame: left, title: "New Tab")], for: code, among: places, now: now)
        homes.retireAll(now: now)
        let adopted = homes.adopt([
            window(11, frame: left, title: "New Tab"),
            window(12, frame: left, title: "New Tab"),
        ], now: now)
        XCTAssertEqual(adopted, [])
        XCTAssertNil(homes.record(of: 11))
    }

    /// The same twins, but one was parked when the app quit and comes back in
    /// its corner: that tells them apart.
    func testTheOneThatComesBackInItsCornerIsTheOneThatWasParked() {
        var homes = WindowHomes()
        homes.claim([window(1, frame: left, title: "New Tab")], for: chat, among: places, now: now)
        homes.claim([window(2, frame: left, title: "New Tab")], for: code, among: places, now: now)
        homes.parked(2, at: corner, from: nil)
        homes.retireAll(now: now)

        let parkedFrame = CGRect(origin: corner, size: left.size)
        homes.adopt([
            window(11, frame: left, title: "New Tab"),
            window(12, frame: parkedFrame, title: "New Tab", inSight: false),
        ], now: now)
        XCTAssertEqual(homes.home(of: 11, among: places), chat.id)
        XCTAssertEqual(homes.home(of: 12, among: places), code.id)
        // It is still in its corner, and still knows where it goes back to.
        XCTAssertEqual(homes.record(of: 12)?.parkedAt, corner)
        XCTAssertEqual(homes.record(of: 12)?.shown, left)
    }

    func testAWindowThatMatchesNothingIsNew() {
        var homes = WindowHomes()
        homes.claim([window(1, frame: left, title: "Inbox")], for: chat, among: places, now: now)
        homes.retireAll(now: now)
        let adopted = homes.adopt([window(11, frame: right, title: "Something else")], now: now)
        XCTAssertEqual(adopted, [])
        XCTAssertEqual(homes.orphans.count, 1)
    }

    func testAnotherAppsOrphanIsNeverAMatch() {
        var homes = WindowHomes()
        homes.claim([window(1, app: "messages", frame: left, title: "Inbox")], for: chat, among: places, now: now)
        homes.retireAll(now: now)
        XCTAssertEqual(homes.adopt([window(11, frame: left, title: "Inbox")], now: now), [])
    }

    func testUntitledWindowsDoNotMatchOnTheirTitle() {
        XCTAssertNil(WindowHomes.digest(nil))
        XCTAssertNil(WindowHomes.digest(""))
        XCTAssertEqual(WindowHomes.digest("Inbox"), WindowHomes.digest("Inbox"))
        XCTAssertNotEqual(WindowHomes.digest("Inbox"), WindowHomes.digest("Outbox"))
    }

    func testAnAppLeftParkedWindowsBehind() {
        var homes = twoHomes()
        homes.parked(2, at: corner, from: nil)
        XCTAssertFalse(homes.leftParkedWindows(of: "browser"))
        homes.retireAll(now: now)
        XCTAssertTrue(homes.leftParkedWindows(of: "browser"))
        XCTAssertFalse(homes.leftParkedWindows(of: "editor"))
    }

    // MARK: Opting out, and the state file

    func testAnAppTakenOffTheListIsForgotten() {
        var homes = twoHomes()
        homes.claim([window(5, app: "editor")], for: code, among: places, now: now)
        let dropped = homes.forget(keeping: ["editor"])
        XCTAssertEqual(Set(dropped.map(\.window)), [1, 2])
        XCTAssertEqual(homes.records.map(\.window), [5])
    }

    func testTheStateFileHoldsNoTitle() throws {
        var homes = WindowHomes()
        homes.claim([window(1, title: "A page nobody else should read")], for: chat, among: places, now: now)
        homes.parked(1, at: corner, from: nil)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(homes)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("nobody else"))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(WindowHomes.self, from: data), homes)
    }
}

/// Where a window is parked. Rects are in Accessibility's space: the origin is
/// the top-left of the main display and y grows downward.
final class ParkingTests: XCTestCase {
    private let laptop = CGRect(x: 0, y: 0, width: 1440, height: 900)
    /// An external display above the laptop, wider than it.
    private let above = CGRect(x: -240, y: -1080, width: 1920, height: 1080)
    private let frame = CGRect(x: 300, y: 200, width: 600, height: 432)

    /// What shows of a parked window: a sliver in the corner.
    private var chip: CGFloat { Parking.keptWidth * Parking.keptHeight }

    /// A display to the right that ends higher up than the laptop does: the
    /// laptop's bottom-right corner hangs below it, so nothing spills over.
    /// (The shape of one of the two arrangements the real calls were measured on.)
    func testACornerBelowAShorterNeighbourIsFree() {
        let beside = CGRect(x: 1440, y: 0, width: 1280, height: 720)
        let spot = Parking.spot(for: frame, on: [laptop, beside])
        XCTAssertEqual(spot?.landing.origin, CGPoint(x: 1439, y: 868))
        XCTAssertEqual(Parking.visibleArea(of: spot!.landing, on: [laptop, beside]), chip)
    }

    func testOnOneDisplayAWindowParksAtTheBottomRight() {
        let spot = Parking.spot(for: frame, on: [laptop])
        XCTAssertEqual(spot?.ask, CGPoint(x: 1439, y: 899))
        // Where macOS 27.2 puts it when asked that: 1 pt wide and 32 pt tall still showing.
        XCTAssertEqual(spot?.landing.origin, CGPoint(x: 1439, y: 868))
        XCTAssertEqual(Parking.visibleArea(of: spot!.landing, on: [laptop]), chip)
    }

    func testAParkedWindowIsOutOfSightAndAnOrdinaryOneIsNot() {
        let landing = Parking.spot(for: frame, on: [laptop])!.landing
        XCTAssertFalse(Parking.isInSight(landing, on: [laptop]))
        XCTAssertTrue(Parking.isInSight(frame, on: [laptop]))
        // Half off the edge is still plainly visible.
        XCTAssertTrue(Parking.isInSight(CGRect(x: 1140, y: 200, width: 600, height: 432), on: [laptop]))
        // A small window in plain view is in sight too.
        XCTAssertTrue(Parking.isInSight(CGRect(x: 300, y: 200, width: 60, height: 60), on: [laptop]))
        XCTAssertFalse(Parking.isInSight(CGRect(x: 5000, y: 5000, width: 600, height: 432), on: [laptop]))
    }

    /// A wider display above the laptop: both of its bottom corners hang clear
    /// of the laptop below it.
    func testAWindowParksOnItsOwnDisplayWhenItsCornerIsFree() {
        let onTheUpper = CGRect(x: 100, y: -900, width: 600, height: 432)
        let spot = Parking.spot(for: onTheUpper, on: [laptop, above])
        XCTAssertEqual(spot?.ask, CGPoint(x: 1679, y: -1))
        XCTAssertEqual(Parking.visibleArea(of: spot!.landing, on: [laptop, above]), chip)
    }

    /// A display to the right: the left display's bottom-right corner would
    /// leave the window lying across the neighbour, so it goes bottom-left.
    func testACornerThatSpillsOntoANeighbourIsAvoided() {
        let left = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let right = CGRect(x: 1000, y: 0, width: 1000, height: 800)
        let spot = Parking.spot(for: frame, on: [left, right])
        XCTAssertEqual(spot?.landing.origin, CGPoint(x: -599, y: 768))
        XCTAssertEqual(Parking.visibleArea(of: spot!.landing, on: [left, right]), chip)
    }

    /// A display directly below, as wide: neither bottom corner of the upper
    /// one is free, so the window parks on the lower display.
    func testWithNoFreeCornerOnItsDisplayItParksOnAnother() {
        let top = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let bottom = CGRect(x: 0, y: 800, width: 1000, height: 800)
        let spot = Parking.spot(for: frame, on: [top, bottom])
        XCTAssertEqual(spot?.ask, CGPoint(x: 999, y: 1599))
        XCTAssertEqual(Parking.visibleArea(of: spot!.landing, on: [top, bottom]), chip)
    }

    func testWithNoDisplayThereIsNowhereToPark() {
        XCTAssertNil(Parking.spot(for: frame, on: []))
    }

    func testAWindowComesBackWhereItWas() {
        XCTAssertEqual(Parking.comeBack(to: frame, size: frame.size, on: [laptop, above]), frame.origin)
    }

    /// Its display was unplugged while it was parked.
    func testAWindowWhoseDisplayIsGoneComesBackOnTheMainOne() {
        let onTheUpper = CGRect(x: 100, y: -900, width: 600, height: 432)
        let point = Parking.comeBack(to: onTheUpper, size: onTheUpper.size, on: [laptop])
        XCTAssertEqual(point, CGPoint(x: 420, y: 234))
        XCTAssertTrue(Parking.isInSight(CGRect(origin: point, size: onTheUpper.size), on: [laptop]))
    }

    func testAWindowWithNoRememberedPlaceComesBackOnTheMainOne() {
        XCTAssertEqual(Parking.comeBack(to: nil, size: CGSize(width: 600, height: 432), on: [laptop]), CGPoint(x: 420, y: 234))
    }
}

/// The config side: opting in is a list, and a file from before has none.
final class PerWindowConfigTests: XCTestCase {
    private let browser = AppRef(bundleId: "com.example.browser", name: "Browser", path: nil)

    func testAVersion4FileHasNoPerWindowApps() throws {
        let old = #"{"version": 4, "profiles": [], "floatingApps": []}"#
        let config = try JSONDecoder().decode(Config.self, from: Data(old.utf8))
        XCTAssertEqual(config.version, Config.currentVersion)
        XCTAssertEqual(config.perWindowApps, [])
        XCTAssertTrue(config.moveWindowShortcuts)
    }

    func testPerWindowAppsSurviveTheFile() throws {
        var config = Config()
        config.perWindowApps = [browser]
        config.moveWindowShortcuts = false
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let back = try decoder.decode(Config.self, from: try encoder.encode(config))
        XCTAssertEqual(back.perWindowApps, [browser])
        XCTAssertFalse(back.moveWindowShortcuts)
    }

    func testSendingAWindowIsTheWorkspaceShortcutWithShift() {
        var config = Config()
        config.perWindowApps = [browser]
        let code = Workspace(name: "Code", shortcut: Shortcut(key: "2"))
        XCTAssertEqual(config.moveWindowShortcut(for: code, among: [code]), Shortcut(key: "2", shift: true))
    }

    /// Nobody loses a key to this before opting an app in.
    func testThereIsNoSuchShortcutWithoutAPerWindowApp() {
        let code = Workspace(name: "Code", shortcut: Shortcut(key: "2"))
        XCTAssertNil(Config().moveWindowShortcut(for: code, among: [code]))
    }

    func testAShortcutThatIsTakenIsNotUsed() {
        var config = Config()
        config.perWindowApps = [browser]
        // ⌥⇧M maximises by default.
        let media = Workspace(name: "Media", shortcut: Shortcut(key: "m"))
        XCTAssertNil(config.moveWindowShortcut(for: media, among: [media]))
        // Another workspace already uses the ⇧ variant.
        let two = Workspace(name: "Two", shortcut: Shortcut(key: "2"))
        let shifted = Workspace(name: "Shifted", shortcut: Shortcut(key: "2", shift: true))
        XCTAssertNil(config.moveWindowShortcut(for: two, among: [two, shifted]))
        XCTAssertNil(config.moveWindowShortcut(for: shifted, among: [two, shifted]))
    }

    func testItCanBeSwitchedOff() {
        var config = Config()
        config.perWindowApps = [browser]
        config.moveWindowShortcuts = false
        let code = Workspace(name: "Code", shortcut: Shortcut(key: "2"))
        XCTAssertNil(config.moveWindowShortcut(for: code, among: [code]))
        XCTAssertNil(config.moveWindowShortcut(for: Workspace(name: "No key"), among: []))
    }
}
