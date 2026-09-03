import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject var keyDebugger: KeyDebugger
    @ObservedObject var recorder: ShortcutRecorder
    let displays: DisplayProfileManager

    /// Which display profile the Workspaces and Shortcuts tabs edit. Follows
    /// the connected one, but any profile can be selected so you can set up a
    /// desk you aren't sitting at.
    @State private var profileID: UUID?

    var body: some View {
        TabView {
            WorkspacesTab(store: store, recorder: recorder, profileID: $profileID)
                .tabItem { Text("Workspaces") }
            ShortcutsTab(store: store, debugger: keyDebugger, recorder: recorder, profileID: $profileID)
                .tabItem { Text("Shortcuts") }
            DisplaysTab(store: store, displays: displays, profileID: $profileID)
                .tabItem { Text("Displays") }
            FloatingAppsTab(store: store)
                .tabItem { Text("Floating Apps") }
            MenuBarTab(store: store)
                .tabItem { Text("Menu Bar") }
        }
        .frame(width: 720, height: 640)
        .onAppear {
            if profileID == nil || !store.config.profiles.contains(where: { $0.id == profileID }) {
                profileID = store.activeProfileID ?? store.config.profiles.first?.id
            }
        }
        // Follow the hardware: plug a monitor in with Settings open and the
        // editors move to that setup's workspaces.
        .onReceive(store.$activeProfileID) { id in
            if let id { profileID = id }
        }
    }
}

/// By-id bindings for the Settings editors.
///
/// Profiles come and go under a live view — deleted on the Displays tab, or the
/// whole array swapped by Reload Config — and an index-based binding captured by
/// a ForEach row or a child view would trap when the array shrinks. These look
/// the profile up on every access instead and no-op if it's gone.
extension ConfigStore {
    func workspacesBinding(profile id: UUID) -> Binding<[Workspace]> {
        Binding(
            get: { self.config.profiles.first { $0.id == id }?.workspaces ?? [] },
            set: { newValue in
                guard let index = self.config.profiles.firstIndex(where: { $0.id == id }) else { return }
                self.config.profiles[index].workspaces = newValue
            }
        )
    }

    func nameBinding(profile id: UUID) -> Binding<String> {
        Binding(
            get: { self.config.profiles.first { $0.id == id }?.name ?? "" },
            set: { newValue in
                guard let index = self.config.profiles.firstIndex(where: { $0.id == id }) else { return }
                self.config.profiles[index].name = newValue
            }
        )
    }
}

/// Picks which display profile the surrounding editor acts on. Callers do the
/// layout; this is just the popup.
struct ProfileScopePicker: View {
    @ObservedObject var store: ConfigStore
    @Binding var profileID: UUID?

    var body: some View {
        Picker("Display profile", selection: $profileID) {
            ForEach(store.config.profiles) { profile in
                Text(label(for: profile)).tag(Optional(profile.id))
            }
        }
    }

    private func label(for profile: DisplayProfile) -> String {
        profile.id == store.activeProfileID ? "\(profile.name) — connected" : profile.name
    }
}

// MARK: - Workspaces

struct WorkspacesTab: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject var recorder: ShortcutRecorder
    @Binding var profileID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                // Applies everywhere, unlike the profile-scoped list below.
                Toggle(
                    "Follow focus: focusing an app that lives in another workspace switches to it",
                    isOn: $store.config.followFocusedApp
                )

                HStack(spacing: 8) {
                    ProfileScopePicker(store: store, profileID: $profileID)
                        .frame(maxWidth: 340)
                    Spacer()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)

            Divider()

            if let id = profileID, let profile = store.config.profiles.first(where: { $0.id == id }) {
                WorkspaceListPane(
                    workspaces: store.workspacesBinding(profile: id),
                    displays: profile.displays,
                    config: store.config,
                    recorder: recorder
                )
                // Fresh selection state per profile — workspace ids don't
                // carry across them, and neither does the display being edited.
                .id(id)
            } else {
                Text("No display profile yet. Plug your displays in, or hit Re-detect on the Displays tab.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// The workspace list + detail editor for one display profile.
struct WorkspaceListPane: View {
    @Binding var workspaces: [Workspace]
    /// The profile's displays — one grid per entry inside every workspace.
    let displays: [DisplayRef]
    let config: Config
    @ObservedObject var recorder: ShortcutRecorder
    @State private var selection: UUID?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: stickySelection) {
                    ForEach(workspaces) { workspace in
                        HStack {
                            Text(workspace.name)
                            Spacer()
                            if let shortcut = workspace.shortcut {
                                Text(shortcut.display)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .tag(workspace.id)
                    }
                }
                Divider()
                HStack(spacing: 8) {
                    Button(action: addWorkspace) { Image(systemName: "plus") }
                    Button(action: removeSelected) { Image(systemName: "minus") }
                        .disabled(selection == nil)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(6)
            }
            .frame(width: 190)

            Divider()

            if let index = workspaces.firstIndex(where: { $0.id == selection }) {
                WorkspaceDetail(
                    workspace: $workspaces[index],
                    displays: displays,
                    config: config,
                    recorder: recorder
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("Select or create a workspace")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            if selection == nil || !workspaces.contains(where: { $0.id == selection }) {
                selection = workspaces.first?.id
            }
        }
    }

    /// Clicking empty sidebar space makes the List set nil — swallow that so
    /// the detail pane never collapses mid-edit. (Removal re-selects explicitly.)
    private var stickySelection: Binding<UUID?> {
        Binding(
            get: { selection },
            set: { newValue in
                if let newValue { selection = newValue }
            }
        )
    }

    private func addWorkspace() {
        let number = workspaces.count + 1
        var workspace = Workspace(name: "Workspace \(number)")
        if number <= 9 {
            workspace.shortcut = Shortcut(key: "\(number)")
        }
        // An empty grid per display of this profile, so the editor has one to
        // show for every monitor in the setup.
        workspace.rebindGrids(to: displays)
        workspaces.append(workspace)
        selection = workspace.id
    }

    private func removeSelected() {
        workspaces.removeAll { $0.id == selection }
        selection = workspaces.first?.id
    }
}

struct WorkspaceDetail: View {
    @Binding var workspace: Workspace
    let displays: [DisplayRef]
    let config: Config
    @ObservedObject var recorder: ShortcutRecorder

    /// Which display's grid the editor is showing. Kept as a key rather than
    /// an index so a profile gaining or losing a monitor can't point it at the
    /// wrong one; `editingKey` falls back when the key goes away.
    @State private var selectedDisplay: String?

    // Scrolls because the pane is taller than the 640pt window once a display
    // picker and both grids' controls are in it — clipping the Apply Layout
    // hint would hide the one line explaining what the grid does.
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Name", text: $workspace.name)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Text("Shortcut")
                    ShortcutField(
                        shortcut: $workspace.shortcut,
                        recorder: recorder,
                        recordingID: "workspace-\(workspace.id.uuidString)"
                    )
                    Spacer()
                }

                Toggle("Launch apps that aren't running when switching", isOn: $workspace.launchMissingApps)

                Divider()

                Text("Apps in this workspace")
                    .font(.headline)

                AppListEditor(apps: $workspace.apps)
                    .frame(height: 150)

                Text("Tip: add the same app to several workspaces — it stays visible and keeps its position when you switch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                HStack {
                    Text("Grid Layout")
                        .font(.headline)
                    Spacer()
                    if !AccessibilityPermission.isGranted {
                        Button("Grant Accessibility…") { AccessibilityPermission.requestAndOpenSettings() }
                    }
                }

                displayScope

                HStack(spacing: 16) {
                    Stepper("Columns: \(grid.wrappedValue.columns)", value: grid.columns, in: 1...8)
                    Stepper("Rows: \(grid.wrappedValue.rows)", value: grid.rows, in: 1...8)
                    Spacer()
                }

                GridLayoutEditor(workspace: $workspace, displays: displays, displayKey: editingKey)

                Text(gridHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }

    /// One grid per display, so the picker is how you say "…and on the other
    /// monitor". A single-display setup gets a label instead of a control.
    @ViewBuilder
    private var displayScope: some View {
        if displays.count > 1 {
            Picker("Display", selection: displaySelection) {
                ForEach(displays) { display in
                    Text(display.name).tag(display.key)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        } else if let only = displays.first {
            Text("Grid for \(only.name)")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text("This profile isn't bound to any displays yet, so there's one grid, "
                 + "applied on whichever screen a window is already on.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// The display being edited: the picked one while it still exists, else
    /// the first — or the unbound grid when the profile has no displays.
    private var editingKey: String {
        if let selectedDisplay, displays.contains(where: { $0.key == selectedDisplay }) {
            return selectedDisplay
        }
        return displays.first?.key ?? DisplayGrid.unboundKey
    }

    private var displaySelection: Binding<String> {
        Binding(get: { editingKey }, set: { selectedDisplay = $0 })
    }

    /// Grids are stored sparsely; this materialises one for the display the
    /// moment the steppers write to it.
    private var grid: Binding<DisplayGrid> {
        let key = editingKey
        return Binding(
            get: { workspace.grid(for: key) ?? DisplayGrid(displayKey: key) },
            set: { workspace.setGrid($0) }
        )
    }

    private var gridHint: String {
        var parts: [String] = []
        if let shortcut = config.applyLayoutShortcut {
            parts.append("\(shortcut.display) (or menu bar → Apply Grid Layout) moves this workspace's apps to the display they're placed on and resizes them to their cells.")
        } else {
            parts.append("Menu bar → Apply Grid Layout moves this workspace's apps to the display they're placed on and resizes them to their cells.")
        }
        if config.snap.enabled, config.snap.hasModifiers {
            var snap = "Hold \(config.snap.modifierDisplay) while dragging any window to snap it to the cell under the cursor."
            if let span = config.snap.spanModifierDisplay {
                snap += " Add \(span) to span several cells."
            }
            parts.append(snap)
        }
        return parts.joined(separator: " ")
    }
}

// MARK: - Grid layout editor

/// Bento editor for one display's grid: drag an app chip onto the grid to
/// place it, drag a placed tile to move it, drag its corner handle to span
/// more cells, ✕ removes it. An app placed on another display's grid shows up
/// as a dimmed chip — dragging it here moves it to this monitor.
struct GridLayoutEditor: View {
    @Binding var workspace: Workspace
    let displays: [DisplayRef]
    /// The display whose grid is being edited (`DisplayGrid.unboundKey` for a
    /// profile with no displays bound).
    let displayKey: String

    /// Bundle id of the chip currently being dragged (set by onDrag; the
    /// drop delegate reads it directly so no async item-provider decoding).
    @State private var draggedChip: String?
    @State private var dropPreview: GridRegion?
    /// Live move/resize of a placed tile.
    @State private var interaction: TileInteraction?

    struct TileInteraction {
        let bundleId: String
        var preview: GridRegion
    }

    private static let palette: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .red, .indigo]

    /// The grid being edited. Absent until something is placed on it, so an
    /// untouched display reads as an empty default rather than nothing at all.
    private var grid: DisplayGrid {
        workspace.grid(for: displayKey) ?? DisplayGrid(displayKey: displayKey)
    }

    /// Everything not already on this display's grid — including apps sitting
    /// on another monitor's, which a drag over here moves.
    private var availableApps: [AppRef] {
        workspace.apps.filter { grid.layout[$0.bundleId] == nil }
    }

    /// The other display an app is currently placed on, if any.
    private func placedElsewhere(_ bundleId: String) -> String? {
        guard let other = workspace.grids.first(where: {
            $0.displayKey != displayKey && $0.layout[bundleId] != nil
        }) else { return nil }
        return displays.first { $0.key == other.displayKey }?.name ?? "another display"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if workspace.apps.isEmpty {
                Text("Add apps above, then drag them onto the grid.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                if !availableApps.isEmpty {
                    HStack(spacing: 6) {
                        Text("Drag onto the grid:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(availableApps) { app in
                                    chip(for: app)
                                }
                            }
                        }
                    }
                }

                canvas
                    .frame(height: 150)

                Text("Drag a tile to move it, drag its corner dot to cover more cells, ✕ to remove.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func chip(for app: AppRef) -> some View {
        let elsewhere = placedElsewhere(app.bundleId)
        return HStack(spacing: 4) {
            Circle()
                .fill(color(for: app.bundleId))
                .frame(width: 7, height: 7)
            Text(app.name)
                .font(.caption)
            if let elsewhere {
                Text("on \(elsewhere)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.secondary.opacity(0.12)))
        .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.4)))
        .opacity(elsewhere == nil ? 1 : 0.65)
        .help(elsewhere.map { "Placed on \($0) — drag here to move it" } ?? app.bundleId)
        .onDrag {
            draggedChip = app.bundleId
            return NSItemProvider(object: app.bundleId as NSString)
        }
    }

    private var canvas: some View {
        GeometryReader { geo in
            let cols = grid.columns
            let rows = grid.rows
            let cellWidth = geo.size.width / CGFloat(cols)
            let cellHeight = geo.size.height / CGFloat(rows)

            ZStack(alignment: .topLeading) {
                ForEach(0..<(cols * rows), id: \.self) { index in
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.secondary.opacity(0.3))
                        .frame(width: max(cellWidth - 4, 1), height: max(cellHeight - 4, 1))
                        .offset(
                            x: CGFloat(index % cols) * cellWidth + 2,
                            y: CGFloat(index / cols) * cellHeight + 2
                        )
                }

                ForEach(workspace.apps) { app in
                    if let stored = grid.layout[app.bundleId] {
                        let region = (interaction?.bundleId == app.bundleId ? interaction!.preview : stored)
                            .clamped(columns: cols, rows: rows)
                        tile(
                            app: app,
                            region: region,
                            cols: cols,
                            rows: rows,
                            cellWidth: cellWidth,
                            cellHeight: cellHeight,
                            canvasSize: geo.size
                        )
                    }
                }

                if let dropPreview {
                    let dropColor = color(for: draggedChip ?? "")
                    RoundedRectangle(cornerRadius: 4)
                        .fill(dropColor.opacity(0.2))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(dropColor, style: StrokeStyle(lineWidth: 2, dash: [4]))
                        )
                        .frame(
                            width: max(CGFloat(dropPreview.colSpan) * cellWidth - 4, 1),
                            height: max(CGFloat(dropPreview.rowSpan) * cellHeight - 4, 1)
                        )
                        .offset(
                            x: CGFloat(dropPreview.col) * cellWidth + 2,
                            y: CGFloat(dropPreview.row) * cellHeight + 2
                        )
                        .allowsHitTesting(false)
                }
            }
            // The ZStack would otherwise size to its largest un-offset child
            // (~one cell) — offsets don't count toward layout — leaving drop
            // targeting and tile hit-testing dead outside the top-left cell.
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .coordinateSpace(name: "gridCanvas")
            .contentShape(Rectangle())
            .onDrop(of: [.text], delegate: GridDropDelegate(
                cols: cols,
                rows: rows,
                size: geo.size,
                draggedChip: $draggedChip,
                preview: $dropPreview,
                place: { bundleId, region in
                    workspace.place(bundleId, at: region, on: displayKey)
                }
            ))
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
    }

    private func tile(
        app: AppRef,
        region: GridRegion,
        cols: Int,
        rows: Int,
        cellWidth: CGFloat,
        cellHeight: CGFloat,
        canvasSize: CGSize
    ) -> some View {
        let tileColor = color(for: app.bundleId)
        let isActive = interaction?.bundleId == app.bundleId

        return RoundedRectangle(cornerRadius: 4)
            .fill(tileColor.opacity(isActive ? 0.45 : 0.3))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(tileColor, lineWidth: isActive ? 2 : 1))
            .overlay(
                Text(app.name)
                    .font(.caption2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(4)
            )
            .overlay(alignment: .topTrailing) {
                Button {
                    workspace.unplace(app.bundleId, on: displayKey)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(2)
            }
            .overlay(alignment: .bottomTrailing) {
                Circle()
                    .fill(tileColor)
                    .frame(width: 9, height: 9)
                    .padding(4)
                    .contentShape(Rectangle())
                    .gesture(resizeGesture(app: app, cols: cols, rows: rows, canvasSize: canvasSize))
            }
            .frame(
                width: max(CGFloat(region.colSpan) * cellWidth - 4, 1),
                height: max(CGFloat(region.rowSpan) * cellHeight - 4, 1)
            )
            .offset(
                x: CGFloat(region.col) * cellWidth + 2,
                y: CGFloat(region.row) * cellHeight + 2
            )
            .gesture(moveGesture(app: app, cols: cols, rows: rows, canvasSize: canvasSize))
    }

    /// Grab anywhere in the tile: it follows in whole-cell steps, span preserved.
    private func moveGesture(app: AppRef, cols: Int, rows: Int, canvasSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("gridCanvas"))
            .onChanged { value in
                guard let stored = grid.layout[app.bundleId] else { return }
                let region = stored.clamped(columns: cols, rows: rows)
                let startCell = cell(at: value.startLocation, cols: cols, rows: rows, size: canvasSize)
                let currentCell = cell(at: value.location, cols: cols, rows: rows, size: canvasSize)
                interaction = TileInteraction(
                    bundleId: app.bundleId,
                    preview: GridRegion(
                        col: min(max(region.col + currentCell.col - startCell.col, 0), cols - region.colSpan),
                        row: min(max(region.row + currentCell.row - startCell.row, 0), rows - region.rowSpan),
                        colSpan: region.colSpan,
                        rowSpan: region.rowSpan
                    )
                )
            }
            .onEnded { _ in commitInteraction() }
    }

    /// Corner handle: the tile spans from its origin to the cell under the cursor.
    private func resizeGesture(app: AppRef, cols: Int, rows: Int, canvasSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("gridCanvas"))
            .onChanged { value in
                guard let stored = grid.layout[app.bundleId] else { return }
                let region = stored.clamped(columns: cols, rows: rows)
                let currentCell = cell(at: value.location, cols: cols, rows: rows, size: canvasSize)
                interaction = TileInteraction(
                    bundleId: app.bundleId,
                    preview: GridRegion(
                        col: region.col,
                        row: region.row,
                        colSpan: max(1, currentCell.col - region.col + 1),
                        rowSpan: max(1, currentCell.row - region.row + 1)
                    )
                )
            }
            .onEnded { _ in commitInteraction() }
    }

    private func commitInteraction() {
        if let interaction {
            workspace.place(interaction.bundleId, at: interaction.preview, on: displayKey)
        }
        interaction = nil
    }

    private func cell(at point: CGPoint, cols: Int, rows: Int, size: CGSize) -> GridCell {
        let col = Int(point.x / max(size.width / CGFloat(cols), 1))
        let row = Int(point.y / max(size.height / CGFloat(rows), 1))
        return GridCell(col: min(max(col, 0), cols - 1), row: min(max(row, 0), rows - 1))
    }

    private func color(for bundleId: String) -> Color {
        guard let index = workspace.apps.firstIndex(where: { $0.bundleId == bundleId }) else { return .gray }
        return Self.palette[index % Self.palette.count]
    }
}

/// Places the dragged chip on the cell under the cursor. `place` moves the app
/// off any other display's grid — an app belongs to one monitor at a time.
private struct GridDropDelegate: DropDelegate {
    let cols: Int
    let rows: Int
    let size: CGSize
    @Binding var draggedChip: String?
    @Binding var preview: GridRegion?
    let place: (String, GridRegion) -> Void

    func validateDrop(info: DropInfo) -> Bool { draggedChip != nil }

    func dropEntered(info: DropInfo) { update(info) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        update(info)
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) { preview = nil }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            draggedChip = nil
            preview = nil
        }
        guard let bundleId = draggedChip, let region = preview else { return false }
        place(bundleId, region)
        return true
    }

    private func update(_ info: DropInfo) {
        let col = Int(info.location.x / max(size.width / CGFloat(cols), 1))
        let row = Int(info.location.y / max(size.height / CGFloat(rows), 1))
        preview = GridRegion(
            col: min(max(col, 0), cols - 1),
            row: min(max(row, 0), rows - 1)
        )
    }
}

// MARK: - Shortcut field

/// Shows the current combo as text; "Reassign" records the next key press
/// (via ShortcutRecorder), ✕ clears it.
struct ShortcutField: View {
    @Binding var shortcut: Shortcut?
    @ObservedObject var recorder: ShortcutRecorder
    let recordingID: String

    var body: some View {
        HStack(spacing: 6) {
            if recorder.activeID == recordingID {
                Text("Press keys… (esc cancels)")
                    .foregroundStyle(.secondary)
                Button("Cancel") { recorder.cancel() }
            } else {
                Text(shortcut?.display ?? "None")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(shortcut == nil ? .secondary : .primary)
                Button(shortcut == nil ? "Assign…" : "Reassign…") {
                    recorder.begin(id: recordingID) { shortcut = $0 }
                }
                .help("Press a key with at least one of ⌃⌥⇧⌘ (keys 0–9, a–z, punctuation)")
                if shortcut != nil {
                    Button {
                        shortcut = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove shortcut")
                }
            }
        }
    }
}

// MARK: - App list editor (shared by workspaces and floating apps)

struct AppListEditor: View {
    @Binding var apps: [AppRef]

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(apps) { app in
                    HStack {
                        AppIcon(path: app.path)
                        Text(app.name)
                        Spacer()
                        Text(app.bundleId)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button {
                            apps.removeAll { $0.bundleId == app.bundleId }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if apps.isEmpty {
                    Text("No apps yet")
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Menu("Add App") {
                    ForEach(runningApps(), id: \.bundleId) { ref in
                        Button(ref.name) { add(ref) }
                    }
                    Divider()
                    Button("Choose from /Applications…") { browse() }
                }
                .frame(width: 180)
                Spacer()
            }
            .padding(.top, 8)
        }
    }

    private func runningApps() -> [AppRef] {
        let existing = Set(apps.map(\.bundleId))
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let bundleId = app.bundleIdentifier, !existing.contains(bundleId) else { return nil }
                return AppRef(bundleId: bundleId, name: app.localizedName ?? bundleId, path: app.bundleURL?.path)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func add(_ ref: AppRef) {
        guard !apps.contains(where: { $0.bundleId == ref.bundleId }) else { return }
        apps.append(ref)
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundle = Bundle(url: url), let bundleId = bundle.bundleIdentifier else { continue }
            let name = (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
                ?? (bundle.infoDictionary?["CFBundleName"] as? String)
                ?? url.deletingPathExtension().lastPathComponent
            add(AppRef(bundleId: bundleId, name: name, path: url.path))
        }
    }
}

struct AppIcon: View {
    let path: String?

    var body: some View {
        Image(nsImage: icon)
            .resizable()
            .frame(width: 18, height: 18)
    }

    private var icon: NSImage {
        if let path {
            return NSWorkspace.shared.icon(forFile: path)
        }
        return NSWorkspace.shared.icon(for: .applicationBundle)
    }
}

// MARK: - Shortcuts

struct ShortcutsTab: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject var debugger: KeyDebugger
    @ObservedObject var recorder: ShortcutRecorder
    /// Workspace switch actions belong to a display profile, so this tab edits
    /// the same profile the Workspaces tab is on.
    @Binding var profileID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button(debugger.isActive ? "Stop Listening" : "Start Listening") {
                            debugger.toggle()
                        }
                        if debugger.isActive {
                            Text("Stays on until you stop it. Keys are captured while you're on this tab; global hotkeys show up as fired actions.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }

                    if debugger.isActive {
                        HStack(spacing: 12) {
                            Text("Held:")
                                .foregroundStyle(.secondary)
                            Text(debugger.heldModifiers.isEmpty ? "—" : debugger.heldModifiers)
                                .font(.system(.title3, design: .monospaced))
                        }
                    }

                    if let press = debugger.lastPress {
                        HStack(spacing: 12) {
                            Text("Last key:")
                                .foregroundStyle(.secondary)
                            Text(press.combo)
                                .font(.system(.title3, design: .monospaced))
                                .bold()
                            Text("keyCode \(press.keyCode)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(press.verdict)
                            .font(.caption)
                            .foregroundStyle(press.usable ? Color.green : Color.orange)
                    }

                    if !debugger.isActive && debugger.lastPress == nil {
                        Text("Activate to see which keys and modifiers macOS delivers while a Tile Bandit window is focused, and which global hotkeys fire — useful when a shortcut doesn't do what you expect.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            } label: {
                Text("Key Debugger").font(.headline)
            }

            HStack(spacing: 8) {
                Text("Actions")
                    .font(.headline)
                Spacer()
                ProfileScopePicker(store: store, profileID: $profileID)
                    .frame(maxWidth: 300)
            }

            List {
                Section("General") {
                    shortcutRow("Hide unassigned apps", $store.config.hideUnassignedShortcut, id: "hide-unassigned")
                    shortcutRow("Apply grid layout (active workspace)", $store.config.applyLayoutShortcut, id: "apply-layout")
                    shortcutRow("Maximize focused window (while held)", $store.config.maximizeHoldShortcut, id: "maximize-hold")
                    shortcutRow("Maximize focused window", $store.config.maximizeShortcut, id: "maximize")
                    shortcutRow("Next workspace", $store.config.nextWorkspaceShortcut, id: "next-workspace")
                    shortcutRow("Previous workspace", $store.config.previousWorkspaceShortcut, id: "previous-workspace")
                    shortcutRow("Open settings", $store.config.openSettingsShortcut, id: "open-settings")
                    shortcutRow("Reload config from disk", $store.config.reloadConfigShortcut, id: "reload-config")
                }
                Section("Grid snapping") {
                    Toggle("Snap a window to the grid when dragging it with modifiers held", isOn: $store.config.snap.enabled)
                        .padding(.vertical, 2)
                    if store.config.snap.enabled {
                        HStack(spacing: 8) {
                            Text("Hold")
                            Toggle("⌃", isOn: $store.config.snap.control)
                            Toggle("⌥", isOn: $store.config.snap.option)
                            Toggle("⇧", isOn: $store.config.snap.shift)
                            Toggle("⌘", isOn: $store.config.snap.command)
                            Text("while dragging a window")
                                .foregroundStyle(.secondary)
                        }
                        .toggleStyle(.button)
                        .padding(.vertical, 2)
                        if !store.config.snap.hasModifiers {
                            Text("Pick at least one modifier — snapping stays off without one.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        } else if let span = store.config.snap.spanModifierDisplay {
                            Text("A drag snaps to the single cell under the cursor; hold \(span) as well to span several.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 16) {
                            Text("Grid when no workspace is active:")
                            Stepper("\(store.config.snap.defaultColumns) columns", value: $store.config.snap.defaultColumns, in: 1...8)
                            Stepper("\(store.config.snap.defaultRows) rows", value: $store.config.snap.defaultRows, in: 1...8)
                        }
                        .padding(.vertical, 2)
                    }
                    if !AccessibilityPermission.isGranted {
                        HStack {
                            Text("Moving windows needs the Accessibility permission. If it still doesn't work after granting, relaunch Tile Bandit.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                            Spacer()
                            Button("Grant…") { AccessibilityPermission.requestAndOpenSettings() }
                        }
                        .padding(.vertical, 2)
                    }
                }
                if let profile = store.config.profiles.first(where: { $0.id == profileID }) {
                    Section("Workspaces in \(profile.name)") {
                        if profile.workspaces.isEmpty {
                            Text("Create a workspace first — each workspace is a switch action.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(store.workspacesBinding(profile: profile.id)) { $workspace in
                            HStack {
                                Text("Switch to \(workspace.name)")
                                Spacer()
                                ShortcutField(
                                    shortcut: $workspace.shortcut,
                                    recorder: recorder,
                                    recordingID: "workspace-\(workspace.id.uuidString)"
                                )
                            }
                            .padding(.vertical, 2)
                        }
                        if profile.id != store.activeProfileID {
                            Text("This profile isn't connected — its shortcuts take over when you plug those displays in.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
        .padding(16)
        .onAppear { debugger.shortcutsTabVisible = true }
        .onDisappear { debugger.shortcutsTabVisible = false }
    }

    private func shortcutRow(_ label: String, _ shortcut: Binding<Shortcut?>, id: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            ShortcutField(shortcut: shortcut, recorder: recorder, recordingID: id)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Displays

/// Manages the display profiles themselves: what's attached right now, which
/// profile that matched, and per-profile rename / duplicate / rebind / delete.
struct DisplaysTab: View {
    @ObservedObject var store: ConfigStore
    let displays: DisplayProfileManager
    @Binding var profileID: UUID?

    @State private var attached: [DisplayRef] = DisplayIdentity.snapshot()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(
                "Each display setup gets its own workspaces. Tile Bandit recognises the attached "
                    + "screens and switches to the matching profile automatically — plug in a monitor "
                    + "and that setup's workspaces own the hotkeys. A setup it hasn't seen before gets "
                    + "a new profile, seeded with a copy of the one you were just on."
            )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    if attached.isEmpty {
                        Text("No displays reported")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(attached) { display in
                        HStack(spacing: 8) {
                            Image(systemName: display.key.hasPrefix(DisplayIdentity.builtInKey)
                                ? "laptopcomputer" : "display")
                            Text(display.name)
                            Spacer()
                            Text(display.key)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                    HStack {
                        Text(matchSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Re-detect") { redetect() }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            } label: {
                Text("Attached now").font(.headline)
            }

            HStack {
                Text("Profiles").font(.headline)
                Spacer()
                Button("New Profile") { addProfile() }
            }

            List {
                ForEach(store.config.profiles) { profile in
                    HStack(spacing: 10) {
                        Image(systemName: profile.id == store.activeProfileID ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(profile.id == store.activeProfileID ? Color.accentColor : Color.secondary)
                            .help(profile.id == store.activeProfileID ? "Connected" : "Not connected")

                        VStack(alignment: .leading, spacing: 3) {
                            TextField("Name", text: store.nameBinding(profile: profile.id))
                                .textFieldStyle(.roundedBorder)
                            Text(subtitle(for: profile))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Button("Edit Workspaces") { profileID = profile.id }

                        Menu {
                            Button("Duplicate") { duplicate(profile) }
                            Button("Bind to Attached Displays") { bind(profile.id) }
                                .disabled(attached.isEmpty)
                            Divider()
                            Button("Delete", role: .destructive) { delete(profile.id) }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .frame(width: 44)
                    }
                    .padding(.vertical, 3)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
        .padding(16)
        // Refreshed both ways on purpose: the notification keeps the list live
        // while the tab is open, and onAppear catches changes that happened
        // while it wasn't in the view tree (an unselected tab gets no
        // notifications, and the settings window is reused once opened).
        .onAppear { attached = DisplayIdentity.snapshot() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didChangeScreenParametersNotification
        )) { _ in
            attached = DisplayIdentity.snapshot()
        }
    }

    private var matchSummary: String {
        if let active = store.activeProfile {
            return "Matched profile: \(active.name)"
        }
        return "No profile matched yet"
    }

    private func subtitle(for profile: DisplayProfile) -> String {
        let count = profile.workspaces.count
        return "\(profile.displaySummary) · \(count) workspace\(count == 1 ? "" : "s")"
    }

    private func redetect() {
        attached = DisplayIdentity.snapshot()
        displays.resolve()
    }

    /// Copies are unbound on purpose: bind them to the setup you want (or let
    /// detection create its own profile when you plug that setup in).
    private func duplicate(_ profile: DisplayProfile) {
        var copy = profile
        copy.id = UUID()
        copy.name = "\(profile.name) copy"
        copy.displays = []
        copy.workspaces = profile.workspaces.map { workspace in
            var clone = workspace
            clone.id = UUID()
            return clone
        }
        store.config.profiles.append(copy)
        profileID = copy.id
    }

    /// Point a profile at the displays attached right now — the fix when
    /// detection made a second profile for a setup you already had, or when you
    /// built a profile before owning the monitor.
    private func bind(_ id: UUID) {
        let snapshot = DisplayIdentity.snapshot()
        guard !snapshot.isEmpty,
              let index = store.config.profiles.firstIndex(where: { $0.id == id })
        else { return }
        // Only one profile may claim a fingerprint, or matching becomes a coin
        // flip: whoever held it is left unbound.
        let keys = Set(snapshot.map(\.key))
        for other in store.config.profiles.indices
        where other != index && store.config.profiles[other].displayKeys == keys {
            store.config.profiles[other].displays = []
        }
        // bind(to:) rather than a plain assignment: the workspaces' grids were
        // keyed to whatever this profile stood for before, and they follow it
        // onto the new displays.
        store.config.profiles[index].bind(to: snapshot)
        displays.resolve()
    }

    private func addProfile() {
        let profile = DisplayProfile(name: "New Profile")
        store.config.profiles.append(profile)
        profileID = profile.id
    }

    private func delete(_ id: UUID) {
        store.config.profiles.removeAll { $0.id == id }
        if profileID == id {
            profileID = store.activeProfileID ?? store.config.profiles.first?.id
        }
        // Deleting the live profile leaves nothing matching the hardware, so
        // re-resolve (which may build a fresh profile for it).
        displays.resolve()
    }
}

// MARK: - Floating apps

struct FloatingAppsTab: View {
    @ObservedObject var store: ConfigStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Floating apps stay visible in every workspace — they are never hidden.")
                .foregroundStyle(.secondary)
            AppListEditor(apps: $store.config.floatingApps)
        }
        .padding(16)
    }
}

// MARK: - Menu Bar

struct MenuBarTab: View {
    @ObservedObject var store: ConfigStore

    private let columns = [GridItem(.adaptive(minimum: 72), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("The icon Tile Bandit shows in the menu bar. Changes apply straight away.")
                .foregroundStyle(.secondary)

            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                // Only symbols this macOS actually ships — see MenuBarIcon.available.
                ForEach(MenuBarIcon.available) { icon in
                    MenuBarIconChoice(icon: icon, isSelected: icon == store.config.menuBarIcon) {
                        store.config.menuBarIcon = icon
                    }
                }
            }

            Toggle("Show the active workspace's name next to the icon", isOn: $store.config.showWorkspaceName)

            GroupBox {
                HStack(spacing: 4) {
                    Image(systemName: previewIcon.rawValue)
                    if store.config.showWorkspaceName {
                        Text(previewName)
                    }
                }
                .font(.system(size: 14))
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
            } label: {
                Text("Preview").font(.headline)
            }

            Spacer()
        }
        .padding(16)
    }

    /// A hand-edited config can name a symbol that doesn't resolve; the status
    /// item falls back, so the preview has to show the same thing.
    private var previewIcon: MenuBarIcon {
        store.config.menuBarIcon.image == nil ? .fallback : store.config.menuBarIcon
    }

    private var previewName: String {
        store.workspaces.first?.name ?? "Workspace"
    }
}

private struct MenuBarIconChoice: View {
    let icon: MenuBarIcon
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(spacing: 4) {
                Image(systemName: icon.rawValue)
                    .font(.system(size: 18))
                Text(icon.label)
                    .font(.caption2)
                    .lineLimit(1)
            }
            .frame(width: 72, height: 52)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .help(icon.label)
    }
}
