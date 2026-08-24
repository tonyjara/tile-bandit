import CoreGraphics
import Foundation

/// A reference to an installed application.
struct AppRef: Codable, Equatable, Hashable, Identifiable {
    var bundleId: String
    var name: String
    var path: String?

    var id: String { bundleId }
}

/// A global keyboard shortcut. `key` is a single character (0-9, a-z).
struct Shortcut: Codable, Equatable, Hashable {
    var key: String
    var control: Bool
    var option: Bool
    var shift: Bool
    var command: Bool

    init(key: String, control: Bool = false, option: Bool = true, shift: Bool = false, command: Bool = false) {
        self.key = key
        self.control = control
        self.option = option
        self.shift = shift
        self.command = command
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        control = try container.decodeIfPresent(Bool.self, forKey: .control) ?? false
        option = try container.decodeIfPresent(Bool.self, forKey: .option) ?? true
        shift = try container.decodeIfPresent(Bool.self, forKey: .shift) ?? false
        command = try container.decodeIfPresent(Bool.self, forKey: .command) ?? false
    }

    var display: String {
        var text = ""
        if control { text += "⌃" }
        if option { text += "⌥" }
        if shift { text += "⇧" }
        if command { text += "⌘" }
        return text + key.uppercased()
    }
}

/// A cell coordinate on a workspace grid. Row 0 / col 0 is the top-left cell.
struct GridCell: Equatable {
    var col: Int
    var row: Int
}

/// A rectangular span of grid cells assigned to one app.
struct GridRegion: Codable, Equatable, Hashable {
    var col: Int
    var row: Int
    var colSpan: Int
    var rowSpan: Int

    init(col: Int, row: Int, colSpan: Int = 1, rowSpan: Int = 1) {
        self.col = col
        self.row = row
        self.colSpan = colSpan
        self.rowSpan = rowSpan
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        col = max(0, try container.decodeIfPresent(Int.self, forKey: .col) ?? 0)
        row = max(0, try container.decodeIfPresent(Int.self, forKey: .row) ?? 0)
        colSpan = max(1, try container.decodeIfPresent(Int.self, forKey: .colSpan) ?? 1)
        rowSpan = max(1, try container.decodeIfPresent(Int.self, forKey: .rowSpan) ?? 1)
    }

    /// Smallest region covering both cells (how drag-painting spans cells).
    static func bounding(_ a: GridCell, _ b: GridCell) -> GridRegion {
        GridRegion(
            col: min(a.col, b.col),
            row: min(a.row, b.row),
            colSpan: abs(a.col - b.col) + 1,
            rowSpan: abs(a.row - b.row) + 1
        )
    }

    /// Keeps hand-edited regions inside the grid.
    func clamped(columns: Int, rows: Int) -> GridRegion {
        let c = min(max(col, 0), columns - 1)
        let r = min(max(row, 0), rows - 1)
        return GridRegion(
            col: c,
            row: r,
            colSpan: min(max(colSpan, 1), columns - c),
            rowSpan: min(max(rowSpan, 1), rows - r)
        )
    }
}

/// Grid dimensions plus the geometry math shared by the layout engine,
/// drag-snap, and the settings editor. `bounds` is always a screen's
/// visibleFrame in AppKit (bottom-left origin) coordinates; rows count
/// from the top, matching what the user sees.
struct GridSize: Equatable {
    let columns: Int
    let rows: Int

    init(columns: Int, rows: Int) {
        self.columns = min(max(columns, 1), 12)
        self.rows = min(max(rows, 1), 12)
    }

    func frame(for region: GridRegion, in bounds: CGRect) -> CGRect {
        let r = region.clamped(columns: columns, rows: rows)
        let cellWidth = bounds.width / CGFloat(columns)
        let cellHeight = bounds.height / CGFloat(rows)
        return CGRect(
            x: bounds.minX + CGFloat(r.col) * cellWidth,
            y: bounds.maxY - CGFloat(r.row + r.rowSpan) * cellHeight,
            width: CGFloat(r.colSpan) * cellWidth,
            height: CGFloat(r.rowSpan) * cellHeight
        )
    }

    func cell(at point: CGPoint, in bounds: CGRect) -> GridCell {
        let cellWidth = bounds.width / CGFloat(columns)
        let cellHeight = bounds.height / CGFloat(rows)
        let col = Int((point.x - bounds.minX) / cellWidth)
        let row = Int((bounds.maxY - point.y) / cellHeight)
        return GridCell(
            col: min(max(col, 0), columns - 1),
            row: min(max(row, 0), rows - 1)
        )
    }
}

/// Hold-modifiers-while-dragging window snapping (bentobox style).
struct SnapSettings: Codable, Equatable {
    var enabled: Bool
    var control: Bool
    var option: Bool
    var shift: Bool
    var command: Bool
    /// Grid used when no workspace is active.
    var defaultColumns: Int
    var defaultRows: Int

    init(
        enabled: Bool = true,
        control: Bool = true,
        option: Bool = true,
        shift: Bool = false,
        command: Bool = false,
        defaultColumns: Int = 2,
        defaultRows: Int = 2
    ) {
        self.enabled = enabled
        self.control = control
        self.option = option
        self.shift = shift
        self.command = command
        self.defaultColumns = defaultColumns
        self.defaultRows = defaultRows
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        control = try container.decodeIfPresent(Bool.self, forKey: .control) ?? true
        option = try container.decodeIfPresent(Bool.self, forKey: .option) ?? true
        shift = try container.decodeIfPresent(Bool.self, forKey: .shift) ?? false
        command = try container.decodeIfPresent(Bool.self, forKey: .command) ?? false
        defaultColumns = min(max(try container.decodeIfPresent(Int.self, forKey: .defaultColumns) ?? 2, 1), 12)
        defaultRows = min(max(try container.decodeIfPresent(Int.self, forKey: .defaultRows) ?? 2, 1), 12)
    }

    var hasModifiers: Bool { control || option || shift || command }

    var modifierDisplay: String {
        var text = ""
        if control { text += "⌃" }
        if option { text += "⌥" }
        if shift { text += "⇧" }
        if command { text += "⌘" }
        return text
    }
}

/// One display's slice of a workspace: how that screen is divided and which
/// apps sit in which of its cells. A workspace holds one per display in its
/// profile — that's what lets a single workspace say "editor and terminal side
/// by side on the big monitor, Slack filling the laptop".
struct DisplayGrid: Codable, Equatable, Hashable, Identifiable {
    /// The `DisplayRef.key` this grid belongs to. Empty means *unbound*: a grid
    /// from a config written before grids were per-display, or one in a profile
    /// not bound to any displays yet. `Workspace.rebindGrids(to:)` gives those
    /// real keys; until then they apply wherever a window already is.
    var displayKey: String
    var columns: Int
    var rows: Int
    /// bundleId → assigned cells. Apps without an entry are left alone by Apply Layout.
    var layout: [String: GridRegion]

    static let unboundKey = ""

    var id: String { displayKey }
    var isUnbound: Bool { displayKey == Self.unboundKey }
    var size: GridSize { GridSize(columns: columns, rows: rows) }

    init(
        displayKey: String = DisplayGrid.unboundKey,
        columns: Int = 2,
        rows: Int = 2,
        layout: [String: GridRegion] = [:]
    ) {
        self.displayKey = displayKey
        self.columns = min(max(columns, 1), 12)
        self.rows = min(max(rows, 1), 12)
        self.layout = layout
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            displayKey: try container.decodeIfPresent(String.self, forKey: .displayKey) ?? DisplayGrid.unboundKey,
            columns: try container.decodeIfPresent(Int.self, forKey: .columns) ?? 2,
            rows: try container.decodeIfPresent(Int.self, forKey: .rows) ?? 2,
            layout: try container.decodeIfPresent([String: GridRegion].self, forKey: .layout) ?? [:]
        )
    }
}

struct Workspace: Codable, Equatable, Hashable, Identifiable {
    var id: UUID
    var name: String
    var apps: [AppRef]
    var shortcut: Shortcut?
    var launchMissingApps: Bool
    /// One entry per display of the owning profile. Sparse on purpose — a
    /// display nobody has laid anything out on yet simply has no grid, and
    /// falls back to the snap defaults.
    var grids: [DisplayGrid]

    private enum CodingKeys: String, CodingKey {
        case id, name, apps, shortcut, launchMissingApps, grids
        /// Pre-v3: one grid for the whole workspace, applied on whichever
        /// screen each window happened to be. Read for migration, never written.
        case gridColumns, gridRows, layout
    }

    init(
        id: UUID = UUID(),
        name: String,
        apps: [AppRef] = [],
        shortcut: Shortcut? = nil,
        launchMissingApps: Bool = false,
        grids: [DisplayGrid] = []
    ) {
        self.id = id
        self.name = name
        self.apps = apps
        self.shortcut = shortcut
        self.launchMissingApps = launchMissingApps
        self.grids = grids
    }

    // Lenient decoding so the config file can be edited by hand without every key present.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let grids: [DisplayGrid]
        if let stored = try container.decodeIfPresent([DisplayGrid].self, forKey: .grids) {
            grids = stored
        } else {
            // Pre-v3 file: fold the workspace-wide grid into a single unbound
            // one. DisplayProfile hands it to that setup's displays on the way in.
            grids = [DisplayGrid(
                columns: try container.decodeIfPresent(Int.self, forKey: .gridColumns) ?? 2,
                rows: try container.decodeIfPresent(Int.self, forKey: .gridRows) ?? 2,
                layout: try container.decodeIfPresent([String: GridRegion].self, forKey: .layout) ?? [:]
            )]
        }
        self.init(
            id: try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            name: try container.decodeIfPresent(String.self, forKey: .name) ?? "Untitled",
            apps: try container.decodeIfPresent([AppRef].self, forKey: .apps) ?? [],
            shortcut: try container.decodeIfPresent(Shortcut.self, forKey: .shortcut),
            launchMissingApps: try container.decodeIfPresent(Bool.self, forKey: .launchMissingApps) ?? false,
            grids: grids
        )
    }

    /// Only the current keys — the pre-v3 ones are dropped on the next write.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(apps, forKey: .apps)
        try container.encodeIfPresent(shortcut, forKey: .shortcut)
        try container.encode(launchMissingApps, forKey: .launchMissingApps)
        try container.encode(grids, forKey: .grids)
    }

    /// Whether Apply Grid Layout has anything to do.
    var hasLayout: Bool { grids.contains { !$0.layout.isEmpty } }

    var hasUnboundGrid: Bool { grids.contains(where: \.isUnbound) }

    /// The grid stored for one display, if there is one.
    func grid(for displayKey: String) -> DisplayGrid? {
        grids.first { $0.displayKey == displayKey }
    }

    /// Every display this app is placed on. Normally one — the editor moves an
    /// app rather than copying it — but a migration or a hand-edit can place it
    /// on several, which LayoutEngine resolves per window.
    func placements(of bundleId: String) -> [(grid: DisplayGrid, region: GridRegion)] {
        grids.compactMap { grid in grid.layout[bundleId].map { (grid, $0) } }
    }

    mutating func setGrid(_ grid: DisplayGrid) {
        if let index = grids.firstIndex(where: { $0.displayKey == grid.displayKey }) {
            grids[index] = grid
        } else {
            grids.append(grid)
        }
    }

    /// Assign an app to cells on one display. An app lives on one display at a
    /// time, so this clears it from the others: dragging a tile onto another
    /// monitor's grid *moves* it there.
    mutating func place(_ bundleId: String, at region: GridRegion, on displayKey: String) {
        for index in grids.indices where grids[index].displayKey != displayKey {
            grids[index].layout.removeValue(forKey: bundleId)
        }
        var target = grid(for: displayKey) ?? DisplayGrid(displayKey: displayKey)
        target.layout[bundleId] = region
        setGrid(target)
    }

    mutating func unplace(_ bundleId: String, on displayKey: String) {
        guard let index = grids.firstIndex(where: { $0.displayKey == displayKey }) else { return }
        grids[index].layout.removeValue(forKey: bundleId)
    }

    /// Point the grids at a set of displays: the i-th grid moves to the i-th
    /// display. Displays past the last grid get a copy of the first one (so
    /// migrating a single-grid workspace lands your old layout on every screen,
    /// ready to be pruned), and grids past the last display merge into the last
    /// kept one. Either way a setup with a different number of screens never
    /// silently drops a placement — an overlap is easier to fix than lost work.
    mutating func rebindGrids(to displays: [DisplayRef]) {
        guard !displays.isEmpty else { return }
        let source = grids
        guard let first = source.first else {
            grids = displays.map { DisplayGrid(displayKey: $0.key) }
            return
        }
        var rebound = displays.enumerated().map { index, display -> DisplayGrid in
            var grid = index < source.count ? source[index] : first
            grid.displayKey = display.key
            return grid
        }
        for dropped in source.dropFirst(displays.count) {
            rebound[rebound.count - 1].layout.merge(dropped.layout) { kept, _ in kept }
        }
        grids = rebound
    }
}

/// One physical display, identified in a way that survives unplugging.
///
/// Deliberately *not* the CGDirectDisplayID: those are handed out per session
/// and change when you replug a monitor. The built-in panel is just "builtin";
/// externals use their EDID vendor/model/serial (serial reads 0 on plenty of
/// monitors, vendor+model still separates a Dell from a Studio Display); a
/// display reporting none of those falls back to its localized name.
struct DisplayRef: Codable, Equatable, Hashable, Identifiable {
    var key: String
    var name: String

    var id: String { key }

    init(key: String, name: String) {
        self.key = key
        self.name = name
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decodeIfPresent(String.self, forKey: .key) ?? ""
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? key
    }
}

/// A display setup and the workspaces belonging to it — laptop on its own,
/// laptop plus the external, lid closed on the Studio Display. Whichever
/// profile matches the attached displays is the live one, so its workspaces
/// own the hotkeys and the menu (see DisplayProfiles.swift).
struct DisplayProfile: Codable, Equatable, Hashable, Identifiable {
    var id: UUID
    var name: String
    /// The displays this profile matches, sorted by key. Empty means *unbound*:
    /// a profile carried over from a pre-profiles config, which the first
    /// detection run adopts onto whatever setup it finds.
    var displays: [DisplayRef]
    var workspaces: [Workspace]

    init(
        id: UUID = UUID(),
        name: String,
        displays: [DisplayRef] = [],
        workspaces: [Workspace] = []
    ) {
        self.id = id
        self.name = name
        self.displays = displays
        self.workspaces = workspaces
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Untitled"
        displays = try container.decodeIfPresent([DisplayRef].self, forKey: .displays) ?? []
        workspaces = try container.decodeIfPresent([Workspace].self, forKey: .workspaces) ?? []
        // A file written before grids were per-display leaves each workspace
        // holding one unbound grid. Hand it to every display in this setup
        // rather than guessing which monitor was meant — the layout you had
        // shows up on both, and you delete what doesn't belong on each.
        for index in workspaces.indices where workspaces[index].hasUnboundGrid {
            workspaces[index].rebindGrids(to: displays)
        }
    }

    /// Claim a set of displays, moving the workspaces' grids onto them. Used
    /// wherever a profile changes which hardware it stands for: adopting a
    /// migrated profile, cloning one for a setup with different monitors, or
    /// the Displays tab's bind-to-attached.
    mutating func bind(to displays: [DisplayRef]) {
        self.displays = displays
        for index in workspaces.indices {
            workspaces[index].rebindGrids(to: displays)
        }
    }

    /// The fingerprint matched against the attached displays. A set is safe
    /// because DisplayIdentity.snapshot() suffixes repeated keys, so the
    /// number of identical panels stays part of the identity.
    var displayKeys: Set<String> { Set(displays.map(\.key)) }

    var isBound: Bool { !displays.isEmpty }

    /// "MacBook + M14" — for the menu and the Displays tab.
    var displaySummary: String {
        displays.isEmpty ? "Not bound to any displays yet" : displays.map(\.name).joined(separator: " + ")
    }
}

/// The status item's icon. Raw values are SF Symbol names, so the enum
/// doubles as the symbol lookup — and because a hand-edited config (or an
/// older macOS missing a symbol) can name one that doesn't resolve, every
/// lookup goes through `image`, which falls back to the default rather than
/// leaving an invisible menu bar item.
enum MenuBarIcon: String, Codable, CaseIterable, Identifiable {
    case grid = "square.grid.2x2.fill"
    case gridOutline = "square.grid.2x2"
    case gridDense = "square.grid.3x3.fill"
    case bento = "rectangle.grid.2x2.fill"
    case columns = "rectangle.split.3x1.fill"
    case circles = "circle.grid.2x2.fill"
    case window = "macwindow"
    case windows = "macwindow.on.rectangle"
    case stack = "square.stack.3d.up.fill"
    case sidebar = "sidebar.squares.left"
    case bolt = "bolt.fill"
    case mask = "theatermasks.fill"

    static let fallback = MenuBarIcon.grid

    var id: String { rawValue }

    /// Unknown/renamed symbol names decode to the default instead of throwing —
    /// the config is hand-editable, and a typo shouldn't cost you the menu bar.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MenuBarIcon(rawValue: raw) ?? .fallback
    }

    var label: String {
        switch self {
        case .grid: return "Grid"
        case .gridOutline: return "Grid (outline)"
        case .gridDense: return "Dense grid"
        case .bento: return "Bento"
        case .columns: return "Columns"
        case .circles: return "Circles"
        case .window: return "Window"
        case .windows: return "Windows"
        case .stack: return "Stack"
        case .sidebar: return "Sidebar"
        case .bolt: return "Bolt"
        case .mask: return "Bandit"
        }
    }
}

struct Config: Codable, Equatable {
    /// 1 = flat `workspaces` list; 2 = workspaces nested inside display
    /// profiles; 3 = one grid per display inside a workspace. Reading an older
    /// file migrates it (see `init(from:)` here and in Workspace/DisplayProfile).
    static let currentVersion = 3

    var version: Int
    /// One entry per display setup. Workspaces live inside a profile, so the
    /// laptop on its own and the desk with the big monitor keep separate sets
    /// of them — including separate grids, since a 3x2 bento makes sense on a
    /// 27" and not on a 14".
    var profiles: [DisplayProfile]
    var floatingApps: [AppRef]
    var hideUnassignedShortcut: Shortcut?
    var applyLayoutShortcut: Shortcut?
    var nextWorkspaceShortcut: Shortcut?
    var previousWorkspaceShortcut: Shortcut?
    var snap: SnapSettings
    /// Menu bar appearance. The name of the active workspace sits next to the
    /// icon unless you'd rather keep the menu bar narrow.
    var menuBarIcon: MenuBarIcon
    var showWorkspaceName: Bool

    private enum CodingKeys: String, CodingKey {
        case version, profiles, floatingApps, hideUnassignedShortcut, applyLayoutShortcut
        case nextWorkspaceShortcut, previousWorkspaceShortcut, snap
        case menuBarIcon, showWorkspaceName
        /// v1 only, read for migration and never written back.
        case workspaces
    }

    init(
        version: Int = Config.currentVersion,
        profiles: [DisplayProfile] = [],
        floatingApps: [AppRef] = [],
        hideUnassignedShortcut: Shortcut? = Shortcut(key: "0"),
        applyLayoutShortcut: Shortcut? = Shortcut(key: "l"),
        nextWorkspaceShortcut: Shortcut? = Shortcut(key: "p"),
        previousWorkspaceShortcut: Shortcut? = Shortcut(key: "n"),
        snap: SnapSettings = SnapSettings(),
        menuBarIcon: MenuBarIcon = .fallback,
        showWorkspaceName: Bool = true
    ) {
        self.version = version
        self.profiles = profiles
        self.floatingApps = floatingApps
        self.hideUnassignedShortcut = hideUnassignedShortcut
        self.applyLayoutShortcut = applyLayoutShortcut
        self.nextWorkspaceShortcut = nextWorkspaceShortcut
        self.previousWorkspaceShortcut = previousWorkspaceShortcut
        self.snap = snap
        self.menuBarIcon = menuBarIcon
        self.showWorkspaceName = showWorkspaceName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Decoding *is* the migration — whatever the file said, what we hold in
        // memory (and write back) is the current shape.
        version = Config.currentVersion
        if let profiles = try container.decodeIfPresent([DisplayProfile].self, forKey: .profiles) {
            self.profiles = profiles
        } else {
            // v1 file: one flat workspace list with no notion of displays.
            // Carry it into an *unbound* profile — the first detection run
            // binds that to whatever is attached, so the setup you happen to
            // upgrade on inherits the workspaces you already had.
            let legacy = try container.decodeIfPresent([Workspace].self, forKey: .workspaces) ?? []
            profiles = [DisplayProfile(name: "Default", workspaces: legacy)]
        }
        floatingApps = try container.decodeIfPresent([AppRef].self, forKey: .floatingApps) ?? []
        // Absent key -> default (also upgrades older configs). Explicit
        // null means the user chose "None", so keep it nil.
        hideUnassignedShortcut = try Self.shortcut(in: container, key: .hideUnassignedShortcut, default: Shortcut(key: "0"))
        applyLayoutShortcut = try Self.shortcut(in: container, key: .applyLayoutShortcut, default: Shortcut(key: "l"))
        nextWorkspaceShortcut = try Self.shortcut(in: container, key: .nextWorkspaceShortcut, default: Shortcut(key: "p"))
        previousWorkspaceShortcut = try Self.shortcut(in: container, key: .previousWorkspaceShortcut, default: Shortcut(key: "n"))
        snap = try container.decodeIfPresent(SnapSettings.self, forKey: .snap) ?? SnapSettings()
        menuBarIcon = try container.decodeIfPresent(MenuBarIcon.self, forKey: .menuBarIcon) ?? .fallback
        showWorkspaceName = try container.decodeIfPresent(Bool.self, forKey: .showWorkspaceName) ?? true
    }

    private static func shortcut(
        in container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys,
        default fallback: Shortcut
    ) throws -> Shortcut? {
        guard container.contains(key) else { return fallback }
        return try container.decodeIfPresent(Shortcut.self, forKey: key)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(profiles, forKey: .profiles)
        try container.encode(floatingApps, forKey: .floatingApps)
        // Encoded explicitly (null for "None") so reloads don't resurrect the defaults.
        try container.encode(hideUnassignedShortcut, forKey: .hideUnassignedShortcut)
        try container.encode(applyLayoutShortcut, forKey: .applyLayoutShortcut)
        try container.encode(nextWorkspaceShortcut, forKey: .nextWorkspaceShortcut)
        try container.encode(previousWorkspaceShortcut, forKey: .previousWorkspaceShortcut)
        try container.encode(snap, forKey: .snap)
        try container.encode(menuBarIcon, forKey: .menuBarIcon)
        try container.encode(showWorkspaceName, forKey: .showWorkspaceName)
    }
}
