import CoreGraphics
import Foundation

/// A reference to an installed application.
struct AppRef: Codable, Equatable, Hashable, Identifiable {
    var bundleId: String
    var name: String
    var path: String?

    var id: String { bundleId }
}

/// A global keyboard shortcut. `key` is a single character — see
/// `HotkeyManager.keyCodes` for the set (0-9, a-z and common punctuation).
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

/// The status item's icon, in two families.
///
/// The drawn set's raw values are `bandit.*` names that `BanditGlyph` renders
/// from Bézier paths; every other raw value *is* an SF Symbol name, so the
/// enum doubles as the symbol lookup. Because a hand-edited config (or an
/// older macOS missing a symbol) can name one that doesn't resolve, every
/// lookup goes through `resolvedImage`, which falls back to the default rather
/// than leaving an invisible menu bar item. The default is a drawn glyph for
/// that same reason: a drawing can't be missing from the system.
enum MenuBarIcon: String, Codable, CaseIterable, Identifiable {
    // Drawn here — see BanditIcons.swift.
    case star = "bandit.star"
    case mask = "bandit.mask"
    case hat = "bandit.hat"
    case horseshoe = "bandit.horseshoe"
    case cactus = "bandit.cactus"
    case wheel = "bandit.wheel"

    // SF Symbols, for anyone who'd rather their menu bar didn't have opinions.
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
    case theaterMasks = "theatermasks.fill"

    static let fallback = MenuBarIcon.cactus

    var id: String { rawValue }

    /// Unknown/renamed symbol names decode to the default instead of throwing —
    /// the config is hand-editable, and a typo shouldn't cost you the menu bar.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MenuBarIcon(rawValue: raw) ?? .fallback
    }

    /// Which half of the set this is. The name is all the model layer knows:
    /// resolving it to a drawing is AppKit's job, and Models stays AppKit-free.
    enum Family: String, CaseIterable {
        case drawn, symbol

        /// The picker's section headings.
        var title: String { self == .drawn ? "Wanted" : "Plain" }
        var caption: String {
            self == .drawn
                ? "Drawn for this app — sharp at any size."
                : "SF Symbols, for a menu bar without opinions."
        }
    }

    private static let drawnPrefix = "bandit."

    var family: Family { rawValue.hasPrefix(Self.drawnPrefix) ? .drawn : .symbol }

    /// The `BanditGlyph` name for a drawn icon, nil for an SF Symbol.
    var glyphName: String? {
        family == .drawn ? String(rawValue.dropFirst(Self.drawnPrefix.count)) : nil
    }

    var label: String {
        switch self {
        case .star: return "Star"
        case .mask: return "Mask"
        case .hat: return "Hat"
        case .horseshoe: return "Horseshoe"
        case .cactus: return "Cactus"
        case .wheel: return "Wheel"
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
        case .theaterMasks: return "Theatre"
        }
    }
}

struct Config: Codable, Equatable {
    /// 1 = flat `workspaces` list; 2 = workspaces nested inside display
    /// profiles; 3 = one grid per display inside a workspace; 4 = per-keyboard
    /// key modifications. Reading an older file migrates it (see `init(from:)`
    /// here and in Workspace/DisplayProfile).
    static let currentVersion = 4

    var version: Int
    /// One entry per display setup. Workspaces live inside a profile, so the
    /// laptop on its own and the desk with the big monitor keep separate sets
    /// of them — including separate grids, since a 3x2 bento makes sense on a
    /// 27" and not on a 14".
    var profiles: [DisplayProfile]
    var floatingApps: [AppRef]
    var hideUnassignedShortcut: Shortcut?
    var applyLayoutShortcut: Shortcut?
    /// Hold to fill the screen with the focused window, release to put it
    /// back — a peek, not a layout change (nothing is persisted).
    var maximizeHoldShortcut: Shortcut?
    /// The sticky sibling: fill the screen and leave it that way.
    var maximizeShortcut: Shortcut?
    var nextWorkspaceShortcut: Shortcut?
    var previousWorkspaceShortcut: Shortcut?
    var openSettingsShortcut: Shortcut?
    var reloadConfigShortcut: Shortcut?
    var snap: SnapSettings
    /// Menu bar appearance. The name of the active workspace sits next to the
    /// icon unless you'd rather keep the menu bar narrow.
    var menuBarIcon: MenuBarIcon
    var showWorkspaceName: Bool
    /// Take the status item out of the menu bar altogether. Hotkeys carry on —
    /// and re-opening Tile Bandit always brings Settings back, which is what
    /// makes this safe to switch on with no shortcut set.
    var hideMenuBarIcon: Bool
    /// Start with the machine. On by default: a workspace switcher you have to
    /// remember to launch is a workspace switcher you stop using. Only means
    /// anything to an installed `.app` — see LoginItem.
    var launchAtLogin: Bool
    /// Focusing an app that belongs to another workspace (Cmd-Tab, Spotlight,
    /// the Dock — all of which unhide it) switches to that workspace instead
    /// of leaving one stray window floating over the one you're in.
    var followFocusedApp: Bool
    /// One entry per keyboard — the Karabiner-shaped half of the app. Separate
    /// from `profiles` because keyboards and displays come and go
    /// independently: which map is live depends on what you're typing on, not
    /// on what you're looking at.
    var keyboards: [KeyboardProfile]
    /// Master switch for all of it. Off means no hidutil mapping is applied and
    /// no event tap is created, which is also how the app leaves the machine
    /// when it quits.
    var keyModifications: Bool
    /// Chords that apply whatever you're typing on. Global rather than filed
    /// under a keyboard because an event tap can't tell which keyboard a plain
    /// keypress came from — only a held layer key carries that. Mostly this is
    /// where a combination gets *disabled* (⌘H, say).
    var chords: [KeyChord]

    private enum CodingKeys: String, CodingKey {
        case version, profiles, floatingApps, hideUnassignedShortcut, applyLayoutShortcut
        case maximizeHoldShortcut, maximizeShortcut
        case nextWorkspaceShortcut, previousWorkspaceShortcut
        case openSettingsShortcut, reloadConfigShortcut, snap
        case menuBarIcon, showWorkspaceName, hideMenuBarIcon, launchAtLogin, followFocusedApp
        case keyboards, keyModifications, chords
        /// v1 only, read for migration and never written back.
        case workspaces
    }

    init(
        version: Int = Config.currentVersion,
        profiles: [DisplayProfile] = [],
        floatingApps: [AppRef] = [],
        hideUnassignedShortcut: Shortcut? = Shortcut(key: "0"),
        applyLayoutShortcut: Shortcut? = Shortcut(key: "l"),
        maximizeHoldShortcut: Shortcut? = Shortcut(key: "m"),
        maximizeShortcut: Shortcut? = Shortcut(key: "m", shift: true),
        nextWorkspaceShortcut: Shortcut? = Shortcut(key: "p"),
        previousWorkspaceShortcut: Shortcut? = Shortcut(key: "n"),
        openSettingsShortcut: Shortcut? = Shortcut(key: ","),
        reloadConfigShortcut: Shortcut? = Shortcut(key: "r"),
        snap: SnapSettings = SnapSettings(),
        menuBarIcon: MenuBarIcon = .fallback,
        showWorkspaceName: Bool = true,
        hideMenuBarIcon: Bool = false,
        launchAtLogin: Bool = true,
        followFocusedApp: Bool = true,
        keyboards: [KeyboardProfile] = [],
        keyModifications: Bool = true,
        chords: [KeyChord] = []
    ) {
        self.version = version
        self.profiles = profiles
        self.floatingApps = floatingApps
        self.hideUnassignedShortcut = hideUnassignedShortcut
        self.applyLayoutShortcut = applyLayoutShortcut
        self.maximizeHoldShortcut = maximizeHoldShortcut
        self.maximizeShortcut = maximizeShortcut
        self.nextWorkspaceShortcut = nextWorkspaceShortcut
        self.previousWorkspaceShortcut = previousWorkspaceShortcut
        self.openSettingsShortcut = openSettingsShortcut
        self.reloadConfigShortcut = reloadConfigShortcut
        self.snap = snap
        self.menuBarIcon = menuBarIcon
        self.showWorkspaceName = showWorkspaceName
        self.hideMenuBarIcon = hideMenuBarIcon
        self.launchAtLogin = launchAtLogin
        self.followFocusedApp = followFocusedApp
        self.keyboards = keyboards
        self.keyModifications = keyModifications
        self.chords = chords
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
        maximizeHoldShortcut = try Self.shortcut(in: container, key: .maximizeHoldShortcut, default: Shortcut(key: "m"))
        maximizeShortcut = try Self.shortcut(in: container, key: .maximizeShortcut, default: Shortcut(key: "m", shift: true))
        nextWorkspaceShortcut = try Self.shortcut(in: container, key: .nextWorkspaceShortcut, default: Shortcut(key: "p"))
        previousWorkspaceShortcut = try Self.shortcut(in: container, key: .previousWorkspaceShortcut, default: Shortcut(key: "n"))
        openSettingsShortcut = try Self.shortcut(in: container, key: .openSettingsShortcut, default: Shortcut(key: ","))
        reloadConfigShortcut = try Self.shortcut(in: container, key: .reloadConfigShortcut, default: Shortcut(key: "r"))
        snap = try container.decodeIfPresent(SnapSettings.self, forKey: .snap) ?? SnapSettings()
        menuBarIcon = try container.decodeIfPresent(MenuBarIcon.self, forKey: .menuBarIcon) ?? .fallback
        showWorkspaceName = try container.decodeIfPresent(Bool.self, forKey: .showWorkspaceName) ?? true
        hideMenuBarIcon = try container.decodeIfPresent(Bool.self, forKey: .hideMenuBarIcon) ?? false
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? true
        followFocusedApp = try container.decodeIfPresent(Bool.self, forKey: .followFocusedApp) ?? true
        keyboards = try container.decodeIfPresent([KeyboardProfile].self, forKey: .keyboards) ?? []
        keyModifications = try container.decodeIfPresent(Bool.self, forKey: .keyModifications) ?? true
        chords = try container.decodeIfPresent([KeyChord].self, forKey: .chords) ?? []
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
        try container.encode(maximizeHoldShortcut, forKey: .maximizeHoldShortcut)
        try container.encode(maximizeShortcut, forKey: .maximizeShortcut)
        try container.encode(nextWorkspaceShortcut, forKey: .nextWorkspaceShortcut)
        try container.encode(previousWorkspaceShortcut, forKey: .previousWorkspaceShortcut)
        try container.encode(openSettingsShortcut, forKey: .openSettingsShortcut)
        try container.encode(reloadConfigShortcut, forKey: .reloadConfigShortcut)
        try container.encode(snap, forKey: .snap)
        try container.encode(menuBarIcon, forKey: .menuBarIcon)
        try container.encode(showWorkspaceName, forKey: .showWorkspaceName)
        try container.encode(hideMenuBarIcon, forKey: .hideMenuBarIcon)
        try container.encode(launchAtLogin, forKey: .launchAtLogin)
        try container.encode(followFocusedApp, forKey: .followFocusedApp)
        try container.encode(keyboards, forKey: .keyboards)
        try container.encode(keyModifications, forKey: .keyModifications)
        try container.encode(chords, forKey: .chords)
    }
}

// MARK: - Key modifications

/// The modifiers a dual-role hold stands in for. Encoded as names
/// (`["control","option","shift","command"]`) because the config is
/// hand-edited; `"hyper"` is accepted as shorthand for all four.
struct ModifierSet: OptionSet, Codable, Hashable, Identifiable {
    let rawValue: Int

    var id: Int { rawValue }

    init(rawValue: Int) { self.rawValue = rawValue }

    static let control = ModifierSet(rawValue: 1 << 0)
    static let option = ModifierSet(rawValue: 1 << 1)
    static let shift = ModifierSet(rawValue: 1 << 2)
    static let command = ModifierSet(rawValue: 1 << 3)
    /// Only ever *sent*, never matched against — see `KeyChord.with`. It exists
    /// so a chord can emit a real function key (fn+F11 is "show desktop",
    /// where a bare F11 is whatever the media-key row does).
    static let function = ModifierSet(rawValue: 1 << 4)
    /// All four at once — the usual reason to want a dual-role key in the
    /// first place, since nothing else is bound to it.
    static let hyper: ModifierSet = [.control, .option, .shift, .command]

    /// Flag, config name, menu-bar glyph. One table so encoding, decoding and
    /// display can't drift apart.
    private static let names: [(flag: ModifierSet, name: String, glyph: String)] = [
        (.function, "fn", "fn"),
        (.control, "control", "⌃"),
        (.option, "option", "⌥"),
        (.shift, "shift", "⇧"),
        (.command, "command", "⌘"),
    ]

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode([String].self)
        let wanted = Set(raw.map { $0.lowercased() })
        if wanted.contains("hyper") {
            self = .hyper
            return
        }
        // An unrecognised name is dropped rather than thrown on — losing one
        // modifier beats refusing to load the file.
        self = Self.names.reduce(into: []) { set, entry in
            if wanted.contains(entry.name) { set.insert(entry.flag) }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(Self.names.filter { contains($0.flag) }.map(\.name))
    }

    /// The individually selectable modifiers, in the order macOS writes them —
    /// for the settings toggles. `fn` is separate because it's send-only.
    static let choices: [ModifierSet] = [.control, .option, .shift, .command]

    /// "⌃⌥⇧⌘", in the order macOS writes them.
    var display: String { Self.names.filter { contains($0.flag) }.map(\.glyph).joined() }

    var isHyper: Bool { self == .hyper }
}

/// A key, by the name it has in `HIDKeys`. Stored as a name rather than a
/// usage or a keycode so the config stays readable, and resolved on use so an
/// unknown name disables one mapping instead of breaking the decode.
struct KeyRef: Codable, Equatable, Hashable, Identifiable, ExpressibleByStringLiteral {
    var name: String

    var id: String { name }

    init(_ name: String) { self.name = name }
    init(stringLiteral value: String) { self.init(value) }

    init(from decoder: Decoder) throws {
        name = try decoder.singleValueContainer().decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(name)
    }

    var key: HIDKey? { HIDKeys.named(name) }
    var isKnown: Bool { key != nil }
    /// "Caps Lock" — falls back to the raw name so a typo is visible in the UI
    /// rather than silently blank.
    var label: String { key?.label ?? name }
}

/// A chord rewrite: one key, pressed with a given set of modifiers, becomes a
/// different key with a different set — or nothing at all.
///
/// Two places use these. Inside a `KeyMapping.chords` they're the layer a hold
/// opens, and they're device-scoped for free, because the hold that gates them
/// is. In `Config.chords` they're global and honestly so: a plain keypress
/// carries no device identity an event tap can read, so there is no such thing
/// as a per-keyboard chord outside a layer.
struct KeyChord: Codable, Equatable, Hashable, Identifiable {
    var id: UUID
    /// The key that triggers it.
    var from: KeyRef
    /// Modifiers that must be down, matched *exactly* — ⌘H doesn't fire on
    /// ⌘⇧H. Inside a layer these are the modifiers besides the held key, so an
    /// empty set means the layer key and this key alone. `fn` is never matched
    /// on, only sent: the laptop keyboard sets it on its own in ways that would
    /// make an exact match unpredictable.
    var with: ModifierSet
    /// `nil` swallows the chord — the combination does nothing at all, which is
    /// how a key like ⌘H gets disabled.
    var to: KeyRef?
    /// The modifiers the replacement is sent with.
    var send: ModifierSet
    var enabled: Bool

    init(
        id: UUID = UUID(),
        from: KeyRef,
        with: ModifierSet = [],
        to: KeyRef? = nil,
        send: ModifierSet = [],
        enabled: Bool = true
    ) {
        self.id = id
        self.from = from
        self.with = with
        self.to = to
        self.send = send
        self.enabled = enabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        from = try container.decode(KeyRef.self, forKey: .from)
        with = try container.decodeIfPresent(ModifierSet.self, forKey: .with) ?? []
        to = try container.decodeIfPresent(KeyRef.self, forKey: .to)
        send = try container.decodeIfPresent(ModifierSet.self, forKey: .send) ?? []
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    /// A chord whose `to` names a key we don't know is dropped; one with no
    /// `to` at all is the deliberate "do nothing" case, not a mistake.
    var isUsable: Bool { enabled && from.isKnown && (to?.isKnown ?? true) }

    /// "⌘H → nothing", "Q → ⌥A"
    var summary: String {
        let trigger = with.isEmpty ? from.label : "\(with.display)\(from.label)"
        guard let to else { return "\(trigger) → nothing" }
        return "\(trigger) → \(send.display)\(to.label)"
    }
}

/// One key modification on one keyboard.
///
/// `hold` is what decides which engine does the work. Without it the mapping is
/// a plain 1:1 remap, which hidutil performs at the HID layer — permission-free
/// and immune to secure input. With it the key has to be watched in userspace,
/// which means the event tap and the Accessibility grant that comes with it.
struct KeyMapping: Codable, Equatable, Hashable, Identifiable {
    var id: UUID
    /// The physical key being modified.
    var from: KeyRef
    /// What a press sends. `nil` with a `hold` set means the key is a modifier
    /// and nothing else — a plain hold key with no tap action.
    var to: KeyRef?
    /// The modifiers a hold stands in for. Empty or nil = not dual-role.
    var hold: ModifierSet?
    /// How long a press has to be held before it stops counting as a tap.
    /// Pressing another key always wins immediately, so this only decides what
    /// a lone press-and-release does.
    var holdMilliseconds: Int
    /// Rewrites that apply only while this key is held — the layer the hold
    /// opens. A key with no chord here still gets the hold's modifiers, so a
    /// half-filled layer still behaves like a plain hyper key everywhere else.
    var chords: [KeyChord]
    var enabled: Bool

    init(
        id: UUID = UUID(),
        from: KeyRef,
        to: KeyRef? = nil,
        hold: ModifierSet? = nil,
        holdMilliseconds: Int = 200,
        chords: [KeyChord] = [],
        enabled: Bool = true
    ) {
        self.id = id
        self.from = from
        self.to = to
        self.hold = hold
        self.holdMilliseconds = Self.clampHold(holdMilliseconds)
        self.chords = chords
        self.enabled = enabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        from = try container.decode(KeyRef.self, forKey: .from)
        to = try container.decodeIfPresent(KeyRef.self, forKey: .to)
        hold = try container.decodeIfPresent(ModifierSet.self, forKey: .hold)
        holdMilliseconds = Self.clampHold(try container.decodeIfPresent(Int.self, forKey: .holdMilliseconds) ?? 200)
        chords = try container.decodeIfPresent([KeyChord].self, forKey: .chords) ?? []
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    /// Below ~60ms a tap can't be told from a hold; above a second it stops
    /// feeling like a key.
    private static func clampHold(_ value: Int) -> Int { min(max(value, 60), 1000) }

    /// Needs the event tap, rather than being a remap hidutil can do alone.
    var isDualRole: Bool { !(hold ?? []).isEmpty }

    /// A mapping with an unknown key name, or with nothing to do, is carried in
    /// the config but never applied.
    var isUsable: Bool {
        guard enabled, from.isKnown else { return false }
        if isDualRole { return to?.isKnown ?? true }
        return to?.isKnown ?? false
    }

    /// "Caps Lock → Escape / hold ⌃⌥⇧⌘"
    var summary: String {
        var text = "\(from.label) → \(to?.label ?? "—")"
        if let hold, !hold.isEmpty { text += " / hold \(hold.display)" }
        if !chords.isEmpty { text += " + \(chords.count) chord\(chords.count == 1 ? "" : "s")" }
        return text
    }
}

/// A physical keyboard, fingerprinted the way DisplayRef fingerprints a screen.
///
/// The identifiers ride along because they're what hidutil matches on, and a
/// profile for a keyboard that's unplugged right now still has to describe the
/// hardware it's for. `name` is what the UI shows and the user may rename;
/// `productName` is the untouched registry string, kept separate because it's
/// the only handle the built-in keyboard offers — it publishes no vendor or
/// product id at all.
struct KeyboardRef: Codable, Equatable, Hashable, Identifiable {
    var key: String
    var name: String
    var productName: String?
    var vendorID: Int?
    var productID: Int?
    var isBuiltIn: Bool

    var id: String { key }

    init(
        key: String,
        name: String,
        productName: String? = nil,
        vendorID: Int? = nil,
        productID: Int? = nil,
        isBuiltIn: Bool = false
    ) {
        self.key = key
        self.name = name
        self.productName = productName
        self.vendorID = vendorID
        self.productID = productID
        self.isBuiltIn = isBuiltIn
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decodeIfPresent(String.self, forKey: .key) ?? ""
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? key
        productName = try container.decodeIfPresent(String.self, forKey: .productName)
        vendorID = try container.decodeIfPresent(Int.self, forKey: .vendorID)
        productID = try container.decodeIfPresent(Int.self, forKey: .productID)
        isBuiltIn = try container.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false
    }
}

/// The key modifications for one keyboard.
///
/// Unlike a DisplayProfile — which stands for a whole *set* of attached screens
/// — a keyboard profile is one-to-one with one keyboard, because that's the
/// granularity a remap applies at: two keyboards plugged in at once each keep
/// their own map, and both are live.
struct KeyboardProfile: Codable, Equatable, Hashable, Identifiable {
    var id: UUID
    var name: String
    /// `nil` means unbound — a map authored for hardware that isn't attached
    /// (duplicated from another keyboard, say). Detection never creates these.
    var keyboard: KeyboardRef?
    var enabled: Bool
    var mappings: [KeyMapping]
    /// Bumped on every edit. A keyboard Tile Bandit has never seen starts from
    /// the most recently edited profile, so a new board inherits the map you've
    /// been tuning rather than arriving blank.
    var modifiedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        keyboard: KeyboardRef? = nil,
        enabled: Bool = true,
        mappings: [KeyMapping] = [],
        modifiedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.keyboard = keyboard
        self.enabled = enabled
        self.mappings = mappings
        self.modifiedAt = Self.whole(modifiedAt)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Untitled"
        keyboard = try container.decodeIfPresent(KeyboardRef.self, forKey: .keyboard)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        mappings = try container.decodeIfPresent([KeyMapping].self, forKey: .mappings) ?? []
        modifiedAt = Self.whole(try container.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? Date())
    }

    /// Whole seconds, because that's all the ISO-8601 the config is written in
    /// can hold. Without this a profile stops being equal to itself the moment
    /// it's saved and read back, which the config's `removeDuplicates` would
    /// then see as a change on every reload.
    private static func whole(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }

    var isBound: Bool { keyboard != nil }

    /// Records an edit. This is what "a new keyboard starts from the last
    /// edited keymaps" reads, so every mutation through Settings goes past it.
    mutating func markEdited() { modifiedAt = Self.whole(Date()) }

    /// The mappings that actually reach an engine.
    var usableMappings: [KeyMapping] { enabled ? mappings.filter(\.isUsable) : [] }

    /// Copy this map onto another keyboard — fresh mapping ids, since they're
    /// that profile's own from here on.
    func cloned(onto keyboard: KeyboardRef?, named name: String) -> KeyboardProfile {
        KeyboardProfile(
            name: name,
            keyboard: keyboard,
            enabled: enabled,
            mappings: mappings.map {
                KeyMapping(
                    from: $0.from,
                    to: $0.to,
                    hold: $0.hold,
                    holdMilliseconds: $0.holdMilliseconds,
                    chords: $0.chords.map {
                        KeyChord(from: $0.from, with: $0.with, to: $0.to, send: $0.send, enabled: $0.enabled)
                    },
                    enabled: $0.enabled
                )
            }
        )
    }
}
