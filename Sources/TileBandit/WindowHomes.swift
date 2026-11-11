import CoreGraphics
import CryptoKit
import Foundation

/// A window of a per-window app as it is right now.
struct LiveWindow: Equatable {
    let id: CGWindowID
    let pid: pid_t
    let bundleId: String
    /// Top-left origin: the space Accessibility and the window server share.
    let frame: CGRect
    let title: String?
    /// On a visible desktop, with more than a corner of it on a display.
    let inSight: Bool
}

/// Which window lives in which workspace, for the apps opted in to per-window
/// workspaces (`Config.perWindowApps`).
///
/// Everything else in Tile Bandit files whole apps under workspaces. For these
/// apps a *window* has a home: it is on show in that workspace and parked out
/// of the way in the others (WindowScope does the moving). This type is only
/// the bookkeeping, kept free of AppKit so the decisions can be tested without
/// a screen, like `StackPlan`.
///
/// A window is known by its window-server id, which holds for as long as the
/// window is open: through new tabs, new titles, moves and resizes, and through
/// Tile Bandit restarting. It does not survive the *app* restarting, so what
/// was known about a window that is gone is kept for a while (`orphans`) and
/// matched to the windows the app comes back with — see `adopt`.
struct WindowHomes: Codable, Equatable {
    /// A workspace of the live display profile, as far as homes care.
    struct Place: Equatable {
        let id: UUID
        let name: String
        /// Bundle ids it lists.
        let apps: Set<String>
    }

    struct Record: Codable, Equatable {
        var window: CGWindowID
        var pid: pid_t
        var bundleId: String
        var home: UUID
        /// Workspace ids differ from one display profile to the next (a new
        /// profile is a clone with fresh ids), names don't: "Code" at the desk
        /// is "Code" on the laptop. The name is how a home carries over.
        var homeName: String
        /// Where the window sits when it is on show. Kept while it is parked,
        /// since that is where it goes back to.
        var shown: CGRect?
        /// Where parking left it, read back after the move. Nil when on show.
        var parkedAt: CGPoint?
        /// A digest of the title, never the title: it is only ever compared,
        /// and a browser's page titles have no business in a state file.
        var titleDigest: String?
        var seen: Date
    }

    /// What a switch should do with a window.
    enum Wanted: Equatable {
        /// Not ours to place: no home yet, so it shows wherever its app does.
        case free
        case shown
        case parked
    }

    /// A window recognised after its app restarted, and what gave it away.
    struct Adoption: Equatable {
        let window: CGWindowID
        let home: UUID
        let homeName: String
        let matchedOn: String
    }

    private(set) var records: [Record] = []
    /// Windows that are gone, newest first — for the app's next launch.
    private(set) var orphans: [Record] = []

    static let orphanLimit = 64
    static let orphanLife: TimeInterval = 30 * 24 * 3600

    var isEmpty: Bool { records.isEmpty && orphans.isEmpty }

    func record(of window: CGWindowID) -> Record? {
        records.first { $0.window == window }
    }

    // MARK: - Reading

    /// The live workspace a record points at: the one it names by id, else the
    /// one of the same name. Either must still list the app; a window whose
    /// workspace dropped its app has no home.
    static func resolve(_ record: Record, among places: [Place]) -> UUID? {
        if let exact = places.first(where: { $0.id == record.home }) {
            return exact.apps.contains(record.bundleId) ? exact.id : nil
        }
        return places.first { $0.name == record.homeName && $0.apps.contains(record.bundleId) }?.id
    }

    func home(of window: CGWindowID, among places: [Place]) -> UUID? {
        record(of: window).flatMap { Self.resolve($0, among: places) }
    }

    func wanted(_ window: CGWindowID, active: UUID?, among places: [Place]) -> Wanted {
        guard let record = record(of: window) else { return .free }
        // No workspace is active, or its home is not in this display setup:
        // nothing says it should be out of the way.
        guard let active, let home = Self.resolve(record, among: places) else { return .shown }
        return home == active ? .shown : .parked
    }

    /// The windows that live in a workspace other than `active` — the ones a
    /// snapshot of `active` leaves out and a layout must not touch.
    func elsewhere(than active: UUID?, among places: [Place]) -> Set<CGWindowID> {
        guard let active else { return [] }
        var out = Set<CGWindowID>()
        for record in records {
            if let home = Self.resolve(record, among: places), home != active { out.insert(record.window) }
        }
        return out
    }

    /// Whether this app left parked windows behind when it last quit. A window
    /// of it that turns up in a corner is then one of ours, not the user's.
    func leftParkedWindows(of bundleId: String) -> Bool {
        orphans.contains { $0.bundleId == bundleId && $0.parkedAt != nil }
    }

    // MARK: - Writing

    /// The workspace being left takes the windows in sight that have no home.
    ///
    /// This is the one place a window gets a home by itself, and it is the
    /// moment 1.6.0 takes a workspace's snapshot, for the same reason: what is
    /// on screen when a workspace is left is what belongs to it. A new window
    /// therefore joins the workspace it was opened in, and never vanishes
    /// under the user's hands. Windows already at home here have their frame
    /// and title refreshed.
    @discardableResult
    mutating func claim(_ windows: [LiveWindow], for place: Place, among places: [Place], now: Date) -> [LiveWindow] {
        var claimed: [LiveWindow] = []
        for window in windows where window.inSight && place.apps.contains(window.bundleId) {
            if let index = records.firstIndex(where: { $0.window == window.id }) {
                let home = Self.resolve(records[index], among: places)
                // Lives elsewhere and is in sight anyway (dragged back out of
                // its corner): its home stands until it is moved.
                if let home, home != place.id { continue }
                if home == nil {
                    // Its home is not in this setup (another display profile
                    // with no workspace of that name): taken like a new one.
                    records[index].home = place.id
                    records[index].homeName = place.name
                    claimed.append(window)
                }
                records[index].shown = window.frame
                records[index].parkedAt = nil
                records[index].titleDigest = Self.digest(window.title)
                records[index].seen = now
            } else {
                records.append(Record(
                    window: window.id, pid: window.pid, bundleId: window.bundleId,
                    home: place.id, homeName: place.name,
                    shown: window.frame, parkedAt: nil, titleDigest: Self.digest(window.title), seen: now
                ))
                claimed.append(window)
            }
        }
        return claimed
    }

    /// The user sent this window to a workspace.
    mutating func assign(_ window: LiveWindow, to place: Place, now: Date) {
        if let index = records.firstIndex(where: { $0.window == window.id }) {
            records[index].home = place.id
            records[index].homeName = place.name
            records[index].titleDigest = Self.digest(window.title)
            records[index].seen = now
        } else {
            records.append(Record(
                window: window.id, pid: window.pid, bundleId: window.bundleId,
                home: place.id, homeName: place.name,
                shown: window.inSight ? window.frame : nil, parkedAt: nil, titleDigest: Self.digest(window.title), seen: now
            ))
        }
    }

    /// - Parameter frame: where it was on show just before, or nil when it was
    ///   not in sight then — the place remembered from earlier is kept.
    mutating func parked(_ window: CGWindowID, at origin: CGPoint, from frame: CGRect?) {
        guard let index = records.firstIndex(where: { $0.window == window }) else { return }
        records[index].parkedAt = origin
        if let frame { records[index].shown = frame }
    }

    mutating func unparked(_ window: CGWindowID) {
        guard let index = records.firstIndex(where: { $0.window == window }) else { return }
        records[index].parkedAt = nil
    }

    /// Windows that no longer exist stop being records and wait as orphans.
    mutating func retire(now: Date, exists: (CGWindowID, pid_t) -> Bool) {
        var alive: [Record] = []
        var gone: [Record] = []
        for record in records {
            if exists(record.window, record.pid) {
                alive.append(record)
            } else {
                var orphan = record
                orphan.seen = now
                gone.append(orphan)
            }
        }
        guard !gone.isEmpty || orphans.contains(where: { now.timeIntervalSince($0.seen) > Self.orphanLife }) else { return }
        records = alive
        orphans = Array((gone + orphans)
            .filter { now.timeIntervalSince($0.seen) <= Self.orphanLife }
            .prefix(Self.orphanLimit))
    }

    /// Everything known is about windows of an earlier login: none of the ids
    /// means anything now.
    mutating func retireAll(now: Date) {
        retire(now: now) { _, _ in false }
    }

    /// Recognises windows an app came back with after a restart.
    ///
    /// A guess, and built to say no: a newcomer and an orphan of the same app
    /// score points for the same title, the same frame, and for the newcomer
    /// sitting out of sight where a parked window was (the app saved that
    /// position when it quit); they lose points when one was parked and the
    /// other is in plain sight. Only the best pairing is taken, and only when
    /// neither side has another pairing just as good — two windows with the
    /// same title and frame are left alone, and are then treated as new.
    @discardableResult
    mutating func adopt(_ newcomers: [LiveWindow], now: Date) -> [Adoption] {
        var candidates = newcomers.filter { record(of: $0.id) == nil }
        var adopted: [Adoption] = []
        while !candidates.isEmpty, !orphans.isEmpty {
            var pairs: [(window: Int, orphan: Int, score: Int, why: String)] = []
            for (w, window) in candidates.enumerated() {
                for (o, orphan) in orphans.enumerated() where orphan.bundleId == window.bundleId {
                    let (score, why) = Self.likeness(window, orphan)
                    if score >= Self.adoptFrom { pairs.append((w, o, score, why)) }
                }
            }
            guard let best = pairs.map(\.score).max() else { break }
            let top = pairs.filter { $0.score == best }
            let sure = top.filter { pair in
                top.filter { $0.window == pair.window }.count == 1 && top.filter { $0.orphan == pair.orphan }.count == 1
            }
            guard !sure.isEmpty else { break }
            for pair in sure {
                let window = candidates[pair.window]
                let orphan = orphans[pair.orphan]
                records.append(Record(
                    window: window.id, pid: window.pid, bundleId: window.bundleId,
                    home: orphan.home, homeName: orphan.homeName,
                    shown: window.inSight ? window.frame : orphan.shown,
                    parkedAt: window.inSight ? nil : window.frame.origin,
                    titleDigest: Self.digest(window.title), seen: now
                ))
                adopted.append(Adoption(window: window.id, home: orphan.home, homeName: orphan.homeName, matchedOn: pair.why))
            }
            let usedWindows = Set(sure.map(\.window))
            let usedOrphans = Set(sure.map(\.orphan))
            candidates = candidates.enumerated().filter { !usedWindows.contains($0.offset) }.map(\.element)
            orphans = orphans.enumerated().filter { !usedOrphans.contains($0.offset) }.map(\.element)
        }
        return adopted
    }

    static let adoptFrom = 2

    static func likeness(_ window: LiveWindow, _ orphan: Record) -> (score: Int, why: String) {
        var score = 0
        var why: [String] = []
        if let digest = digest(window.title), digest == orphan.titleDigest {
            score += 2
            why.append("title")
        }
        if let shown = orphan.shown, Parking.near(shown, window.frame) {
            score += 2
            why.append("frame")
        }
        let wasParked = orphan.parkedAt != nil
        if wasParked, !window.inSight {
            score += 1
            why.append("parked")
            if let at = orphan.parkedAt, Parking.near(at, window.frame.origin) { score += 1 }
        } else if wasParked != !window.inSight {
            score -= 2
        }
        return (score, why.joined(separator: " + "))
    }

    /// Nil for no title or an empty one, so two untitled windows never match
    /// on it.
    static func digest(_ title: String?) -> String? {
        guard let title, !title.isEmpty else { return nil }
        return SHA256.hash(data: Data(title.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Drops everything about apps that are no longer per-window. Returns the
    /// live records dropped, so their windows can be brought back first.
    mutating func forget(keeping bundleIds: Set<String>) -> [Record] {
        let dropped = records.filter { !bundleIds.contains($0.bundleId) }
        records.removeAll { !bundleIds.contains($0.bundleId) }
        orphans.removeAll { !bundleIds.contains($0.bundleId) }
        return dropped
    }
}

/// The geometry of putting a window out of the way, kept pure for the tests.
/// All rects are in the top-left space Accessibility uses.
///
/// macOS has no call that hides one window of another app, and it will not let
/// one be moved off screen entirely. Measured on macOS 27.2
/// (docs/plans/per-window-workspaces.md): asked for a place wholly outside
/// every display, AppKit brings the window back until 40 pt of its width and
/// 32 pt of its height are on one; asked for a point one inside a display's
/// bottom corner, it leaves the width alone and only keeps those 32 pt of
/// height. So a parked window is asked to sit one point inside a bottom corner
/// and ends up as a sliver 1 pt wide and 32 pt tall. The numbers are only used
/// to *choose* the corner; where a window really landed is read back, never
/// assumed.
enum Parking {
    /// How far inside the corner a parked window is asked to be.
    static let keptWidth: CGFloat = 1
    /// What the system keeps on the display whatever is asked.
    static let keptHeight: CGFloat = 32
    /// What it keeps of the width when the place asked for is off every
    /// display — the most of a parked window that can end up showing.
    static let clampedWidth: CGFloat = 40

    struct Spot: Equatable {
        /// The position to ask for: one point inside the corner.
        let ask: CGPoint
        /// Where the window is expected to end up.
        let landing: CGRect
    }

    static func visibleArea(of frame: CGRect, on screens: [CGRect]) -> CGFloat {
        screens.reduce(0) { total, screen in
            let overlap = screen.intersection(frame)
            return total + (overlap.isNull ? 0 : overlap.width * overlap.height)
        }
    }

    /// More than a parked corner of it is on some display.
    static func isInSight(_ frame: CGRect, on screens: [CGRect]) -> Bool {
        let area = frame.width * frame.height
        let floor = clampedWidth * keptHeight * 1.5
        return visibleArea(of: frame, on: screens) > min(64 * 64, max(area / 2, floor))
    }

    /// The corner to park `frame` in: the bottom corner where the least of it
    /// shows on *any* display — what hangs outside one display must not land
    /// on its neighbour — then a corner of the display it is on, then the right
    /// one. Bottom corners only: at the top macOS keeps the whole title bar
    /// under the menu bar.
    static func spot(for frame: CGRect, on screens: [CGRect]) -> Spot? {
        guard !screens.isEmpty else { return nil }
        let own = screens.indices.max { a, b in
            visibleArea(of: frame, on: [screens[a]]) < visibleArea(of: frame, on: [screens[b]])
        }
        var best: (spot: Spot, exposure: CGFloat, rank: Int)?
        for (index, screen) in screens.enumerated() {
            let y = screen.maxY - keptHeight
            let corners = [
                Spot(
                    ask: CGPoint(x: screen.maxX - keptWidth, y: screen.maxY - 1),
                    landing: CGRect(x: screen.maxX - keptWidth, y: y, width: frame.width, height: frame.height)
                ),
                Spot(
                    ask: CGPoint(x: screen.minX - frame.width + keptWidth, y: screen.maxY - 1),
                    landing: CGRect(x: screen.minX - frame.width + keptWidth, y: y, width: frame.width, height: frame.height)
                ),
            ]
            for (side, spot) in corners.enumerated() {
                let exposure = visibleArea(of: spot.landing, on: screens)
                let rank = (index == own ? 0 : 2) + side
                if let current = best, (current.exposure, current.rank) <= (exposure, rank) { continue }
                best = (spot, exposure, rank)
            }
        }
        return best?.spot
    }

    /// Where a window goes when it comes back: where it was, unless that place
    /// is no longer on a display (its monitor was unplugged while it was
    /// parked), in which case the middle of the main one.
    static func comeBack(to shown: CGRect?, size: CGSize, on screens: [CGRect]) -> CGPoint {
        if let shown, isInSight(shown, on: screens) { return shown.origin }
        guard let main = screens.first else { return shown?.origin ?? .zero }
        return CGPoint(
            x: main.minX + max(0, (main.width - size.width) / 2),
            y: main.minY + max(0, (main.height - size.height) / 2)
        )
    }

    static func near(_ a: CGPoint, _ b: CGPoint) -> Bool {
        abs(a.x - b.x) < 2 && abs(a.y - b.y) < 2
    }

    static func near(_ a: CGRect, _ b: CGRect) -> Bool {
        near(a.origin, b.origin) && abs(a.width - b.width) < 2 && abs(a.height - b.height) < 2
    }
}
