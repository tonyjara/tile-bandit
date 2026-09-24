# Tile Bandit

macOS menu-bar workspace switcher (FlashSpace-style). Pure SwiftPM — no
`.xcodeproj`, and it should stay that way (the owner works in neovim with
sourcekit-lsp, which understands SPM natively).

## Commands

- `swift build` / `swift run` — dev
- `make app` — release bundle at `dist/Tile Bandit.app` (ad-hoc signed)
- `make notarized CODESIGN_ID="Developer ID Application: … (TEAMID)"` — signed,
  notarised, stapled zip for the Homebrew cask; prints the sha256 to paste into
  `packaging/tile-bandit.rb`. Hardened runtime and timestamp are set there and
  can't be added after the fact.
- `make icon` — re-bake `Resources/AppIcon.icns` from `AppIconArt`; the result
  is checked in, so `make app` stays a copy with no rendering step
- `make glyphs` — contact sheet of the drawn glyphs at 16pt and up, light and
  dark. A 16pt drawing can't be judged from source.

## Architecture (Sources/TileBandit/)

- `main.swift` — NSApplication bootstrap; activation policy `.accessory`.
  Calls `Banner.show()` first.
- `Banner.swift` — the ASCII mascot + config path / Accessibility status
  printed to stdout at launch. Only visible on a terminal launch (`swift run`);
  a Finder-launched `.app` has nowhere to print. The art uses raw string
  literals (`#"""…"""#`) because the mascot itself contains `"""`, and ANSI
  styling is applied only when stdout `isatty`. Also lists the detected
  keyboards — the one piece of hardware whose detection you can't confirm by
  looking at the screen.
- `AppDelegate.swift` — status item + wiring, and the answers to the menu's
  actions (`StatusMenuActions`); what the menu *looks* like lives in
  StatusMenu.swift. Subscribes to config changes and re-registers hotkeys /
  rebuilds the menu (debounced via Combine). Also owns `DisplayProfileManager`:
  a profile change re-registers hotkeys and rebuilds the menu immediately
  rather than waiting on the debounce, since the whole set of workspace
  shortcuts has just changed. Reload Config re-resolves the profile too, since
  the file may have renamed or removed profiles. The status item's image and
  title are set in `rebuildMenu()` (not once at launch) so
  `menuBarIcon`/`showWorkspaceName` changes apply live.
  `rebuildMenu()` also applies `hideMenuBarIcon` (`statusItem.isVisible`), and
  `applicationShouldHandleReopen` opens Settings — that's the escape hatch for a
  hidden status item, since re-opening the app is the one route that still works
  with no shortcut assigned either. `applyConfig()` reconciles the login item.
  As `NSMenuDelegate` it notes the frontmost app in `menuWillOpen` and hands it
  to `MaximizeHold.stick(on:)`: a menu action runs *after* the menu closed, so
  asking who's in front at that point is a race (comparison is by pid — a
  `swift run` build has no bundle identifier to compare).
  `menuAbout` fills the standard About panel by hand for the same reason: no
  bundle means no name, version or icon to read.
  Owns `KeyboardManager` and `KeyModEngine` too; a keyboard coming or going
  doesn't touch workspaces or hotkeys, so it reapplies key modifications on its
  own rather than through `applyConfig()`. `applicationWillTerminate` clears
  them: key modifications are the one thing this app leaves *on the machine*
  rather than in its own process, and a carrier key with nothing left to
  interpret it would be a dead key.
- `StatusMenu.swift` — the menu bar menu, kept apart from AppDelegate because
  it is the one purely *view* part of the app. Four groups, in the order you
  need them: the brand row (Copperplate — the nearest thing macOS ships to a
  saloon sign — opening the About panel) and the live display setup with its
  profile submenu; Workspaces (each with a ✓ when active and a solid-vs-dashed
  grid glyph saying whether Apply Grid Layout has anything to do there) plus
  next/previous; Windows; then Setup (which ends with Check for Updates… —
  see UpdateChecker.swift). Key equivalents come from the config
  rather than being hard-coded, so a reassignment shows up in the menu. Section
  headers are `NSMenuItem.sectionHeader` on macOS 14+ and a styled disabled
  item below that. The Key Modifications master switch is in the menu on
  purpose: when a remap misfires, the keyboard is exactly the thing you can't
  use to go fix it.
  The `MenuBarIcon` → `NSImage` extension lives here rather than in Models so
  the model layer stays AppKit-free; `resolvedImage` falls back to the default
  and `available` filters the picker, so a symbol this macOS lacks can never
  leave a blank, unclickable status item — and since the fallback is a *drawn*
  glyph, it can't be missing either.
  `flattened(_:into:)` is not cosmetic: AppKit won't draw a vector-backed image
  in a menu item (an SF Symbol or a PDF template comes out blank, while a
  drawing-handler image draws fine), so every menu icon is repainted into a
  fixed-size bitmap-backed image first. It keeps `isTemplate`, so macOS still
  tints it for dark menus and highlighted rows, and the uniform box is what
  keeps the titles lined up.
- `BanditIcons.swift` — the drawn icon set: `BanditGlyph` (star, mask, hat,
  horseshoe, cactus, wheel) as Bézier paths in a 100×100 box, scaled to
  whatever is asked for and marked template. An icon pack would have been a
  dependency plus a licence, and none of them cut a sheriff star for a 16pt
  menu bar. `Sketch` cuts holes with a `.clear` blend rather than an even-odd
  winding rule, because the parts overlap on purpose — a hat's crown sits *on*
  its brim, and even-odd would punch a hole where they meet. `AppIconArt` is
  the one coloured piece (leather, bento tiles, gold star), drawn rather than
  stored so the About panel, a bundle-less `swift run` build and the `.icns`
  are the same artwork. The file is deliberately self-contained — AppKit and
  nothing of ours — so `make glyphs` and `make icon` can compile it alone.
- `LoginItem.swift` — launch at login through `SMAppService.mainApp` (macOS
  13+): no helper bundle, no privileged install, and the Login Items entry
  macOS shows is the app's own name. Guarded by `isSupported`, which is really
  "are we a `.app`?" — SMAppService works off the main bundle, and a `swift run`
  build would file the path of a build artifact as a login item. `.requiresApproval`
  is deliberately left alone (the user switched it off in System Settings;
  re-registering every launch would be arguing with them) and the Settings
  toggle says so instead. Verified against an ad-hoc signed bundle — no
  Developer ID needed for this part.
- `UpdateChecker.swift` — one HTTPS GET at `api.github.com/.../releases/latest`,
  behind the menu's Check for Updates…. It deliberately *only asks*: the cask
  owns installation, so there is nothing to download, verify or swap. Where
  Homebrew really installed us, `UpdateInstaller.swift` offers Install and
  Relaunch — it runs `brew update` + `brew upgrade --cask tile-bandit` itself
  (Homebrew still does the installing), checks the bundle's Info.plist for the
  new version, then a detached `sh` waits for our pid to exit and `open`s the
  bundle again. Anywhere else the alert hands over the command instead. Sparkle would be a
  dependency plus a signing key, and two updaters disagreeing about what's
  installed is worse than having none. Permission-free, on demand only — no
  timer, nothing sent but the request. `isBundledApp` is LoginItem's
  `isSupported` question again and for a neighbouring reason: only a bundle has
  a stamped version to compare, and only a bundle was installed by Homebrew, so
  a `swift run` build is told to pull and rebuild rather than given a `brew`
  line about a checkout it can't see. A non-200 is reported, never folded into
  "up to date" — GitHub answers 403 to an unauthenticated caller it's rate
  limiting (and to one that sends no `User-Agent`, which is why the request sets
  one), and "no news" read as "you're current" would strand someone on an old
  build for good. Version comparison is component-wise numeric, so 1.10.0 beats
  1.9.0 and a `-beta` suffix never reads as newer than the release it precedes.
- `Models.swift` — `Config`/`DisplayProfile`/`DisplayRef`/`Workspace`/`AppRef`/
  `Shortcut` plus the grid types (`DisplayGrid`/`GridRegion`/`GridCell`/
  `GridSize`/`SnapSettings`) and `MenuBarIcon` (two families: `bandit.*` raw
  values name a drawn `BanditGlyph`, everything else *is* an SF Symbol name; an
  unknown one decodes to `.fallback`, which is a drawn glyph so it can never
  fail to resolve; the default is the cactus), Codable with lenient decoding
  (config is hand-editable). `hideMenuBarIcon` and `launchAtLogin` (default on)
  live here too.
  `GridSize` also owns the cell↔rect math shared by LayoutEngine, SnapManager,
  and the settings editor (rects are AppKit coords; row 0 is the top row).
  **Workspaces live inside a `DisplayProfile`**, not at the top level, and
  **a workspace holds one `DisplayGrid` per display** (`grids`, keyed by
  `DisplayRef.key`) — that's what lets one workspace put some apps on the big
  monitor and others on the laptop. `grids` is sparse: a display nobody has
  laid anything out on has no entry. An app belongs to one display at a time,
  which `place(_:at:on:)` enforces by clearing it from the other grids;
  `placements(of:)` still returns a list because a migration or a hand-edit can
  put one app on several, and LayoutEngine resolves that per window.
  `rebindGrids(to:)` moves a workspace's grids onto a different set of displays
  (i-th grid → i-th display, extra displays get a copy of the first, extra
  grids merge into the last) — it's how migration, profile adoption, cloning
  and Displays-tab binding all avoid dropping a placement; `DisplayProfile.bind(to:)`
  is the profile-level wrapper and should be preferred over assigning
  `displays` directly.
  The key-modification types live here too — `ModifierSet` (encoded as names,
  `"hyper"` accepted as shorthand for all four), `KeyRef` (a key by its
  `HIDKeys` name, resolved on use so an unknown name disables one mapping
  instead of breaking the decode), `KeyMapping`, `KeyChord`, `KeyboardRef` and
  `KeyboardProfile`. A `KeyChord` rewrites one key-plus-modifiers into another
  (or into nothing, which is how a combination gets *disabled*). They live in
  two places for a reason: inside `KeyMapping.chords` they're the layer a hold
  opens and are device-scoped for free, because the hold gating them is;
  in `Config.chords` they're global and honestly so, since a plain keypress
  carries no device identity an event tap can read. `ModifierSet.function`
  (`fn`) is send-only — it can emit fn+F11 but is never matched on, because the
  laptop keyboard raises it on its own in ways that would make an exact match
  unpredictable. `KeyboardProfile.modifiedAt` is rounded to whole seconds
  because that's all the ISO-8601 the config is written in can hold; without it
  a profile stops being equal to itself once saved, and `removeDuplicates` would
  see a change on every reload.
  `Config.currentVersion` is 4. Decoding *is* the migration: a v1 file (flat
  `workspaces`) becomes a single *unbound* profile, which the first detection
  run adopts onto whatever displays are attached; a v2 workspace's single
  `gridColumns`/`gridRows`/`layout` becomes one unbound `DisplayGrid`, which
  `DisplayProfile.init(from:)` hands to *every* display in the setup (copying
  beats guessing which monitor was meant — the user deletes what doesn't
  belong). A v3 file simply has no `keyboards`, which decodes to none.
  `version` is normalised in memory and the legacy keys are dropped on
  the next write.
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
  All permission-free. `screensByKey()`/`storedKey(for:)` are the reverse
  lookup — how a stored `DisplayGrid` finds the monitor it was drawn for, using
  the same "#n" suffixing as `snapshot()`.
- `ConfigStore.swift` — ObservableObject; JSON at
  `~/.config/tilebandit/config.json`; debounced autosave (dates ISO-8601, so a
  keyboard profile's `modifiedAt` reads as a date in the file). Also holds the
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
  the first app). Both the hide and the unhide are issued *unconditionally*,
  never gated on `NSRunningApplication.isHidden`: that property is a cache
  AppKit refreshes asynchronously, so an app the user brought back by a route
  we never hear about (a notification banner, the Dock, Mission Control) can
  still read `isHidden == true` and get skipped — it then sits over the grid
  through switch after switch. Redundant hide/unhide calls are no-ops.
  `switchToNext()`/`switchToPrevious()` cycle in config order
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
  Focus can also drive a switch (config `followFocusedApp`, default on):
  every activation restarts a 0.2s timer, and `followFocus` then switches to
  the workspace owning whatever is *frontmost at that point* — Cmd-Tab /
  Spotlight / a Dock click unhide the app anyway, so the workspace comes along
  rather than one window sitting stranded over the current one. Deciding on
  the settled frontmost app instead of on the notification is what makes it
  reliable: hiding apps hands focus around, so a switch arrives as a burst of
  activations (coalesced into one check, which then sees our own focusApp's
  app and does nothing), and an app unhidden by Cmd-Tab can still report
  `isHidden` at the moment it activates. Floating apps never pull you away.
  With no active workspace (fresh launch, or a profile adoption that landed
  nowhere) follow-focus only fires when the app is in exactly one workspace —
  in several it's ambiguous, so it stays put instead of picking config order.
  The app is written into `lastFocusedApp` before switching so focus lands
  on what the user reached for, not on that workspace's previous focus.
  `hideUnassignedApps()` is the cleanup action (default hotkey ⌥0, menu item,
  and runs at launch): hides everything outside the active workspace, or outside
  all of the live profile's workspaces when none is active — "assigned" means
  assigned in the setup you're plugged into. No-op when the profile has no
  workspaces, so a fresh install (or a just-created profile) doesn't blank the
  screen.
- `LayoutEngine.swift` — the AX-based tiling (the one part needing the
  Accessibility permission): `AccessibilityPermission` + `AX` helpers
  (AXUIElement window enumeration, frame get/set, top-left↔bottom-left
  coordinate flip) and `LayoutEngine.apply(workspace)`, which **moves** each
  laid-out app's standard windows to the display it's placed on and sizes them
  to their `GridRegion` there. This is the only thing that moves a window
  between screens; it runs only from the Apply Grid Layout hotkey (default ⌥L)
  or menu item. `target(for:placements:screens:)` picks the display: the one
  the window is already on if the app is placed there (only happens with an
  app on several grids), else the first placement whose display is attached,
  else — nothing attached matches, e.g. a profile forced from the menu for a
  desk you aren't at — the window's current screen, so the action tiles
  something rather than appearing broken.
  Also home to `MaximizeHold` (hold ⌥M by default): press fills the focused
  window's screen `visibleFrame`, release restores the saved frame. A peek,
  not a layout change — nothing is written to the config. No menu item (a
  menu can't express "while held"). AppDelegate calls `end()` whenever it
  tears hotkeys down (config change, shortcut recording), because the Carbon
  released event dies with the registration and the window would otherwise
  stay stuck maximized. `stick(on:)` is the sticky sibling (⌥⇧M, and the
  one of the two with a menu item): maximize and leave it — it drops the saved
  frame first, so it also *commits* a live peek rather than fighting its
  release. The optional app is for that menu item, which runs after the menu
  has closed and so can't ask who's frontmost itself; a hotkey passes nothing
  and asks in the moment.
- `SnapManager.swift` — bentobox drag-snap: *global mouse* NSEvent monitors
  (mouse monitors are permission-free; global *key* monitors would need
  Accessibility) watch drags; holding the configured modifiers (default ⌃⌥)
  while dragging a window shows a `GridOverlayWindow` and the window snaps to
  the highlighted cells on release. The highlight is the *single cell under the
  cursor*; spanning needs the span modifier held too (`SnapSettings.spanModifier`
  — the first of ⇧⌘⌃⌥ the snap combo hasn't claimed, so ⇧ by default), and the
  span anchors where that modifier went down. Anchoring at the drag *start*
  instead — the original design — meant any move across a cell boundary spanned
  two cells and a single cell was unreachable. Arms only
  after the window's AX position actually changes, so modifier-drags inside
  window content (e.g. ⌥-select in a terminal) never snap. Uses the active
  workspace's grid *for the display being dragged on*, re-read when the drag
  crosses onto another screen; a display with no grid falls back to the
  `SnapSettings` dims. The key lookup walks the attached screens, so it happens
  on engage and screen-crossing only, never per mouse event.
- `HotkeyManager.swift` — Carbon `RegisterEventHotKey` (chosen over
  CGEventTap/NSEvent monitors specifically because it needs no permission).
  Handles `kEventHotKeyReleased` too: `register(_:pressed:released:)` is the
  hold-style variant (MaximizeHold uses it); Carbon fires released when the
  combo breaks whichever of the key or modifier goes up first.
  Refuses shortcuts without modifiers. `keyCodes` is the whole supported key
  set — 0-9, a-z plus common punctuation (`,` is there so ⌥, can be the
  Settings shortcut, matching the macOS convention); KeyDebugger's verdict and
  ShortcutRecorder's accepted keys both derive from it.
- `KeyDebugger.swift` — key-press debugger, shown on the Key Modifications tab
  (it started on Shortcuts, and moved once key modifications existed: "what key
  is this, really?" is the question you ask right before remapping one, and far
  less often about a hotkey). Uses a *local* NSEvent monitor (permission-free;
  a global monitor would need Accessibility). Listens only while it's being
  looked at: leaving the tab (`debuggerTabVisible` going false) or the settings
  window resigning key (closed, minimised, another app in front — AppDelegate
  observes it) stops it. The window is kept alive after closing, so a monitor
  left to the Stop button could stay armed indefinitely. Consumes keyDown events only while its own tab is visible
  (`debuggerTabVisible`) — and never when the first responder is an NSTextView,
  since that tab has editable fields and typing has to keep working. Its
  verdict answers two questions at once, because a key can be remappable
  (`HIDKeys`) without being usable as a global shortcut: a bare key is exactly
  that, and telling the user to "add a modifier" would be wrong advice next to
  the remapping editor. Hotkeys stay registered while it runs — the hotkey
  handlers report firings via `recordHotkeyFired` since Carbon consumes those
  events before NSEvent monitors see them. Passes events through untouched
  while ShortcutRecorder is capturing (`shouldPassThrough`).
- `ShortcutRecorder.swift` — captures the next key combo for the "Reassign"
  buttons in Settings, via a *local* NSEvent monitor (permission-free).
  While recording, AppDelegate unregisters all Carbon hotkeys (a registered
  combo would otherwise be consumed before the monitor sees it) and
  re-registers when recording ends; closing the settings window cancels a
  live recording so hotkeys can't stay unregistered. Keys resolve via
  `HotkeyManager.keyNames` (keyCode → name) so shifted/optioned characters
  record correctly.
- `HIDKeys.swift` — the supported key set as one table, in the three
  vocabularies this app has to speak at once: a hand-editable name for the
  config, a HID usage (page 0x07) for hidutil, and a virtual keycode for the
  event tap. Lookups are lenient on the name (`caps_lock`, `CapsLock` and
  `caps lock` all land on the same key) since the config is hand-edited.
  `carrierPool` is the F13–F20 block, handed out to dual-role mappings — see
  KeyRemapper for why that indirection exists.
- `Keyboards.swift` — keyboard detection, the KeyboardRef half of what
  DisplayProfiles does for screens. `KeyboardIdentity` reads the IOKit registry
  (properties only — *opening* a HID device would prompt for Input Monitoring,
  so nothing here does) and fingerprints each keyboard as
  `hid:vendor-product[-serial]`, or `builtin`. Deliberately *not* "#n"-suffixed
  the way displays are: one physical keyboard often publishes several HID
  services and they must collapse to one entry, at the cost of two identical
  serial-less keyboards looking like one — hidutil couldn't tell them apart
  either. Devices with no `Transport` are skipped, which is what filters out
  driver-provided virtual keyboards (Karabiner's and the like).
  `isKeyboard()` checks `DeviceUsagePairs` as well as the primary usage, and
  that second half is not belt-and-braces: a composite board publishes one
  interface carrying several top-level collections, so a Dygma Raise arrives
  with a *primary* usage of 12:1 (consumer) and its keyboard only named in the
  pairs. Reading the registry by `PrimaryUsage` alone — `ioreg | grep
  '"PrimaryUsage" = 6'`, say — concludes such a keyboard isn't one at all.
  `matchingJSON(for:)` builds hidutil's `--matching` dictionary: vendor plus
  product, deliberately *without* a usage filter, because a keyboard whose
  keyboard interface is currently seized by another driver publishes no
  keyboard-usage service and a filtered matcher would silently select nothing;
  landing on the device's other interfaces is harmless, since a UserKeyMapping
  only rewrites keyboard-page usages — harmless, but *silent*, which is what
  `unreachable(from:)` exists to fix. Being seized and being unplugged look
  identical from the config's side, and they are not: the seized one is handed a
  matcher that still selects its mouse and consumer interfaces, so hidutil
  writes the mapping there and exits 0 while no key is ever rewritten. Diffing
  the keyboard walk (`snapshot()`) against every HID device present
  (`presentDeviceKeys()`, the same walk with the usage filter dropped, keyed
  identically so the two are comparable) is what tells them apart; both go
  through `forEachHIDService(keyboardsOnly:)`. `KeyboardManager` keeps the
  answer in `unreachable` and logs it once per change — a rescan fires on every
  plug and on wake — and KeyModificationsTab puts it on screen.
  The built-in keyboard publishes no vendor
  or product id at all, so it falls back to its registry product string — and
  that one *does* need the usage filter, because the trackpad beside it answers
  to the same name. (`BuiltIn` looks like the obvious matcher and isn't:
  hidutil doesn't accept it and silently matches nothing.)
  `KeyboardManager` watches IOKit match/terminate notifications (debounced 0.8s;
  an empty read means the registry is mid-reconfiguration, never "no keyboards")
  plus wake, and files a profile for any keyboard it hasn't seen — cloned from
  the most recently edited one, so a new board inherits the map you've been
  tuning. With no profiles at all it starts empty: a first run must not invent
  remappings. Unlike displays there's no "active" profile to resolve — every
  attached keyboard's map is live at once.
- `KeyRemapper.swift` — the HID half plus the coordinator. `KeyRemapPlan`
  resolves config + attached keyboards into what each engine should be doing;
  computing it in one place is what keeps the halves agreeing, since the carrier
  key hidutil rewrites a dual-role key *to* is the same one the tap watches
  *for*. `KeyRemapper` applies it by shelling out to `/usr/bin/hidutil`, which
  needs no TCC grant and no root, and whose `--matching` filter is what makes a
  mapping per-keyboard. What it writes is decided by reading the service back
  (`liveMapping`, straight off the IOKit registry — permission-free and no
  subprocess), never by remembering what it wrote: a UserKeyMapping lives on the
  HID service, so it dies with an unplug or a reboot, and the Modifier Keys pane,
  another remapper or a second copy of this app quitting will clear it just as
  happily. A cache would go on believing a mapping that is no longer there and
  nothing would ever put it back. `KeyboardIdentity.matchingProperties(for:)` is
  the one predicate behind both halves — the registry walk has to single out
  exactly the services `matchingJSON` sent hidutil at, or the two would disagree
  forever. hidutil is always waited on, including off the main thread: an exit
  status nobody reads is how a mapping fails to apply in silence.
  `KeyRemapPlan.chord(for:flags:layers:)` is where chord *selection* lives —
  a pure decision kept next to the plan that defines it rather than
  reimplemented on the key path — and a held layer beats a global chord, being
  the more specific statement. `CapsLock.turnOff()` lives here too: caps lock
  is the one key whose effect outlives the press, so remapping it away strands
  whatever state it was left in — log in with caps on and there's nothing left
  to press it off with. `KeyRemapPlan.capsLockUnreachable` is what asks for it
  (caps lock's key taken away and nothing else emitting caps lock — a mapping
  or chord that still *sends* caps lock leaves a way back), and `KeyModEngine`
  acts on it on *every* apply, not just when the plan changes: the state is set
  by the world, and launch / rescan / wake / config edit are the only moments
  we're reliably looking. Permission-free like the rest — IOHIDSystem's
  parameter connection needs no TCC grant and no root. `KeyModEngine` is the
  one switch over both engines; `shutDown()` leaves no trace.
- `DualRoleTap.swift` — the userspace half: keys that mean one thing tapped and
  another held. A `CGEventTap` at `.cghidEventTap` rewrites events before
  anything else sees them, including the WindowServer's hotkey dispatch, so a
  hold-modifier combo can still fire a Carbon hotkey. It never has to ask which
  keyboard an event came from — a CGEvent can't answer that, which is the usual
  reason this kind of thing needs a kernel driver — because hidutil has already
  rewritten the real key to a per-device carrier, so the carrier *is* the answer.
  Modifiers are OR'd onto events passing through while a carrier is down rather
  than synthesized as flagsChanged: an injected modifier that missed its release
  would leave the machine stuck, and nothing reads modifier state except through
  these events. A key's keyUp is stamped with whatever its keyDown got, so
  letting the carrier go first can't leave an app holding a phantom key.
  Pressing another key settles "this was a hold" immediately; the timer only
  decides what a lone press-and-release meant. A chord match short-circuits all
  of that: the original key is swallowed and a replacement posted in its place,
  a half at a time — down on the trigger's down, up on its up — so holding a
  chord holds the replacement and auto-repeat repeats it. What a key was
  rewritten *to* is remembered from its keyDown so the keyUp matches even if the
  layer key was released first. Re-enables itself on `tapDisabledByTimeout`,
  which macOS fires if the tap ever blocks.
- `SettingsView.swift` — SwiftUI settings hosted in an NSWindow
  (NSHostingController), under a poster strip (`SettingsHeader`: the app icon,
  the name in Copperplate, the version) — the one window with room for the
  thing to have a face. Tabs: Workspaces, Shortcuts, Displays, Key
  Modifications, Floating Apps, General (launch at login; the show/hide
  switches; an icon grid over `MenuBarIcon.available` split by family with a
  heading each; a preview that mirrors the same fallback the status item uses —
  it draws the same flattened `NSImage`s the menu does rather than
  `Image(systemName:)`, so drawn glyphs and symbols sit in one grid). The two
  captions under the toggles exist to stop a checkbox lying: one when macOS
  holds the login item off, one naming the ways back in once the status item is
  hidden.
  The follow-focus toggle sits on its own row above the Workspaces tab's
  profile picker — it's global, unlike everything below the picker.
  The Workspaces and Shortcuts tabs are scoped to one display profile via a
  shared `profileID` selection (`ProfileScopePicker`) that follows the attached
  hardware but can be pointed at any profile; `WorkspaceListPane` is keyed by
  `.id(profileID)` so its selection state (and which display's grid is being
  edited) doesn't leak across profiles. `WorkspaceDetail` picks the display
  whose grid is shown — a segmented picker with 2+ displays, a label with one,
  and the unbound grid when the profile is bound to none — tracked as a *key*
  rather than an index so a profile gaining or losing a monitor can't point it
  at the wrong grid.
  The Displays tab shows what's attached (with the keys detection uses), which
  profile matched, and per-profile rename / duplicate / bind-to-attached /
  delete. Binding a profile unbinds any other holding the same fingerprint —
  two claimants would make matching a coin flip.
  `GridLayoutEditor` edits one display's grid and is drag-based: drag an app
  chip onto the grid to place it (internal DnD — the dragged bundleId is
  stashed in view state, no async NSItemProvider decoding), drag a tile to
  move, drag its corner handle to span cells, ✕ removes. Chips cover every app
  not on *this* grid, dimmed and labelled with the other display when the app
  sits on one, so moving an app between monitors is a single drag. A second
  row badges the apps already *on* the grid: tiles may overlap (two apps can
  share cells, and a hand-edit can stack them exactly), and in a ZStack the
  last one drawn takes every click — so clicking a badge raises that app's
  tile with `zIndex`, which is the only way to reach one another tile covers,
  and the only way to get at its ✕ and resize dot. The pick is held as a
  bundle id and re-validated against the grid on read (`selection`), because
  the app can leave it — removed, dragged to another monitor, or the display
  picker switched — while this view and its state live on. Grids are
  materialised on first write (the steppers' binding), which is why an
  untouched display stays out of the config. `ShortcutField` shows the current combo as text
  with Reassign (records via ShortcutRecorder) and clear buttons.
- `KeyModificationsTab.swift` — the settings UI for the key-modification
  engine, in its own file because that feature already owns four others.
  Scoped to one keyboard at a time by a picker that opens on whichever is
  actually plugged in. `refreshDevices()` reads both halves of the hardware
  picture together — what's attached, and what's present but has no keyboard
  interface (`KeyboardIdentity.unreachable(from:)`) — because the second is the
  only warning this feature gets about a mapping that reaches nothing; without
  it the keyboard just reads as not connected. The by-id bindings stamp
  `modifiedAt` on every write,
  since "a new keyboard starts from the last edited keymaps" is exactly what
  that field means. The master toggle sits *outside* the region it disables —
  SwiftUI's `.disabled` is additive, so an inner `.disabled(false)` can't undo
  an outer one, and the switch would have had no way back on. Keys are chosen
  from a grouped popup rather than by pressing them: once a mapping is live the
  physical key no longer reports itself (caps lock already arrives as F18), so
  recording would capture the carrier. A hold's chords hang off the mapping
  behind an explicit chevron button — DisclosureGroup's own chevron is
  invisible against a List row here. The KeyDebugger box sits at the top,
  outside the disabled region, since a diagnostic is most wanted exactly when
  the modifications are switched off. Deleting the profile of a keyboard that's
  *attached* is futile (the next scan files it again, cloned from whatever was
  edited last), so that menu offers Clear Mappings instead.

## Conventions

- Zero third-party dependencies; keep it that way unless there's a strong reason.
- Display detection stays permission-free: NSScreen plus the `CGDisplay*`
  metadata functions need no TCC grant, and `didChangeScreenParametersNotification`
  is an ordinary notification. Don't reach for IOKit/EDID parsing for nicer
  display names — the profile name is user-editable, which is cheaper.
- Key modifications are split across two engines by what they need. A plain 1:1
  remap goes through hidutil at the HID layer: permission-free, and *below*
  secure input, so it keeps working in password fields. Only a dual-role key
  (tap one thing, hold another) or a chord needs the event tap — so a config
  with nothing but remaps never creates one, and never needs a grant. The tap is inert inside
  secure input, which is the price of it.
- Tiling (LayoutEngine/SnapManager's AX calls) and dual-role keys
  (DualRoleTap) need the Accessibility permission; everything else must stay
  permission-free. TCC ties the grant to
  the code signature: ad-hoc re-signing (`make app`) resets it on every
  rebuild — pass `CODESIGN_ID="Apple Development: … (TEAMID)"` for a stable
  grant. For dev, processes launched from a terminal are TCC-attributed to the
  terminal app, so granting Accessibility to the terminal once keeps
  `swift run` builds trusted across rebuilds.
