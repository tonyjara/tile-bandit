import AppKit
import Combine
import SwiftUI

extension MenuBarIcon {
    /// nil when this macOS doesn't ship the symbol. The picker filters on it
    /// and `resolvedImage` falls back, so a symbol that isn't there can never
    /// leave a blank, unclickable status item.
    var image: NSImage? {
        NSImage(systemSymbolName: rawValue, accessibilityDescription: "Tile Bandit — \(label)")
    }

    var resolvedImage: NSImage? { image ?? MenuBarIcon.fallback.image }

    static var available: [MenuBarIcon] { allCases.filter { $0.image != nil } }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = ConfigStore()
    private lazy var engine = WorkspaceEngine(store: store)
    private lazy var snap = SnapManager(store: store, engine: engine)
    private lazy var displays = DisplayProfileManager(store: store)
    private let hotkeys = HotkeyManager()
    private let keyDebugger = KeyDebugger()
    private let shortcutRecorder = ShortcutRecorder()

    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var settingsCloseObserver: NSObjectProtocol?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeading

        engine.onActiveWorkspaceChange = { [weak self] in self?.rebuildMenu() }

        // A display change swaps which profile — which set of workspaces — is
        // live, so hotkeys and the menu have to be rebuilt right away rather
        // than waiting on the debounced config subscription below.
        displays.onActiveProfileChange = { [weak self] id in
            guard let self else { return }
            self.engine.adoptProfile(id)
            self.applyConfig()
        }

        // While recording a shortcut, Carbon hotkeys must be off (they'd
        // consume matching combos before the recorder's monitor sees them)
        // and KeyDebugger must pass keys through.
        keyDebugger.shouldPassThrough = { [weak self] in self?.shortcutRecorder.isRecording ?? false }
        shortcutRecorder.$activeID
            .map { $0 != nil }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] recording in
                guard let self else { return }
                if recording {
                    self.hotkeys.unregisterAll()
                } else {
                    self.registerHotkeys()
                }
            }
            .store(in: &cancellables)

        store.$config
            .removeDuplicates()
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.applyConfig() }
            .store(in: &cancellables)

        // Resolves the attached displays to a profile (creating one on first
        // run) before hotkeys are registered, so they land on the right
        // workspaces. Also fires applyConfig() via the handler above.
        displays.start()
        applyConfig()

        // Start clean: hide apps that aren't assigned to any workspace.
        engine.hideUnassignedApps()

        if store.workspaces.isEmpty {
            openSettings()
        }
    }

    private func applyConfig() {
        registerHotkeys()
        rebuildMenu()
        snap.refresh()
    }

    private func registerHotkeys() {
        hotkeys.unregisterAll()
        for workspace in store.workspaces {
            guard let shortcut = workspace.shortcut else { continue }
            let id = workspace.id
            let name = workspace.name
            hotkeys.register(shortcut) { [weak self] in
                guard let self else { return }
                self.keyDebugger.recordHotkeyFired(shortcut, action: "Switch to \(name)")
                self.engine.switchTo(id)
            }
        }
        if let shortcut = store.config.hideUnassignedShortcut {
            hotkeys.register(shortcut) { [weak self] in
                guard let self else { return }
                self.keyDebugger.recordHotkeyFired(shortcut, action: "Hide unassigned apps")
                self.engine.hideUnassignedApps()
            }
        }
        if let shortcut = store.config.applyLayoutShortcut {
            hotkeys.register(shortcut) { [weak self] in
                guard let self else { return }
                self.keyDebugger.recordHotkeyFired(shortcut, action: "Apply grid layout")
                self.applyActiveLayout()
            }
        }
        if let shortcut = store.config.nextWorkspaceShortcut {
            hotkeys.register(shortcut) { [weak self] in
                guard let self else { return }
                self.keyDebugger.recordHotkeyFired(shortcut, action: "Next workspace")
                self.engine.switchToNext()
            }
        }
        if let shortcut = store.config.previousWorkspaceShortcut {
            hotkeys.register(shortcut) { [weak self] in
                guard let self else { return }
                self.keyDebugger.recordHotkeyFired(shortcut, action: "Previous workspace")
                self.engine.switchToPrevious()
            }
        }
    }

    private func rebuildMenu() {
        let active = store.workspaces.first { $0.id == engine.activeWorkspaceID }
        statusItem.button?.image = store.config.menuBarIcon.resolvedImage
        // Hiding the name leaves the icon alone in the menu bar; without it
        // there'd be nothing left to click.
        let name = store.config.showWorkspaceName ? active?.name : nil
        statusItem.button?.title = name.map { " \($0)" } ?? ""

        let menu = NSMenu()

        addDisplaySection(to: menu)
        menu.addItem(.separator())

        if store.workspaces.isEmpty {
            menu.addItem(NSMenuItem(title: "No workspaces in this profile yet", action: nil, keyEquivalent: ""))
        }

        for workspace in store.workspaces {
            let item = NSMenuItem(title: workspace.name, action: #selector(menuSwitch(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = workspace.id
            if workspace.id == engine.activeWorkspaceID {
                item.state = .on
            }
            if let shortcut = workspace.shortcut {
                applyKeyEquivalent(shortcut, to: item)
            }
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let next = NSMenuItem(title: "Next Workspace", action: #selector(nextWorkspace), keyEquivalent: "")
        next.target = self
        if let shortcut = store.config.nextWorkspaceShortcut {
            applyKeyEquivalent(shortcut, to: next)
        }
        menu.addItem(next)

        let previous = NSMenuItem(title: "Previous Workspace", action: #selector(previousWorkspace), keyEquivalent: "")
        previous.target = self
        if let shortcut = store.config.previousWorkspaceShortcut {
            applyKeyEquivalent(shortcut, to: previous)
        }
        menu.addItem(previous)

        let hide = NSMenuItem(title: "Hide Unassigned Apps", action: #selector(hideUnassigned), keyEquivalent: "")
        hide.target = self
        if let shortcut = store.config.hideUnassignedShortcut {
            applyKeyEquivalent(shortcut, to: hide)
        }
        menu.addItem(hide)

        let applyLayout = NSMenuItem(title: "Apply Grid Layout", action: #selector(applyLayoutAction), keyEquivalent: "")
        applyLayout.target = self
        if let shortcut = store.config.applyLayoutShortcut {
            applyKeyEquivalent(shortcut, to: applyLayout)
        }
        menu.addItem(applyLayout)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettingsAction), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let reload = NSMenuItem(title: "Reload Config", action: #selector(reloadConfig), keyEquivalent: "r")
        reload.target = self
        menu.addItem(reload)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Tile Bandit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    /// Shows which display profile is live, with a submenu to force another
    /// one — handy for setting up a desk you're not sitting at. A manual pick
    /// holds until the next display change, which re-detects and takes it back.
    private func addDisplaySection(to menu: NSMenu) {
        let item = NSMenuItem(
            title: "Display: \(store.activeProfile?.name ?? "Detecting…")",
            action: nil,
            keyEquivalent: ""
        )
        let submenu = NSMenu()
        for profile in store.config.profiles {
            let entry = NSMenuItem(
                title: "\(profile.name)  —  \(profile.displaySummary)",
                action: #selector(menuActivateProfile(_:)),
                keyEquivalent: ""
            )
            entry.target = self
            entry.representedObject = profile.id
            if profile.id == store.activeProfileID { entry.state = .on }
            submenu.addItem(entry)
        }
        submenu.addItem(.separator())
        let redetect = NSMenuItem(title: "Re-detect Displays", action: #selector(redetectDisplays), keyEquivalent: "")
        redetect.target = self
        submenu.addItem(redetect)
        item.submenu = submenu
        menu.addItem(item)
    }

    @objc private func menuActivateProfile(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? UUID {
            displays.activate(id)
        }
    }

    @objc private func redetectDisplays() {
        displays.resolve()
    }

    @objc private func menuSwitch(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? UUID {
            engine.switchTo(id)
        }
    }

    @objc private func hideUnassigned() {
        engine.hideUnassignedApps()
    }

    @objc private func nextWorkspace() {
        engine.switchToNext()
    }

    @objc private func previousWorkspace() {
        engine.switchToPrevious()
    }

    @objc private func applyLayoutAction() {
        applyActiveLayout()
    }

    private func applyActiveLayout() {
        guard let workspace = engine.activeWorkspace else { return }
        LayoutEngine.apply(workspace)
    }

    private func applyKeyEquivalent(_ shortcut: Shortcut, to item: NSMenuItem) {
        item.keyEquivalent = shortcut.key.lowercased()
        var mask: NSEvent.ModifierFlags = []
        if shortcut.control { mask.insert(.control) }
        if shortcut.option { mask.insert(.option) }
        if shortcut.shift { mask.insert(.shift) }
        if shortcut.command { mask.insert(.command) }
        item.keyEquivalentModifierMask = mask
    }

    @objc private func openSettingsAction() {
        openSettings()
    }

    @objc private func reloadConfig() {
        store.reload()
        // The file may have added, removed or renamed profiles, so the live
        // one has to be matched against the hardware again.
        displays.resolve()
    }

    private func openSettings() {
        if settingsWindow == nil {
            let hosting = NSHostingController(
                rootView: SettingsView(
                    store: store,
                    keyDebugger: keyDebugger,
                    recorder: shortcutRecorder,
                    displays: displays
                )
            )
            let window = NSWindow(contentViewController: hosting)
            window.title = "Tile Bandit"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
            // A recording left armed after the window closes would leave all
            // hotkeys unregistered.
            settingsCloseObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.shortcutRecorder.cancel()
            }
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(applyLayoutAction) {
            return engine.activeWorkspace.map { !$0.layout.isEmpty } ?? false
        }
        if menuItem.action == #selector(nextWorkspace) || menuItem.action == #selector(previousWorkspace) {
            return !store.workspaces.isEmpty
        }
        return true
    }
}
