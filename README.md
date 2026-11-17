# Usage Guard

A MobileSubstrate tweak for jailbroken 32-bit iOS 6 devices that enforces a
repeating **use / break** cycle:

* 20 minutes of normal phone use,
* then a mandatory 30-minute break with a full-screen lock overlay,
* repeat indefinitely.

Both durations are configurable from a PIN-protected parent panel. The tweak
runs inside SpringBoard, so the break overlay appears above apps, the home
screen, notifications and alerts regardless of what is in the foreground.

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
If the wizard is postponed, the panel stays locked until a PIN is set; the
seven-tap gesture opens the wizard again.

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
* forward jumps and the first tick after sleep credit at most 2 seconds of usage,
  which is why usage only counts while the screen is on and unlocked.

## Safety valve

The break overlay always exposes **Apel de urgență 112**. Pressing it hides the
timeline and opens `tel:112` through SpringBoard, so a real emergency call can
be placed even though every other interaction is blocked. The window stays open
only while a call is active and closes as soon as the call ends; if no call ever
starts it closes after 15 seconds. The overlay then returns by itself while the
break is still running. If the URL cannot be opened, the
overlay reports `Apelul de urgență nu este disponibil pe acest dispozitiv.` in
its subtitle instead of behind it. Blocking power, volume, lock or telephony is
never attempted.

Apple's own passcode and lock screen are untouched. If the device locks, the
native lock screen takes over, the overlay hides, and it reappears after unlock
while a break is still active.

## Repository layout

```
Makefile                Theos build (armv7, iOS 6.0 deployment target)
control                 Debian package metadata
UsageGuard.plist        MobileSubstrate filter (com.apple.springboard)
Tweak.x                single SpringBoard bootstrap hook
src/UGGuardCore.{h,c}   pure C cycle engine, serialization, MM:SS formatting
src/UGPrefs.{h,m}       plist persistence + PBKDF2 PIN vault and rate limit
src/UGOverlayWindow.{h,m}  high-level window and break overlay UI
src/UGParentPanel.{h,m}    PIN gate, first-run wizard, settings panel
src/UGRuntime.{h,m}     clock, Darwin notifications, guarded swizzles, glue
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
Ubuntu runner, builds the probe tweak first, then this tweak, statically
validates both packages, and uploads:

| artifact | contents |
| --- | --- |
| `usage-guard-deb` | `org.usageguard.timer_1.0.0_iphoneos-arm.deb` — install this |
| `usage-guard-probe-deb` | minimal SpringBoard smoke-test package |
| `build-logs` | full `make` output for both builds (also uploaded when a build fails) |

Download the `.deb` from the run's *Artifacts* section on GitHub, or from a
checkout with the GitHub CLI:

```sh
gh run download --name usage-guard-deb
```

Validation is enforced, not advisory: the pipeline fails unless the payload is
a single-slice **armv7** `MH_DYLIB` with `LC_VERSION_MIN_IPHONEOS 6.0.0` and a
code signature, `Architecture: iphoneos-arm`, `Depends:` containing
`mobilesubstrate`, and exactly the dylib plus its filter plist under
`Library/MobileSubstrate/DynamicLibraries/` naming `com.apple.springboard`.

### Local build (optional, requires your own toolchain)

With a working Theos installation, the iPhoneOS 6.1 SDK and `ldid` on PATH:

```sh
make package FINALPACKAGE=1
```

The package is written to `packages/` as
`org.usageguard.timer_1.0.0_iphoneos-arm.deb`. The tweak targets
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
pause, the capped credit on the first tick after sleep, reset and start-break,
serialization round-trip (including override clamping), duration validation and
`MM:SS` formatting.

## Install

Copy the built `.deb` to the device and install it with dpkg, then respring or
restart SpringBoard:

```sh
scp packages/org.usageguard.timer_1.0.0_iphoneos-arm.deb root@DEVICE_IP:/var/root/
ssh root@DEVICE_IP \
  'dpkg -i /var/root/org.usageguard.timer_1.0.0_iphoneos-arm.deb && killall -9 SpringBoard'
```

A `.deb` import feature in desktop jailbreak utilities (for example 3uTools'
deb installer) works the same way. After installation the tweak starts with
SpringBoard; there is no app icon and no settings bundle.

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
* **No on-device test in this repository.** CI builds the package and runs the
  host C tests; runtime behaviour must be smoke-tested on a real jailbroken
  iOS 6.1.3 device (respring, overlay over several apps, lock/unlock, emergency
  call, PIN lockout).
