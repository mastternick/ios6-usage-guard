# Usage Guard

A MobileSubstrate tweak for jailbroken 32-bit iOS 6 devices that enforces a
repeating **use / break** cycle:

* 20 minutes of normal phone use,
* then a mandatory 30-minute break with a full-screen lock overlay,
* repeat indefinitely.

Both durations are configurable from a PIN-protected parent panel and from the
**Usage Guard** pane in Settings. The tweak runs inside SpringBoard, so the break
overlay appears above apps, the home screen, notifications and alerts regardless
of what is in the foreground.

## What it looks like

During a break the whole screen is replaced with:

* **Pauză de la telefon!**
* **Mai ai 20 minute până poți folosi telefonul.**
* a large `MM:SS` countdown inside a circular progress ring,
* a red **Apel de urgență 112** button.

Usage time only counts while the screen is on, the device is unlocked, the tweak
is enabled and there is no parent pause. Break time counts in real time, even
with the screen off, and is applied from the wall clock when the device wakes or
SpringBoard restarts.

## Parent access

* During a break, **tap the title seven times within three seconds**.
* Enter the PIN (4–8 digits) on the keypad.
* The panel lets the parent:
  * change the usage duration (1–240 minutes),
  * change the break duration (1–240 minutes),
  * enable/disable the tweak,
  * see the current phase and remaining time,
  * pause the cycle for 15/30/60 minutes (overlay hidden, timeline frozen and
    resumed exactly where it paused),
  * start a break immediately,
  * reset the cycle,
  * change the PIN.

There is **no factory, universal or recovery PIN**. On first run (no PIN
stored) the setup wizard asks for the PIN twice before the panel becomes usable.
If the wizard is postponed the guard stays inert — nothing is enforced and the
overlay never appears — and the wizard reopens the next time the pane is shown.

## PIN storage

* PBKDF2-HMAC-SHA256 via CommonCrypto.
* Random 16-byte salt from `SecRandomCopyBytes` (with a libc entropy fallback).
* 25 000 iterations, stored in the plist so the count can be raised later
  without invalidating existing PINs.
* Salt, hash and iteration count are stored base64-encoded in the preferences
  plist. The plaintext PIN is never written, logged or retained.
* Five failed attempts trigger a 30-second lockout; each further five double it,
  capped at eight minutes. The failure counter and lockout deadline are
  persisted, so a respring does not reset them.

## Persistence

`/var/mobile/Library/Preferences/org.usageguard.timelock.plist`, written
atomically. It contains the cycle state as a versioned `key=value` string
(enabled flag, phase, remaining seconds, last-tick wall clock, override
deadline, configured durations) plus the PIN fields. The file is written on real
transitions (phase change, lock/screen change, parent action) and otherwise at
most once a minute, so it is not rewritten on every tick.

On startup:

* a break continues to elapse using real time since the last tick, capped at
  the remaining break time;
* an interrupted usage phase gets no credit for the downtime;
* a parent pause ends at its real end time: the break it froze keeps elapsing,
  so a break that fell due during the pause is over instead of restarting;
* a missing or corrupt plist, or a value of the wrong type, falls back to 20/30
  defaults and an unlocked vault rather than raising.

Clock rules on every tick:

* backward jumps are ignored: the gap is not credited and time restarts from
  "now", while a parent pause keeps only the time it had left, measured from
  the clock it was granted under, so winding the clock back and then respringing
  or rebooting cannot extend it;
* forward jumps credit at most 2 seconds of usage per tick, which bounds what
  a single awake gap can spend;
* the first tick after the device becomes usable again (screen on and unlocked)
  credits nothing: the usage clock is re-anchored on that transition, so
  unlocking the phone never hands out the 2-second cap for time the phone was
  not in use. Usage therefore only counts while the screen is on and unlocked.

## Settings pane

The package also installs a preference bundle
(`/Library/PreferenceBundles/UsageGuardPrefs.bundle`) plus a PreferenceLoader
entry (`/Library/PreferenceLoader/Preferences/UsageGuard.plist`), so a
**Usage Guard** row appears at the bottom of `Settings`. There is no app icon:
the pane lives in Settings. The entry is a real controller (`isController` plus
`detail` in the entry plist, `NSPrincipalClass` in the bundle's `Info.plist`),
so tapping the row pushes `UGPreferencesController` — a `PSViewController`
subclass that builds its own grouped table view — instead of a dead link cell.
The pane has five sections, top to bottom:

| section | rows |
| --- | --- |
| **Status** | `Usage Guard activ` switch; `Stare` (current phase); `Utilizare rămasă`; `Pauză rămasă`; `Runtime: activ (pid N)` or `Runtime: nu este detectat` |
| **Time Limits** | `Utilizare (minute)` and `Pauză (minute)`, 1–240 each, edited through a prompt |
| **Actions** | `Începe pauza acum`, `Resetează ciclul`, `Pauză 15 min`, `Pauză 30 min`, `Pauză 60 min`, `Reia restricțiile`, `Testează ecranul de blocare` |
| **Security** | `Schimbă codul PIN` (`Setează un cod PIN` when none is stored) and the `Cere PIN pentru modificări` switch |
| **Information** | tweak version, runtime, bundle version, preferences path, status-file age, kill-switch state, `DebugLogging` state |

The pane keeps no copy of the state: every read reloads the preferences file and
every change is a read-modify-write that is announced to SpringBoard (see
below). The remaining-time rows normally take the runtime's published
`Remaining` and subtract the age of the status heartbeat
(`Remaining - (now - LastTick)`, floored at zero). That live value is used only
while the runtime has a fresh heartbeat, is not inert, setup is complete and no
parent pause is active; in every other case the pane falls back to the
persisted cycle state: `Remaining` from the preferences file, or `0` while the
tweak is disabled. When it applies, it counts down with the
overlay instead of showing a value up to a minute stale. `Cere PIN pentru
modificări` defaults to on, which makes every row that changes the cycle or the
PIN ask for the PIN first; the test-overlay row never asks, because it changes
nothing. `Reia restricțiile` is the way out of a parent pause: it clears the
pause immediately instead of waiting for it to expire.

## First-run setup

A fresh install is **inert but loaded**: the tweak is injected into SpringBoard,
waits for the status heartbeat, and enforces nothing until setup is complete.
The preferences file is created at load and the tweak writes only
`SetupComplete = 0` before setup: the tweak itself keeps no cycle state, stores
no PIN, locks nothing, shows no overlay and never arms the Home/Siri suppression
until setup finishes. The pane is a separate writer and does not follow that
rule: until a PIN exists there is no PIN gate, so a wizard cancelled after it
started leaves the pane fully usable, and its rows can write `State`, the PIN
fields and `RequirePIN` before setup. That is intentional for a fresh install —
every restriction is gated on `SetupComplete`, so nothing is enforced while it
is still `0`. A preferences file from an earlier release is treated as set up —
`SetupComplete` is pinned to `YES` on first read — only when a PIN is stored, so
upgrading does not re-run the wizard; a device that never stored a PIN still
gets the first-run wizard.

Setup runs from Settings → Usage Guard: the wizard opens the first time the pane
is shown. The overlay's seven-tap parent panel is *not* a setup path — the
overlay only appears once a break is running or through `Testează ecranul de
blocare`, and neither can happen before setup. The wizard asks for the PIN
twice, then the usage and break durations, explains the emergency valve, and
finishes by storing the PIN, both durations, `SetupComplete = YES` and
`enabled = 1`. The usage clock is re-anchored at that moment, so no time is
billed for the period before setup finished. Until then the only key the tweak
itself has written is `SetupComplete = 0`.

## Settings ↔ runtime communication

The pane and SpringBoard share the preferences file and one status file, and
signal each other over three Darwin notification names (declared in
`src/UGNotify.h`):

| name | direction | meaning |
| --- | --- | --- |
| `org.usageguard.timer.settingschanged` | Settings → SpringBoard | the preferences plist changed on disk; the runtime reloads state, `SetupComplete` and `RequirePIN` and repaints |
| `org.usageguard.timer.testoverlay` | Settings → SpringBoard | preview the break overlay for 5 seconds |
| `org.usageguard.timer.statuschanged` | SpringBoard → Settings | the status file was rewritten |

**Preferences file** — unchanged path,
`/var/mobile/Library/Preferences/org.usageguard.timelock.plist`. It holds the
cycle state, the PIN vault and two booleans: `SetupComplete` and `RequirePIN`.
Every writer reloads the file, changes only its own keys and merges them into
what it just read, so the two processes cannot clobber each other's keys.

**Status file** — `/var/mobile/Library/Preferences/org.usageguard.timer.status.plist`,
written by the SpringBoard runtime immediately on any meaningful change and,
when nothing meaningful changed, no more often than once every 2 seconds, so
the heartbeat stays well inside the pane's 5-second freshness window. All keys
are numbers except `Version`:

```
RuntimePID  RuntimeStartedAt  LastTick  Enabled  SetupComplete  Phase
Remaining  UsageMinutes  BreakMinutes  OverrideRemaining  Inert
KillSwitch  DebugLogging  Version (string)
```

`Enabled` is the effective value (`SetupComplete` **and** the stored enabled
flag), not the raw switch. `LastTick` is a wall-clock heartbeat: a status file
whose `LastTick` is more than 5 seconds old, or a missing file, is the pane's
"the dylib is not loaded" signal — SpringBoard either never injected the tweak
or has been restarted since. That freshness window is the only liveness
evidence the pane has; it never assumes the tweak is running.

## Diagnostics

`DebugLogging` (a boolean in the preferences plist) turns on a small number of
`NSLog` lines — startup, hook count, corrupt state, PIN lockout — that appear
after a respring. The Information section of the pane shows its state, along
with the tweak version, the bundle version, the preferences path, the status
file age and the kill-switch state, which is usually enough to tell "not
installed" from "installed but inert".

The status file is the first thing to read when something looks wrong: copy
`/var/mobile/Library/Preferences/org.usageguard.timer.status.plist` off the
device and open it with `plutil` or Xcode on the desktop. `RuntimePID` and
`LastTick` answer "is the tweak running in this SpringBoard?", `Inert` and
`KillSwitch` answer "is it deliberately doing nothing?", and `Phase`/`Remaining`
answer "what does it think the cycle is doing?". A stale `LastTick` after a
respring is expected until the new runtime writes its first snapshot.

## Test overlay

`Testează ecranul de blocare` (Actions) posts
`org.usageguard.timer.testoverlay`. SpringBoard raises the real break window
with test copy for **5 seconds** and dismisses it by itself. The preview is
purely visual: it never arms the Home/Siri hooks, writes no state, and does not
start, extend, shorten or end a break — the countdown it draws is the preview's
own and goes away with it. It is refused while the parent panel is on screen or
while the tweak is inert, and if a real break falls due during the preview the
real overlay takes over. It also needs the runtime to be loaded: with a stale
status file the button has nothing to talk to.

## Safety valve

The break overlay always exposes **Apel de urgență 112**. Pressing it hides the
timeline and opens `tel:112` through SpringBoard, so a real emergency call can
be placed even though every other interaction is blocked. The window stays open
only while a call is active and closes as soon as the call ends; if no call ever
starts it closes after 15 seconds. The overlay then returns by itself while the
break is still running. Only the window steps aside: the home-button/Siri
suppression stays armed for the whole emergency window, so the valve cannot be
used to get free SpringBoard access. If the URL cannot be opened, the
overlay reports `Apelul de urgență nu este disponibil pe acest dispozitiv.` in
its subtitle instead of behind it. Blocking power, volume, lock or telephony is
never attempted.

Apple's own passcode and lock screen are untouched. If the device locks, the
native lock screen takes over, the overlay hides, and it reappears after unlock
while a break is still active.

## Repository layout

```
Makefile                Theos build: the tweak plus the preference bundle
control                 Debian package metadata
UsageGuard.plist        MobileSubstrate filter (com.apple.springboard)
Tweak.x                single SpringBoard bootstrap hook
layout/Library/PreferenceLoader/Preferences/UsageGuard.plist
                        PreferenceLoader entry (the Settings row)
prefs/                  preference bundle sources and resources
prefs/Resources/Info.plist  the bundle's Info.plist (staged into the bundle)
prefs/UGPreferencesController.{h,m}  the grouped Settings pane
prefs/UGSettingsIPC.{h,m}            plist access and Darwin announcements
src/UGGuardCore.{h,c}   pure C cycle engine, serialization, MM:SS formatting
src/UGPrefs.{h,m}       plist persistence + PBKDF2 PIN vault and rate limit
src/UGNotify.h          the three Darwin notification names
src/UGVersion.h         release string plus the preferences, status and kill-switch paths
                        (the only definition of all four; CI rejects copies)
src/UGOverlayWindow.{h,m}  high-level window and break overlay UI
src/UGParentPanel.{h,m}    PIN gate, first-run wizard, settings panel
src/UGRuntime.{h,m}     clock, Darwin notifications, guarded swizzles, glue
scripts/validate_deb.py static .deb validator used by CI
scripts/selftest_validate_deb.py  synthetic packages for that validator
tests/test_guard_core.c host tests for the C engine
tests/run.sh            host test runner
```

`UGGuardCore.c` includes only `<stdio.h>`, `<string.h>` and `<stddef.h>`, so the
same file builds on a desktop compiler and inside the tweak. The cycle engine
uses no allocation and its serialized state is bounded well below 512 bytes.

## Build — GitHub Actions (no local toolchain)

The supported path is the CI pipeline in `.github/workflows/build.yml`. It runs
on every push to `main` and on manual `workflow_dispatch`, installs Theos with
the iPhoneOS 6.1 SDK and a 32-bit-capable LLVM toolchain on a GitHub-hosted
Ubuntu runner, builds the probe tweak first, then this tweak and its preference
bundle, statically validates both packages, and uploads:

| artifact | contents |
| --- | --- |
| `usage-guard-deb` | `org.usageguard.timer_1.0.3_iphoneos-arm.deb` — install this |
| `usage-guard-probe-deb` | minimal SpringBoard smoke-test package |
| `build-logs` | full `make` output for both builds (also uploaded when a build fails) |

Download the `.deb` from the run's *Artifacts* section on GitHub, or from a
checkout with the GitHub CLI:

```sh
gh run download --name usage-guard-deb
```

Validation is enforced, not advisory: before building, the pipeline fails unless
`control`, the bundle's `Info.plist` (`prefs/Resources/Info.plist`, the file
Theos stages into the bundle) and `src/UGVersion.h` all carry the same version,
and unless the pane takes that version from the header — a hard-coded `1.0.3`
literal in `prefs/UGPreferencesController.m` or `prefs/UGSettingsIPC.m` fails
the build. The same step also fails if
`org.usageguard.timelock.plist`, `org.usageguard.timer.status.plist` or
`org.usageguard.timer.disable` appears anywhere under `src/` or `prefs/`
outside `src/UGVersion.h`, so the release version and those plist paths have
exactly one definition.
The validator then fails the package unless

* the payload is exactly five files — the armv7 `MH_DYLIB` and its filter plist
  under `Library/MobileSubstrate/DynamicLibraries/`, the armv7 `MH_BUNDLE`
  executable (`UsageGuardPrefs`, filetype 8) and its `Info.plist` under
  `Library/PreferenceBundles/UsageGuardPrefs.bundle/`, and the PreferenceLoader
  entry `Library/PreferenceLoader/Preferences/UsageGuard.plist` (the bundle is
  linked `-bundle` with `_DYNAMIC_LIBRARY = NO`, so the validator rejects a
  dylib-shaped bundle executable, including one carrying an `LC_ID_DYLIB`);
* the filter plist names `com.apple.springboard` and the PreferenceLoader plist
  names the `UsageGuardPrefs` bundle;
* the PreferenceLoader entry is a real controller — `entry.isController` is
  boolean true, `entry.detail` names the controller class and `entry.bundle` is
  `UsageGuardPrefs` — so PreferenceLoader loads the bundle and pushes the pane;
* the bundle's `Info.plist` declares `CFBundleExecutable` (`UsageGuardPrefs`,
  the binary that must exist) and a non-empty `NSPrincipalClass` (the class
  PreferenceLoader instantiates; the two keys are independent and may differ);
* both binaries are single-slice **armv7**, `LC_VERSION_MIN_IPHONEOS` 6.0.0 and
  signed (`LC_CODE_SIGNATURE`); the bundle executable carries no `LC_ID_DYLIB`;
* `Architecture: iphoneos-arm` and `Depends:` list `mobilesubstrate` and
  `preferenceloader`.

The probe package keeps its own two-file payload (dylib plus filter plist)
whose only dependency is `mobilesubstrate`; the validator checks each layout
separately, and it rejects `Library/PreferenceLoader` or
`Library/PreferenceBundles` content — even an empty directory — in any package
other than `org.usageguard.timer`.

### Local build (optional, requires your own toolchain)

With a working Theos installation, the iPhoneOS 6.1 SDK and `ldid` on PATH:

```sh
make package FINALPACKAGE=1
```

The package is written to `packages/` as
`org.usageguard.timer_1.0.3_iphoneos-arm.deb`. The tweak targets
`iphone:clang:6.1:6.0`, `ARCHS = armv7` (iPhone 4S / iPad 2 class hardware).

### Host tests (no Theos, no device)

```sh
gcc -std=c99 -Wall -Wextra -Werror -O2 -Isrc \
    src/UGGuardCore.c tests/test_guard_core.c -o /tmp/usageguard_core_tests
/tmp/usageguard_core_tests
```

or simply `tests/run.sh`. The tests cover full cycle wrap-around, usage gating
(screen off, locked, disabled), break elapse across a wall-clock gap, break
expiry resetting the allowance, parent pauses without drift, pause expiry that
still ends an expired break on time, backward clock jumps that cannot extend a
pause, the capped credit on a long awake gap, no free credit on the first tick
after reactivation, reset and start-break,
serialization round-trip (including override clamping), duration validation and
`MM:SS` formatting.

## Install

Copy the built `.deb` to the device and install it with dpkg, then respring or
restart SpringBoard:

```sh
scp packages/org.usageguard.timer_1.0.3_iphoneos-arm.deb root@DEVICE_IP:/var/root/
ssh root@DEVICE_IP \
  'dpkg -i /var/root/org.usageguard.timer_1.0.3_iphoneos-arm.deb && killall -9 SpringBoard'
```

A `.deb` import feature in desktop jailbreak utilities (for example 3uTools'
deb installer) works the same way. The package installs the tweak
(`/Library/MobileSubstrate/DynamicLibraries/UsageGuard.dylib` and its filter
plist), the preference bundle
(`/Library/PreferenceBundles/UsageGuardPrefs.bundle/`) and the PreferenceLoader
entry (`/Library/PreferenceLoader/Preferences/UsageGuard.plist`), and it
declares `Depends: mobilesubstrate, preferenceloader, firmware (>= 6.0)`. Cydia
and dpkg refuse the install without PreferenceLoader, which is what puts the
pane in Settings. After installation the tweak starts with SpringBoard; there is
no app icon — the pane lives in Settings → Usage Guard, and until the first-run
setup is completed nothing is enforced.

To remove it: `dpkg -r org.usageguard.timer` (or `dpkg -P`) followed by a
respring. The preferences file `org.usageguard.timelock.plist` lives in the
preferences directory and is created at runtime, so the package removal leaves
it in place; delete it by hand if a clean slate is wanted.

## Emergency recovery

The tweak has a hard kill switch for a device that has become unusable. Create
the marker file (over SSH, or with a file manager such as 3uTools):

```sh
touch /var/mobile/Library/Preferences/org.usageguard.timer.disable
```

While that file exists the tweak does nothing at all: no overlay, no swizzled
methods (or, if they were already installed, they simply call the original), no
usage accounting and no PIN wizard. The check runs on every 1 Hz tick, so the
device is usable about a second after the file appears — no respring needed.
The marker is only ever read, never created, modified or deleted by the tweak.
The `Kill switch` row in the Settings pane's Information section shows whether
the marker is currently seen, so its state is visible without a shell.

Remove the file and respring to re-enable it (a running runtime also picks the
removal up within a second):

```sh
rm /var/mobile/Library/Preferences/org.usageguard.timer.disable
killall -9 SpringBoard
```

Last resorts, in order: uninstall with `dpkg -r org.usageguard.timer` and
respring, or boot into Safe Mode (MobileSubstrate disables tweaks there).

## Troubleshooting

* **No overlay appears.** Check that the package is installed, the filter plist
  targets `com.apple.springboard`, and the tweak is enabled. `DebugLogging` set
  to `true` in the preferences plist enables a small number of `NSLog` lines
  (startup, hook count, corrupt state, PIN lockout) after a respring.
* **Forgot the PIN.** There is no recovery PIN by design. Remove the package
  and delete `/var/mobile/Library/Preferences/org.usageguard.timelock.plist`,
  then reinstall and run the first-run wizard.
* **Panel does not open from the title.** The gesture needs seven taps within
  three seconds while the break overlay is visible.
* **No Usage Guard row in Settings.** PreferenceLoader is a declared dependency
  (`Depends: ... preferenceloader ...`); reinstall the package so dpkg pulls it
  in, then respring. If the row exists but tapping it does nothing, the bundle is
  not loadable as a controller: the entry plist needs `isController` true and a
  `detail` class, and the bundle's `Info.plist` needs `NSPrincipalClass` — CI
  fails the build when any of them is missing. If the row is there but the
  Status section reports no live runtime, SpringBoard has not injected the tweak
  or was restarted since — see Diagnostics above.

## Limitations (honest list)

* **Runtime best-effort bypass resistance.** Siri / Voice Control and the home
  button are blocked while the overlay is up by runtime swizzling of exactly two
  methods: `SpringBoard -_menuButtonWasHeld` and
  `SpringBoard -_handleMenuButtonEvent`. Both are void, take no arguments, and
  their signatures are still checked at runtime before the swizzle. No prefix
  matching is used, and nothing else on any class is touched. A selector absent
  on a given iOS 6 build is skipped; the original implementation is always
  called when the overlay is not shown. This deters casual attempts, not someone
  with root access, who can unload the tweak or call private APIs directly.
* **Not a passcode replacement.** The tweak never touches Apple's lock state
  or passcode; a locked device shows the native lock screen.
* **Emergency valve window.** While `tel:112` is opened the timeline stays
  hidden for as long as the call lasts; if no call ever starts, it comes back
  after 15 seconds. If SpringBoard silently refuses to open the URL, the timeline
  still returns after that window. If the dialer itself is unreachable, the
  button reports that emergency calling is unavailable inside the overlay.
* **Calls always win.** While a call is active (incoming, outgoing or the
  emergency call itself) the overlay is suppressed, detected through the public
  read-only `CTCallCenter.currentCalls` API when the platform reports it. No telephony service is hooked,
  replaced or disabled; the overlay simply stays out of the way until the call
  ends.
* **Clock trust.** The cycle uses wall-clock deltas with clamping as described
  above. A determined user changing the system clock can move the cycle
  forward: a forward jump during a parent pause makes the pause look expired,
  so the break it froze resumes at the pause's end time and the jump can end it
  at once. Backward jumps are ignored, forward usage credit is capped at 2
  seconds per tick, and a parent pause keeps only the time it had left,
  including across a respring or reboot.
* **Break while disabled.** Disabling the tweak freezes the cycle, including a
  running break; re-enabling resumes it.
* **Settings writes are last-write-wins.** The pane and SpringBoard both
  read-modify-write the preferences plist and merge only the keys they changed,
  but whoever writes last wins for those keys. Changing the same setting from
  the break overlay's parent panel and from Settings at the same moment does not
  merge somewhere in the middle: the later save is the one that survives. The
  open pane reloads the file once a second, so it does pick up changes made
  elsewhere, it just cannot arbitrate between two saves of the same value.
* **The status file is a heartbeat, not a log.** It is written by SpringBoard,
  so when SpringBoard is killed it keeps its last contents: `RuntimePID`,
  `LastTick` and `KillSwitch` are stale by design until the next SpringBoard
  writes them. A `LastTick` older than 5 seconds means "no live runtime", never
  "no tweak installed". Nothing enforces anything from that file; deleting it
  only empties the pane's Information section until the next write.
* **The pane cannot verify a PIN change made while it is open.** The pane
  reloads the state every second, so a PIN changed from the break overlay's
  parent panel is visible to it, but the authorization it already granted is not
  re-checked. What it does do is drop that authorization whenever the pane
  disappears or Preferences.app resigns active or goes to the background, and
  at that same moment it dismisses any editor alert that is open and discards
  the pending edit. Reopening Settings therefore always asks for the PIN
  again, reaching Home and coming back to a suspended Preferences.app does
  too, and a half-finished edit cannot be completed later.
* **SpringBoard only.** Nothing is injected into individual apps; the overlay
  is a SpringBoard-level window at `UIWindowLevelAlert + 1000` that is
  re-raised on every 1 Hz synchronisation while a break is running.
* **Private API guards.** The lock/screen state is queried every second, best
  source first: `SBAwayController` (`+sharedAwayController`, `-isLocked`,
  `-isDimmed`) is the iOS 6 authority; `SBLockScreenManager.isLocked` and
  `SBBacklightController.screenIsOn` are only the iOS 7+ second choice; the last
  resort is the notify(3) *state* of `com.apple.springboard.lockstate` and
  `com.apple.springboard.hasBlankedScreen` via `notify_register_check` /
  `notify_get_state`. The notification name is never treated as a value, because
  `lockstate` fires on both lock and unlock. When no source can answer, the
  tweak assumes "locked, screen off": it neither counts usage nor covers the
  screen on a guess. No private method ABI is assumed at compile time.
* **No physical-device test was performed for this release.** CI cross-builds
  the package, `scripts/validate_deb.py` checks the payload statically and the
  host C tests cover the cycle engine; nothing in this repository exercises the
  Settings pane, the status file, the Darwin notifications or the overlay on
  hardware. Runtime behaviour must be smoke-tested on a real jailbroken iOS
  6.1.3 device: respring, overlay over several apps, lock/unlock, the emergency
  call, PIN lockout, a Settings round-trip and the test overlay.
