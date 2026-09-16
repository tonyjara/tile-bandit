import AppKit

// MARK: - Icons

extension MenuBarIcon {
    /// nil when this macOS doesn't ship the symbol. The picker filters on it
    /// and `resolvedImage` falls back, so a symbol that isn't there can never
    /// leave a blank, unclickable status item. Drawn glyphs always resolve,
    /// which is why the fallback is one of those.
    func image(size: CGFloat = 16) -> NSImage? {
        if let glyphName {
            return BanditGlyph(rawValue: glyphName)?.image(size: size)
        }
        let symbol = NSImage(systemSymbolName: rawValue, accessibilityDescription: "Tile Bandit — \(label)")
        // Sizing a symbol by its point size rather than its frame is what keeps
        // its stroke weight matched to the menu bar's text.
        return symbol?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size - 1, weight: .regular))
    }

    func resolvedImage(size: CGFloat = 16) -> NSImage? {
        image(size: size) ?? MenuBarIcon.fallback.image(size: size)
    }

    /// The same icon, flattened for a menu row — see `flattened(_:into:)`.
    func menuImage(size: CGFloat = 15) -> NSImage? {
        resolvedImage(size: size).map { flattened($0, into: NSSize(width: size + 3, height: size)) }
    }

    static var available: [MenuBarIcon] { allCases.filter { $0.image() != nil } }
}

/// Redraws an image into a plain one of a fixed size, aspect-fitted.
///
/// Not cosmetic: AppKit won't draw a *vector-backed* image in a menu item —
/// an SF Symbol or a PDF-backed template comes out blank, while anything with
/// a bitmap behind it draws normally. Painting it into a drawing-handler image
/// is what makes a symbol show up at all. The handler re-runs per backing
/// scale, so this costs no sharpness on Retina, and copying `isTemplate`
/// across keeps macOS tinting the result for dark menus and highlighted rows.
///
/// The fixed box is worth having on its own: symbols come in assorted widths,
/// and a menu whose icons are all the same width is a menu whose titles line up.
func flattened(_ image: NSImage, into box: NSSize) -> NSImage {
    let out = NSImage(size: box, flipped: false) { _ in
        let source = image.size
        guard source.width > 0, source.height > 0 else { return true }
        let scale = min(box.width / source.width, box.height / source.height, 1)
        let width = source.width * scale
        let height = source.height * scale
        image.draw(in: NSRect(
            x: (box.width - width) / 2,
            y: (box.height - height) / 2,
            width: width,
            height: height
        ))
        return true
    }
    out.isTemplate = image.isTemplate
    return out
}

/// The first of `names` this macOS actually ships, flattened to menu-row size.
///
/// A menu whose rows don't all have an image looks ragged — AppKit indents the
/// ones that do — so a name that resolves nowhere still gets a blank of the
/// right size rather than nil.
private func menuSymbol(_ names: String...) -> NSImage {
    let box = NSSize(width: 18, height: 15)
    for name in names {
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular))
        else { continue }
        return flattened(symbol, into: box)
    }
    return NSImage(size: box, flipped: false) { _ in true }
}

// MARK: - Menu

/// Everything the status item's menu can ask for.
///
/// A protocol rather than loose selectors so that a renamed action is a
/// compile error instead of a menu item that quietly does nothing.
@objc protocol StatusMenuActions: AnyObject {
    func menuSwitchWorkspace(_ sender: NSMenuItem)
    func menuActivateProfile(_ sender: NSMenuItem)
    func menuRedetectDisplays()
    func menuNextWorkspace()
    func menuPreviousWorkspace()
    func menuHideUnassigned()
    func menuApplyLayout()
    func menuMaximizeWindow()
    func menuToggleKeyModifications()
    func menuOpenSettings()
    func menuReloadConfig()
    func menuAbout()
}

/// Builds the status item's menu.
///
/// Separate from AppDelegate because this is the one part of the app that is
/// purely a *view*: the delegate owns the engines and answers the actions,
/// while everything about what the menu looks like — the order, the sections,
/// the glyphs — is decided here.
///
/// The shape is four groups, in the order you need them: who you are (the
/// brand row and the live display setup), where you're going (workspaces),
/// what you can do to the windows in front of you, and the housekeeping.
struct StatusMenu {
    let store: ConfigStore
    let activeWorkspaceID: UUID?
    unowned let target: StatusMenuActions

    func build() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(brandItem())
        menu.addItem(displayItem())
        menu.addItem(.separator())

        menu.addItem(Self.sectionHeader("Workspaces"))
        addWorkspaces(to: menu)
        menu.addItem(.separator())

        menu.addItem(Self.sectionHeader("Windows"))
        addWindowActions(to: menu)
        menu.addItem(.separator())

        menu.addItem(Self.sectionHeader("Setup"))
        addSetup(to: menu)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Tile Bandit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.image = menuSymbol("power")
        menu.addItem(quit)
        return menu
    }

    // MARK: Header

    /// Two lines: the name in the closest thing macOS ships to a saloon sign,
    /// and what the app is wanted for. Clicking it opens the About panel,
    /// which is also the only place the version number is written down.
    private func brandItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Tile Bandit", action: #selector(StatusMenuActions.menuAbout), keyEquivalent: "")
        item.target = target
        item.image = store.config.menuBarIcon.menuImage(size: 15)
        item.attributedTitle = Self.brandTitle()
        return item
    }

    static func brandTitle() -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 1

        let title = NSMutableAttributedString(
            string: "Tile Bandit\n",
            attributes: [
                .font: westernFont(size: 13),
                .foregroundColor: NSColor.labelColor,
                .kern: 0.6,
                .paragraphStyle: paragraph,
            ]
        )
        title.append(NSAttributedString(
            string: "wanted · for tile rustlin'",
            attributes: [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph,
            ]
        ))
        return title
    }

    /// Copperplate is engraved small caps and ships with macOS, which makes it
    /// the one western-adjacent face we can count on. Supplemental fonts *can*
    /// be removed, so every caller falls back to the system font.
    static func westernFont(size: CGFloat) -> NSFont {
        NSFont(name: "Copperplate", size: size) ?? .systemFont(ofSize: size, weight: .semibold)
    }

    /// The live display setup, with a submenu to force another — handy for a
    /// desk you aren't sitting at. A manual pick holds until the next display
    /// change, which re-detects and takes it back.
    private func displayItem() -> NSMenuItem {
        let profile = store.activeProfile
        let item = NSMenuItem(title: profile?.name ?? "Detecting displays…", action: nil, keyEquivalent: "")
        item.image = menuSymbol((profile?.displays.count ?? 0) > 1 ? "display.2" : "display")
        item.toolTip = profile?.displaySummary

        let submenu = NSMenu()
        for candidate in store.config.profiles {
            let entry = NSMenuItem(
                title: "\(candidate.name)  —  \(candidate.displaySummary)",
                action: #selector(StatusMenuActions.menuActivateProfile(_:)),
                keyEquivalent: ""
            )
            entry.target = target
            entry.representedObject = candidate.id
            if candidate.id == store.activeProfileID { entry.state = .on }
            submenu.addItem(entry)
        }
        submenu.addItem(.separator())
        let redetect = NSMenuItem(
            title: "Re-detect Displays",
            action: #selector(StatusMenuActions.menuRedetectDisplays),
            keyEquivalent: ""
        )
        redetect.target = target
        redetect.image = menuSymbol("arrow.triangle.2.circlepath")
        submenu.addItem(redetect)

        item.submenu = submenu
        return item
    }

    // MARK: Sections

    private func addWorkspaces(to menu: NSMenu) {
        if store.workspaces.isEmpty {
            let empty = NSMenuItem(title: "None in this display profile yet", action: nil, keyEquivalent: "")
            empty.image = menuSymbol("square.dashed")
            menu.addItem(empty)
        }

        for workspace in store.workspaces {
            let item = NSMenuItem(
                title: workspace.name,
                action: #selector(StatusMenuActions.menuSwitchWorkspace(_:)),
                keyEquivalent: ""
            )
            item.target = target
            item.representedObject = workspace.id
            // Solid grid = something is laid out here, so Apply Grid Layout has
            // work to do; dashed = apps only.
            item.image = menuSymbol(workspace.hasLayout ? "square.grid.2x2" : "square.dashed")
            if workspace.id == activeWorkspaceID { item.state = .on }
            if let shortcut = workspace.shortcut { Self.applyKeyEquivalent(shortcut, to: item) }
            menu.addItem(item)
        }

        add(
            "Next Workspace",
            #selector(StatusMenuActions.menuNextWorkspace),
            symbol: "arrow.right",
            shortcut: store.config.nextWorkspaceShortcut,
            to: menu
        )
        add(
            "Previous Workspace",
            #selector(StatusMenuActions.menuPreviousWorkspace),
            symbol: "arrow.left",
            shortcut: store.config.previousWorkspaceShortcut,
            to: menu
        )
    }

    private func addWindowActions(to menu: NSMenu) {
        add(
            "Apply Grid Layout",
            #selector(StatusMenuActions.menuApplyLayout),
            symbol: "square.grid.3x3.square",
            shortcut: store.config.applyLayoutShortcut,
            to: menu
        )
        add(
            "Maximize Window",
            #selector(StatusMenuActions.menuMaximizeWindow),
            symbol: "arrow.up.left.and.arrow.down.right",
            shortcut: store.config.maximizeShortcut,
            to: menu
        )
        add(
            "Hide Unassigned Apps",
            #selector(StatusMenuActions.menuHideUnassigned),
            symbol: "eye.slash",
            shortcut: store.config.hideUnassignedShortcut,
            to: menu
        )
    }

    private func addSetup(to menu: NSMenu) {
        // The master switch belongs in the menu bar rather than only in
        // Settings: when a remap misfires, the keyboard is exactly the thing
        // you can't use to go fix it.
        let keyMods = add(
            "Key Modifications",
            #selector(StatusMenuActions.menuToggleKeyModifications),
            symbol: "keyboard",
            shortcut: nil,
            to: menu
        )
        keyMods.state = store.config.keyModifications ? .on : .off

        add(
            "Settings…",
            #selector(StatusMenuActions.menuOpenSettings),
            symbol: "gearshape",
            shortcut: store.config.openSettingsShortcut,
            to: menu
        )
        add(
            "Reload Config",
            #selector(StatusMenuActions.menuReloadConfig),
            symbol: "arrow.clockwise",
            shortcut: store.config.reloadConfigShortcut,
            to: menu
        )
    }

    // MARK: Pieces

    @discardableResult
    private func add(
        _ title: String,
        _ action: Selector,
        symbol: String,
        shortcut: Shortcut?,
        to menu: NSMenu
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target
        item.image = menuSymbol(symbol)
        if let shortcut { Self.applyKeyEquivalent(shortcut, to: item) }
        menu.addItem(item)
        return item
    }

    /// macOS 14 has real section headers; older systems get the same idea by
    /// hand — small, spaced-out capitals that read as a label and not as
    /// something you can click.
    static func sectionHeader(_ title: String) -> NSMenuItem {
        if #available(macOS 14.0, *) {
            return .sectionHeader(title: title)
        }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(
            string: title.uppercased(),
            attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
                .kern: 0.9,
            ]
        )
        item.isEnabled = false
        return item
    }

    /// Menu items take their key equivalents from the config rather than
    /// hard-coding them, so a reassignment shows up here too.
    static func applyKeyEquivalent(_ shortcut: Shortcut, to item: NSMenuItem) {
        item.keyEquivalent = shortcut.key.lowercased()
        var mask: NSEvent.ModifierFlags = []
        if shortcut.control { mask.insert(.control) }
        if shortcut.option { mask.insert(.option) }
        if shortcut.shift { mask.insert(.shift) }
        if shortcut.command { mask.insert(.command) }
        item.keyEquivalentModifierMask = mask
    }
}
