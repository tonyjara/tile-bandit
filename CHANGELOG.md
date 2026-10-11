# Changelog

Notable changes, newest first. Versions follow the number in
`Resources/Info.plist`, which is what `make app` stamps into the bundle and what
the Homebrew cask points at.

## Unreleased

### Added

- **fn (Globe) can be remapped** on Apple keyboards, including a MacBook's
  built-in one: as the key being remapped, and as the key a remap sends. Taking
  fn away also takes what it does — fn plus the top row stops sending F1–F12,
  and the Globe key's own action (input source, emoji, dictation) stops — while
  a key remapped *to* fn takes all of that over. On keyboards that handle fn
  themselves and never send it to the Mac, it's listed as unavailable, with the
  reason. It can't be a hold key's tap or part of a chord.

### Changed

- **Add Mapping listens for the keys.** Press the key to remap, then the key it
  should send, or pick either from the list. Your modifications are paused
  while it listens, so a key that's already remapped is captured as itself, and
  pressing fn or Caps Lock to pick them doesn't switch input source or leave
  Caps Lock on. The mapping joins the list only once it's complete — scrolled
  into view and briefly highlighted — and Esc or Cancel at any step leaves
  nothing behind. It used to append a half-made row at the bottom of the list,
  often out of sight.

## 1.4.0

### Added

- **Caffeinate** keeps the Mac awake: no idle sleep, no display sleep and no
  screen saver, on battery as well as plugged in. Turn it on from the menu's
  Setup section, or assign it a shortcut in Settings → Shortcuts (it has none
  by default). While it's on, a coffee cup sits in the menu bar, even if the
  main icon is hidden, and clicking the cup turns it off. It lasts only until
  Tile Bandit quits, and closing the lid still sleeps the Mac.

## 1.3.0

### Added

- **Install and Relaunch** from Check for Updates…. When Homebrew installed Tile
  Bandit, the update alert can now run the upgrade itself (`brew update`, then
  `brew upgrade --cask tile-bandit`) and reopen the app afterwards, with a
  progress window you can cancel. If the upgrade fails, the alert shows brew's
  output and the command to run yourself. Copies Homebrew didn't install still
  get the command to copy.

### Fixed

- **The key debugger no longer stays on.** Start Listening used to stay armed
  until Stop was pressed, even after leaving the tab or closing the settings
  window. It now stops on its own when you leave the Key Modifications tab,
  close or minimise the settings window, or switch to another app.

## 1.2.0

### Added

- **Badges for the apps on a grid** in the grid layout editor. Tiles can
  overlap (two apps can share cells, and a hand-edited config can stack them
  exactly), and until now the tile drawn last took every click, so a covered
  tile's ✕ and resize handle were out of reach. Clicking an app's badge brings
  its tile to the front so you can resize or remove it.

### Fixed

- **Stuck keys from dual-role keys and chords.** The event tap used to run on
  the main run loop, behind the settings window, the menu and every display
  and keyboard rescan. When it blocked, macOS switched it off between a key's
  press and its release. That left a hold's modifiers on every later keystroke,
  or left a chord's replacement key down and auto-repeating. The tap now runs
  on its own thread. Every teardown (tap disabled, re-plan, shutdown) now sends
  the releases it owes. Presses the window server no longer sees as down are
  also released after a short grace period, which covers a release that got
  lost, for example from a Bluetooth keyboard dropping a report.

## 1.1.0

### Added

- **Check for Updates…** in the menu bar's Setup section. It asks GitHub what
  the latest release is and says so — it never downloads or replaces anything,
  because the Homebrew cask owns installation. Offers the release notes and, on
  an installed `.app`, copies `brew upgrade --cask tile-bandit` to the
  clipboard. A build run from source is told to pull and rebuild instead, since
  Homebrew never installed it and can't upgrade it.
- A guard against a keyboard that is **plugged in but publishes no keyboard
  interface** — the state a device is left in when another driver seizes it,
  and the reason `matchingJSON(for:)` can't filter by usage. In that state
  hidutil is still handed a matcher that selects the device's other interfaces,
  writes the mapping there and exits 0, so everything reports success while no
  key is ever rewritten; from the config's side it is indistinguishable from
  unplugged. Tile Bandit now tells the two apart by diffing the keyboard walk
  against every HID device present, warns on the Key Modifications tab, and
  logs it once when it changes.

  Note: this is a defensive guard, not a fix for an observed failure. Detection
  goes through the same `isKeyboard()` the rest of the app uses, so a composite
  device that declares keyboard usage in `DeviceUsagePairs` rather than as its
  primary usage — a Dygma Raise, for one — is correctly seen as a keyboard and
  is never flagged.

## 1.0.0

First release.

- Menu-bar workspace switcher: per-workspace app sets, switching by hotkey or
  menu, next/previous with wrap-around, and a cleanup action that hides
  everything unassigned. Switching never moves windows.
- Display profiles: workspaces live inside a display setup, detected from the
  attached screens and matched by fingerprint, so the laptop and the desk keep
  separate layouts. Detection is permission-free.
- Bentobox grid tiling: a grid per display per workspace, applied by hotkey, plus
  modifier-drag snapping with spanning, and hold-to-maximize.
- Key modifications: per-keyboard remaps through `hidutil` at the HID layer
  (permission-free, and below secure input), with dual-role keys and chord
  layers through an event tap when a mapping needs one.
- Western icon set drawn as Bézier paths rather than shipped as an icon pack,
  a reorganised menu, and launch at login through `SMAppService`.
