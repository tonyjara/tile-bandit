import AppKit
import SwiftUI

/// Bentobox-style drag snapping: hold the configured modifiers while dragging
/// a window and a grid overlay appears; the cells under the drag highlight
/// (drag across several to span them) and the window snaps there on release.
///
/// Watches drags with *global mouse* NSEvent monitors — mouse monitors need
/// no permission (only key monitors require Accessibility). The AX calls that
/// identify and move the window do need the Accessibility grant, same as
/// LayoutEngine.
///
/// A drag only arms once the window has actually moved, so a modifier-drag
/// inside a window's content (e.g. ⌥-rectangular-selection in a terminal)
/// never snaps anything.
final class SnapManager {
    private let store: ConfigStore
    private let engine: WorkspaceEngine

    private var monitors: [Any] = []
    private var pending: PendingDrag?
    private var session: SnapSession?
    private var promptedForPermission = false
    private lazy var overlay = GridOverlayWindow()

    /// A modifier-drag we've noticed but not armed yet: `window` is what's
    /// under the cursor; we arm once its position changes (a real window drag).
    private struct PendingDrag {
        let window: AXUIElement
        let initialOrigin: CGPoint // AX coordinates
    }

    private struct SnapSession {
        let window: AXUIElement
        /// The dragged-on display's grid — re-read when the drag crosses onto
        /// another screen, since each display has its own in a workspace.
        var grid: GridSize
        var screen: NSScreen
        var anchor: GridCell
        var region: GridRegion
    }

    init(store: ConfigStore, engine: WorkspaceEngine) {
        self.store = store
        self.engine = engine
    }

    /// Starts/stops the global mouse monitors to match the config.
    func refresh() {
        let wantActive = store.config.snap.enabled && store.config.snap.hasModifiers
        if wantActive, monitors.isEmpty {
            if let drag = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged, handler: { [weak self] in
                self?.mouseDragged($0)
            }) { monitors.append(drag) }
            if let up = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp, handler: { [weak self] in
                self?.mouseUp($0)
            }) { monitors.append(up) }
        } else if !wantActive, !monitors.isEmpty {
            monitors.forEach(NSEvent.removeMonitor)
            monitors.removeAll()
            reset()
        }
    }

    // MARK: - Event handling

    private func mouseDragged(_ event: NSEvent) {
        let required = store.config.snap.modifierFlags
        guard !required.isEmpty,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask).isSuperset(of: required)
        else {
            reset() // released the modifiers mid-drag = cancel
            return
        }

        let location = NSEvent.mouseLocation
        if session != nil {
            updateSession(at: location)
        } else if let pending {
            if let origin = AX.axFrame(of: pending.window)?.origin,
               abs(origin.x - pending.initialOrigin.x) > 1 || abs(origin.y - pending.initialOrigin.y) > 1 {
                engage(pending.window, at: location)
            }
        } else {
            guard ensurePermission(), let window = AX.movableWindow(at: location) else { return }
            pending = PendingDrag(window: window, initialOrigin: AX.axFrame(of: window)?.origin ?? .zero)
        }
    }

    private func mouseUp(_ event: NSEvent) {
        defer { reset() }
        guard let session,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                  .isSuperset(of: store.config.snap.modifierFlags)
        else { return }
        let target = session.grid.frame(for: session.region, in: session.screen.visibleFrame)
        AX.setFrame(session.window, to: target)
    }

    // MARK: - Session lifecycle

    private func engage(_ window: AXUIElement, at location: CGPoint) {
        guard let screen = screenAt(location) else { return }
        let grid = currentGrid(on: screen)
        let anchor = grid.cell(at: location, in: screen.visibleFrame)
        let region = GridRegion.bounding(anchor, anchor)
        pending = nil
        session = SnapSession(window: window, grid: grid, screen: screen, anchor: anchor, region: region)
        overlay.show(GridOverlaySpec(columns: grid.columns, rows: grid.rows, highlight: region), on: screen)
    }

    private func updateSession(at location: CGPoint) {
        guard var session else { return }
        if let screen = screenAt(location), screen.frame != session.screen.frame {
            // Crossed onto another display: that display has its own grid in
            // this workspace, so pick it up before re-anchoring.
            session.screen = screen
            session.grid = currentGrid(on: screen)
            session.anchor = session.grid.cell(at: location, in: screen.visibleFrame)
        }
        let current = session.grid.cell(at: location, in: session.screen.visibleFrame)
        session.region = .bounding(session.anchor, current)
        self.session = session
        overlay.show(
            GridOverlaySpec(columns: session.grid.columns, rows: session.grid.rows, highlight: session.region),
            on: session.screen
        )
    }

    private func reset() {
        pending = nil
        if session != nil {
            session = nil
            overlay.hide()
        }
    }

    // MARK: - Helpers

    /// The active workspace's grid *for this display*, else the configured
    /// fallback dims — which also covers a display the workspace has never had
    /// anything laid out on. Only called when a drag engages or crosses
    /// screens, not per mouse event: the key lookup walks the attached screens.
    private func currentGrid(on screen: NSScreen) -> GridSize {
        if let workspace = engine.activeWorkspace,
           let grid = workspace.grid(for: DisplayIdentity.storedKey(for: screen)) ?? workspace.grids.first(where: \.isUnbound) {
            return grid.size
        }
        return GridSize(columns: store.config.snap.defaultColumns, rows: store.config.snap.defaultRows)
    }

    private func screenAt(_ point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { NSPointInRect(point, $0.frame) }
    }

    private func ensurePermission() -> Bool {
        if AccessibilityPermission.isGranted { return true }
        if !promptedForPermission {
            promptedForPermission = true
            AccessibilityPermission.request()
        }
        return false
    }
}

extension SnapSettings {
    var modifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if control { flags.insert(.control) }
        if option { flags.insert(.option) }
        if shift { flags.insert(.shift) }
        if command { flags.insert(.command) }
        return flags
    }
}

// MARK: - Overlay

struct GridOverlaySpec: Equatable {
    var columns: Int
    var rows: Int
    var highlight: GridRegion?
}

/// Borderless, click-through window that draws the grid over the screen
/// being dragged on.
final class GridOverlayWindow {
    private var window: NSWindow?
    private var hosting: NSHostingView<GridOverlayView>?
    private var lastSpec: GridOverlaySpec?

    func show(_ spec: GridOverlaySpec, on screen: NSScreen) {
        let window = ensureWindow()
        if window.frame != screen.visibleFrame {
            window.setFrame(screen.visibleFrame, display: true)
        }
        if lastSpec != spec {
            hosting?.rootView = GridOverlayView(spec: spec)
            lastSpec = spec
        }
        if !window.isVisible {
            window.orderFrontRegardless()
        }
    }

    func hide() {
        window?.orderOut(nil)
        lastSpec = nil
    }

    private func ensureWindow() -> NSWindow {
        if let window { return window }
        let hosting = NSHostingView(rootView: GridOverlayView(spec: GridOverlaySpec(columns: 2, rows: 2, highlight: nil)))
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .screenSaver
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.contentView = hosting
        self.hosting = hosting
        self.window = window
        return window
    }
}

struct GridOverlayView: View {
    var spec: GridOverlaySpec

    var body: some View {
        GeometryReader { geo in
            let cellWidth = geo.size.width / CGFloat(spec.columns)
            let cellHeight = geo.size.height / CGFloat(spec.rows)

            ZStack(alignment: .topLeading) {
                ForEach(0..<(spec.columns * spec.rows), id: \.self) { index in
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.white.opacity(0.5), lineWidth: 1.5)
                        .shadow(color: .black.opacity(0.5), radius: 1)
                        .frame(width: max(cellWidth - 10, 1), height: max(cellHeight - 10, 1))
                        .offset(
                            x: CGFloat(index % spec.columns) * cellWidth + 5,
                            y: CGFloat(index / spec.columns) * cellHeight + 5
                        )
                }

                if let highlight = spec.highlight {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.accentColor.opacity(0.3))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, lineWidth: 2.5))
                        .frame(
                            width: max(CGFloat(highlight.colSpan) * cellWidth - 10, 1),
                            height: max(CGFloat(highlight.rowSpan) * cellHeight - 10, 1)
                        )
                        .offset(
                            x: CGFloat(highlight.col) * cellWidth + 5,
                            y: CGFloat(highlight.row) * cellHeight + 5
                        )
                }
            }
            // Fill the window — offsets don't count toward the ZStack's own
            // layout size, so without this the dim backdrop would only cover
            // the first cell.
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .background(Color.black.opacity(0.12))
        }
    }
}
