import AppKit
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = ConfigStore()
    private lazy var engine = WorkspaceEngine(store: store)
    private lazy var snap = SnapManager(store: store, engine: engine)
    private lazy var displays = DisplayProfileManager(store: store)
    private lazy var keyboards = KeyboardManager(store: store)
    private let keyMods = KeyModEngine()
    private let hotkeys = HotkeyManager()
    private let keyDebugger = KeyDebugger()
    private let shortcutRecorder = ShortcutRecorder()
    private let maximizeHold = MaximizeHold()

    private var statusItem: NSStatusItem!
    /// Who was in front when the status menu opened — see `menuMaximizeWindow`.
    private var frontmostWhenMenuOpened: NSRunningApplication?
    private var settingsWindow: NSWindow?
    private var settingsCloseObserver: NSObjectProtocol?
    private var settingsResignObserver: NSObjectProtocol?
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
                    self.maximizeHold.end()
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

        // A keyboard coming or going doesn't touch workspaces or hotkeys, so
        // it reapplies the key modifications on its own rather than going
        // through applyConfig().
        keyboards.onKeyboardsChange = { [weak self] attached in
            guard let self else { return }
            self.keyMods.apply(config: self.store.config, attached: attached)
        }

        // Resolves the attached displays to a profile (creating one on first
        // run) before hotkeys are registered, so they land on the right
        // workspaces. Also fires applyConfig() via the handler above.
        displays.start()
        keyboards.start()
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
        keyMods.apply(config: store.config, attached: keyboards.attached)
        LoginItem.reconcile(enabled: store.config.launchAtLogin)
    }

    /// Opening Tile Bandit while it's already running opens Settings.
    ///
    /// This is the escape hatch for `hideMenuBarIcon`: with no status item and
    /// possibly no shortcut assigned either, double-clicking the app in
    /// /Applications (or hitting it in Spotlight) has to lead somewhere.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        openSettings()
        return true
    }

    /// Key modifications are the one thing this app leaves *on the machine*
    /// rather than in its own process — a hidutil mapping outlives us, and a
    /// carrier key with nothing left to interpret it would be a dead key. So
    /// quitting hands every keyboard back unmodified.
    func applicationWillTerminate(_ notification: Notification) {
        keyMods.shutDown()
    }

    private func registerHotkeys() {
        hotkeys.unregisterAll()
        // If a hold was live, its release event died with the registration —
        // restore now rather than leaving the window stuck maximized.
        maximizeHold.end()
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
        if let shortcut = store.config.maximizeHoldShortcut {
            hotkeys.register(shortcut, pressed: { [weak self] in
                guard let self else { return }
                self.keyDebugger.recordHotkeyFired(shortcut, action: "Maximize focused window (while held)")
                self.maximizeHold.begin()
            }, released: { [weak self] in
                self?.maximizeHold.end()
            })
        }
        if let shortcut = store.config.maximizeShortcut {
            hotkeys.register(shortcut) { [weak self] in
                guard let self else { return }
                self.keyDebugger.recordHotkeyFired(shortcut, action: "Maximize focused window")
                self.maximizeHold.stick()
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
        if let shortcut = store.config.openSettingsShortcut {
            hotkeys.register(shortcut) { [weak self] in
                guard let self else { return }
                self.keyDebugger.recordHotkeyFired(shortcut, action: "Open settings")
                self.openSettings()
            }
        }
        if let shortcut = store.config.reloadConfigShortcut {
            hotkeys.register(shortcut) { [weak self] in
                guard let self else { return }
                self.keyDebugger.recordHotkeyFired(shortcut, action: "Reload config")
                self.reloadConfig()
            }
        }
    }

    private func rebuildMenu() {
        // Hiding the icon leaves the hotkeys — and `applicationShouldHandleReopen`
        // — as the ways back in, which is why both exist.
        statusItem.isVisible = !store.config.hideMenuBarIcon
        // Set here rather than once at launch so a menuBarIcon/showWorkspaceName
        // change applies live.
        statusItem.button?.image = store.config.menuBarIcon.resolvedImage(size: 16)
        // Hiding the name leaves the icon alone in the menu bar; without it
        // there'd be nothing left to click.
        let active = store.workspaces.first { $0.id == engine.activeWorkspaceID }
        let name = store.config.showWorkspaceName ? active?.name : nil
        statusItem.button?.title = name.map { " \($0)" } ?? ""

        let menu = StatusMenu(
            store: store,
            activeWorkspaceID: engine.activeWorkspaceID,
            target: self
        ).build()
        menu.delegate = self
        statusItem.menu = menu
    }

    private func applyActiveLayout() {
        guard let workspace = engine.activeWorkspace else { return }
        LayoutEngine.apply(workspace)
    }

    private func reloadConfig() {
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
                    displays: displays,
                    keyboards: keyboards
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
            // Resigning key covers closing, minimising and switching to
            // another app alike: the debugger listens only while it's in front.
            settingsResignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.keyDebugger.stop()
            }
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        activate()
    }

    private func activate() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

// MARK: - Menu actions

/// The other half of `StatusMenu`: it decides what the menu looks like, this
/// answers what its rows do.
extension AppDelegate: StatusMenuActions {
    @objc func menuSwitchWorkspace(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        engine.switchTo(id)
    }

    @objc func menuActivateProfile(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        displays.activate(id)
    }

    @objc func menuRedetectDisplays() {
        displays.resolve()
    }

    @objc func menuNextWorkspace() {
        engine.switchToNext()
    }

    @objc func menuPreviousWorkspace() {
        engine.switchToPrevious()
    }

    @objc func menuHideUnassigned() {
        engine.hideUnassignedApps()
    }

    @objc func menuApplyLayout() {
        applyActiveLayout()
    }

    /// The sticky maximize (⌥⇧M's twin). Its hold-to-peek sibling has no menu
    /// item on purpose — a menu can't express "while held".
    @objc func menuMaximizeWindow() {
        maximizeHold.stick(on: frontmostWhenMenuOpened)
    }

    /// The master switch, reachable without the keyboard — which is the whole
    /// point, since the thing it switches off is the keyboard.
    @objc func menuToggleKeyModifications() {
        store.config.keyModifications.toggle()
    }

    @objc func menuOpenSettings() {
        openSettings()
    }

    @objc func menuReloadConfig() {
        reloadConfig()
    }

    /// Asks GitHub what the latest release is and says so. On a cask install
    /// it can also run the upgrade and relaunch (UpdateInstaller); otherwise
    /// it hands over the command, since a `brew upgrade` of a copy Homebrew
    /// didn't install would fail or install a second one.
    @objc func menuCheckForUpdates() {
        activate()
        Task { @MainActor in
            present(await UpdateChecker.check())
        }
    }

    @MainActor
    private func present(_ outcome: UpdateChecker.Outcome) {
        enum Choice { case install, notes, copy, dismiss }
        let alert = NSAlert()
        alert.icon = AppIconArt.image(size: 128)
        var choices: [Choice] = []

        switch outcome {
        case let .upToDate(current):
            alert.messageText = "Tile Bandit \(current) is the latest release."
            alert.informativeText = "Nothing to do."
            alert.addButton(withTitle: "OK")
            choices = [.dismiss]

        case let .available(latest, current):
            alert.messageText = "Tile Bandit \(latest) is available."
            // A source build was never installed by Homebrew, so naming the
            // cask command there would be advice about a checkout we can't see.
            if UpdateInstaller.isAvailable {
                alert.informativeText = "You're on \(current). Homebrew will install it, "
                    + "and Tile Bandit will relaunch when it's done."
                alert.addButton(withTitle: "Install and Relaunch")
                choices = [.install]
            } else if UpdateChecker.isBundledApp {
                alert.informativeText = "You're on \(current). Install it with:\n\n\(UpdateChecker.upgradeCommand)"
            } else {
                alert.informativeText = "This build reports \(current) and was run from source, so it updates with a "
                    + "pull and a rebuild rather than through Homebrew."
            }
            alert.addButton(withTitle: "Release Notes")
            choices.append(.notes)
            if UpdateChecker.isBundledApp, !UpdateInstaller.isAvailable {
                alert.addButton(withTitle: "Copy Command")
                choices.append(.copy)
            }
            alert.addButton(withTitle: "Later")
            choices.append(.dismiss)

        case let .failed(reason):
            alert.alertStyle = .warning
            alert.messageText = "Couldn't check for updates."
            // Named rather than swallowed: "no news" and "never asked" look the
            // same from here, and only one of them means you're up to date.
            alert.informativeText = reason
            alert.addButton(withTitle: "OK")
            choices = [.dismiss]
        }

        let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        switch choices.indices.contains(index) ? choices[index] : .dismiss {
        case .install:
            if case let .available(latest, _) = outcome { installUpdate(latest) }
        case .notes:
            NSWorkspace.shared.open(UpdateChecker.releasesPage)
        case .copy:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(UpdateChecker.upgradeCommand, forType: .string)
        case .dismiss:
            break
        }
    }

    @MainActor
    private func installUpdate(_ latest: String) {
        let running = UpdateInstaller.RunningProcess()
        let panel = UpdateProgressPanel(version: latest) { running.cancel() }
        panel.show()
        Task { @MainActor in
            do {
                try await UpdateInstaller.install(expecting: latest, running: running)
                panel.close()
                UpdateInstaller.relaunch()
            } catch UpdateInstaller.Failure.cancelled {
                panel.close()
            } catch {
                panel.close()
                showUpdateFailure(error)
            }
        }
    }

    @MainActor
    private func showUpdateFailure(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "The update didn't install."
        switch error {
        case let UpdateInstaller.Failure.brew(step, status, output):
            // The tail is where brew puts the reason; the rest is progress chatter.
            let tail = output.split(separator: "\n").suffix(8).joined(separator: "\n")
            alert.informativeText = "\(step) exited \(status).\n\n\(tail)"
        case let UpdateInstaller.Failure.unchanged(installed):
            alert.informativeText = "Homebrew finished, but the installed copy is still \(installed). "
                + "The tap may not have the release yet — try again in a few minutes."
        default:
            alert.informativeText = error.localizedDescription
        }
        alert.informativeText += "\n\nYou can also run it yourself:\n\(UpdateChecker.upgradeCommand)"
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Copy Command")
        if alert.runModal() == .alertSecondButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(UpdateChecker.upgradeCommand, forType: .string)
        }
    }

    /// The standard About panel, filled in by hand: a `swift run` build has no
    /// bundle to read a name, version or icon out of, and the dev loop is
    /// exactly where "which build am I looking at?" gets asked.
    @objc func menuAbout() {
        activate()
        let credits = NSMutableAttributedString(
            string: "Wanted for tile rustlin'.\n",
            attributes: [
                .font: StatusMenu.westernFont(size: 12),
                .foregroundColor: NSColor.labelColor,
            ]
        )
        credits.append(NSAttributedString(
            string: "A keyboard-driven workspace switcher\nthat lives in the menu bar.",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        ))
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Tile Bandit",
            .applicationVersion: Banner.version,
            .applicationIcon: AppIconArt.image(size: 256),
            .credits: credits,
        ])
    }
}

extension AppDelegate: NSMenuDelegate {
    /// Window actions in the menu act on whatever the user was just in. By the
    /// time a menu item fires, the menu has closed and focus has moved, so the
    /// answer is taken here, while it's still true.
    func menuWillOpen(_ menu: NSMenu) {
        // Compared by pid rather than bundle id: a `swift run` build has no
        // bundle identifier at all, so that test would match everything.
        let front = NSWorkspace.shared.frontmostApplication
        frontmostWhenMenuOpened = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
    }
}

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(menuApplyLayout) {
            return engine.activeWorkspace?.hasLayout ?? false
        }
        if menuItem.action == #selector(menuNextWorkspace) || menuItem.action == #selector(menuPreviousWorkspace) {
            return !store.workspaces.isEmpty
        }
        return true
    }
}
