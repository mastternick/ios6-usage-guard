#import "UGRuntime.h"

#import <CoreTelephony/CTCallCenter.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdlib.h>

#import "UGGuardCore.h"
#import "UGOverlayWindow.h"
#import "UGParentPanel.h"
#import "UGPrefs.h"

static NSString *const kUGNotificationScreenBlanked = @"com.apple.springboard.hasBlankedScreen";
static NSString *const kUGNotificationLockComplete = @"com.apple.springboard.lockcomplete";
static NSString *const kUGNotificationLockState = @"com.apple.springboard.lockstate";

static const long long kUGEmergencyWindowSeconds = 120;
static const long long kUGPersistIntervalSeconds = 5;
enum { kUGMaxHooks = 16 };

/*
 * Very narrow swizzle allowlist: Siri activation and the home-button menu
 * actions. Power, volume, lock and telephony are never touched. Only methods
 * that return void and take at most three single-word arguments are hooked
 * (checked at runtime from the method's own type encoding).
 */
typedef struct {
    const char *className;
    const char *selectorPrefix;
} UGAllowlistEntry;

static const UGAllowlistEntry kUGAllowlist[] = {
    { "SBAssistantController", "activate" },
    { "SBUIController", "handleMenuButton" },
    { "SBUIController", "_menuButton" }
};

typedef struct {
    SEL selector;
    __unsafe_unretained Class cls;
    IMP original;
    int arity;
} UGHookEntry;

static UGHookEntry sUGHooks[kUGMaxHooks];
static NSInteger sUGHookCount = 0;
static BOOL sUGHooksInstalled = NO;
static volatile int sUGOverlayLocked = 0;

static IMP UGOriginalImplementation(id self, SEL selector)
{
    for (NSInteger index = 0; index < sUGHookCount; index++) {
        if (sUGHooks[index].selector != selector) continue;
        if (!sUGHooks[index].cls || [self isKindOfClass:sUGHooks[index].cls]) {
            return sUGHooks[index].original;
        }
    }
    return NULL;
}

/* One forwarder per arity keeps the original call signature exact: all the
 * allowlisted argument types are single 32-bit words, so passing them as id
 * preserves the bits. */
static void UGHook0(id self, SEL selector)
{
    IMP original;
    if (sUGOverlayLocked) return;
    original = UGOriginalImplementation(self, selector);
    if (!original) return;
    ((void (*)(id, SEL))original)(self, selector);
}

static void UGHook1(id self, SEL selector, id first)
{
    IMP original;
    if (sUGOverlayLocked) return;
    original = UGOriginalImplementation(self, selector);
    if (!original) return;
    ((void (*)(id, SEL, id))original)(self, selector, first);
}

static void UGHook2(id self, SEL selector, id first, id second)
{
    IMP original;
    if (sUGOverlayLocked) return;
    original = UGOriginalImplementation(self, selector);
    if (!original) return;
    ((void (*)(id, SEL, id, id))original)(self, selector, first, second);
}

static void UGHook3(id self, SEL selector, id first, id second, id third)
{
    IMP original;
    if (sUGOverlayLocked) return;
    original = UGOriginalImplementation(self, selector);
    if (!original) return;
    ((void (*)(id, SEL, id, id, id))original)(self, selector, first, second, third);
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
    sUGHooks[sUGHookCount].arity = arity;
    sUGHookCount++;
    method_setImplementation(method, replacement);
}

static void UGUninstallHooks(void)
{
    for (NSInteger index = sUGHookCount - 1; index >= 0; index--) {
        Method method = class_getInstanceMethod(sUGHooks[index].cls, sUGHooks[index].selector);
        if (method && method_getImplementation(method) ==
                      UGHookFunctionForArity(sUGHooks[index].arity)) {
            method_setImplementation(method, sUGHooks[index].original);
        }
        sUGHooks[index].selector = NULL;
        sUGHooks[index].cls = Nil;
        sUGHooks[index].original = NULL;
        sUGHooks[index].arity = 0;
    }
    sUGHookCount = 0;
    sUGHooksInstalled = NO;
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
    BOOL _screenOn;
    BOOL _unlocked;

    long long _emergencyUntil;
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

    _screenOn = YES;
    _unlocked = YES;
    [self refreshDeviceStateFromNotification:nil];

    [self registerDarwinNotifications];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationDidBecomeActive:)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];

    [self installBypassHooks];
    [self ensureWindow];

    _timer = [NSTimer timerWithTimeInterval:1.0
                                     target:self
                                   selector:@selector(tick)
                                   userInfo:nil
                                    repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:_timer forMode:NSRunLoopCommonModes];

    _needsFirstRunWizard = ![_prefs hasPIN];

    [self syncUI];
    [self persistIfChanged];
}

- (void)stop
{
    if (!_started) return;
    _started = NO;

    [_timer invalidate];
    _timer = nil;

    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    [[NSNotificationCenter defaultCenter] removeObserver:self];

    {
        CFNotificationCenterRef center = CFNotificationCenterGetDarwinNotifyCenter();
        NSArray *names = @[kUGNotificationScreenBlanked,
                           kUGNotificationLockComplete,
                           kUGNotificationLockState];
        for (NSString *name in names) {
            CFNotificationCenterRemoveObserver(center,
                                               (__bridge const void *)self,
                                               (__bridge CFStringRef)name,
                                               NULL);
        }
    }

    [self persistIfChanged];

    if (_panelPresented) {
        _panelPresented = NO;
        _panel = nil;
        [_window.overlayController dismissViewControllerAnimated:NO completion:nil];
    }

    sUGOverlayLocked = 0;
    [_window setHidden:YES];
    _window = nil;

    UGUninstallHooks();
}

#pragma mark - Clock

- (void)tick
{
    long long now;
    int events;

    /* Re-query every second so a missed unlock notification cannot leave the
     * overlay hidden for the rest of a break. */
    [self refreshDeviceStateFromNotification:nil];

    now = UGNowSeconds();
    events = ug_tick(&_state, now, _screenOn ? 1 : 0, _unlocked ? 1 : 0);

    [self syncUI];
    [self pushStateToPanel];

    if (events != UGEventNone || now - _lastPersistWall >= kUGPersistIntervalSeconds) {
        [self persistIfChanged];
    }

    if (_needsFirstRunWizard && !_panelPresented && _screenOn && _unlocked) {
        _needsFirstRunWizard = NO;
        [self presentPanelWithSetup:YES];
    }
}

- (void)persistIfChanged
{
    char buffer[UG_STATE_BUFFER_SIZE];
    NSString *encoded;

    if (ug_serialize(&_state, buffer, sizeof buffer) == 0) return;
    encoded = [NSString stringWithUTF8String:buffer];
    if (_savedStateString && [encoded isEqualToString:_savedStateString]) return;

    if ([_prefs saveState:&_state]) {
        _savedStateString = encoded;
        _lastPersistWall = UGNowSeconds();
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
- (BOOL)isCallActive
{
    if (!_callCenter) _callCenter = [[CTCallCenter alloc] init];
    return _callCenter.currentCalls.count > 0;
}

- (void)syncUI
{
    long long now = UGNowSeconds();
    BOOL emergency = _emergencyUntil > now;
    BOOL locked = ug_is_locked(&_state, now) && _screenOn && _unlocked &&
                  !emergency && ![self isCallActive];

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
    [self persistIfChanged];
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

    /* Safety valve: the timeline is hidden for a bounded window so a real call
     * can be placed even though every other interaction is blocked. */
    _emergencyUntil = UGNowSeconds() + kUGEmergencyWindowSeconds;
    sUGOverlayLocked = 0;
    [_window setHidden:YES];

    emergencyURL = [NSURL URLWithString:@"tel:112"];
    if (![[UIApplication sharedApplication] canOpenURL:emergencyURL]) {
        UIAlertView *alert;
        _emergencyUntil = 0;
        [self syncUI];
        alert = [[UIAlertView alloc] initWithTitle:@"Apel de urgență"
                                         message:@"Apelul de urgență nu este disponibil pe acest dispozitiv."
                                        delegate:nil
                               cancelButtonTitle:@"OK"
                               otherButtonTitles:nil];
        [alert show];
        return;
    }

    [[UIApplication sharedApplication] openURL:emergencyURL];
    [self persistIfChanged];
}

#pragma mark - Device state

- (void)refreshDeviceStateFromNotification:(NSString *)notification
{
    BOOL queriedScreen = NO;
    BOOL queriedLock = NO;
    BOOL screenOn = _screenOn;
    BOOL unlocked = _unlocked;

    {
        Class backlightClass = NSClassFromString(@"SBBacklightController");
        if (backlightClass && [backlightClass respondsToSelector:@selector(sharedInstance)]) {
            id controller = [backlightClass performSelector:@selector(sharedInstance)];
            SEL selector = NSSelectorFromString(@"screenIsOn");
            if (controller && [controller respondsToSelector:selector]) {
                screenOn = ((BOOL (*)(id, SEL))objc_msgSend)(controller, selector);
                queriedScreen = YES;
            }
        }
    }

    {
        Class lockScreenClass = NSClassFromString(@"SBLockScreenManager");
        if (lockScreenClass && [lockScreenClass respondsToSelector:@selector(sharedInstance)]) {
            id manager = [lockScreenClass performSelector:@selector(sharedInstance)];
            SEL selector = NSSelectorFromString(@"isLocked");
            if (manager && [manager respondsToSelector:selector]) {
                unlocked = !((BOOL (*)(id, SEL))objc_msgSend)(manager, selector);
                queriedLock = YES;
            }
        }
    }

    /* Conservative fallback for iOS 6 builds without these controllers: the
     * lock notifications are the only signal available. */
    if (!queriedScreen) {
        if ([notification isEqualToString:kUGNotificationScreenBlanked] ||
            [notification isEqualToString:kUGNotificationLockComplete]) {
            screenOn = NO;
        } else if ([notification isEqualToString:kUGNotificationLockState]) {
            screenOn = YES;
        }
    }
    if (!queriedLock) {
        if ([notification isEqualToString:kUGNotificationLockComplete]) {
            unlocked = NO;
        } else if ([notification isEqualToString:kUGNotificationLockState]) {
            unlocked = YES;
        }
    }

    _screenOn = screenOn;
    _unlocked = unlocked;
}

- (void)handleDarwinNotification:(NSString *)name
{
    [self refreshDeviceStateFromNotification:name];
    if (!_unlocked && _panelPresented) [self dismissPanel];
    [self persistIfChanged];
    [self syncUI];
}

- (void)applicationDidBecomeActive:(NSNotification *)notification
{
    (void)notification;
    [self refreshDeviceStateFromNotification:nil];
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
    if (sUGHooksInstalled) return;
    sUGHooksInstalled = YES;

    for (size_t entry = 0; entry < sizeof(kUGAllowlist) / sizeof(kUGAllowlist[0]); entry++) {
        Class targetClass = NSClassFromString(
            [NSString stringWithUTF8String:kUGAllowlist[entry].className]);
        NSString *prefix =
            [NSString stringWithUTF8String:kUGAllowlist[entry].selectorPrefix];

        if (!targetClass) continue;

        for (Class current = targetClass;
             current && current != [NSObject class];
             current = class_getSuperclass(current)) {
            unsigned int methodCount = 0;
            Method *methods = class_copyMethodList(current, &methodCount);
            if (!methods) continue;

            for (unsigned int index = 0; index < methodCount; index++) {
                Method method = methods[index];
                NSString *name = NSStringFromSelector(method_getName(method));
                int arity = 0;

                if (![name hasPrefix:prefix]) continue;
                if (!UGMethodIsBlockable(method, &arity)) continue;
                UGInstallHook(current, method, arity);
            }
            free(methods);
        }
    }

    UGLog(@"Usage Guard: %ld bypass hook(s) installed", (long)sUGHookCount);
}

@end
