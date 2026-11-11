# Audit: the previous workspace's window stays up after a switch

2026-11-10. Tile Bandit 1.5.0 (`dbbaa11`), the copy installed in /Applications,
on macOS 27.2. Nothing was changed in the code; this is the audit only.

## Summary

The reported symptom was captured on the owner's own switches and has one
confirmed cause, which is in what a switch chooses to focus, not in the hiding.

**At the end of a switch, Tile Bandit brings the workspace's last-focused app to
the front. When that app also belongs to the workspace being left and is the
one already in front, the switch changes nothing you can see.** Its window was
never hidden (an app in both workspaces is left alone on purpose), it is put in
front again, and the new workspace's other windows come back behind it.

At 22:01:15 the owner switched workspaces 16 times in ten seconds on a setup
where Chrome is in all three workspaces. Every one of the 16 hid and showed
exactly the right apps, and every one of the 16 then put Chrome in front.

The rest of the audit found one more mechanism that is real and measured (an
app that is busy keeps its window until it is free, and nothing checks
afterwards), several that are plausible but were not caught happening, and a
few places where a failure leaves no trace. They are ranked below.

## How the evidence was gathered

Three sources, all read-only towards the owner's windows:

- **The system log.** macOS itself records each "bring to front" request Tile
  Bandit makes (`SLSSetFrontProcessWithInfo`), the window server accepting it,
  and each app carrying out a hide or a show (`DoHide(self)`, `DoShow(self)`).
  Read with `log show --info --debug`.
- **A passive observer** written for this audit: a background process that
  listens to app activate, hide, unhide, launch and quit notifications and, at
  each one, records which app is in front and which apps actually own a window
  on screen. It ran from 22:05 to 22:14 and saw five more real switches.
- **One experiment**, with a helper process of its own and no one else's
  windows: a window made invisible and click-through, hidden and shown through
  the same call Tile Bandit uses, while the helper was idle, while its main
  thread was blocked, and while it ran a modal dialog.

Not done, because the owner was at the keyboard and it would have been
noticed: anything that changes which app has focus, anything in full screen,
and running a debug build of the engine (its first act is to hide every app
outside the workspace). The scratch files are deleted.

## What a switch is

Needed to read the findings. A Tile Bandit workspace is a list of apps, not a
macOS Space and not a list of windows. `WorkspaceEngine.switchTo`
(`Sources/TileBandit/WorkspaceEngine.swift:75-106`) does three things, all at
once and all without waiting for an answer:

1. asks every app of the target workspace to unhide (lines 82-91);
2. asks every other ordinary app to hide, except floating apps (line 96);
3. brings one app of the target workspace to the front: the one remembered as
   last focused there, else the first one running (line 100, `focusApp`,
   lines 277-293).

It then records the new workspace as active (line 102).

So several things the brief asks about do not exist here: no window ids are
kept, so none can go stale; no Accessibility call is part of a switch (those
are only in the grid layout, see finding 9); nothing is per display or per
Space. That is also the limit of the design: Tile Bandit cannot hide one
window of an app and keep another.

## Findings, most likely cause first

### 1. The switch focuses the app that is already in front (confirmed)

**Where.** `WorkspaceEngine.swift:277-293` (`focusApp` puts the remembered app
first), `:185-193` (`recordActivation` remembers any app of the active
workspace that comes to the front, shared or not), `:93-96` (an app in both
workspaces is never hidden).

**What goes wrong.** Take Chrome in workspaces M and C. You read something in
Chrome while in C, so C remembers Chrome. You do the same in M, so M remembers
Chrome. From then on, switching between them with Chrome in front does this:
the other apps are swapped behind it, and Chrome is brought to the front,
where it already was. If Chrome's window covers the others, the screen does not
change at all. Only the name in the menu bar does.

It is intermittent because the memory follows the last click. Click Kururu
while in C and the next switch to C lands on Kururu and looks right; click
Chrome there and it looks broken again.

**Evidence.** The owner's 16 switches between 22:01:15 and 22:01:25, on the
setup with the laptop and an AirPlay display, where M is Chrome, WhatsApp and
Discord, C is Yaak, Kururu and Chrome, and a third workspace is Chrome alone:

| | Switch to | Apps shown | Apps hidden (that had been visible) | Brought to front |
|---|---|---|---|---|
| 1 | M | Chrome, WhatsApp, Discord | Kururu | Chrome |
| 2 | Chrome | Chrome | Kururu, WhatsApp, Discord | Chrome |
| 3 | M | Chrome, WhatsApp, Discord | Kururu | Chrome |
| 4 | C | Kururu, Chrome | WhatsApp, Discord | Chrome |
| 5 | Chrome | Chrome | WhatsApp, Discord, Kururu | Chrome |
| 6-16 | the same three, in turn | correct every time | correct every time | Chrome, 11 of 11 |

The window server accepted all 16 requests ("new foreground connection …
com.google.chrome"). Row 4 is the telling one: Kururu was running and had just
been shown, yet Chrome was focused, so C's memory said Chrome.

A minute later the owner had typed in Kururu, and the observer saw the next
switches behave: 22:11:33 to C focused Kururu and the screen went from Chrome,
WhatsApp and Discord to Chrome and Kururu; 22:13:09 to the Chrome workspace
left Chrome alone on screen; 22:13:12 back to C focused Kururu again.

How common this is: every display setup in the owner's config but one has an
app in more than one workspace (Chrome, Arc or Obsidian). Only the laptop on
its own has none.

**To confirm it yourself.** In a setup with Chrome in two workspaces, click
Chrome in each, then switch between them: nothing moves. Click another app in
one of them and switch away and back: now it works.

**Proposed fix.** Keep, per workspace, the apps in the order they were last
used, not only the last one. When choosing what to focus, skip the app that is
in front right now if the target workspace has another app running, and take
the next most recent. A switch then always changes what is in front when the
workspace has something of its own to show, and a workspace with only the
shared app still lands on it. About 20 lines in `recordActivation` and
`focusApp`.

Two details to fix with it:

- `recordActivation` credits an activation to whichever workspace is active
  when the notification is *delivered* (line 190). Notifications lag the
  request by 40 to 55 ms (measured: request 22:11:33.840, notification
  33.895), so an activation that belongs to the workspace just left can be
  credited to the new one when the app is in both. Rare by hand, possible when
  cycling fast. Ignore activations for a short moment after a switch, except
  the one the switch asked for.
- This is a choice for the owner, see "Decisions" at the end.

### 2. The new workspace's other windows come back behind what stayed (expected, not measured)

**Where.** `WorkspaceEngine.swift:82-91` (unhide) and `:288-292` (`activate()`).

**What goes wrong.** Unhiding an app does not raise it: its windows return
where they were in the stacking order, behind the app in front. Only one app is
then brought forward, and on macOS 14 and later `activate()` with no options
raises only that app's main window, not all of them. So after a switch the
order is: the focused app's main window, then whatever was in front before and
was not hidden (a shared app, a floating app, an app that is in no workspace),
then the rest of the new workspace. A window of the old workspace's shared app
can sit on top of the new workspace's second app, and on top of the focused
app's second window.

**Evidence.** At 22:10:04 Discord was shown and never activated; that part is
certain. The observer did not record stacking order, so the order itself is
from how unhide is documented to work, not from a measurement.

**To confirm.** Add the logging in "Logging to add" (it lists on-screen windows
front to back after each switch), or: two workspaces sharing a large Chrome
window, the target with two other apps; switch and see whether the second app
is under Chrome.

**Proposed fix.** Activate with `.activateAllWindows`. Then decide whether a
switch should also raise the workspace's other apps above what stayed
(activate each of them in reverse order of last use, the focus target last).
That costs a burst of activations, which the fix in finding 4 has to ignore.

### 3. A busy app keeps its window until it is free, and nothing checks afterwards (mechanism confirmed)

**Where.** `WorkspaceEngine.swift:265-273` (`hideApps`: one `hide()` per app,
result dropped at line 271) and `:89` (`unhide()`, the same). Nothing looks at
the screen again after `switchTo` returns.

**What goes wrong.** Hiding is done by the app itself, on its main thread. The
log shows each app running its own `DoHide(self)`. An app that is busy at that
instant (a browser under load, an Electron app in a long task, Xcode indexing)
keeps its windows up until it gets to the request. An app that never gets to
it, or drops it, stays up until the next switch, because the request is sent
once.

**Evidence.** The experiment, same call, same machine:

| Helper's state | Window gone after |
|---|---|
| idle | 44 ms |
| main thread blocked for 4 s (hide asked 0.3 s in) | 3,717 ms, the moment it was free |
| inside a modal dialog | 22 ms |

In the owner's 16 switches every real app hid within 45 ms, so this did not
cause that episode. It is the likeliest cause on the laptop-only setup, which
has no shared app.

Two more facts from the experiment: `hide()` returned `false` every time,
including when it worked, so its result cannot be used to detect a failure on
this macOS; and it does nothing at all for an app with no Dock icon (accessory
apps), which Tile Bandit rightly never asks.

**To confirm.** With the logging below, a line "LEFTOVER" after a switch names
any app outside the workspace that still has a window on screen 0.3 s and 1 s
later.

**Proposed fix.** After each switch, check twice (about 0.3 s and 1 s later):
any ordinary app outside the workspace that is not hidden, or still owns an
on-screen window (`CGWindowListCopyWindowInfo`, which needs no permission), is
asked to hide again and logged. Cancel the check when another switch starts.

### 4. Follow-focus can undo or redirect a switch (plausible, not caught)

**Where.** `WorkspaceEngine.swift:200-243`. `switchTo` (line 75) does not
cancel a pending check.

**What goes wrong.** Every activation arms a timer; 0.2 s after the last one,
`followFocus` reads the app in front and, if it belongs to another workspace,
switches there. Three ways this fights a switch you asked for:

- **A check armed before the switch fires after it.** You bring an app to the
  front and press a workspace hotkey within 0.2 s. The timer from the first
  activation is still running. It is normally restarted by the activation the
  switch causes, but that notification takes 40 to 55 ms to arrive. If the
  timer fires in that gap and `NSWorkspace.frontmostApplication` still names
  the old app, the engine switches straight back to the workspace you left.
  Whether that value can be stale in the gap is the open question; the logging
  below settles it.
- **An app that brings itself to the front.** A development build that
  restarts on every rebuild, an app that comes forward for a call or a
  finished download. It is in another workspace, so the workspace follows it.
  This is the feature working as written, and from the chair it is "it
  switched back on its own".
- **A target workspace with nothing running** (`focusApp` returns at line 287
  without focusing anything). The app in front was just told to hide, macOS
  picks the next app itself, and if that one belongs to a third workspace and
  is slow to hide (finding 3), follow-focus goes there.

Also at line 237: an app in several workspaces, none of them active, sends you
to the first in config order, not the one used last.

**Evidence.** None of the three was caught. What was caught is the feature
working: at 22:10:04 WhatsApp was brought forward by hand from the Chrome
workspace and Tile Bandit switched to M about 0.15 s later.

**Proposed fix.** Cancel the pending check at the top of `switchTo`. Count
switches, have each check remember the count when it was armed, and when a
switch has happened since, arm again instead of acting. That removes the first
case entirely and costs nothing. For the second, a setting per app ("never
pulls the workspace") is the owner's call.

### 5. Apps a switch never hides

**Where and what.**

- `WorkspaceEngine.swift:267`: an app with no bundle identifier is skipped by
  `hideApps`. That is any window-owning program started from a terminal
  without an app bundle: a `swift run` build, a Python or Java window. It
  stays up through every switch. The audit's own helper was such an app and
  showed up in the running list as an ordinary app with no identifier.
  **Fix:** hide by process, not by identifier: every ordinary app that is not
  Tile Bandit and not in the allowed set, identifier or not.
- An app in no workspace that is launched or brought forward after the switch
  stays until the next switch or ⌥0. Captured at 22:11:41: an unassigned app
  was opened in C and stayed on screen with it. This is by design (you opened
  it), listed so it is not mistaken for the bug. Follow-focus ignores such
  apps (`:227-237`).
- `WorkspaceEngine.swift:247-249`: apps with no Dock icon are never asked.
  Correct, since macOS refuses to hide them anyway (measured: `hide()` did
  nothing). Picture-in-picture video is one of these.

### 6. Full screen and Spaces (not tested)

**Where.** The whole of `switchTo`; nothing in it knows about Spaces.

**What may go wrong.** A window in native full screen lives in a Space of its
own. Whether asking its app to hide takes you out of that Space, or leaves you
looking at it, was not tested, because a full-screen transition on the owner's
screen would have been noticed. Likewise a workspace whose focused app has its
windows on another desktop: whether macOS follows it there depends on the
"switch to a Space with open windows" setting, and the engine does not know
which happened.

**To confirm.** With an app of workspace M in full screen and in front, press
the hotkey for C. If the full-screen window stays, this is a cause. The same
with the observer running gives the timeline.

**Proposed fix.** Depends on the result. If hide is ignored in full screen, the
permission-free option is to detect it afterwards (finding 3's check) and say
so in the menu; leaving full screen for the user needs Accessibility.

### 7. Display changes, sleep and wake

**Where.** `DisplayProfiles.swift:136-213`, `WorkspaceEngine.swift:112-129`
(`adoptProfile`), `AppDelegate.swift:40-44`.

**What goes wrong.**

- **A placeholder display is taken for a real setup.** The config holds a
  setup with an empty name, bound to the display key
  `edid:1970170734-1986622068-0`. Those two numbers are the ASCII for `unkn`
  and `virt`: the stand-in macOS reports when no real display is available
  (lid closed and the monitor asleep or gone). The guard at line 167 only
  rejects *zero* displays, so the stand-in became a setup: Tile Bandit cloned
  the workspaces into it (lines 193-208), switched to one of them, hiding and
  showing apps while the screen was off, and does so again each time the
  stand-in returns. On wake it adopts the real setup and switches again.
- Each adoption runs a full switch (`adoptProfile` → `switchTo`), which takes
  focus on wake, possibly behind the lock screen, where the focus request can
  be ignored. Nothing listens for wake to put the workspace back afterwards;
  only the keyboard code observes `didWakeNotification` (`Keyboards.swift:297`).
- A display whose identity changes between sessions gets a new setup each time,
  with new workspace ids, so the focus memory for it starts empty.

**Evidence.** The phantom setup in the config. The Mac did not sleep during the
observation, so no wake was captured. The end state after a wake should be
consistent (the last adoption wins); this is a cause of windows changing "by
themselves", less of the reported symptom.

**Proposed fix.** In `resolve()`, ignore a snapshot made only of placeholder
displays (vendor `unkn`, model `virt`, or `CGDisplayIsAsleep`), as an empty one
already is, and remove the phantom setup once. On `didWakeNotification`, run
the check from finding 3 instead of a blind switch.

### 8. Relaunch, update and quit

**Where.** `AppDelegate.swift:95-100`, `:129-134`; `WorkspaceEngine.swift:28,
32, 38` (all memory is in the process).

**What goes wrong.** After a relaunch (an update, a crash, a login) no
workspace is active: the first adoption finds no memory and lands nowhere, and
`hideUnassignedApps()` then keeps the apps of *every* workspace visible. What
the previous run had hidden stays hidden; what it showed stays shown; the menu
bar shows no name; next and previous start from the first workspace; all focus
memory is gone, so the first switches fall back to "first app in the list".
Quitting unhides nothing, so hidden apps stay hidden with nothing managing
them.

It does not by itself leave a previous workspace's window up: the first hotkey
puts everything right.

**Proposed fix.** Save the active workspace id per setup (a small state file
next to the config, not the config) and re-apply it at launch. Decide whether
quitting should show everything again.

### 9. Failures that leave no trace

None of these was seen failing; each would be invisible if it did.

| Where | What is dropped |
|---|---|
| `WorkspaceEngine.swift:89, 271, 289-291` | The results of `unhide()`, `hide()` and `activate()`. (`hide()`'s result is useless on this macOS, see finding 3, so checking the screen is the only way.) |
| `WorkspaceEngine.swift:76` | A switch to a workspace id that no longer exists returns silently. A hotkey holds the id it was registered with for up to 0.3 s after a config change (`AppDelegate.swift:78-82`). |
| `WorkspaceEngine.swift:283-287` | A workspace with nothing running focuses nothing and says nothing. |
| `WorkspaceEngine.swift:302` | `openApplication` has no completion handler: a launch that fails is silent, and an app that does launch is not focused when it is ready. |
| `AppDelegate.swift:145-215` | Every `hotkeys.register(...)` result is discarded. A combination macOS refuses (already taken, or used twice in the config) is a hotkey that does nothing. `HotkeyManager.swift:34` ignores `InstallEventHandler`'s status as well. |
| `LayoutEngine.swift:147-151, 175-185` | Every Accessibility read and write drops its error, there is no retry, and no timeout is set (`AXUIElementSetMessagingTimeout` is never called). The default wait for an app that does not answer is several seconds per call. |
| `SnapManager.swift:73-95` | Those Accessibility calls run on the main thread from the mouse-drag monitor. While one waits on a frozen app, hotkeys queue up: a switch appears dead, then fires late. Only with the snap modifiers held over a frozen app's window, so rare. |

**Proposed fix.** Log each of these (see below), set a short Accessibility
timeout (0.5 s) on every element before use, and show a hotkey that failed to
register in Settings next to its shortcut.

## Checked and found sound

- **Focus requests being refused.** Newer macOS can refuse a background app
  that tries to bring another app forward. Not here: the window server
  accepted all 16 requests in the logged episode, and each of the four
  switches watched live ended with its target in front.
- **Fast switching.** 16 switches in ten seconds, as little as 0.37 s apart,
  ended with every app in the right state. Requests to one app are carried out
  in the order sent.
- **The stale `isHidden` flag.** The engine no longer reads it (the comments at
  `:87-88` and `:257-264` explain why). The observer did see the flag lag the
  screen by a fraction of a second, which is harmless now. A side effect: every switch
  also asks the dozen apps that are already hidden to hide again, and each one
  wakes to do nothing.
- **Stale window ids, closed or minimised windows.** No window is tracked, so
  there is nothing to go stale.
- **Hotkeys through remapped keys.** The workspace hotkeys use ⌥, which no key
  modification in the config produces, so the key remapper is not in their
  path.

## Logging to add

One line per event through `os.Logger` (subsystem `com.twonary.TileBandit`,
category `switch`), at the default level so the system keeps it on disk;
info-level lines are held in memory only and were gone within minutes when
read back for this audit. Read with
`log show --last 1h --predicate 'subsystem == "com.twonary.TileBandit"'`.

1. **Switch start**: a running number, what asked for it (hotkey, menu,
   next/previous, follow-focus, display change), from which workspace to
   which, the app in front before, the app chosen to focus and why (remembered
   or first in list), how many apps were asked to show and to hide.
2. **Switch check**, 0.3 s and 1 s later: the app in front; on-screen windows
   front to back by app; `LEFTOVER` with the name of any app outside the
   workspace that still has one. This line settles findings 2, 3 and 6.
3. **Follow-focus**: every time the check runs: the app in front, the active
   workspace, the switch number when it was armed and now, and what it decided.
   This settles finding 4.
4. **Display setups**: each adoption, with the display keys that caused it.
5. **Hotkeys**: each registration that fails, with the combination and the
   status code.

With these in place, the next time a window stays up, the lines around that
minute say which finding it was.

## Decisions for the owner

1. **What should a switch focus when the remembered app is the one already in
   front?** Recommended: the workspace's most recent *other* app (finding 1).
   The alternative is to keep today's behaviour and only make it visible, with
   a brief flash of the workspace name.
2. **Should a switch raise all of the workspace's windows above a shared app's
   window**, or only the focused app (finding 2)?
3. **Should an app that brings itself forward be able to move the workspace**
   (finding 4), or only a deliberate Cmd-Tab, Dock click or hotkey?
4. **On which display setup do you usually see it?** If it is also on the
   laptop alone, where no app is shared, findings 3 to 6 move up, and the
   logging is the next step before any fix.
