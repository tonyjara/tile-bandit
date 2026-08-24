# Tile Bandit

```
      .-"""""""-.
     /  _     _  \
    |  (o)===(o)  |    Tile Bandit
     \     ^     /     menu-bar workspace switcher
      '-.......-'
```

A fast, keyboard-driven workspace switcher for macOS that lives in your menu bar.
Inspired by [FlashSpace](https://github.com/wojciech-kulik/FlashSpace).

Instead of macOS Spaces (with their slow slide animation), Tile Bandit treats
**workspaces as groups of apps**, grouped in turn by **display profile** — the
laptop on its own, the laptop plus a monitor, the lid closed on a big display
each get their own set. Switching to a workspace simply:

1. unhides the apps that belong to it,
2. hides every other app (floating apps excepted),
3. focuses the app you were last in there (its first app, the first time).

No animation, no waiting — and crucially, **windows never move**. An app that
belongs to two workspaces (or is in the Floating list) is left completely alone
during a switch: it stays visible, exactly where it was.

## Status: MVP

Does: display profiles (auto-detected), workspaces, per-workspace apps, global
hotkeys, floating apps, menu bar switcher (with a pickable icon), grid tiling
(Apply Grid Layout plus modifier-drag snapping), SwiftUI settings (including a
Shortcuts tab with a key-press debugger), hand-editable JSON config, and a
**Hide Unassigned Apps**
action (default ⌥0, also in the menu) that hides everything outside the active
workspace — it runs automatically at launch too.
Doesn't (yet): launch at login.

Only the window-moving parts (Apply Grid Layout and drag-snap) need the
Accessibility permission. Switching, hotkeys and display detection are
permission-free: they hide/unhide whole apps (`NSRunningApplication`), use
Carbon `RegisterEventHotKey`, and read `NSScreen` metadata.

## Display profiles

Tile Bandit recognises which screens are attached and switches to that setup's
workspaces automatically. Each setup — MacBook alone, MacBook + external, lid
closed on a Studio Display — is a **display profile** with its own workspaces,
its own hotkey assignments and its own grids — one grid *per display* — so a
3×2 bento on the big monitor doesn't follow you onto the 14".

- Profiles are **created automatically** the first time a setup is seen, named
  from the displays themselves ("MacBook", "MacBook + M14", "Studio Display"),
  and **seeded with a copy of the profile you were just on** — plug in a monitor
  and your workspaces are already there, ready to be re-tiled. Names are
  editable in Settings → Displays.
- Plugging or unplugging a screen restores the workspace you last used in that
  profile; the first time, it lands on the same-named workspace as the one you
  were in (the copies line up), and if there's no match it leaves your windows
  alone.
- Displays are recognised by EDID vendor/model/serial (built-in panels just by
  being built-in), not by macOS's per-session display IDs, so unplugging and
  replugging the same monitor is the same profile. Rearranging displays in
  System Settings isn't a new setup either.
- The menu bar shows the live profile at the top, with a submenu to force a
  different one — handy for configuring a desk you aren't sitting at. The next
  display change re-detects and takes it back.

Settings → **Displays** lists what's attached (with the identifiers detection
uses), which profile matched, and lets you rename, duplicate, delete, or point a
profile at the displays attached right now.

## Grid layout

A workspace holds **one grid per display** in its profile. That's how you say
"in this workspace, the editor and terminal go side by side on the big monitor
and Slack fills the laptop" — each screen gets its own dimensions and its own
app placements.

In Settings → **Workspaces**, the Grid Layout section has a display picker
(when the profile has more than one screen). Pick a display, set its columns
and rows, then drag app chips onto the grid; drag a tile to move it, its corner
dot to span cells, ✕ to take it off. An app placed on another monitor's grid
shows up as a dimmed chip labelled with that display — drag it over and it
*moves* there. An app lives on one display at a time.

**Apply Grid Layout** (default ⌥L, also in the menu) then moves each placed
app's windows to the display it's assigned to and sizes them to their cells.
This is the only thing that moves a window between screens, and it only ever
runs when you ask for it: switching workspaces still never moves a window.

Drag-snapping follows the same per-display grids — hold ⌃⌥ while dragging a
window and you get the grid belonging to the screen you're over, switching as
you cross onto another one. A display the workspace has nothing laid out on
falls back to the default dimensions in Settings.

## Run it

Requirements: macOS 13+ and a Swift toolchain (`xcode-select --install` is
enough — the Xcode IDE is *not* required).

```sh
swift run     # dev build + launch; the menu bar icon appears
make dev      # auto-rebuild & relaunch on file changes (needs watchexec)
make app      # release build → dist/Tile Bandit.app
```

Launched from a terminal it prints the mascot above along with your config
path and whether Accessibility is granted — an accessory app is otherwise
silent, so that's how you know it came up. (A `.app` opened from Finder has
nowhere to print; look for the menu bar icon instead.)

There is no hot reload — quit the running instance before starting a new one
(two instances mean two menu bar icons fighting over the same hotkeys).

First run opens Settings automatically:

1. Add a workspace — it gets ⌥1, ⌥2, … by default.
2. Add apps to it ("Add App" lists running apps, or browse /Applications).
3. Press the hotkey.

Tip: add the same app (your browser, your terminal) to several workspaces — it
stays visible and keeps its position when you switch between them. Apps in the
**Floating Apps** tab are visible in *every* workspace.

## Menu bar

The status item shows the icon plus the name of the workspace you're in.
Settings → **Menu Bar** swaps the icon for any of a dozen SF Symbols (grids,
windows, a stack, a bandit mask) and can drop the workspace name if you'd
rather keep the menu bar narrow — the icon alone still opens the menu. Changes
land immediately, no relaunch.

In JSON that's `menuBarIcon` (an SF Symbol name) and `showWorkspaceName`. A
symbol your macOS doesn't ship falls back to the default grid rather than
leaving an invisible menu bar item, so hand-editing it is safe.

## Config

Everything lives in `~/.config/tilebandit/config.json`. Edit it by hand if you
like, then hit **Reload Config** in the menu bar.

```json
{
  "version": 3,
  "profiles": [
    {
      "id": "9C2A1B44-0000-4000-8000-000000000001",
      "name": "MacBook + M14",
      "displays": [
        { "key": "builtin", "name": "MacBook" },
        { "key": "edid:12462-25053-0", "name": "M14" }
      ],
      "workspaces": [
        {
          "id": "5E1F0E56-3C63-4E8B-9B6A-000000000000",
          "name": "Code",
          "apps": [
            { "bundleId": "com.apple.Terminal", "name": "Terminal", "path": "/System/Applications/Utilities/Terminal.app" }
          ],
          "shortcut": { "key": "1", "control": false, "option": true, "shift": false, "command": false },
          "launchMissingApps": false,
          "grids": [
            {
              "displayKey": "edid:12462-25053-0",
              "columns": 2,
              "rows": 2,
              "layout": { "com.apple.Terminal": { "col": 0, "row": 0, "colSpan": 1, "rowSpan": 2 } }
            },
            { "displayKey": "builtin", "columns": 1, "rows": 1, "layout": {} }
          ]
        }
      ]
    }
  ],
  "floatingApps": [],
  "menuBarIcon": "square.grid.2x2.fill",
  "showWorkspaceName": true,
  "hideUnassignedShortcut": { "key": "0", "control": false, "option": true, "shift": false, "command": false }
}
```

Workspaces live inside a profile; `displays` is the fingerprint that profile
matches (a `displays: []` profile is unbound and matches nothing until you bind
it in Settings → Displays). Each workspace's `grids` has one entry per display,
tied to the profile's `displays[].key`; an entry with an empty `displayKey` is
unbound and applies wherever a window already is.

Older configs are migrated on read, and the current shape is written back on
the next save:

- `version: 1` (a top-level `workspaces` list) moves its workspaces into a
  profile bound to whatever displays are attached at that moment, named after
  them.
- `version: 2` (one `gridColumns`/`gridRows`/`layout` per workspace) gives that
  grid to *every* display in the profile rather than guessing which monitor you
  meant, so your old layout shows up on each screen and you delete what doesn't
  belong there.

Nothing is lost either way — apps, shortcuts and placements all come along.

`hideUnassignedShortcut` triggers the cleanup action: with a workspace active
it hides everything outside that workspace (great for "I pulled up a couple of
random apps, now take me back"); with none active it hides apps that aren't in
*any* workspace. Set it to `null` to disable.

Shortcuts must include at least one modifier (a bare key would swallow normal
typing system-wide). Keys `0–9` and `a–z` work; the UI offers digits, letters
are available via the JSON.

The **Shortcuts** tab lists every action — Hide Unassigned Apps plus one switch
action per workspace — with editable shortcuts, and a **Key Debugger**: hit
"Start Listening" and it shows the exact modifiers and key macOS delivers, the
raw keyCode, and whether the combo is usable as a shortcut. Registered global
hotkeys show up as fired actions (e.g. "⌥1 — Switch to Code"). It stays on
until you stop it; keys are only swallowed while the Shortcuts tab itself is
visible, so typing elsewhere keeps working. It sees ordinary key presses only
while a Tile Bandit window is focused — that's what keeps it permission-free.

## Development

Pure Swift Package Manager — there is no `.xcodeproj`. That makes it
first-class in **neovim**: `sourcekit-lsp` ships with the Swift toolchain and
understands SPM packages natively, so with `nvim-lspconfig`'s `sourcekit`
server you get completion and diagnostics with zero extra setup. (Xcode users
can still `open Package.swift`.)

```
Sources/TileBandit/
├── main.swift             NSApplication bootstrap (accessory app, no Dock icon)
├── Banner.swift           the ASCII hello printed on a terminal launch
├── AppDelegate.swift      status item, menu, config → hotkeys/menu wiring
├── Models.swift           Config / DisplayProfile / Workspace / Shortcut (Codable)
├── DisplayProfiles.swift  display fingerprinting + auto profile detection
├── ConfigStore.swift      ObservableObject + debounced JSON autosave
├── WorkspaceEngine.swift  the actual switching: unhide → hide → focus
├── LayoutEngine.swift     AX window moving (the one part needing permission)
├── SnapManager.swift      modifier-drag snap-to-grid + overlay
├── HotkeyManager.swift    Carbon RegisterEventHotKey wrapper (no permissions)
├── KeyDebugger.swift      local key-press monitor for the Shortcuts tab
├── ShortcutRecorder.swift captures a combo for the Reassign buttons
└── SettingsView.swift     SwiftUI settings window
```

## Roadmap

Done since the first cut: window tiling via the Accessibility API, drag-snap,
per-display workspaces (display profiles), a grid per display inside each
workspace, a shortcut recorder, per-workspace focus memory, and a pickable menu
bar icon.

- Launch at login.
- Option to *keep* unassigned apps visible during switches (current behavior
  hides everything outside the target workspace).
- Persist the last workspace per profile across relaunches (it's in-memory
  today, so it survives replugging a monitor but not quitting the app).

A stable codesigning identity is worth setting up now that tiling needs
Accessibility: ad-hoc-signed rebuilds reset the TCC grant every time (see
`CODESIGN_ID` in the Makefile).

## Credits

Concept inspired by [FlashSpace](https://github.com/wojciech-kulik/FlashSpace)
(GPL-3.0). Tile Bandit is an independent implementation and shares no code.
