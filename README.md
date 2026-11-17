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

`/var/mobile/Library/Preferences/org.usageguard.timer.plist`, written
atomically. It contains the cycle state as a versioned `key=value` string
(enabled flag, phase, remaining seconds, last-tick wall clock, override
deadline, configured durations) plus the PIN fields.

On startup:

* a break continues to elapse using real time since the last tick, capped at
  the remaining break time;
* an interrupted usage phase gets no credit for the downtime;
* backward clock jumps are ignored (the gap is not credited and time restarts
  from "now");
* forward jumps during usage credit at most 60 seconds per tick;
* a missing or corrupt plist falls back to 20/30 defaults.

## Safety valve

The break overlay always exposes **Apel de urgență 112**. Pressing it hides the
timeline for at most 120 seconds and opens `tel:112` through SpringBoard, so a
real emergency call can be placed even though every other interaction is
blocked. The overlay returns by itself if the break is still running. Blocking
power, volume, lock or telephony is never attempted.

Apple's own passcode and lock screen are untouched. If the device locks, the
native lock screen takes over, the overlay hides, and it reappears after unlock
while a break is still active.

## Repository layout

```
Makefile                Theos build (armv7, iOS 6.0 deployment target)
control                 Debian package metadata
UsageGuard.plist        MobileSubstrate filter (com.apple.springboard)
Tweak.xm                single SpringBoard bootstrap hook
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

## Build

Requires a working Theos installation with the iPhoneOS 6.1 SDK, and clang with
`ldid` available (standard Theos setup).

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
expiry resetting the allowance, PIN-pause/resume without drift, reset and
start-break, forward/backward clock jumps, serialization round-trip, duration
validation and `MM:SS` formatting.

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

To remove it: `dpkg -r org.usageguard.timer` (or `dpkg -P` to drop the
preferences file) followed by a respring.

## Troubleshooting

* **No overlay appears.** Check that the package is installed, the filter plist
  targets `com.apple.springboard`, and the tweak is enabled. `DebugLogging` set
  to `true` in the preferences plist enables a small number of `NSLog` lines
  (startup, hook count, corrupt state, PIN lockout) after a respring.
* **Forgot the PIN.** There is no recovery PIN by design. Remove the package
  and delete `/var/mobile/Library/Preferences/org.usageguard.timer.plist`, then
  reinstall and run the first-run wizard.
* **Panel does not open from the title.** The gesture needs seven taps within
  three seconds while the break overlay is visible.

## Limitations (honest list)

* **Runtime best-effort bypass resistance.** Siri activation and menu-button
  actions are blocked by runtime swizzling restricted to `SBAssistantController
  -activate*` and `SBUIController -handleMenuButton* / -_menuButton*`, only for
  void methods taking at most three single-word arguments whose signatures are
  read from the method itself. Classes/selectors absent on a given iOS 6 build
  are skipped; the original implementation is always called when the overlay is
  not shown. This deters casual attempts, not someone with root access, who can
  unload the tweak or call private APIs directly.
* **Not a passcode replacement.** The tweak never touches Apple's lock state
  or passcode; a locked device shows the native lock screen.
* **Emergency valve window.** While `tel:112` is opened the timeline stays
  hidden for up to 120 seconds (bounded, deliberate). If SpringBoard silently
  refuses to open the URL, the timeline still returns after that window. If the
  dialer itself is unreachable, the button reports that emergency calling is
  unavailable.
* **Calls always win.** While a call is active (incoming, outgoing or the
  emergency call itself) the overlay is suppressed, detected through the public
  read-only `CTCallCenter.currentCalls` API when the platform reports it. No telephony service is hooked,
  replaced or disabled; the overlay simply stays out of the way until the call
  ends.
* **Clock trust.** The cycle uses wall-clock deltas with clamping as described
  above. A determined user changing the system clock can move the cycle
  forward; backward jumps are ignored, and forward usage credit is capped.
* **Break while disabled.** Disabling the tweak freezes the cycle, including a
  running break; re-enabling resumes it.
* **SpringBoard only.** Nothing is injected into individual apps; the overlay
  is a SpringBoard-level window at `UIWindowLevelAlert + 1000` that is
  re-raised on show and on foreground changes.
* **Private API guards.** `SBLockScreenManager.isLocked` and
  `SBBacklightController.screenIsOn` are queried through `NSClassFromString`
  and `respondsToSelector:`; if either is missing, the SpringBoard Darwin
  notifications (`hasBlankedScreen`, `lockcomplete`, `lockstate`) drive the
  screen/lock flags instead. No private method ABI is assumed at compile time.
* **No on-device test in this repository.** CI builds the package and runs the
  host C tests; runtime behaviour must be smoke-tested on a real jailbroken
  iOS 6.1.3 device (respring, overlay over several apps, lock/unlock, emergency
  call, PIN lockout).
