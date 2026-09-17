# Changelog

Notable changes, newest first. Versions follow the number in
`Resources/Info.plist`, which is what `make app` stamps into the bundle and what
the Homebrew cask points at.

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
