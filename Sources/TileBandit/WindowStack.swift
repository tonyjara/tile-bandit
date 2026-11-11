import AppKit
import CoreGraphics

/// One ordinary window as the window server lists it.
struct WindowRef: Hashable {
    let id: CGWindowID
    let pid: pid_t
    /// Top-left origin, the same space Accessibility uses — which is what lets
    /// a window be matched to its AX element by frame when it has to be.
    let bounds: CGRect
}

/// What is on screen, front to back.
///
/// `CGWindowListCopyWindowInfo` needs no permission for this: owner, layer and
/// bounds are always given, and only window *titles* wait on Screen Recording.
/// It never prompts. This is the ground truth the switch is checked against —
/// `NSRunningApplication.isHidden` is a cache that lags the screen.
enum WindowList {
    /// Ordinary windows on the visible Spaces, front to back. Layer 0 only
    /// (no menus, panels above everything, or the desktop), and nothing
    /// smaller than a toolbar: apps keep one-pixel helper windows around.
    static func onScreen() -> [WindowRef] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { entry in
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                  let number = entry[kCGWindowNumber as String] as? Int,
                  let pid = entry[kCGWindowOwnerPID as String] as? Int,
                  let box = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: box),
                  bounds.width >= 50, bounds.height >= 50
            else { return nil }
            return WindowRef(id: CGWindowID(number), pid: pid_t(pid), bounds: bounds)
        }
    }
}

/// How a workspace was when it was left: its windows front to back, and the
/// app that had focus.
///
/// Written in exactly one place — `WorkspaceEngine.switchTo`, about the
/// workspace being *left*, from what is on screen at that moment. That is what
/// makes the memory per workspace: focusing a shared app in one workspace has
/// no way to reach another workspace's snapshot, because nothing writes a
/// snapshot for a workspace that isn't the active one.
struct WorkspaceSnapshot: Equatable {
    struct Entry: Hashable {
        let window: CGWindowID
        let bundleId: String
    }

    /// Front to back. Window ids, so two windows of one app keep their own
    /// places — a shared browser can have one window on top here and another
    /// on top in the next workspace.
    var stack: [Entry] = []
    var focusBundleId: String?

    /// Enough for any real desk; the cap only stops closed windows piling up.
    static let stackLimit = 64

    /// Takes in what is on screen now.
    ///
    /// - `onScreen`: the workspace's own windows (its apps and floating apps),
    ///   front to back.
    /// - `frontmost`: the app in front, if it is one of those.
    ///
    /// Windows remembered from before that aren't on screen now are kept, after
    /// the ones that are: an app still finishing its unhide when the workspace
    /// is left again would otherwise lose its place. Windows that were closed
    /// drop out when the order is used, since they are no longer anywhere.
    mutating func update(onScreen: [Entry], frontmost: String?) {
        let now = Set(onScreen.map(\.window))
        stack = Array((onScreen + stack.filter { !now.contains($0.window) }).prefix(Self.stackLimit))
        if let frontmost {
            focusBundleId = frontmost
        } else if let top = onScreen.first {
            // Something outside the workspace was in front (an app in no
            // workspace, our own settings window): the workspace's own top
            // window is the nearest thing to "where you were".
            focusBundleId = top.bundleId
        }
    }
}

/// The arithmetic of putting a stack back, kept pure so it can be tested
/// without a screen. Generic because it runs on windows when Accessibility is
/// granted and on whole apps when it isn't.
enum StackPlan {
    /// The order to aim for: what was remembered, as far as it is still here,
    /// then everything else in the order it is in now. So a window opened
    /// since (a shared app's new window from another workspace, say) goes
    /// *under* what the workspace remembers, not over it.
    static func desired<T: Hashable>(remembered: [T], actual: [T]) -> [T] {
        let present = Set(actual)
        var seen = Set<T>()
        var order: [T] = []
        for item in remembered where present.contains(item) && seen.insert(item).inserted {
            order.append(item)
        }
        for item in actual where seen.insert(item).inserted {
            order.append(item)
        }
        return order
    }

    /// `order` with the first item matching `lead` moved to the front.
    static func promoting<T>(_ order: [T], first lead: (T) -> Bool) -> [T] {
        guard let index = order.firstIndex(where: lead), index > 0 else { return order }
        var copy = order
        copy.insert(copy.remove(at: index), at: 0)
        return copy
    }

    /// The fewest things to bring forward so `actual` becomes `desired`, in
    /// the order to do it (the last one ends up in front).
    ///
    /// Bringing something forward puts it on top of everything, so whatever is
    /// *not* raised keeps its current relative order at the bottom. The longest
    /// tail of `desired` that already sits in the right relative order can
    /// therefore stay put; the rest is raised from the back forward. Nothing
    /// to do returns an empty list — the common case, since apps hidden
    /// together come back in the order they left.
    static func raisesNeeded<T: Hashable>(desired: [T], actual: [T]) -> [T] {
        var position: [T: Int] = [:]
        for (index, item) in actual.enumerated() where position[item] == nil {
            position[item] = index
        }
        let wanted = desired.filter { position[$0] != nil }
        guard wanted.count > 1 else { return [] }

        var keep = 1
        while keep < wanted.count,
              let above = position[wanted[wanted.count - keep - 1]],
              let below = position[wanted[wanted.count - keep]],
              above < below {
            keep += 1
        }
        return wanted.prefix(wanted.count - keep).reversed()
    }
}
