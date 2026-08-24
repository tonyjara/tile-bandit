import AppKit
import ApplicationServices

/// The one part of Tile Bandit that needs the Accessibility permission:
/// moving/resizing windows for the grid layout. Everything else (switching,
/// hotkeys, the snap manager's mouse monitors) stays permission-free.
///
/// TCC ties the grant to the code signature — see CLAUDE.md for the ad-hoc
/// signing / `swift run` implications.
enum AccessibilityPermission {
    static var isGranted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt the first time; silently returns false after
    /// a denial (macOS only prompts once per signature).
    @discardableResult
    static func request() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// For the Settings buttons: prompt if possible, and open the
    /// Accessibility pane so the user can flip the toggle either way.
    static func requestAndOpenSettings() {
        request()
        if !isGranted,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Thin AXUIElement helpers. All public rects are AppKit (bottom-left origin)
/// coordinates; conversion to the AX coordinate space (top-left origin of the
/// primary display, y grows downward) happens at the boundary.
enum AX {
    // MARK: - Window queries

    /// Visible standard windows of a process (skips minimized windows,
    /// panels, sheets).
    static func standardWindows(pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        guard let list = copyValue(app, kAXWindowsAttribute) as? [AXUIElement] else { return [] }
        return list.filter { window in
            if bool(window, kAXMinimizedAttribute) == true { return false }
            let subrole = string(window, kAXSubroleAttribute)
            return subrole == nil || subrole == kAXStandardWindowSubrole
        }
    }

    /// Window frame in AppKit coordinates.
    static func frame(of window: AXUIElement) -> CGRect? {
        guard let axFrame = axFrame(of: window) else { return nil }
        return cocoaRect(fromAX: axFrame)
    }

    /// Window frame in raw AX coordinates (used for cheap "did it move" checks).
    static func axFrame(of window: AXUIElement) -> CGRect? {
        guard let origin = point(window, kAXPositionAttribute),
              let size = size(window, kAXSizeAttribute) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    static func setFrame(_ window: AXUIElement, to cocoaRect: CGRect) {
        let target = axRect(fromCocoa: cocoaRect)
        set(window, kAXPositionAttribute, point: target.origin)
        set(window, kAXSizeAttribute, size: target.size)
        // Apps that clamp the resize (terminals snapping to cell multiples)
        // can drift; setting position again keeps them anchored in the region.
        set(window, kAXPositionAttribute, point: target.origin)
    }

    /// The screen a window mostly sits on.
    static func screenOf(_ window: AXUIElement) -> NSScreen? {
        guard let cocoa = frame(of: window) else { return nil }
        return NSScreen.screens.max { area($0.frame.intersection(cocoa)) < area($1.frame.intersection(cocoa)) }
    }

    /// The movable window under a point (AppKit coordinates). Used by
    /// drag-snap: walks from the element under the cursor up to its window
    /// and rejects surfaces that can't or shouldn't be moved (the desktop,
    /// sheets, popovers).
    static func movableWindow(at cocoaPoint: CGPoint) -> AXUIElement? {
        let axPoint = CGPoint(x: cocoaPoint.x, y: primaryScreenHeight - cocoaPoint.y)
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(axPoint.x), Float(axPoint.y), &element) == .success,
              let element,
              let window = containingWindow(of: element)
        else { return nil }

        var settable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(window, kAXPositionAttribute as CFString, &settable)
        guard settable.boolValue else { return nil }

        let subrole = string(window, kAXSubroleAttribute)
        guard subrole == nil || subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole else {
            return nil
        }
        return window
    }

    // MARK: - Coordinate spaces

    private static var primaryScreenHeight: CGFloat {
        // screens[0] is the primary display; its frame origin is (0, 0).
        NSScreen.screens.first?.frame.maxY ?? 0
    }

    /// The same flip works in both directions (it's an involution).
    static func axRect(fromCocoa rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    static func cocoaRect(fromAX rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    // MARK: - Attribute plumbing

    private static let systemWide = AXUIElementCreateSystemWide()

    private static func containingWindow(of element: AXUIElement) -> AXUIElement? {
        if string(element, kAXRoleAttribute) == kAXWindowRole { return element }
        if let ref = copyValue(element, kAXWindowAttribute), CFGetTypeID(ref) == AXUIElementGetTypeID() {
            return (ref as! AXUIElement)
        }
        var current = element
        for _ in 0..<25 {
            guard let ref = copyValue(current, kAXParentAttribute), CFGetTypeID(ref) == AXUIElementGetTypeID() else {
                return nil
            }
            let parent = ref as! AXUIElement
            if string(parent, kAXRoleAttribute) == kAXWindowRole { return parent }
            current = parent
        }
        return nil
    }

    private static func copyValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        copyValue(element, attribute) as? String
    }

    private static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        copyValue(element, attribute) as? Bool
    }

    private static func point(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        guard let ref = copyValue(element, attribute), CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        var out = CGPoint.zero
        guard AXValueGetValue(ref as! AXValue, .cgPoint, &out) else { return nil }
        return out
    }

    private static func size(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        guard let ref = copyValue(element, attribute), CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        var out = CGSize.zero
        guard AXValueGetValue(ref as! AXValue, .cgSize, &out) else { return nil }
        return out
    }

    private static func set(_ element: AXUIElement, _ attribute: String, point: CGPoint) {
        var value = point
        guard let axValue = AXValueCreate(.cgPoint, &value) else { return }
        AXUIElementSetAttributeValue(element, attribute as CFString, axValue)
    }

    private static func set(_ element: AXUIElement, _ attribute: String, size: CGSize) {
        var value = size
        guard let axValue = AXValueCreate(.cgSize, &value) else { return }
        AXUIElementSetAttributeValue(element, attribute as CFString, axValue)
    }

    private static func area(_ rect: CGRect) -> CGFloat {
        rect.isNull ? 0 : rect.width * rect.height
    }
}

/// Applies a workspace's grid layout: every app with assigned cells gets its
/// standard windows resized to that region on whichever screen each window
/// currently occupies.
///
/// Deliberately an explicit action (hotkey / menu item) — workspace
/// *switching* still never moves a window.
enum LayoutEngine {
    @discardableResult
    static func apply(_ workspace: Workspace) -> Bool {
        guard AccessibilityPermission.isGranted else {
            AccessibilityPermission.request()
            return false
        }

        let grid = workspace.grid
        var movedAnything = false
        for ref in workspace.apps {
            guard let region = workspace.layout[ref.bundleId] else { continue }
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: ref.bundleId) {
                for window in AX.standardWindows(pid: app.processIdentifier) {
                    guard let screen = AX.screenOf(window) ?? NSScreen.main else { continue }
                    AX.setFrame(window, to: grid.frame(for: region, in: screen.visibleFrame))
                    movedAnything = true
                }
            }
        }
        return movedAnything
    }
}
