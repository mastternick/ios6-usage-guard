#import "UGRuntime.h"

#import <CoreTelephony/CTCallCenter.h>
#import <UIKit/UIKit.h>
#import <notify.h>
#import <objc/runtime.h>
#import <stdint.h>
#import <stdlib.h>

#import "UGGuardCore.h"
#import "UGOverlayWindow.h"
#import "UGParentPanel.h"
#import "UGPrefs.h"

static NSString *const kUGNotificationScreenBlanked = @"com.apple.springboard.hasBlankedScreen";
static NSString *const kUGNotificationLockComplete = @"com.apple.springboard.lockcomplete";
static NSString *const kUGNotificationLockState = @"com.apple.springboard.lockstate";

/* Escape window for a real emergency call, and the upper bound while one runs. */
static const long long kUGEmergencyNoCallSeconds = 15;
static const long long kUGEmergencyCallSeconds = 120;

/* At most one state write per minute unless something actually happened. */
static const long long kUGPersistIntervalSeconds = 60;
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

static BOOL UGNotificationStateValue(const char *name, int *token, BOOL *value)
{
    uint64_t state = 0;

    if (*token < 0 && notify_register_check(name, token) != NOTIFY_STATUS_OK) {
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

    BOOL _needsFirstRunWizard;
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
    if (!_activated) {
        _activated = YES;
        [self refreshDeviceState];
        [self refreshCallActive];
        [self registerDarwinNotifications];
        [self installBypassHooks];
        [self ensureWindow];
    }

    _needsFirstRunWizard = ![_prefs hasPIN];

    [self syncUI];
    [self persistIfChanged:YES];
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
        /* The inert interval is not credited to usage; a break keeps elapsing. */
        ug_state_startup(&_state, UGNowSeconds());
        [self activate];
        return NO;
    }

    if (!_inert) {
        _inert = YES;
        sUGOverlayLocked = 0;
        _emergencyUntil = 0;
        _emergencyCallSeen = NO;
        _needsFirstRunWizard = NO;

        if (_panelPresented) {
            _panelPresented = NO;
            _panel = nil;
            [_window.overlayController dismissViewControllerAnimated:NO completion:nil];
        }
        [_window.overlayController updateLocked:NO remaining:0 duration:0];
        [_window setHidden:YES];
        UGLog(@"Usage Guard: disable marker present, tweak is inert");
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

    if ([self enterInertModeIfNeeded]) return;

    wasScreenOn = _screenOn;
    wasUnlocked = _unlocked;

    /* Re-query every second so a missed unlock notification cannot leave the
     * overlay hidden — or on the lock screen — for the rest of a break. */
    [self refreshDeviceState];
    [self refreshCallActive];
    [self updateEmergencyState];

    now = UGNowSeconds();
    events = ug_tick(&_state, now, _screenOn ? 1 : 0, _unlocked ? 1 : 0);

    [self syncUI];
    [self pushStateToPanel];

    [self persistIfChanged:(events != UGEventNone ||
                            _screenOn != wasScreenOn ||
                            _unlocked != wasUnlocked)];

    if (_needsFirstRunWizard && !_panelPresented && _screenOn && _unlocked) {
        _needsFirstRunWizard = NO;
        [self presentPanelWithSetup:YES];
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
    if (!forced && now - _lastPersistWall < kUGPersistIntervalSeconds) return;

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
        _emergencyCallSeen = YES;
        _emergencyUntil = now + kUGEmergencyCallSeconds;
        return;
    }

    if (_emergencyCallSeen || now >= _emergencyUntil) {
        _emergencyUntil = 0;
        _emergencyCallSeen = NO;
    }
}

- (void)syncUI
{
    long long now = UGNowSeconds();
    BOOL emergency = _emergencyUntil > now;
    BOOL locked = ug_is_locked(&_state, now) && _screenOn && _unlocked &&
                  !emergency && !_callActive;

    sUGOverlayLocked = locked ? 1 : 0;

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

#pragma mark - Parent panel

- (void)presentPanelWithSetup:(BOOL)requiresSetup
{
    UGParentPanelController *panel;

    if (_panelPresented) return;

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
    return [_prefs setPIN:pin];
}

- (NSInteger)panelPINLockoutSeconds
{
    return [_prefs PINLockoutRemainingSeconds];
}

- (void)panelApplyState:(UGState)state
{
    _state = state;
    [self persistIfChanged:YES];
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

- (void)overlayControllerDidRequestEmergencyCall:(UGOverlayController *)controller
{
    NSURL *emergencyURL;

    (void)controller;

    /* Safety valve: the timeline steps aside for a short window so a real call
     * can be dialled. The window closes when the call ends (or after 15 s when
     * no call starts), so tapping and hanging up is not a way to stay out. */
    _emergencyUntil = UGNowSeconds() + kUGEmergencyNoCallSeconds;
    _emergencyCallSeen = NO;
    sUGOverlayLocked = 0;
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

    (void)name;
    if ([self enterInertModeIfNeeded]) return;

    [self refreshDeviceState];
    if (!_unlocked && _panelPresented) [self dismissPanel];
    [self persistIfChanged:(_screenOn != wasScreenOn || _unlocked != wasUnlocked)];
    [self syncUI];
}

#pragma mark - Notifications and hooks

- (void)registerDarwinNotifications
{
    CFNotificationCenterRef center = CFNotificationCenterGetDarwinNotifyCenter();
    NSArray *names = @[kUGNotificationScreenBlanked,
                       kUGNotificationLockComplete,
                       kUGNotificationLockState];

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
