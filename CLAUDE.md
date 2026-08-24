# Tile Bandit

macOS menu-bar workspace switcher (FlashSpace-style). Pure SwiftPM — no
`.xcodeproj`, and it should stay that way (the owner works in neovim with
sourcekit-lsp, which understands SPM natively).

## Commands

- `swift build` / `swift run` — dev
- `make app` — release bundle at `dist/Tile Bandit.app` (ad-hoc signed)

## Architecture (Sources/TileBandit/)

- `main.swift` — NSApplication bootstrap; activation policy `.accessory`.
  Calls `Banner.show()` first.
- `Banner.swift` — the ASCII mascot + config path / Accessibility status
  printed to stdout at launch. Only visible on a terminal launch (`swift run`);
  a Finder-launched `.app` has nowhere to print. The art uses raw string
  literals (`#"""…"""#`) because the mascot itself contains `"""`, and ANSI
  styling is applied only when stdout `isatty`.
- `AppDelegate.swift` — status item + menu; subscribes to config changes and
  re-registers hotkeys / rebuilds the menu (debounced via Combine). Also owns
  `DisplayProfileManager`: a profile change re-registers hotkeys and rebuilds
  the menu immediately rather than waiting on the debounce, since the whole set
  of workspace shortcuts has just changed. The menu's top item shows the live
  profile, with a submenu to force another (useful for a desk you aren't at —
  the next display change re-detects and takes it back) plus Re-detect
  Displays; Reload Config re-resolves too, since the file may have renamed or
  removed profiles. The status item's image and title are set in
  `rebuildMenu()` (not once at launch) so `menuBarIcon`/`showWorkspaceName`
  changes apply live. The `MenuBarIcon` → `NSImage` extension lives here rather
  than in Models so the model layer stays AppKit-free; `resolvedImage` falls
  back to the default and `available` filters the picker, so a symbol this
  macOS lacks can never leave a blank, unclickable status item.
- `Models.swift` — `Config`/`DisplayProfile`/`DisplayRef`/`Workspace`/`AppRef`/
  `Shortcut` plus the grid types (`GridRegion`/`GridCell`/`GridSize`/
  `SnapSettings`) and `MenuBarIcon` (raw values *are* SF Symbol names; an
  unknown one decodes to `.fallback` rather than throwing), Codable with
  lenient decoding (config is hand-editable).
  `GridSize` also owns the cell↔rect math shared by LayoutEngine, SnapManager,
  and the settings editor (rects are AppKit coords; row 0 is the top row).
  **Workspaces live inside a `DisplayProfile`**, not at the top level;
  `Config.currentVersion` is 2 and decoding a v1 file (flat `workspaces`)
  migrates it into a single *unbound* profile, which the first detection run
  adopts onto whatever displays are attached. Decoding is the migration, so
  `version` is normalised to current in memory and the old top-level
  `workspaces` key is dropped on the next write.
- `DisplayProfiles.swift` — display-setup detection. `DisplayIdentity` builds a
  stable per-screen key (built-in → `builtin`; externals → EDID
  `vendor-model-serial`, since serial is 0 on plenty of monitors; otherwise the
  localized name) and infers profile names ("MacBook", "MacBook + M14",
  "Studio Display"). `snapshot()` sorts by key so rearranging displays isn't a
  new setup, and suffixes repeated keys so *how many* identical panels are
  attached stays part of the fingerprint. `DisplayProfileManager` watches
  `didChangeScreenParametersNotification` (debounced 1.2s — one plug fires it
  several times; an empty snapshot means asleep, never "a setup with no
  displays") and resolves the attached set to a profile: match by fingerprint,
  else adopt a *lone* unbound profile (the migration carrier — deliberately
  only when it's the only one, so a duplicate is never silently claimed), else
  create one cloning the profile you were just on (fresh workspace ids).
  All permission-free.
- `ConfigStore.swift` — ObservableObject; JSON at
  `~/.config/tilebandit/config.json`; debounced autosave. Also holds the
  non-persisted `activeProfileID` (derived from the hardware) and the
  `workspaces` lens onto the live profile — everything outside Settings reads
  `store.workspaces`, never `config.profiles`. Settings does reach into
  `config.profiles`, because it edits setups you aren't plugged into, and does
  so through the by-id `workspacesBinding`/`nameBinding` helpers (an
  index-based binding traps when a profile is deleted or a reload swaps the
  array under a live view).
- `WorkspaceEngine.swift` — switching = unhide target apps → hide everything
  else (floating apps excepted) → activate the workspace's last-focused app
  (tracked in-memory via `didActivateApplicationNotification`; falls back to
  the first app). `switchToNext()`/`switchToPrevious()` cycle in config order
  with wrap-around (default hotkeys ⌥P = next, ⌥N = previous — per owner's
  explicit request, note it's inverted from the emacs n/p convention).
  **Switching never moves windows** — that invariant is why
  apps shared between workspaces keep their position; grid tiling deliberately
  moves windows but only from explicit user actions in LayoutEngine/SnapManager,
  never as part of a switch. Operates on the live profile's workspaces;
  `adoptProfile(_:)` is how a display change swaps which set that is — it lands
  on the workspace last used in that profile, else the same-named workspace as
  the one just left (new profiles are clones, so "Code" on the laptop lines up
  with "Code" at the desk), else nothing at all, leaving windows alone. That
  memory is in-memory only, like `lastFocusedApp`.
  `hideUnassignedApps()` is the cleanup action (default hotkey ⌥0, menu item,
  and runs at launch): hides everything outside the active workspace, or outside
  all of the live profile's workspaces when none is active — "assigned" means
  assigned in the setup you're plugged into. No-op when the profile has no
  workspaces, so a fresh install (or a just-created profile) doesn't blank the
  screen.
- `LayoutEngine.swift` — the AX-based tiling (the one part needing the
  Accessibility permission): `AccessibilityPermission` + `AX` helpers
  (AXUIElement window enumeration, frame get/set, top-left↔bottom-left
  coordinate flip) and `LayoutEngine.apply(workspace)`, which resizes each
  laid-out app's standard windows to its `GridRegion` on the window's current
  screen. Runs only from the Apply Grid Layout hotkey (default ⌥L) or menu
  item.
- `SnapManager.swift` — bentobox drag-snap: *global mouse* NSEvent monitors
  (mouse monitors are permission-free; global *key* monitors would need
  Accessibility) watch drags; holding the configured modifiers (default ⌃⌥)
  while dragging a window shows a `GridOverlayWindow` and the window snaps to
  the highlighted cells on release — drag across cells to span them. Arms only
  after the window's AX position actually changes, so modifier-drags inside
  window content (e.g. ⌥-select in a terminal) never snap. Uses the active
  workspace's grid, else `SnapSettings` fallback dims.
- `HotkeyManager.swift` — Carbon `RegisterEventHotKey` (chosen over
  CGEventTap/NSEvent monitors specifically because it needs no permission).
  Refuses shortcuts without modifiers.
- `KeyDebugger.swift` — key-press debugger for the Shortcuts tab. Uses a
  *local* NSEvent monitor (permission-free; a global monitor would need
  Accessibility). Persistent: only the Stop button stops it. Consumes keyDown
  events only while the Shortcuts tab is visible (`shortcutsTabVisible`).
  Hotkeys stay registered while it runs — the hotkey handlers report firings
  via `recordHotkeyFired` since Carbon consumes those events before NSEvent
  monitors see them. Passes events through untouched while ShortcutRecorder
  is capturing (`shouldPassThrough`).
- `ShortcutRecorder.swift` — captures the next key combo for the "Reassign"
  buttons in Settings, via a *local* NSEvent monitor (permission-free).
  While recording, AppDelegate unregisters all Carbon hotkeys (a registered
  combo would otherwise be consumed before the monitor sees it) and
  re-registers when recording ends; closing the settings window cancels a
  live recording so hotkeys can't stay unregistered. Keys resolve via
  `HotkeyManager.keyNames` (keyCode → name) so shifted/optioned characters
  record correctly.
- `SettingsView.swift` — SwiftUI settings hosted in an NSWindow
  (NSHostingController); tabs: Workspaces, Shortcuts, Displays, Floating Apps,
  Menu Bar (icon grid over `MenuBarIcon.available` + the workspace-name toggle,
  with a preview that mirrors the same fallback the status item uses).
  The Workspaces and Shortcuts tabs are scoped to one display profile via a
  shared `profileID` selection (`ProfileScopePicker`) that follows the attached
  hardware but can be pointed at any profile; `WorkspaceListPane` is keyed by
  `.id(profileID)` so its selection state doesn't leak across profiles.
  The Displays tab shows what's attached (with the keys detection uses), which
  profile matched, and per-profile rename / duplicate / bind-to-attached /
  delete. Binding a profile unbinds any other holding the same fingerprint —
  two claimants would make matching a coin flip.
  `GridLayoutEditor` is drag-based: drag an app chip onto the grid to place
  it (internal DnD — the dragged bundleId is stashed in view state, no async
  NSItemProvider decoding), drag a tile to move, drag its corner handle to
  span cells, ✕ removes. `ShortcutField` shows the current combo as text
  with Reassign (records via ShortcutRecorder) and clear buttons.

## Conventions

- Zero third-party dependencies; keep it that way unless there's a strong reason.
- Display detection stays permission-free: NSScreen plus the `CGDisplay*`
  metadata functions need no TCC grant, and `didChangeScreenParametersNotification`
  is an ordinary notification. Don't reach for IOKit/EDID parsing for nicer
  display names — the profile name is user-editable, which is cheaper.
- Only tiling (LayoutEngine/SnapManager's AX calls) needs the Accessibility
  permission; everything else must stay permission-free. TCC ties the grant to
  the code signature: ad-hoc re-signing (`make app`) resets it on every
  rebuild — pass `CODESIGN_ID="Apple Development: … (TEAMID)"` for a stable
  grant. For dev, processes launched from a terminal are TCC-attributed to the
  terminal app, so granting Accessibility to the terminal once keeps
  `swift run` builds trusted across rebuilds.
