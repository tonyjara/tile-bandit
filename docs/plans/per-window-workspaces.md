# Per-window workspaces: assessment and design

2026-11-10. Tile Bandit 1.6.0 (`5117b9c`) on macOS 27.2.

App and workspace names are generic stand-ins: "the browser" is an app with
several windows that belong in different workspaces, "Chat" and "Code" are two
workspaces that both list it.

## Verdict

**Recommended: park the other workspaces' windows in a screen corner through
Accessibility, per app and opt-in. Risk: medium.** It fits beside the app-level
model without changing it: an app that is not opted in takes exactly the code
path it takes in 1.6.0.

The feature is built behind the opt-in (see "Status" at the end). It has not
been run against a real browser, for the same reason 1.6.0's restore was not:
the engine cannot be started on this machine without hiding its owner's apps,
and the shell it was built in has no Accessibility grant. What could be
measured without either was measured, and is marked as such below: the calls
that park a window and bring it back were run, from Tile Bandit's own code,
against the windows of a scratch process.

What you give up, in one place:

- A parked window is not invisible. macOS 27 keeps a sliver of it on screen,
  1 pt wide and 32 pt tall, in a bottom corner of its display (measured).
- The feature needs the Accessibility permission. Without it an opted-in app
  behaves as a whole app, as today.
- A switch moves windows for opted-in apps. "Switching never moves a window"
  stays true for every other app.
- A window is recognised for as long as it stays open. After the app itself
  restarts, its windows are matched again by title and frame, which is a best
  effort and is said in the log when it is a guess.

## What was asked

Workspaces are lists of apps, and a switch hides and shows whole apps. An app
listed in two workspaces is never hidden between them, so every one of its
windows is on screen in both. For a browser with one window per task this means
both windows in every workspace; 1.6.0 puts the right one on top but cannot take
the other away. The request: a window of such an app lives in one workspace.

## 1. Hiding one window

macOS has no call that hides one window of another app. Three ways to get the
effect, measured on macOS 27.2 with a helper process and two windows of its own
(Accessibility calls on one's own process need no grant and run AppKit's own
handlers, the same ones another app's call ends up in), on two arrangements: an
external display above the laptop's, and one to its right:

| | Park in a corner | Minimise | Move to another Space |
|---|---|---|---|
| How | Set the window's position through Accessibility | Set `AXMinimized` | Private window-server calls |
| Time to leave the screen | One call, no animation | 533 to 579 ms | not tested |
| Time to come back | One call, no animation | 546 to 659 ms | not tested |
| What stays visible | A sliver of the window, 1 × 32 pt | Nothing, or a Dock tile per window unless "Minimize windows into application icon" is on | Nothing |
| Cmd-` inside the app | Still reaches the parked window | Skips it | Jumps to the other Space |
| Mission Control | Shows it | Does not | Shows it under the other Space |
| Needs | Accessibility | Accessibility | Private API, and on current macOS a way into the Dock process |
| Survives the app quitting | The app saves the parked position | The app saves it minimised | n/a |

**Parking.** macOS will not put a window wholly off screen, and how much it
keeps depends on what is asked:

| Asked for | Where it landed | What stays on the display |
|---|---|---|
| (30000, 30000), far outside | bottom-right corner of the nearest display | 40 pt of its width, 32 pt of its height |
| far to the left | left edge | 40 pt of its width |
| far above | under the menu bar | the whole title bar, so the top is no use |
| one point inside the bottom-right corner | exactly there horizontally, 32 pt up from the bottom | 1 × 32 pt |
| one point inside the bottom-left corner | the same, mirrored | 1 × 32 pt |

There is no error in any of these: AppKit moves the window to the nearest place
it allows, and reading the position back says where that was. So Tile Bandit
asks for one point inside a bottom corner and gets a sliver 1 pt wide and 32 pt
tall, which is the top-left edge of the window's title bar (bottom-right corner)
or its top-right edge (bottom-left). The window stayed there for as long as it
was watched, and through `AXRaise` and `AXMain`. Parked windows of one display
stack on the same spot, so it is one sliver, not one per window. Bringing a
window back is the same call with its old position, and it landed exactly where
it had been, both times.

With several displays the corner has to be chosen: the part of the window that
hangs outside one display must not land on a neighbour, where it would be in
plain view. Both arrangements measured have a free corner on each display (to
the right of the laptop the external display ends higher up, so the laptop's
bottom-right corner hangs below it). Two displays side by side with their bottom
edges level leave only the outer corners free, and the code picks those.

Not measured: a window moved while its app is hidden (the helper could not be
hidden without first taking focus). The design does not rely on it: the screen
is read back after the switch and a window found in the wrong place is moved
again.

**Minimising.** Reliable and public, and the cleanest result: the window is
gone from the screen, from Cmd-` and from Mission Control. The cost is the
animation, which cannot be switched off per call: about 0.55 s out and 0.55 to
0.65 s back for each window, on every switch. Tile Bandit's reason to exist is
that a switch has no animation, and the 1.6.0 log shows switches 0.37 s apart.
It also has to tell windows it minimised from windows the user minimised, and a
restored window comes back on top and has to be put back in order.

**Spaces.** There is no public call to move another app's window to a Space.
The private ones have been closed step by step since macOS 14.5 and the tools
that still do it inject code into the Dock with System Integrity Protection
partly off. Not an option for a notarised app.

**Choice: parking.** It is the only one that keeps a switch instant, and the
sliver is small enough to live with. Minimising stays possible later as a second
method (the code that moves windows is one type, `WindowScope`).

## 2. Telling windows apart

| Candidate | Stable through new tabs | Stable through an app restart | Needs |
|---|---|---|---|
| Window-server id (`CGWindowID`, the id 1.6.0 uses) | Yes | No, every window gets a new one | Nothing to list; Accessibility to act on one |
| Title | No, it is the front tab's | Usually, if the same tab is in front | Accessibility |
| Frame | Yes | Usually, browsers restore it | Nothing |
| `AXIdentifier` | Yes | Yes where it exists | Browsers set none that tells windows apart |

**While a window is open: its window-server id.** Measured: the private
`_AXUIElementGetWindow` still answers on macOS 27.2 with the same number the
window server lists. 1.6.0 already looks it up by name at run time and falls
back to matching by frame. The id does not change with tabs, titles, moves or
resizes, and it survives Tile Bandit restarting, so the homes are saved to a
small state file (`~/.config/tilebandit/windows.json`) and read again at launch.

**After the app restarts: title and frame, as a guess.** When a per-window app
quits, what Tile Bandit knew about its windows is kept. When windows of that app
appear that it has never seen, each is matched to one remembered window: same
title, same frame, or sitting in a parking corner where a parked one was (the
app saved that position when it quit). A match has to be unambiguous; a window
that matches nothing, or two things equally, is treated as new. The log says
which windows were matched and on what.

**New windows join the workspace they were opened in.** Precisely: a window with
no home is shown wherever its app is shown, and gets its home when the workspace
it is in is left, the same moment 1.6.0 takes its snapshot (and the only place
that writes one). So a new window never disappears under the user's hands, and
there is still exactly one writer.

**Moving a window** is explicit: Move Window to ▸ in the menu, or ⇧ added to a
workspace's own shortcut (⌥2 goes to Code, ⌥⇧2 sends the focused window there).
The window goes; you stay.

A rule in the config ("windows whose title contains … live in Code") would be
the durable answer for windows that carry a profile or project name in their
title. It is left for later, see "Later".

## 3. What it does to the rest of Tile Bandit

**The switch.** One addition, for opted-in apps only, before anything is hidden
or shown: windows that live elsewhere go to the corner, windows that live in the
target come back to where they were. Whether the app itself is shown is decided
as today, by the workspace's app list. An app the target does not list is hidden
whole and its windows are not touched.

**Tiling.** Apply Grid Layout sizes every window of a laid-out app. It skips
windows that live in another workspace, or it would pull them out of the corner.
Drag-snap and maximise act on the window under the cursor or in focus and need
no change.

**Stack restore.** A workspace's snapshot holds only its own windows: parked
ones are left out when it is taken and when it is put back. This is what 1.6.0's
per-window order was reaching for, and it gets simpler, since the other
workspace's browser window is no longer in the stack at all.

**Follow-focus.** Becomes per window for opted-in apps: when the focused window
of the app in front lives in another workspace, the workspace follows it. That
covers Cmd-Tab, Mission Control and a link opened from another app into a
parked window. Cmd-` changes the focused window without
activating anything, so an Accessibility observer watches the focused window of
opted-in apps (and only those). Two guards keep it from fighting a switch: after
parking, the app's main window is set to one that lives here, so Cmd-Tab lands
on it; and for one second after a switch a focused window that lives elsewhere
is answered by putting this workspace's window forward, never by switching back.

**Multiple displays.** The corner is chosen per window: the bottom corner where
the least of it shows on any display, its own display first. A display change
runs a switch, as today, and that parks again with the new geometry. A window
whose remembered place was on a display that is gone comes back centred on the
main one. Not handled: macOS pulling windows back on screen after a wake; the
next switch parks them again.

**Cmd-Tab and the Dock.** Unchanged for the app. The app stays one entry and
shows as running.

**Mission Control.** Shows every window, parked ones included, at full size.
Picking one focuses it, and follow-focus then switches to its workspace.

**Native full screen.** A full-screen window has a Space of its own and cannot be
moved. It is skipped and said in the log, as finding 6 of the 1.6.0 audit.

**Quitting.** Tile Bandit puts every parked window back before it quits, and at
launch, since no workspace is active then. After a crash the windows stay in
their corners until the next launch (the state file says where each one goes
back to). The menu has Bring Parked Windows Back, and without Tile Bandit a
parked window is reached through Mission Control and brought back with the
app's Window ▸ Move & Resize menu.

**The first minutes after opting an app in.** No window has a home yet, so all
of them show wherever the app does, and the first workspace you leave takes all
the ones on screen. Send each window where it belongs first (⌥⇧ and the
workspace's key), or expect the other workspaces to come up without the app's
windows until you do.

**The config.** `perWindowApps`, a list of apps beside `floatingApps`, and
`moveWindowShortcuts` (on). The version goes from 4 to 5; a v4 file has neither
key, which reads as "no app, on". Nothing else in the file changes and workspaces
keep listing apps. Which window lives where is state, not configuration, and is
not in the config.

## 4. Opt-in per app

Per app, off for all by default. Reasons to keep it that way and not switch it
on for "browsers":

- it needs a permission the app-level switch does not;
- it changes what Cmd-` does and leaves a sliver in a corner of the screen;
- single-window apps gain nothing from it, and apps with palettes and inspectors
  (design tools, IDEs with detached panels) would have each panel filed under a
  workspace.

A floating app is never scoped: it is on every workspace by definition.

## Design, as built

| Piece | Where | What |
|---|---|---|
| Which window lives where | `WindowHomes.swift` | Pure, no AppKit: records by window id, claiming, resolving a home in the live display profile (by workspace id, else by name, so the laptop's "Code" lines up with the desk's), matching after an app restart. Covered by tests. |
| Where to park | `WindowHomes.swift`, `Parking` | Pure geometry: which corner, whether a frame is out of sight, where a window comes back when its display is gone. Covered by tests. |
| Moving windows | `WindowScope.swift` | The Accessibility side: reads an app's windows once per switch, parks and shows, reads back where each one landed, keeps the state file, watches focused windows. |
| The switch | `WorkspaceEngine.swift` | Calls the above at four points: leaving (claim), arriving (arrange), the checks after a switch (anything in the wrong place is moved again and logged as `STRAY` or `STILL PARKED`), follow-focus. All behind `scope.isOn`. |
| Layout | `LayoutEngine.swift` | Skips windows that live elsewhere. |
| Settings, menu, shortcuts | `SettingsView.swift`, `StatusMenu.swift`, `AppDelegate.swift` | The list of per-window apps, Move Window to ▸, Bring Parked Windows Back, ⇧ + workspace shortcut. |

`scope.isOn` is false unless at least one app is opted in and the Accessibility
permission is granted. A switch never asks for the permission; Settings does.

The log (`make log`) has a `window` category: what was parked and shown at each
switch, every window claimed and by which workspace, matches after a restart and
what they were matched on, and every move that did not take.

## Risks

| Risk | Likelihood | What limits it |
|---|---|---|
| A real browser handles the position call differently from the helper measured | Low: Chromium, WebKit and Electron windows are AppKit windows | Every move is read back and logged; a window that would not go is said by id. |
| Windows stranded in a corner (crash, permission revoked) | Low | Put back at quit and at launch; the menu item; Mission Control. |
| A new window opened while the app's last used window is parked opens near the corner | Unknown, depends on the app | Not handled. Would show up in step 5 below. |
| A window cannot be moved while its app is hidden | Unknown, could not be measured | The check 0.1 s after the switch parks it then; it would flash once. |
| Follow-focus bouncing between workspaces | Low | One-second hold after a switch; the app's main window is set on arrival. |
| Wrong match after the app restarts | Medium | Only unambiguous matches; the log says what was matched; one shortcut fixes a wrong one. |
| A frozen opted-in app slows a switch | Low | One read per app per switch, each call capped at one second, an app that does not answer is skipped. |
| macOS changes the clamp or drops `_AXUIElementGetWindow` | Unknown | The landing place is read, never assumed; the id has a fallback by frame. |

## Before a release

To try on the real thing, in a build run from source or a release candidate:

1. Opt the browser in (Settings ▸ Apps), with it listed in two workspaces and
   two windows open.
2. In Chat, send one window to Code (⌥⇧ and Code's key). It should leave at
   once, with a sliver left in a bottom corner.
3. Switch between Chat and Code a dozen times, fast. Each should show its own
   window and no other. `make log` should show no `STRAY` and no `STILL PARKED`.
4. Cmd-` in the browser: the workspace should follow to the other window.
5. Open a new window in Code, switch away and back: it should be Code's.
6. Apply Grid Layout in Chat: the parked window must stay parked.
7. Quit and relaunch the browser: both windows should be matched (the log says
   so). Quit Tile Bandit: both windows should be back on screen.
8. Unplug or plug a display with a window parked.

## Later

- Title rules in the config, for windows that name a profile or a project.
- Minimising as a second way to put a window away.
- A window shown in every workspace (pinned), like a floating app but for one
  window.
- A shortcut field per workspace for "send window here", if ⇧ is not enough.
- Checking parked windows after a wake.

## Status

2026-11-10: assessed and built, behind the opt-in, on `master` after 1.6.0. Not
released: no version was cut, and the copy installed through Homebrew is
unchanged.

| | |
|---|---|
| `swift build`, `swift test` | Pass. 64 tests, 46 of them new: homes, matching after a restart, the choice of corner, the config. |
| The Accessibility calls (`AX.ownWindows`, park, read back, bring back, main window, the focused-window observer) | Run from this code against a scratch process's own windows on macOS 27.2. Parked where predicted, came back to the exact frame. |
| The switch itself, against a real browser | Not run. Needs the Accessibility grant and a build the owner starts. The list under "Before a release" is that run. |
| Moving a window while its app is hidden | Not measured. |
