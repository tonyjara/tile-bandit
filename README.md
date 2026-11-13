<div align="center">

```
         _________
        /       o \
        |~~~~~~~~~|
     ___|_________|___
   _(_________________)_
  (_____________________)   TILE BANDIT
       | \_o)   (o_/ |      menu-bar workspace switcher
       .-'"""""""""'-.      wanted · for tile rustlin'
        \ \/\/\/\/\ /
         \ \/\/\/\ /
          \ \/\/\ /
           \ \/\ /
            '-.-'
```

**A keyboard-driven workspace switcher for macOS that lives in the menu bar.**
No Spaces, no slide animation, no waiting.

</div>

---

Tile Bandit treats **workspaces as groups of apps**. Switching to one:

1. unhides the apps that belong to it,
2. hides every other app (floating apps excepted),
3. puts it back the way you left it: the same app in front, and its windows in
   the same order.

**Windows never move during a switch.** An app in two workspaces — your
browser, your terminal — stays exactly where it is when you flip between them.
Each workspace remembers its own order, so the browser can be in front in one
and behind the editor in the other; using it in one never changes the other.
With the Accessibility permission that memory is per window (one browser window
on top here, another there); without it, per app.
Window *tiling* exists too, but only ever when you ask for it.

For an app you keep one window of per task — a browser, say — there is an
opt-in the other way round: [per-window apps](#per-window-apps), where each
*window* lives in one workspace.

Workspaces are grouped by **display profile**: the laptop on its own, the
laptop plus a monitor, the lid closed on a big display — each setup gets its
own workspaces, its own shortcuts and its own grids, and Tile Bandit switches
between them automatically when you plug or unplug a screen.

It also does the Karabiner half of the job: **per-keyboard key modifications**,
including dual-role keys and chords.

Requires macOS 13 or newer. Zero third-party dependencies.

## Install

```sh
brew install --cask tonyjara/tap/tile-bandit
```

Signed and notarised, so it opens without a Gatekeeper detour, and
`brew upgrade --cask tile-bandit` keeps it current. Because the signature is
stable across releases, macOS keeps the Accessibility grant through an upgrade
rather than making you approve it again.

Homebrew does the installing, but the menu bar's **Check for Updates…** will
tell you when there's something to install — it asks GitHub for the latest
release, compares it with the version you're running, and hands you the `brew`
line. It never downloads or replaces anything itself, and it only ever runs when
you ask it to.

The app is menu-bar only — no Dock icon, no window at launch. The first launch
opens Settings: add a workspace, add apps to it, press its shortcut. It starts
with your machine unless you turn that off in Settings ▸ General.

To remove it, `brew uninstall --cask tile-bandit`, or
`brew uninstall --zap --cask tile-bandit` to take `~/.config/tilebandit` with it.

<details>
<summary><b>Building from source instead</b></summary>

A Swift toolchain is all you need — `xcode-select --install`; the Xcode IDE is
*not* required.

```sh
git clone https://github.com/tonyjara/tile-bandit.git && cd tile-bandit
make app                       # → dist/Tile Bandit.app
cp -R "dist/Tile Bandit.app" /Applications/
open "/Applications/Tile Bandit.app"
```

`make app` signs ad-hoc, and macOS ties the Accessibility permission to the
signature — so every rebuild asks for it again. Pass a stable identity to keep
the grant:

```sh
make app CODESIGN_ID="Apple Development: you@example.com (TEAMID)"
```

For the dev loop, granting Accessibility to your *terminal* is easier still:
processes launched from it inherit the grant, so it survives rebuilds.

</details>

## Permissions

Most of Tile Bandit needs nothing at all. Two features do:

| Feature | Needs | Why |
| --- | --- | --- |
| Apply Grid Layout, drag-snap | Accessibility | Moving another app's windows is an Accessibility API |
| Per-window apps | Accessibility | The same: a window that lives elsewhere is moved out of the way |
| Dual-role keys, chords | Accessibility | They run on a `CGEventTap` |
| Everything else | — | Hiding apps, hotkeys, display detection, plain key remaps |

Plain 1:1 key remaps go through `hidutil` at the HID layer, which needs no
permission and works *below* secure input — so they keep working in password
fields. Only a key that means one thing tapped and another held needs the tap.

## Shortcuts

Defaults, all reassignable in Settings → Shortcuts:

| | |
| --- | --- |
| `⌥1` … `⌥9` | Switch to workspace 1–9 |
| `⌥⇧1` … `⌥⇧9` | Send the focused window to workspace 1–9 (per-window apps only) |
| `⌥P` / `⌥N` | Next / previous workspace |
| `⌥0` | Hide unassigned apps |
| `⌥L` | Apply grid layout |
| `⌥M` | Maximize focused window **while held** (release restores it) |
| `⌥⇧M` | Maximize focused window and leave it |
| `⌥,` | Settings |
| `⌥R` | Reload config |
| `⌃⌥` + drag | Snap a window to the grid (add `⇧` to span cells) |

A workspace's shortcut belongs to the workspace, not to its place in the list:
`⌥1` … `⌥9` are handed out in order as workspaces are created, and reordering
them (drag a row in Settings → Workspaces, or select it and press `⌥⌘↑` / `⌥⌘↓`)
changes the menu and what next / previous cycle through, never which key
goes where.

Shortcuts need at least one modifier — a bare key would swallow normal typing
system-wide.

## Display profiles

Tile Bandit recognises which screens are attached and switches to that setup's
workspaces on its own.

- Profiles are **created automatically** the first time a setup is seen, named
  from the displays themselves ("MacBook", "MacBook + Desk Monitor", "Desk Monitor"),
  and **seeded with a copy of the profile you were just on** — plug in a
  monitor and your workspaces are already there, ready to be re-tiled.
- Plugging or unplugging restores the workspace you last used in that profile;
  the first time, it lands on the same-named workspace as the one you were in,
  and if there's no match it leaves your windows alone.
- Displays are recognised by EDID vendor/model/serial, not by macOS's
  per-session display IDs — so unplugging and replugging the same monitor is
  the same profile, and rearranging displays in System Settings isn't a new
  setup either.
- The menu bar shows the live profile, with a submenu to force a different one
  — handy for configuring a desk you aren't sitting at. The next display change
  re-detects and takes it back.

Settings → **Displays** lists what's attached (with the identifiers detection
uses), which profile matched, and lets you rename, duplicate, delete or bind a
profile to the displays attached right now.

## Grid layout

A workspace holds **one grid per display**. That's how you say "in this
workspace the editor and terminal go side by side on the big monitor and chat
fills the laptop".

In Settings → **Workspaces**, pick a display, set its columns and rows, then
drag app chips onto the grid; drag a tile to move it, its corner dot to span
cells, ✕ to take it off. An app placed on another monitor's grid shows up as a
dimmed chip labelled with that display — drag it over and it *moves* there. An
app lives on one display at a time.

To remove something, click it and press Delete, use its ✕, or right-click it.
A tile comes off the grid and goes back to the chips; a chip (an app not on
this grid) is taken out of the workspace.

**Apply Grid Layout** (`⌥L`) then moves each placed app's windows to the
display it's assigned to and sizes them to their cells. This is the only thing
that moves a window between screens, and it only runs when you ask.

**Drag-snapping** follows the same per-display grids: hold `⌃⌥` while dragging
a window and you get the grid belonging to the screen you're over, switching as
you cross onto another one. The highlight is the single cell under the cursor;
hold `⇧` as well to span from where you pressed it. A display the workspace has
nothing laid out on falls back to the default dimensions in Settings.

## Per-window apps

Workspaces hold apps, and an app in two workspaces shows all its windows in
both. For most apps that is what you want. For a browser with one window for
chat and another for code it isn't: you get both windows everywhere.

Add such an app under Settings → **Apps** → Per-window apps and each of its
windows lives in **one** workspace:

- A window belongs to the workspace it was opened in. (Exactly: a window with
  no home yet shows wherever its app does, and the workspace you leave it in
  takes it.)
- **Move Window to ▸** in the menu, or `⇧` with a workspace's shortcut, sends
  the focused window to another workspace. The window goes; you stay.
- Focusing a window that lives elsewhere — Cmd-`, Mission Control, a link that
  opens in it — takes you to its workspace, like follow-focus does for apps.
- Apply Grid Layout leaves the windows of other workspaces alone.

macOS has no way to hide one window of an app, so a window that lives elsewhere
is **parked**: moved to a bottom corner of its display, where the system keeps
a sliver of it showing (1 × 32 pt), and moved back to where it was when you
return. No animation, nothing in the Dock. This is the one case where a switch
moves windows, and only for the apps you list here.

Things to know:

- It needs the Accessibility permission. Without it a per-window app is
  switched whole, like any other.
- The app still has to be listed in each workspace where its windows may live.
- A window is recognised for as long as it stays open, through tabs, titles and
  Tile Bandit restarting. When the *app* restarts, its windows are matched
  again by title and frame; a window that can't be told apart is treated as new.
- Right after you opt an app in, no window has a home, so the first workspace
  you leave takes all the ones on screen. Send each where it belongs first.
- Tile Bandit puts every parked window back when it quits. **Bring Parked
  Windows Back** in the menu does it on demand.
- Windows in native full screen and minimised windows are left alone.

Which window lives where is kept in `~/.config/tilebandit/windows.json`, by
window id. No title is stored, only a digest to compare.

## Key modifications

The Karabiner-shaped half, filed per keyboard — which map is live depends on
what you're typing on, and every attached keyboard's map is live at once.

- **Remaps** — caps lock → escape, say. Applied with `hidutil`: no permission,
  no root, and below secure input.
- **Dual-role keys** — tap for one key, hold for a modifier set (`hyper` is
  shorthand for ⌃⌥⇧⌘). Needs Accessibility.
- **Chords** — rewrite a key-plus-modifiers into another, or into nothing,
  which is how a combination gets *disabled* (⌘H is the usual candidate).
  Chords hung off a hold are device-scoped and only live while that key is
  down; chords in the top-level `chords` list apply whatever you're typing on.
- A keyboard Tile Bandit has never seen is filed automatically, cloned from the
  most recently edited profile — so a new board inherits the map you've been
  tuning. With no profiles at all it stays empty: a first run invents nothing.

**Add Mapping** listens: press the key you want to remap, then the key it
should send — or pick either from the list, which is where Escape (Esc cancels)
and a MacBook's F1–F12 (its top row sends brightness and volume) live. Your key
modifications are paused while it listens, so a key that's already remapped is
captured as itself rather than as what it became. Nothing joins the list until
both keys are in; Esc or Cancel leaves nothing behind.

**fn (Globe)** can be remapped on Apple keyboards — `"fn"` (or `"globe"`) in
the config. Remap it *from* fn and you give up what fn does: fn plus the top
row stops sending F1–F12 (the media keys come out instead), fn plus the arrows
stops giving Home/End/Page Up/Page Down, and the Globe key's own action — the
"Press 🌐 key to" setting, the emoji picker, dictation, the fn shortcuts —
stops too, because macOS never sees an fn press. Remap another key *to* fn and
that key takes all of it over. Other keyboards handle fn inside the keyboard,
so it never reaches the Mac and is listed as unavailable there. fn can be a
plain remap's target, but not a hold key's tap or part of a chord.

Nothing outlives the app: quitting hands every keyboard back unmodified, and
the menu bar has a master switch for when a mapping misbehaves and the keyboard
is the thing you can't use to go fix it.

Settings → **Key Modifications** has a **key debugger** too: press a key and it
tells you exactly what macOS delivered, what the key is called in the config,
and whether it's usable as a global shortcut.

## Menu bar

The status item shows an icon plus the name of the workspace you're in, and the
menu is grouped the way you use it: the live display setup at the top,
workspaces, window actions, then setup.

Settings → **General** swaps the icon. There are two families:

- **Wanted** — a sheriff star, a bandit mask, a ten-gallon hat, a horseshoe, a
  cactus and a wagon wheel, drawn as Bézier paths right in the app, so they're
  sharp at any size and can't go missing.
- **Plain** — a dozen SF Symbols, for a menu bar without opinions.

The default is the cactus. The workspace name can be dropped if you'd rather
keep the menu bar narrow, and the status item can be **hidden altogether** —
hotkeys carry on working, and opening Tile Bandit again (Finder, Spotlight)
always reopens Settings, so hiding it can't lock you out even with no shortcut
assigned. Changes apply immediately, no relaunch.

**Launch at login** is on by default, on the same tab. It's registered with
`SMAppService`, so macOS lists Tile Bandit under System Settings ▸ General ▸
Login Items — and if you switch it off there, Tile Bandit takes the hint rather
than re-registering itself on every launch. Only an installed `.app` can
register; a `swift run` build says so instead of pretending.

## Config

Everything lives in `~/.config/tilebandit/config.json` — hand-editable, then
**Reload Config** (`⌥R`) in the menu. Decoding is lenient on purpose: an
unknown icon name, an unknown key name or a missing field falls back instead of
throwing the file out.

```json
{
  "version": 5,
  "profiles": [
    {
      "id": "9C2A1B44-0000-4000-8000-000000000001",
      "name": "MacBook + Desk Monitor",
      "displays": [
        { "key": "builtin", "name": "MacBook" },
        { "key": "edid:1234-5678-0", "name": "Desk Monitor" }
      ],
      "workspaces": [
        {
          "id": "5E1F0E56-3C63-4E8B-9B6A-000000000000",
          "name": "Code",
          "apps": [
            { "bundleId": "com.apple.Terminal", "name": "Terminal" }
          ],
          "shortcut": { "key": "1", "option": true },
          "grids": [
            {
              "displayKey": "edid:1234-5678-0",
              "columns": 2,
              "rows": 2,
              "layout": {
                "com.apple.Terminal": { "col": 0, "row": 0, "colSpan": 1, "rowSpan": 2 }
              }
            }
          ]
        }
      ]
    }
  ],
  "floatingApps": [],
  "perWindowApps": [
    { "bundleId": "com.example.browser", "name": "Browser" }
  ],
  "moveWindowShortcuts": true,
  "keyboards": [],
  "chords": [],
  "menuBarIcon": "bandit.cactus",
  "showWorkspaceName": true,
  "hideMenuBarIcon": false,
  "launchAtLogin": true,
  "followFocusedApp": true
}
```

- Workspaces live **inside a profile**; `displays` is the fingerprint that
  profile matches. A profile with `displays: []` is unbound and matches nothing
  until you bind it in Settings → Displays.
- Each workspace's `grids` has one entry per display, tied to
  `displays[].key`. It's sparse — a display nobody has laid anything out on has
  no entry.
- Apps in **Floating Apps** are visible in every workspace and are never hidden
  by a switch.
- Apps in `perWindowApps` have each window live in one workspace — see
  [Per-window apps](#per-window-apps). Empty by default. `moveWindowShortcuts`
  (default on) is the `⇧` + workspace shortcut that sends a window, registered
  only while the list has an app.
- `launchAtLogin` (default on) and `hideMenuBarIcon` (default off) are the two
  switches on the General tab.
- `followFocusedApp` (default on): focusing an app that belongs to another
  workspace — Cmd-Tab, Spotlight, a Dock click — switches to that workspace
  rather than leaving one window stranded over the one you're in.
- Any shortcut can be set to `null` to disable it.

Older configs are migrated on read and written back in the current shape on the
next save; nothing is lost. `version: 1` (a flat `workspaces` list) becomes a
profile bound to whatever is attached, and `version: 2`'s single grid per
workspace is copied onto every display in its profile. Versions 3 and 4 only
lack keys added since (key modifications, per-window apps), which read as none.

## Development

Pure Swift Package Manager — there is no `.xcodeproj`, which is what makes it
first-class in **neovim**: `sourcekit-lsp` ships with the toolchain and
understands SPM natively. (Xcode users can still `open Package.swift`.)

```sh
swift run     # dev build + launch; prints the mascot, config path and permission state
make dev      # auto-rebuild & relaunch on change (needs watchexec)
make app      # release build → dist/Tile Bandit.app
make icon     # re-bake Resources/AppIcon.icns from the drawing in BanditIcons.swift
make glyphs   # contact sheet of the drawn menu bar glyphs, light and dark
```

There's no hot reload — quit the running instance before starting a new one, or
two menu bar icons will fight over the same hotkeys. For development, grant
Accessibility to your *terminal*: processes launched from it inherit that
grant, so it survives rebuilds.

```
Sources/TileBandit/
├── main.swift               NSApplication bootstrap (accessory app, no Dock icon)
├── Banner.swift             the ASCII hello printed on a terminal launch
├── AppDelegate.swift        status item, wiring, menu actions
├── StatusMenu.swift         what the menu bar menu looks like
├── BanditIcons.swift        the drawn glyph set + the app icon artwork
├── LoginItem.swift          launch at login, via SMAppService
├── UpdateChecker.swift      asks GitHub for the latest release; brew installs it
├── Models.swift             Config / DisplayProfile / Workspace / Shortcut (Codable)
├── ConfigStore.swift        ObservableObject + debounced JSON autosave
├── DisplayProfiles.swift    display fingerprinting + profile detection
├── WorkspaceEngine.swift    the actual switching: unhide → hide → restore, then check
├── WindowStack.swift        what is on screen, what a workspace remembers
├── Log.swift                the trace in the system log
├── LayoutEngine.swift       AX window moving + maximize
├── SnapManager.swift        modifier-drag snap-to-grid + overlay
├── HotkeyManager.swift      Carbon RegisterEventHotKey wrapper
├── HIDKeys.swift            the key table: config name ↔ HID usage ↔ keycode
├── Keyboards.swift          keyboard detection (IOKit registry, properties only)
├── KeyRemapper.swift        hidutil remaps + the plan both engines share
├── DualRoleTap.swift        the CGEventTap: tap-vs-hold and chords
├── KeyDebugger.swift        "what key is this, really?"
├── ShortcutRecorder.swift   captures a combo for the Reassign buttons
├── KeyCapture.swift         captures one key for Add Mapping, remaps paused
├── SettingsView.swift       SwiftUI settings window
└── KeyModificationsTab.swift  … and its biggest tab
```

`swift test` runs the tests of the switch decisions.

### When a switch goes wrong

Every switch leaves a few lines in the system log: what asked for it, what was
in front, what was focused and why, and what was actually on screen a moment
later. An app that was asked to hide and didn't is named there as `LEFTOVER`.

```sh
make log                 # the last hour
SINCE=1d make log        # further back
make log-live            # follow it while you switch
```

Without the checkout:

```sh
/usr/bin/log show --last 1h --info --predicate 'subsystem == "com.twonary.TileBandit"'
```

## Roadmap

- Updates that install themselves. The app tells you one is out; applying it is
  still `brew upgrade`.
- Option to *keep* unassigned apps visible during switches.
- Persist the last workspace per profile across relaunches (it survives
  replugging a monitor today, but not quitting).

## Credits

Concept inspired by [FlashSpace](https://github.com/wojciech-kulik/FlashSpace)
(GPL-3.0). Tile Bandit is an independent implementation and shares no code.
