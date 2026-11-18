#import "UGRuntime.h"

#import <CoreTelephony/CTCallCenter.h>
#import <UIKit/UIKit.h>
#import <notify.h>
#import <objc/runtime.h>
#import <stdint.h>
#import <stdlib.h>
#import <unistd.h>

#import "UGGuardCore.h"
#import "UGNotify.h"
#import "UGOverlayWindow.h"
#import "UGParentPanel.h"
#import "UGPrefs.h"
#import "UGVersion.h"

static NSString *const kUGNotificationScreenBlanked = @"com.apple.springboard.hasBlankedScreen";
static NSString *const kUGNotificationLockComplete = @"com.apple.springboard.lockcomplete";
static NSString *const kUGNotificationLockState = @"com.apple.springboard.lockstate";

/* Escape window while the dialer opens and no call ever starts. */
static const long long kUGEmergencyNoCallSeconds = 15;

/* At most one state write per minute unless something actually happened. */
static const long long kUGPersistIntervalSeconds = 60;

/* The status file is a heartbeat: refresh it at least this often so the
 * Preferences pane can tell a live runtime from a dead one. The pane's own
 * freshness window (kUGStatusFreshnessSeconds, 5 s, in the preference bundle)
 * is deliberately the wider of the two: writing every 2 s leaves room for a
 * late 1 Hz tick without a live runtime ever looking dead. */
static const long long kUGStatusRefreshSeconds = 2;

/* Length of a Settings "test overlay" preview. */
static const long long kUGTestOverlaySeconds = 5;

enum { kUGMaxHooks = 4 };

/*
 * Very narrow swizzle allowlist, by exact class and selector. On iOS 6 the home
 * button handlers live on SpringBoard itself: SBAssistantController only has
 * -activateIgnoringTouches (non-void) and SBUIController has no menu-button
 * methods at all. Power, volume, lock and telephony are never touched. Only
 * methods that return void and take at most three single-word arguments are
 * hooked (checked at runtime from the method's own type encoding).
 */
typedef struct {
    const char *className;
    const char *selectorName;
} UGAllowlistEntry;

static const UGAllowlistEntry kUGAllowlist[] = {
    { "SpringBoard", "_menuButtonWasHeld" },    /* Siri / Voice Control */
    { "SpringBoard", "_handleMenuButtonEvent" } /* menu button events */
};

typedef struct {
    SEL selector;
    __unsafe_unretained Class cls;
    IMP original;
} UGHookEntry;

static UGHookEntry sUGHooks[kUGMaxHooks];
static NSInteger sUGHookCount = 0;
static volatile int sUGOverlayLocked = 0;

/* notify(3) check tokens; -1 until the first successful registration. */
static int sUGLockStateToken = -1;
static int sUGBlankedToken = -1;

static IMP UGOriginalImplementation(__unsafe_unretained id self, SEL selector)
{
    for (NSInteger index = 0; index < sUGHookCount; index++) {
        if (sUGHooks[index].selector != selector) continue;
        if (!sUGHooks[index].cls || [self isKindOfClass:sUGHooks[index].cls]) {
            return sUGHooks[index].original;
        }
    }
    return NULL;
}

/*
 * One forwarder per arity, ABI-exact for the original method: `self` is
 * __unsafe_unretained and every extra argument is uintptr_t, the single word
 * the hook slot really holds. ARC must never retain or release a scalar, and
 * the original IMP is cast to the identical signature.
 */
static void UGHook0(__unsafe_unretained id self, SEL selector)
{
    IMP original;
    if (sUGOverlayLocked) return;
    original = UGOriginalImplementation(self, selector);
    if (!original) return;
    ((void (*)(__unsafe_unretained id, SEL))original)(self, selector);
}

static void UGHook1(__unsafe_unretained id self, SEL selector, uintptr_t first)
{
    IMP original;
    if (sUGOverlayLocked) return;
    original = UGOriginalImplementation(self, selector);
    if (!original) return;
    ((void (*)(__unsafe_unretained id, SEL, uintptr_t))original)(self, selector, first);
}

static void UGHook2(__unsafe_unretained id self, SEL selector,
                    uintptr_t first, uintptr_t second)
{
    IMP original;
    if (sUGOverlayLocked) return;
    original = UGOriginalImplementation(self, selector);
    if (!original) return;
    ((void (*)(__unsafe_unretained id, SEL, uintptr_t, uintptr_t))original)(
        self, selector, first, second);
}

static void UGHook3(__unsafe_unretained id self, SEL selector,
                    uintptr_t first, uintptr_t second, uintptr_t third)
{
    IMP original;
    if (sUGOverlayLocked) return;
    original = UGOriginalImplementation(self, selector);
    if (!original) return;
    ((void (*)(__unsafe_unretained id, SEL, uintptr_t, uintptr_t, uintptr_t))original)(
        self, selector, first, second, third);
}

static IMP UGHookFunctionForArity(int arity)
{
    switch (arity) {
        case 0: return (IMP)UGHook0;
        case 1: return (IMP)UGHook1;
        case 2: return (IMP)UGHook2;
        case 3: return (IMP)UGHook3;
        default: return NULL;
    }
}

static BOOL UGMethodIsBlockable(Method method, int *arity)
{
    const char *encoding = method_getTypeEncoding(method);
    NSMethodSignature *signature;
    const char *returnType;

    if (!encoding) return NO;
    signature = [NSMethodSignature signatureWithObjCTypes:encoding];
    if (!signature) return NO;
    returnType = [signature methodReturnType];
    if (!returnType || returnType[0] != 'v' || returnType[1] != '\0') return NO;

    if (signature.numberOfArguments < 2 || signature.numberOfArguments > 5) return NO;
    for (NSUInteger index = 2; index < signature.numberOfArguments; index++) {
        const char *type = [signature getArgumentTypeAtIndex:index];
        if (!type || type[1] != '\0') return NO;
        switch (type[0]) {
            case '@': case '#': case ':':
            case 'i': case 'I': case 'c': case 'C': case 'B': case 's': case 'S':
                break;
            default:
                return NO;
        }
    }

    *arity = (int)(signature.numberOfArguments - 2);
    return YES;
}

static BOOL UGHookHasSelector(SEL selector)
{
    for (NSInteger index = 0; index < sUGHookCount; index++) {
        if (sUGHooks[index].selector == selector) return YES;
    }
    return NO;
}

static void UGInstallHook(Class cls, Method method, int arity)
{
    SEL selector = method_getName(method);
    IMP replacement = UGHookFunctionForArity(arity);

    if (sUGHookCount >= kUGMaxHooks || !replacement || UGHookHasSelector(selector)) return;

    sUGHooks[sUGHookCount].selector = selector;
    sUGHooks[sUGHookCount].cls = cls;
    sUGHooks[sUGHookCount].original = method_getImplementation(method);
    sUGHookCount++;
    method_setImplementation(method, replacement);
}

/*
 * Compile-time shapes of the private SpringBoard classes that are only queried.
 * The factories are declared on the protocols, so the receiver is a
 * protocol-qualified Class and every call is an ordinary typed message send:
 * no objc_msgSend casts and no ARC retain or release of anything that is not
 * provably an object. Each use is still guarded by respondsToSelector:.
 */
@protocol UGAwayControllerProbe <NSObject>
+ (id)sharedAwayController;
- (BOOL)isLocked;
- (BOOL)isDimmed;
@end

@protocol UGBacklightProbe <NSObject>
+ (id)sharedInstance;
- (BOOL)screenIsOn;
@end

@protocol UGLockScreenProbe <NSObject>
+ (id)sharedInstance;
- (BOOL)isLocked;
@end

/*
 * Private-state probes, best first for iOS 6:
 *   1. SBAwayController (iOS 5/6): +sharedAwayController, -isLocked, -isDimmed.
 *   2. SBLockScreenManager / SBBacklightController (iOS 7+; absent on target).
 *   3. notify(3) state of lockstate / hasBlankedScreen.
 * The notification *name* is never used as a value: lockstate fires on lock and
 * on unlock alike, so the name alone cannot say which way the state moved.
 */
static BOOL UGAwayControllerLocked(BOOL *locked, BOOL *dimmed)
{
    Class cls = NSClassFromString(@"SBAwayController");
    id<UGAwayControllerProbe> controller;

    if (!cls) return NO;
    if (![(id)cls respondsToSelector:@selector(sharedAwayController)]) return NO;
    controller = [(id<UGAwayControllerProbe>)cls sharedAwayController];
    if (!controller) return NO;

    *locked = [controller isLocked];
    *dimmed = [controller respondsToSelector:@selector(isDimmed)]
        ? [controller isDimmed]
        : NO;
    return YES;
}

static BOOL UGBacklightScreenOn(BOOL *on)
{
    Class cls = NSClassFromString(@"SBBacklightController");
    id<UGBacklightProbe> controller;

    if (!cls) return NO;
    if (![(id)cls respondsToSelector:@selector(sharedInstance)]) return NO;
    controller = [(id<UGBacklightProbe>)cls sharedInstance];
    if (!controller || ![controller respondsToSelector:@selector(screenIsOn)]) return NO;

    *on = [controller screenIsOn];
    return YES;
}

static BOOL UGLockScreenManagerLocked(BOOL *locked)
{
    Class cls = NSClassFromString(@"SBLockScreenManager");
    id<UGLockScreenProbe> manager;

    if (!cls) return NO;
    if (![(id)cls respondsToSelector:@selector(sharedInstance)]) return NO;
    manager = [(id<UGLockScreenProbe>)cls sharedInstance];
    if (!manager || ![manager respondsToSelector:@selector(isLocked)]) return NO;

    *locked = [manager isLocked];
    return YES;
}

static BOOL UGNotificationStateValue(NSString *name, int *token, BOOL *value)
{
    uint64_t state = 0;

    if (*token < 0 && notify_register_check([name UTF8String], token) != NOTIFY_STATUS_OK) {
        *token = -1;
        return NO;
    }
    if (notify_get_state(*token, &state) != NOTIFY_STATUS_OK) return NO;
    *value = state != 0;
    return YES;
}

static void UGDarwinNotificationCallback(CFNotificationCenterRef center,
                                         void *observer,
                                         CFStringRef name,
                                         const void *object,
                                         CFDictionaryRef userInfo)
{
    UGRuntime *runtime;

    (void)center;
    (void)object;
    (void)userInfo;

    runtime = (__bridge UGRuntime *)observer;
    [runtime performSelectorOnMainThread:@selector(handleDarwinNotification:)
                              withObject:(__bridge NSString *)name
                           waitUntilDone:NO];
}

@interface UGRuntime () <UGOverlayControllerDelegate, UGParentPanelDelegate>
- (void)handleSettingsChanged;
- (BOOL)adoptDiskStateIfChanged;
- (void)beginTestOverlay;
- (void)updateTestOverlayAt:(long long)now;
- (void)endTestOverlay;
- (void)writeStatusIfNeeded:(BOOL)forced;
@end

@implementation UGRuntime {
    UGPrefs *_prefs;
    UGState _state;

    NSTimer *_timer;
    UGOverlayWindow *_window;
    __weak UGParentPanelController *_panel;
    BOOL _panelPresented;

    BOOL _started;
    BOOL _activated;
    BOOL _inert;
    BOOL _screenOn;
    BOOL _unlocked;
    BOOL _callActive;

    long long _emergencyUntil;
    BOOL _emergencyCallSeen;
    long long _lastPersistWall;
    NSString *_savedStateString;
    CTCallCenter *_callCenter;

    BOOL _setupComplete;

    /* Status file: identity, last written signature and wall clock. */
    long long _runtimePID;
    long long _runtimeStartedAt;
    NSString *_lastStatusSignature;
    long long _lastStatusWriteWall;
    BOOL _statusFailureLogged;

    /* Settings preview: the real state machine is untouched by it. */
    BOOL _testModeActive;
    long long _testModeUntil;
}

+ (instancetype)sharedRuntime
{
    /* Created on the SpringBoard main thread; every caller is main-thread. */
    static UGRuntime *shared = nil;
    if (!shared) shared = [[UGRuntime alloc] init];
    return shared;
}

#pragma mark - Lifecycle

- (void)start
{
    if (_started) return;
    _started = YES;

    _prefs = [UGPrefs sharedPrefs];
    [_prefs loadState:&_state now:UGNowSeconds()];
    _savedStateString = [_prefs diskStateString];

    /* While the kill switch is engaged the plist must not be touched at all,
     * and -setupComplete may migrate (write) the key. The migration is
     * therefore deferred to -activate, which only runs once the runtime is
     * live. */
    if (!UGKillSwitchEngaged()) _setupComplete = [_prefs setupComplete];

    _runtimePID = (long long)getpid();
    if (_runtimeStartedAt <= 0) _runtimeStartedAt = UGNowSeconds();

    /* Nothing about the device is assumed: both flags stay NO until a real
     * query says otherwise, so usage can never be credited at the lock screen
     * and the overlay can never cover it. */
    _screenOn = NO;
    _unlocked = NO;

    if (![self enterInertModeIfNeeded]) [self activate];

    /* The clock runs even while inert: it is what notices the operator
     * removing the disable marker, and it performs no accounting then. */
    _timer = [NSTimer timerWithTimeInterval:1.0
                                     target:self
                                   selector:@selector(tick)
                                   userInfo:nil
                                    repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:_timer forMode:NSRunLoopCommonModes];
}

/* Installs hooks, notifications and the window. Idempotent. */
- (void)activate
{
    _setupComplete = [_prefs setupComplete];

    if (!_activated) {
        _activated = YES;
        if (_runtimeStartedAt <= 0) _runtimeStartedAt = UGNowSeconds();
        [self refreshDeviceState];
        [self refreshCallActive];
        [self registerDarwinNotifications];
        [self installBypassHooks];
        [self ensureWindow];
    }

    /* A fresh install stays inert-but-loaded: nothing is persisted and nothing
     * is locked until Settings (or the panel wizard) records a PIN. */
    [self syncUI];
    if (_setupComplete) [self persistIfChanged:YES];
    [self writeStatusIfNeeded:YES];
}

/*
 * Operator escape hatch. Returns YES while the runtime must stay inert: no
 * overlay, no hooks installed (an already installed one simply forwards), no
 * accounting and no PIN wizard. The marker file is never created or removed
 * here.
 */
- (BOOL)enterInertModeIfNeeded
{
    if (!UGKillSwitchEngaged()) {
        if (!_inert) return NO;
        _inert = NO;
        UGLog(@"Usage Guard: disable marker removed, resuming");
        /* Settings may have written while the tweak was inert (enable, limits,
         * pause, a new PIN). Re-read the file before re-anchoring: starting
         * from the stale cache would persist the old state over those writes
         * and verifyPIN: could restore a replaced PIN vault. */
        [_prefs reloadFromDisk];
        [_prefs loadState:&_state now:UGNowSeconds()];
        _setupComplete = [_prefs setupComplete];
        /* The inert interval is not credited to usage; a break keeps elapsing. */
        ug_state_startup(&_state, UGNowSeconds());
        [self activate];
        [self writeStatusIfNeeded:YES];
        return NO;
    }

    if (!_inert) {
        _inert = YES;
        sUGOverlayLocked = 0;
        _emergencyUntil = 0;
        _emergencyCallSeen = NO;
        /* A preview left running would keep the overlay window visible while
         * the tweak is supposed to be doing nothing at all. */
        [self endTestOverlay];

        if (_panelPresented) {
            _panelPresented = NO;
            _panel = nil;
            [_window.overlayController dismissViewControllerAnimated:NO completion:nil];
        }
        [_window.overlayController updateLocked:NO remaining:0 duration:0];
        [_window setHidden:YES];
        UGLog(@"Usage Guard: disable marker present, tweak is inert");
        [self writeStatusIfNeeded:YES];
    }
    return YES;
}

#pragma mark - Clock

- (void)tick
{
    long long now;
    int events;
    BOOL wasScreenOn;
    BOOL wasUnlocked;

    if ([self enterInertModeIfNeeded]) {
        /* Inert: no accounting and no UI, but the heartbeat keeps running so
         * the Preferences pane can tell "loaded but inert" from "not loaded". */
        [self writeStatusIfNeeded:NO];
        return;
    }

    wasScreenOn = _screenOn;
    wasUnlocked = _unlocked;

    /* Re-query every second so a missed unlock notification cannot leave the
     * overlay hidden — or on the lock screen — for the rest of a break. */
    [self refreshDeviceState];
    [self refreshCallActive];
    [self updateEmergencyState];
    [self rebaseClockIfBecameActive:(wasScreenOn && wasUnlocked)];

    now = UGNowSeconds();
    /* Until setup is complete the clock is not ticked and nothing is persisted:
     * a fresh install must not lock anything, and there is no agreement yet on
     * durations to enforce. Device state and the status file stay live. */
    events = _setupComplete
        ? ug_tick(&_state, now, _screenOn ? 1 : 0, _unlocked ? 1 : 0)
        : UGEventNone;

    [self syncUI];
    [self pushStateToPanel];

    if (_setupComplete) {
        [self persistIfChanged:(events != UGEventNone ||
                                _screenOn != wasScreenOn ||
                                _unlocked != wasUnlocked)];
    }
    [self writeStatusIfNeeded:NO];
}

/*
 * The 1 Hz timer stops while the device sleeps, so the first tick after an
 * unlock sees a huge gap and would credit UG_MAX_CREDIT_SECONDS of it even
 * though nothing was used. Whenever the device goes from inactive (screen off
 * or locked) to active, move the usage anchor to now: the inactive gap is not
 * usage. Breaks are unaffected: they elapse in real time by design.
 */
- (void)rebaseClockIfBecameActive:(BOOL)wasActive
{
    if (!wasActive && _screenOn && _unlocked) {
        ug_rebase_last_wall(&_state, UGNowSeconds());
    }
}

/*
 * `forced` marks a real transition (phase change, lock/screen change, parent
 * action). Everything else is rate limited, so the plist is not rewritten every
 * second just because the wall clock moved.
 */
- (void)persistIfChanged:(BOOL)forced
{
    char buffer[UG_STATE_BUFFER_SIZE];
    NSString *encoded;
    long long now;

    if (!_prefs) return;
    if (ug_serialize(&_state, buffer, sizeof buffer) == 0) return;
    encoded = [NSString stringWithUTF8String:buffer];
    if (_savedStateString && [encoded isEqualToString:_savedStateString]) return;

    now = UGNowSeconds();
    /* Only rate limit while the clock is consistent: after a backward jump the
     * gap is negative, and skipping then would permanently disable the saves. */
    if (!forced && now >= _lastPersistWall &&
        now - _lastPersistWall < kUGPersistIntervalSeconds) return;

    /* Another process wrote the cycle state since our last save (the pane can
     * land between a Settings write and the notification, or while this
     * process also saves). Writing now would replace that change, so adopt it
     * first and let the normal decision run on the merged state. */
    if ([self adoptDiskStateIfChanged]) {
        if (ug_serialize(&_state, buffer, sizeof buffer) == 0) return;
        encoded = [NSString stringWithUTF8String:buffer];
        if (_savedStateString && [encoded isEqualToString:_savedStateString]) return;
        now = UGNowSeconds();
    }

    if ([_prefs saveState:&_state]) {
        _savedStateString = encoded;
        _lastPersistWall = now;
    }
}

#pragma mark - UI synchronisation

- (void)ensureWindow
{
    if (_window) return;
    _window = [[UGOverlayWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    _window.overlayController.delegate = self;
}

/* Read-only telephony state: the overlay must never cover an active call. */
- (void)refreshCallActive
{
    if (!_callCenter) _callCenter = [[CTCallCenter alloc] init];
    _callActive = _callCenter.currentCalls.count > 0;
}

/*
 * Closes the emergency escape window as soon as the call ends, or after
 * kUGEmergencyNoCallSeconds when no call ever started: dialling 112 and hanging
 * up must not keep the overlay away.
 */
- (void)updateEmergencyState
{
    long long now;

    if (_emergencyUntil <= 0) return;

    now = UGNowSeconds();
    if (_callActive) {
        /* A real call keeps the overlay away for its whole length; the window
         * closes as soon as the call ends. */
        _emergencyCallSeen = YES;
        return;
    }

    if (_emergencyCallSeen || now >= _emergencyUntil) {
        _emergencyUntil = 0;
        _emergencyCallSeen = NO;
    }
}

- (void)syncUI
{
    long long now;
    BOOL emergency;
    BOOL locked;

    /* A refresh queued before the kill switch must not lock the home button
     * while the tweak is inert: tick never runs then, so nothing would undo it. */
    if (_inert) {
        sUGOverlayLocked = 0;
        return;
    }

    now = UGNowSeconds();

    if (_testModeActive) {
        if (!_screenOn || !_unlocked || _callActive) {
            /* A preview must never sit over the lock screen, a dark screen or
             * a call screen: end it as soon as the device stops being usable. */
            [self endTestOverlay];
        } else if (_panelPresented) {
            /* The panel needs the window; the preview must not fight it. */
            [self endTestOverlay];
        } else if (!(ug_is_locked(&_state, now) && _screenOn && _unlocked &&
                     _emergencyUntil <= now && !_callActive)) {
            /* Preview in progress: it owns the window and deliberately leaves
             * sUGOverlayLocked alone, so Home and Siri keep working. */
            [self ensureWindow];
            [_window setHidden:NO];
            _window.windowLevel = UIWindowLevelAlert + 1000.0f;
            [self updateTestOverlayAt:now];
            return;
        } else {
            /* A real break fell due during the preview: it wins outright. */
            [self endTestOverlay];
        }
    }

    /* Fresh install: no enforcement at all, and the overlay window stays down
     * unless the parent panel itself is on screen. */
    if (!_setupComplete) {
        sUGOverlayLocked = 0;
        if (_window) {
            [_window.overlayController updateLocked:NO remaining:0 duration:0];
            if (!_panelPresented) [_window setHidden:YES];
        }
        return;
    }

    emergency = _emergencyUntil > now;
    locked = ug_is_locked(&_state, now) && _screenOn && _unlocked &&
             !emergency && !_callActive;

    /* The window hides for the emergency valve and for any call, but the
     * bypass hooks stay armed for as long as the valve window is open —
     * including the whole duration of an emergency call, not just the 15 s
     * deadline. Hiding the overlay must not hand out free SpringBoard access.
     * A plain call that was not started from the overlay arms nothing. */
    sUGOverlayLocked = (locked || _emergencyUntil > 0) ? 1 : 0;

    if (!_window) return;

    if (locked) {
        [_window setHidden:NO];
        _window.windowLevel = UIWindowLevelAlert + 1000.0f;
        [_window.overlayController updateLocked:YES
                                     remaining:_state.remaining
                                      duration:(long long)_state.breakMinutes * 60LL];
    } else {
        [_window.overlayController updateLocked:NO remaining:0 duration:0];
        if (!_panelPresented) [_window setHidden:YES];
    }
}

- (void)pushStateToPanel
{
    UGParentPanelController *panel = _panel;
    if (_panelPresented && panel) [panel updateState:_state];
}

#pragma mark - Settings preview

/*
 * Five-second preview requested by the Preferences pane. It renders the real
 * break screen with test copy, but hands nothing to the guard: the state
 * machine, the persisted state and sUGOverlayLocked are all left untouched, so
 * the child can still use Home and Siri and the preview expires by itself.
 */
- (void)beginTestOverlay
{
    long long now;

    if (_inert || _panelPresented) return;
    /* Same rule as tick: never start a preview over a lock screen, a dark
     * screen or a call. */
    if (!_screenOn || !_unlocked || _callActive) return;
    /* A real break is already on screen: the preview has nothing to add and
     * must not replace the live countdown. */
    if (ug_is_locked(&_state, UGNowSeconds()) && _screenOn && _unlocked) return;

    [self ensureWindow];
    now = UGNowSeconds();
    _testModeActive = YES;
    _testModeUntil = now + kUGTestOverlaySeconds;
    [_window.overlayController setTestMode:YES];
    [_window setHidden:NO];
    _window.windowLevel = UIWindowLevelAlert + 1000.0f;
    [self updateTestOverlayAt:now];
}

- (void)updateTestOverlayAt:(long long)now
{
    long long remaining = _testModeUntil - now;

    if (remaining <= 0) {
        [self endTestOverlay];
        return;
    }
    [_window.overlayController updateLocked:YES
                                 remaining:remaining
                                  duration:kUGTestOverlaySeconds];
}

- (void)endTestOverlay
{
    if (!_testModeActive) return;

    _testModeActive = NO;
    _testModeUntil = 0;
    if (!_window) return;

    [_window.overlayController setTestMode:NO];
    [_window.overlayController updateLocked:NO remaining:0 duration:0];
    if (!_panelPresented) [_window setHidden:YES];
}

#pragma mark - Status file

/*
 * Heartbeat read by the Preferences pane. Written when something meaningful
 * changed, when it is older than kUGStatusRefreshSeconds, or when forced. The
 * signature deliberately leaves Remaining, OverrideRemaining and LastTick out:
 * they move every second, and rewriting the plist at 1 Hz would be pure churn
 * for a heartbeat the 2 s refresh already keeps fresh. A failed write is
 * logged once and otherwise ignored; the guard never depends on it.
 */
- (void)writeStatusIfNeeded:(BOOL)forced
{
    long long now;
    long long overrideRemaining;
    BOOL enabled;
    BOOL killSwitch;
    BOOL debugLogging;
    NSDictionary *status;
    NSString *signature;

    if (!_prefs) return;

    now = UGNowSeconds();
    overrideRemaining = ug_override_remaining(&_state, now);
    enabled = (_setupComplete && _state.enabled) ? YES : NO;
    killSwitch = UGKillSwitchEngaged();
    debugLogging = UGDebugLoggingEnabled();

    /* Deliberately no Remaining and no OverrideRemaining here: both move with
     * the clock and would otherwise rewrite the file at 1 Hz. With them
     * excluded, a write happens when a real field changes or when the 2 s
     * heartbeat is due, and LastTick below is refreshed on that write. */
    signature = [NSString stringWithFormat:
        @"%lld|%lld|%d|%d|%d|%d|%d|%d|%d|%d|%@",
        _runtimePID,
        _runtimeStartedAt,
        enabled ? 1 : 0,
        _setupComplete ? 1 : 0,
        _state.phase,
        _state.usageMinutes,
        _state.breakMinutes,
        _inert ? 1 : 0,
        killSwitch ? 1 : 0,
        debugLogging ? 1 : 0,
        @UG_VERSION];

    if (!forced && _lastStatusWriteWall > 0 &&
        [signature isEqualToString:_lastStatusSignature] &&
        now >= _lastStatusWriteWall &&
        now - _lastStatusWriteWall < kUGStatusRefreshSeconds) {
        return;
    }

    status = @{
        @"RuntimePID": @(_runtimePID),
        @"RuntimeStartedAt": @(_runtimeStartedAt),
        @"LastTick": @(now),
        @"Enabled": @(enabled),
        @"SetupComplete": @(_setupComplete),
        @"Phase": @(_state.phase),
        @"Remaining": @(_state.remaining),
        @"UsageMinutes": @(_state.usageMinutes),
        @"BreakMinutes": @(_state.breakMinutes),
        @"OverrideRemaining": @(overrideRemaining),
        @"Inert": @(_inert),
        @"KillSwitch": @(killSwitch),
        @"DebugLogging": @(debugLogging),
        @"Version": @UG_VERSION
    };

    if (![status writeToFile:@UG_STATUS_PATH atomically:YES]) {
        if (!_statusFailureLogged) {
            _statusFailureLogged = YES;
            UGLog(@"Usage Guard: could not write %@", @UG_STATUS_PATH);
        }
        return;
    }

    _statusFailureLogged = NO;
    _lastStatusSignature = signature;
    _lastStatusWriteWall = now;
    notify_post([kUGNotifyStatusChanged UTF8String]);
}

#pragma mark - Settings reload

/*
 * Takes over the cycle state another process wrote (the pane's enable/disable,
 * limits, pause or reset), and only when the string on disk differs from the
 * one this runtime last wrote. Returns YES when the disk state was adopted;
 * otherwise the in-memory state stays authoritative.
 */
- (BOOL)adoptDiskStateIfChanged
{
    NSString *onDisk;
    long long now;

    if (!_prefs) return NO;
    onDisk = [_prefs diskStateString];
    /* nil means the file or the key is absent/unreadable: nothing to adopt. */
    if (!onDisk) return NO;
    if (_savedStateString && [onDisk isEqualToString:_savedStateString]) return NO;

    [_prefs reloadFromDisk];
    now = UGNowSeconds();
    [_prefs loadState:&_state now:now];
    _savedStateString = onDisk;
    UGLog(@"Usage Guard: adopted the cycle state written by Settings");
    return YES;
}

/*
 * The Preferences pane just wrote the plist. SetupComplete, RequirePIN and the
 * PIN vault are refreshed on every notification; the cycle state is adopted
 * only when the file really holds a different State than the one this runtime
 * last wrote. A notification that never touched State (PIN check, a failed
 * attempt, setRequirePIN:, setSetupComplete:) must not throw away the usage
 * accounted since the last persist — that would hand the child back up to a
 * minute of allowance on demand.
 */
- (void)handleSettingsChanged
{
    BOOL wasSetupComplete = _setupComplete;

    [_prefs reloadFromDisk];
    [self adoptDiskStateIfChanged];
    _setupComplete = [_prefs setupComplete];

    /* Enforcement only starts once setup is complete, so re-anchor the clock
     * the moment it becomes true instead of billing the time before it. */
    if (!wasSetupComplete && _setupComplete) {
        ug_state_startup(&_state, UGNowSeconds());
    }

    [self syncUI];
    [self pushStateToPanel];
    if (_setupComplete) [self persistIfChanged:YES];
    [self writeStatusIfNeeded:YES];
}

#pragma mark - Parent panel

- (void)presentPanelWithSetup:(BOOL)requiresSetup
{
    UGParentPanelController *panel;

    if (_panelPresented) return;

    [self endTestOverlay];
    [self ensureWindow];
    [_window setHidden:NO];
    [_window.overlayController updateLocked:NO remaining:0 duration:0];

    panel = [[UGParentPanelController alloc] initWithDelegate:self
                                                requiresSetup:requiresSetup];
    panel.modalPresentationStyle = UIModalPresentationFullScreen;
    _panel = panel;
    _panelPresented = YES;
    [_window.overlayController presentViewController:panel animated:YES completion:nil];
}

- (void)dismissPanel
{
    if (!_panelPresented) return;

    _panelPresented = NO;
    _panel = nil;
    [_window.overlayController dismissViewControllerAnimated:YES completion:nil];
    [self performSelector:@selector(delayedSyncUI:) withObject:nil afterDelay:0.4];
}

- (void)delayedSyncUI:(id)ignored
{
    (void)ignored;
    [self syncUI];
}

- (UGState)panelCurrentState
{
    return _state;
}

- (BOOL)panelVerifyPIN:(NSString *)pin
{
    return [_prefs verifyPIN:pin];
}

- (BOOL)panelStorePIN:(NSString *)pin
{
    BOOL stored = [_prefs setPIN:pin];

    /* The panel's own wizard is a valid first-run path: a stored PIN is what
     * makes enforcement legal, so record setup completion with it. */
    if (stored && !_setupComplete && [_prefs setSetupComplete:YES]) {
        _setupComplete = YES;
        ug_state_startup(&_state, UGNowSeconds());
        [self persistIfChanged:YES];
        [self syncUI];
        [self writeStatusIfNeeded:YES];
    }
    return stored;
}

- (NSInteger)panelPINLockoutSeconds
{
    return [_prefs PINLockoutRemainingSeconds];
}

- (void)panelApplyState:(UGState)state
{
    _state = state;
    if (_setupComplete) [self persistIfChanged:YES];
    [self syncUI];
}

- (void)panelRequestDismiss
{
    [self dismissPanel];
}

#pragma mark - Overlay actions

- (void)overlayControllerDidRequestParentAccess:(UGOverlayController *)controller
{
    (void)controller;
    [self presentPanelWithSetup:![_prefs hasPIN]];
}

- (void)overlayControllerDidRequestTestDismiss:(UGOverlayController *)controller
{
    (void)controller;
    /* Nothing to undo: the preview never armed the guard or moved the state. */
    [self endTestOverlay];
}

- (void)overlayControllerDidRequestEmergencyCall:(UGOverlayController *)controller
{
    NSURL *emergencyURL;

    (void)controller;

    /* Safety valve: the timeline steps aside for a short window so a real call
     * can be dialled. The window closes when the call ends (or after 15 s when
     * no call starts), so tapping and hanging up is not a way to stay out. */
    _emergencyUntil = UGNowSeconds() + kUGEmergencyNoCallSeconds;
    _emergencyCallSeen = NO;
    /* The window hides so the dialer is reachable, but the bypass hooks stay
     * armed: only the overlay goes away, not the guard. syncUI keeps them
     * armed for the whole emergency window. */
    sUGOverlayLocked = 1;
    [_window setHidden:YES];

    emergencyURL = [NSURL URLWithString:@"tel:112"];
    if (![[UIApplication sharedApplication] canOpenURL:emergencyURL]) {
        _emergencyUntil = 0;
        /* The alert window sits below the overlay window, so the message has to
         * live inside the overlay itself to be readable. */
        [self ensureWindow];
        [_window.overlayController
            showNotice:@"Apelul de urgență nu este disponibil pe acest dispozitiv."];
        [self syncUI];
        return;
    }

    [[UIApplication sharedApplication] openURL:emergencyURL];
    [self persistIfChanged:YES];
}

#pragma mark - Device state

/*
 * Builds the real device state from private queries, never from the
 * notification name. Anything that cannot be determined is treated as "not
 * usable": no usage credit and no overlay on a guess.
 */
- (void)refreshDeviceState
{
    BOOL locked = NO;
    BOOL dimmed = NO;
    BOOL value = NO;
    BOOL unlockKnown = NO;
    BOOL screenKnown = NO;

    /* 1. iOS 5/6 away controller: authoritative for the lock state. */
    if (UGAwayControllerLocked(&locked, &dimmed)) {
        _unlocked = !locked;
        unlockKnown = YES;
        if (locked) {
            _screenOn = !dimmed;
            screenKnown = YES;
        }
    }

    /* 2. iOS 7+ controllers; absent on the target device. */
    if (!screenKnown && UGBacklightScreenOn(&value)) {
        _screenOn = value;
        screenKnown = YES;
    }
    if (!unlockKnown && UGLockScreenManagerLocked(&value)) {
        _unlocked = !value;
        unlockKnown = YES;
    }

    /* 3. Last resort on iOS 6: the notify(3) *state* of the same notifications
     *    says whether the phone is locked or the screen is blanked. */
    if (!unlockKnown &&
        UGNotificationStateValue(kUGNotificationLockState, &sUGLockStateToken, &value)) {
        _unlocked = !value;
        unlockKnown = YES;
    }
    if (!screenKnown &&
        UGNotificationStateValue(kUGNotificationScreenBlanked, &sUGBlankedToken, &value)) {
        _screenOn = !value;
        screenKnown = YES;
    }

    if (!unlockKnown) _unlocked = NO;
    if (!screenKnown) _screenOn = NO;
}

- (void)handleDarwinNotification:(NSString *)name
{
    BOOL wasScreenOn = _screenOn;
    BOOL wasUnlocked = _unlocked;

    if ([name isEqualToString:kUGNotifySettingsChanged]) {
        if ([self enterInertModeIfNeeded]) return;
        [self handleSettingsChanged];
        return;
    }
    if ([name isEqualToString:kUGNotifyTestOverlay]) {
        if ([self enterInertModeIfNeeded]) return;
        [self beginTestOverlay];
        return;
    }

    if ([self enterInertModeIfNeeded]) return;

    [self refreshDeviceState];
    [self rebaseClockIfBecameActive:(wasScreenOn && wasUnlocked)];
    if (!_unlocked && _panelPresented) [self dismissPanel];
    if (_setupComplete) {
        [self persistIfChanged:(_screenOn != wasScreenOn || _unlocked != wasUnlocked)];
    }
    [self syncUI];
}

#pragma mark - Notifications and hooks

- (void)registerDarwinNotifications
{
    CFNotificationCenterRef center = CFNotificationCenterGetDarwinNotifyCenter();
    NSArray *names = @[kUGNotificationScreenBlanked,
                       kUGNotificationLockComplete,
                       kUGNotificationLockState,
                       kUGNotifySettingsChanged,
                       kUGNotifyTestOverlay];

    for (NSString *name in names) {
        CFNotificationCenterAddObserver(center,
                                        (__bridge const void *)self,
                                        UGDarwinNotificationCallback,
                                        (__bridge CFStringRef)name,
                                        NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
    }
}

- (void)installBypassHooks
{
    /* Exact class/selector pairs only: no prefix matching, so a future SpringBoard
     * method that happens to start the same way is never swizzled by accident. */
    for (size_t entry = 0; entry < sizeof(kUGAllowlist) / sizeof(kUGAllowlist[0]); entry++) {
        Class targetClass = NSClassFromString(
            [NSString stringWithUTF8String:kUGAllowlist[entry].className]);
        SEL selector = NSSelectorFromString(
            [NSString stringWithUTF8String:kUGAllowlist[entry].selectorName]);
        Method method;
        int arity = 0;

        if (!targetClass) continue;
        method = class_getInstanceMethod(targetClass, selector);
        if (!method) continue;
        if (!UGMethodIsBlockable(method, &arity)) continue;
        UGInstallHook(targetClass, method, arity);
    }

    UGLog(@"Usage Guard: %ld bypass hook(s) installed", (long)sUGHookCount);
}

@end
