#import "UGPreferencesListController.h"

#import "UGGuardCore.h"
#import "UGPrefs.h"
#import "UGSettingsIPC.h"
#import "UGTrace.h"
#import "UGVersion.h"

/*
 * Row and alert constants. The row enums are not used to index anything: the
 * specifier array is the index. They remain as the documented order of each
 * group so the pane reads the same way as the standalone app's.
 */
enum {
    kUGStatusRowEnabled = 0,
    kUGStatusRowPhase = 1,
    kUGStatusRowUsageLeft = 2,
    kUGStatusRowBreakLeft = 3,
    kUGStatusRowRuntime = 4
};

enum {
    kUGAlertTagAuthorization = 101,
    kUGAlertTagEditUsage = 102,
    kUGAlertTagEditBreak = 103,
    kUGAlertTagNewPIN = 104,
    kUGAlertTagConfirmPIN = 105,
    kUGAlertTagNotice = 106,
    kUGAlertTagWizardWelcome = 111,
    kUGAlertTagWizardPIN = 112,
    kUGAlertTagWizardConfirmPIN = 113,
    kUGAlertTagWizardUsage = 114,
    kUGAlertTagWizardBreak = 115,
    kUGAlertTagWizardEmergency = 116,
    kUGAlertTagWizardFinish = 117
};

enum {
    kUGWizardStepWelcome = 0,
    kUGWizardStepPIN = 1,
    kUGWizardStepConfirmPIN = 2,
    kUGWizardStepUsage = 3,
    kUGWizardStepBreak = 4,
    kUGWizardStepEmergency = 5,
    kUGWizardStepFinish = 6,
    kUGWizardStepIdle = 7
};

static NSString *const kUGEmergencyInstructions =
    @"Păstrează această procedură pentru situații de urgență.\n\n"
     "Prin SSH, ca root:\n"
     "touch " UG_KILLSWITCH_PATH "\n\n"
     "Cât timp fișierul există, Usage Guard nu face nimic: fără ecran de "
     "blocare, fără numărătoare. După ce îl ștergi, repornește SpringBoard.";

static const NSTimeInterval kUGRefreshInterval = 1.0;

#pragma mark - Helpers

static NSString *UGFormatSeconds(long long seconds)
{
    char buffer[16];
    ug_format_mmss(seconds > 0 ? seconds : 0, buffer, sizeof buffer);
    return [NSString stringWithUTF8String:buffer];
}

/* Strict decimal 1...240; "12a" and "0" are both rejected. */
static BOOL UGParseMinutes(NSString *text, int *minutes)
{
    if (![text isKindOfClass:[NSString class]]) return NO;

    NSString *trimmed =
        [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (trimmed.length == 0 || trimmed.length > 3) return NO;

    for (NSUInteger index = 0; index < trimmed.length; index++) {
        unichar character = [trimmed characterAtIndex:index];
        if (character < '0' || character > '9') return NO;
    }

    NSInteger value = [trimmed integerValue];
    if (value < UG_MIN_MINUTES || value > UG_MAX_MINUTES) return NO;
    if (minutes) *minutes = (int)value;
    return YES;
}

@implementation UGPreferencesListController {
    UGSettingsIPC *_ipc;
    UGState _state;
    NSDictionary *_status;

    /* Everything the rendered rows show, flattened into one comparable string.
     * The 1 Hz timer reloads only when this changes. */
    NSString *_signature;
    NSTimer *_refreshTimer;

    /* Rows whose visible text is not driven by a get selector. They live in
     * the host's _specifiers array and are updated in place, so renaming them
     * keeps the array (and its ids) stable. */
    PSSpecifier *_runtimeTextSpecifier;
    PSSpecifier *_editUsageSpecifier;
    PSSpecifier *_editBreakSpecifier;
    PSSpecifier *_pinButtonSpecifier;
    PSSpecifier *_requirePINSpecifier;

    BOOL _notificationsInstalled;

    NSInteger _alertCount;

    /* Weak on purpose: Preferences can dismiss and release an alert while the
     * pane still holds a reference. A stale strong pointer would then be
     * messaged after deallocation; a weak one simply reads back nil. */
    __weak UIAlertView *_activeAlert;
    void (^_resumeAfterNotice)(void);

    BOOL _authorized;
    void (^_pendingAuthorizedAction)(void);

    BOOL _wizardShown;
    NSInteger _wizardStep;
    NSString *_wizardPIN;
    NSString *_pendingPIN;
    int _wizardUsageMinutes;
    int _wizardBreakMinutes;
}

#pragma mark - Lifecycle

+ (void)load
{
    /* Runs when Preferences dlopen()s the bundle: the first trace line names
     * the copy of UsageGuardPrefs.bundle the host actually loaded. */
    UGTrace(@"list controller class loaded from %@",
            [[NSBundle bundleForClass:self] bundlePath]);
}

- (UGSettingsIPC *)ugIPC
{
    /* Created on first use: PSListController may ask for specifiers from inside
     * its own initializer, before -initForContentSize: has installed the IPC. */
    if (!_ipc) _ipc = [[UGSettingsIPC alloc] init];
    return _ipc;
}

- (id)initForContentSize:(CGSize)size
{
    UGTrace(@"list initForContentSize: entry %.0fx%.0f", size.width, size.height);

    self = [super initForContentSize:size];
    if (!self) return nil;

    [self ugIPC];
    ug_state_defaults(&_state, UGNowSeconds());
    _wizardStep = kUGWizardStepIdle;
    self.title = @"Usage Guard";

    UGTrace(@"list initForContentSize: exit principal=%@",
            NSStringFromClass([self class]));

    return self;
}

- (void)dealloc
{
    UGTrace(@"list dealloc: pane released");

    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    [_refreshTimer invalidate];
    _refreshTimer = nil;

    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewDidLoad
{
    [super viewDidLoad];

    /* Registration is idempotent: a repeated viewDidLoad must not make every
     * notification call the handler twice. */
    if (_notificationsInstalled) return;
    _notificationsInstalled = YES;

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self
               selector:@selector(applicationWillResignActive:)
                   name:UIApplicationWillResignActiveNotification
                 object:nil];
    [center addObserver:self
               selector:@selector(applicationDidEnterBackground:)
                   name:UIApplicationDidEnterBackgroundNotification
                 object:nil];
    [center addObserver:self
               selector:@selector(applicationDidBecomeActive:)
                   name:UIApplicationDidBecomeActiveNotification
                 object:nil];
}

- (void)viewWillAppear:(BOOL)animated
{
    UGTrace(@"list viewWillAppear: entry specifiers=%ld", (long)_specifiers.count);

    [super viewWillAppear:animated];
    self.title = @"Usage Guard";

    /* Make sure the host's array exists, then refresh it from the state that
     * may have changed while the pane was away. */
    _signature = nil;
    [self specifiers];
    [self ugReloadAndDisplay];
    [self ugStartRefreshTimer];

    UGTrace(@"list viewWillAppear: exit");
}

- (void)viewDidAppear:(BOOL)animated
{
    UGTrace(@"list viewDidAppear: entry setupComplete=%d hasPIN=%d",
            (int)[[self ugIPC] setupComplete], (int)[[self ugIPC] hasPIN]);

    [super viewDidAppear:animated];

    if (_wizardShown) return;
    _wizardShown = YES;

    if (![[self ugIPC] setupComplete]) [self beginWizard];
}

- (void)viewWillDisappear:(BOOL)animated
{
    UGTrace(@"list viewWillDisappear: entry alerts=%ld", (long)_alertCount);

    [self ugStopRefreshTimer];
    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                             selector:@selector(ugReloadAndDisplay)
                                               object:nil];

    /* Whatever was on screen is gone with the pane; start clean next time. */
    _alertCount = 0;
    _resumeAfterNotice = nil;
    [self clearAuthorization];

    [super viewWillDisappear:animated];

    UGTrace(@"list viewWillDisappear: exit");
}

- (void)applicationWillResignActive:(NSNotification *)notification
{
    (void)notification;
    /* Preferences.app stays resident: leaving the foreground must not leave
     * the pane unlocked for the next person who opens Settings. */
    [self clearAuthorization];
}

- (void)applicationDidEnterBackground:(NSNotification *)notification
{
    (void)notification;
    [self clearAuthorization];
}

/* First-run setup must survive a trip through the background. Preferences
 * keeps this controller alive across a Home press, so viewDidAppear: does not
 * run again; clearAuthorization dismisses the wizard and leaves _wizardShown
 * set. Without this, setup could not be finished until Preferences is killed,
 * and the guard stayed inert meanwhile. */
- (void)applicationDidBecomeActive:(NSNotification *)notification
{
    (void)notification;

    if ([[self ugIPC] setupComplete]) return;
    if (_alertCount > 0) return;
    if (![self isViewLoaded] || !self.view.window) return;

    _wizardShown = NO;
    UGTrace(@"list applicationDidBecomeActive: re-arming wizard, setup incomplete");
    [self beginWizard];
}

- (void)clearAuthorization
{
    UGTrace(@"list clearAuthorization: entry activeAlert=%d wizardStep=%ld",
            (int)(_activeAlert != nil), (long)_wizardStep);

    _authorized = NO;
    _pendingAuthorizedAction = nil;
    _pendingPIN = nil;
    _wizardPIN = nil;

    /* A presented editor outlives a background transition: dismiss it so it
     * cannot re-open an unlocked editor once the PIN state is gone. The stored
     * resume block goes with it. */
    _resumeAfterNotice = nil;

    /* Reading the weak ivar into a strong local keeps the alert alive for the
     * whole dismissal; if it was already released this is simply nil. */
    UIAlertView *alert = _activeAlert;
    _activeAlert = nil;
    if (!alert) {
        UGTrace(@"list clearAuthorization: no live alert");
        return;
    }

    UGTrace(@"list clearAuthorization: dismissing alert tag=%ld", (long)alert.tag);
    [alert dismissWithClickedButtonIndex:alert.cancelButtonIndex animated:NO];

    if (_wizardStep != kUGWizardStepIdle) _wizardStep = kUGWizardStepIdle;
}

#pragma mark - Live refresh

- (void)ugStartRefreshTimer
{
    [self ugStopRefreshTimer];
    _refreshTimer = [NSTimer scheduledTimerWithTimeInterval:kUGRefreshInterval
                                                     target:self
                                                   selector:@selector(ugRefreshTimerFired:)
                                                   userInfo:nil
                                                    repeats:YES];
}

- (void)ugStopRefreshTimer
{
    [_refreshTimer invalidate];
    _refreshTimer = nil;
}

- (void)ugRefreshTimerFired:(NSTimer *)timer
{
    (void)timer;

    /* An alert owns the screen; reloading underneath it would be a flicker and
     * could yank the row the parent is looking at. */
    if (_alertCount > 0) return;

    NSString *previous = _signature;
    [self ugReloadLiveState];
    if ([previous isEqualToString:_signature]) return;

    /* Cheap refresh: rename the rows that need it in place and let the host
     * redraw its table. A full specifier rebuild every second would drop a
     * switch mid-drag and interrupt taps. */
    [self ugRefreshSpecifierContent];
    [self reload];
}

/* Reads cycle state and the runtime heartbeat, then refreshes the signature.
 * Never touches the UI, so it is safe from any pane callback. */
- (void)ugReloadLiveState
{
    [[self ugIPC] loadState:&_state];
    _status = [[self ugIPC] statusSnapshot];
    _signature = [self ugSignature];
}

/* Everything the pane renders, flattened into one comparable string. */
- (NSString *)ugSignature
{
    NSNumber *pid = [_status objectForKey:@"RuntimePID"];
    NSNumber *tick = [_status objectForKey:@"LastTick"];
    NSNumber *killSwitch = [_status objectForKey:@"KillSwitch"];
    NSNumber *inert = [_status objectForKey:@"Inert"];
    NSNumber *debug = [_status objectForKey:@"DebugLogging"];

    return [NSString stringWithFormat:
            @"%d|%d|%lld|%lld|%d|%d|%ld|%ld|%d|%d|%d|%ld|%ld|%ld|%ld|%d|%lld",
            _state.enabled, _state.phase, _state.remaining, _state.overrideUntil,
            _state.usageMinutes, _state.breakMinutes,
            (long)(pid ? [pid longLongValue] : -1),
            (long)(tick ? [tick longLongValue] : -1),
            (killSwitch ? [killSwitch boolValue] : 0),
            (inert ? [inert boolValue] : 0),
            (debug ? [debug boolValue] : 0),
            (long)[[self ugIPC] hasPIN], (long)[[self ugIPC] requirePIN],
            (long)[[self ugIPC] setupComplete], (long)[[self ugIPC] lockoutRemaining],
            [[self ugIPC] runtimeIsLive] ? 1 : 0, [self ugStatusAgeSeconds]];
}

- (void)ugReloadAndDisplay
{
    [self ugReloadLiveState];
    [self ugRefreshSpecifierContent];
    [self reload];
}

/* Deferred refresh for the one case where the row has to contradict itself for
 * a moment: a switch that the parent just turned off is already drawn off while
 * the PIN prompt is up, so the row is restored from persisted state. */
- (void)ugScheduleReload
{
    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                             selector:@selector(ugReloadAndDisplay)
                                               object:nil];
    [self performSelector:@selector(ugReloadAndDisplay) withObject:nil afterDelay:0.0];
}

#pragma mark - Specifiers

/*
 * The host, not this method's return value, decides what the table shows: since
 * iOS 4 Preferences builds its groups from PSListController's own _specifiers
 * ivar, so the row array has to be published there. Returning a private array
 * from this method alone leaves the host with an empty pane. The ivar is
 * declared in the faked PSListController interface and bound to the real
 * Preferences class at load time (non-fragile ABI, dynamic lookup).
 *
 * The list is built once; rows whose text has no get selector are renamed in
 * place, so a reload never replaces the objects the host is using.
 */
- (NSArray *)specifiers
{
    if (!_specifiers) {
        _specifiers = [self ugBuildSpecifiers];
    }
    return _specifiers;
}

- (void)ugRefreshSpecifierContent
{
    [_runtimeTextSpecifier setName:[self runtimeDescription]];
    [_editUsageSpecifier setName:
        [NSString stringWithFormat:@"Utilizare (minute): %d", _state.usageMinutes]];
    [_editBreakSpecifier setName:
        [NSString stringWithFormat:@"Pauză (minute): %d", _state.breakMinutes]];
    [_pinButtonSpecifier setName:
        ([[self ugIPC] hasPIN] ? @"Schimbă codul PIN" : @"Setează un cod PIN")];
    [_requirePINSpecifier setProperty:[NSNumber numberWithBool:[[self ugIPC] hasPIN]]
                               forKey:@"enabled"];
}

- (PSSpecifier *)ugGroupSpecifierNamed:(NSString *)name
{
    return [PSSpecifier preferenceSpecifierNamed:name
                                          target:nil
                                             set:NULL
                                             get:NULL
                                          detail:nil
                                            cell:PSGroupCell
                                            edit:nil];
}

- (PSSpecifier *)ugSwitchSpecifierNamed:(NSString *)name
                                    set:(SEL)set
                                    get:(SEL)get
{
    return [PSSpecifier preferenceSpecifierNamed:name
                                          target:self
                                             set:set
                                             get:get
                                          detail:nil
                                            cell:PSSwitchCell
                                            edit:nil];
}

- (PSSpecifier *)ugValueSpecifierNamed:(NSString *)name get:(SEL)get
{
    return [PSSpecifier preferenceSpecifierNamed:name
                                          target:self
                                             set:NULL
                                             get:get
                                          detail:nil
                                            cell:PSTitleValueCell
                                            edit:nil];
}

- (PSSpecifier *)ugTextSpecifierNamed:(NSString *)name
{
    return [PSSpecifier preferenceSpecifierNamed:name
                                          target:nil
                                             set:NULL
                                             get:NULL
                                          detail:nil
                                            cell:PSStaticTextCell
                                            edit:nil];
}

- (PSSpecifier *)ugButtonSpecifierNamed:(NSString *)name action:(SEL)action
{
    PSSpecifier *specifier = [PSSpecifier preferenceSpecifierNamed:name
                                                            target:self
                                                               set:NULL
                                                               get:NULL
                                                            detail:nil
                                                              cell:PSButtonCell
                                                              edit:nil];
    [specifier setButtonAction:action];
    [specifier setTarget:self];
    return specifier;
}

- (PSSpecifier *)ugIdentify:(PSSpecifier *)specifier as:(NSString *)identifier
{
    /* PSSpecifier keys rows by this property. Names change at runtime (the
     * runtime line, both limits, the PIN button), so a name-derived key would
     * go stale and the group header would collide with the "Stare" row. */
    [specifier setProperty:identifier forKey:@"id"];
    return specifier;
}

- (NSArray *)ugBuildSpecifiers
{
    NSMutableArray *rows = [NSMutableArray arrayWithCapacity:28];

    /* Stare */
    [rows addObject:[self ugIdentify:[self ugGroupSpecifierNamed:@"Stare"]
                                  as:@"status.group"]];
    [rows addObject:[self ugIdentify:[self ugSwitchSpecifierNamed:@"Usage Guard activ"
                                                               set:@selector(setEnabled:specifier:)
                                                               get:@selector(enabledForSpecifier:)]
                                  as:@"status.enabled"]];
    [rows addObject:[self ugIdentify:[self ugValueSpecifierNamed:@"Stare"
                                                             get:@selector(phaseDescriptionForSpecifier:)]
                                  as:@"status.phase"]];
    [rows addObject:[self ugIdentify:[self ugValueSpecifierNamed:@"Utilizare rămasă"
                                                             get:@selector(usageRemainingForSpecifier:)]
                                  as:@"status.usageLeft"]];
    [rows addObject:[self ugIdentify:[self ugValueSpecifierNamed:@"Pauză rămasă"
                                                             get:@selector(breakRemainingForSpecifier:)]
                                  as:@"status.breakLeft"]];
    _runtimeTextSpecifier =
        [self ugIdentify:[self ugTextSpecifierNamed:[self runtimeDescription]]
                      as:@"status.runtime"];
    [rows addObject:_runtimeTextSpecifier];

    /* Limite de timp */
    [rows addObject:[self ugIdentify:[self ugGroupSpecifierNamed:@"Limite de timp"]
                                  as:@"limits.group"]];
    _editUsageSpecifier =
        [self ugIdentify:[self ugButtonSpecifierNamed:
                            [NSString stringWithFormat:@"Utilizare (minute): %d",
                                                        _state.usageMinutes]
                                                action:@selector(ugEditUsageMinutes)]
                      as:@"limits.usage"];
    [rows addObject:_editUsageSpecifier];
    _editBreakSpecifier =
        [self ugIdentify:[self ugButtonSpecifierNamed:
                            [NSString stringWithFormat:@"Pauză (minute): %d",
                                                        _state.breakMinutes]
                                                action:@selector(ugEditBreakMinutes)]
                      as:@"limits.break"];
    [rows addObject:_editBreakSpecifier];

    /* Acțiuni */
    [rows addObject:[self ugIdentify:[self ugGroupSpecifierNamed:@"Acțiuni"]
                                  as:@"actions.group"]];
    [rows addObject:[self ugIdentify:[self ugButtonSpecifierNamed:@"Începe pauza acum"
                                                           action:@selector(ugStartBreakNow)]
                                  as:@"actions.startBreak"]];
    [rows addObject:[self ugIdentify:[self ugButtonSpecifierNamed:@"Resetează ciclul"
                                                           action:@selector(ugResetCycle)]
                                  as:@"actions.reset"]];
    [rows addObject:[self ugIdentify:[self ugButtonSpecifierNamed:@"Pauză 15 min"
                                                           action:@selector(ugPauseFifteenMinutes)]
                                  as:@"actions.pause15"]];
    [rows addObject:[self ugIdentify:[self ugButtonSpecifierNamed:@"Pauză 30 min"
                                                           action:@selector(ugPauseThirtyMinutes)]
                                  as:@"actions.pause30"]];
    [rows addObject:[self ugIdentify:[self ugButtonSpecifierNamed:@"Pauză 60 min"
                                                           action:@selector(ugPauseSixtyMinutes)]
                                  as:@"actions.pause60"]];
    [rows addObject:[self ugIdentify:[self ugButtonSpecifierNamed:@"Reia restricțiile"
                                                           action:@selector(ugResumeRestrictions)]
                                  as:@"actions.resume"]];
    [rows addObject:[self ugIdentify:[self ugButtonSpecifierNamed:@"Testează ecranul de blocare"
                                                           action:@selector(ugTestOverlay)]
                                  as:@"actions.testOverlay"]];

    /* Securitate */
    [rows addObject:[self ugIdentify:[self ugGroupSpecifierNamed:@"Securitate"]
                                  as:@"security.group"]];
    _pinButtonSpecifier =
        [self ugIdentify:[self ugButtonSpecifierNamed:
                            ([[self ugIPC] hasPIN] ? @"Schimbă codul PIN"
                                                    : @"Setează un cod PIN")
                                                action:@selector(ugChangePIN)]
                      as:@"security.pin"];
    [rows addObject:_pinButtonSpecifier];

    _requirePINSpecifier =
        [self ugIdentify:[self ugSwitchSpecifierNamed:@"Cere PIN pentru modificări"
                                                  set:@selector(setRequirePIN:specifier:)
                                                  get:@selector(requirePINForSpecifier:)]
                      as:@"security.requirePIN"];
    /* A switch that cannot be honoured (no PIN stored yet) is greyed out by the
     * host when the specifier carries enabled = NO. */
    [_requirePINSpecifier setProperty:[NSNumber numberWithBool:[[self ugIPC] hasPIN]]
                               forKey:@"enabled"];
    [rows addObject:_requirePINSpecifier];

    /* Informații */
    [rows addObject:[self ugIdentify:[self ugGroupSpecifierNamed:@"Informații"]
                                  as:@"info.group"]];
    [rows addObject:[self ugIdentify:[self ugValueSpecifierNamed:@"Versiune Usage Guard"
                                                             get:@selector(versionForSpecifier:)]
                                  as:@"info.version"]];
    [rows addObject:[self ugIdentify:[self ugValueSpecifierNamed:@"Runtime"
                                                             get:@selector(runtimeForSpecifier:)]
                                  as:@"info.runtime"]];
    [rows addObject:[self ugIdentify:[self ugValueSpecifierNamed:@"Versiune pachet"
                                                             get:@selector(bundleVersionForSpecifier:)]
                                  as:@"info.bundleVersion"]];
    [rows addObject:[self ugIdentify:[self ugValueSpecifierNamed:@"Fișier preferințe"
                                                             get:@selector(preferencesPathForSpecifier:)]
                                  as:@"info.preferencesPath"]];
    [rows addObject:[self ugIdentify:[self ugValueSpecifierNamed:@"Stare runtime"
                                                             get:@selector(statusAgeForSpecifier:)]
                                  as:@"info.statusAge"]];
    [rows addObject:[self ugIdentify:[self ugValueSpecifierNamed:@"Jurnal"
                                                             get:@selector(traceLogForSpecifier:)]
                                  as:@"info.traceLog"]];
    [rows addObject:[self ugIdentify:[self ugButtonSpecifierNamed:@"Șterge jurnalul"
                                                           action:@selector(ugDeleteTraceLog)]
                                  as:@"info.clearTraceLog"]];

    return rows;
}

#pragma mark - State descriptions

/* The pane's own vocabulary for the cycle, in the same tone as the overlay. */
- (NSString *)phaseDescription
{
    if (!_state.enabled) return @"Oprit";

    long long overrideLeft = ug_override_remaining(&_state, UGNowSeconds());
    if (overrideLeft > 0) {
        return [NSString stringWithFormat:@"Pauză până la expirare · %@",
                UGFormatSeconds(overrideLeft)];
    }

    if (_state.phase == UGPhaseBreak) return @"Pauză";

    /* Installed but not enforcing (operator kill switch or inert runtime). */
    if ([self runtimeReportsInert]) return @"Disponibil";

    return @"Activ";
}

- (BOOL)runtimeReportsInert
{
    NSNumber *inert = [_status objectForKey:@"Inert"];
    NSNumber *killSwitch = [_status objectForKey:@"KillSwitch"];

    if (inert && [inert boolValue]) return YES;
    if (killSwitch && [killSwitch boolValue]) return YES;
    return NO;
}

/* The status file is written every few seconds; the disk State can lag by the
 * persist throttle. Correct the published Remaining for the snapshot's age so
 * both countdown rows show what the overlay is counting down right now. NO when
 * the snapshot has no numbers for the phase the pane is displaying. */
- (BOOL)liveRemainingSeconds:(long long *)seconds
{
    if (![[self ugIPC] runtimeIsLive]) return NO;
    if (![[self ugIPC] setupComplete]) return NO;

    NSNumber *inert = [_status objectForKey:@"Inert"];
    if (inert && [inert boolValue]) return NO;

    if (ug_override_remaining(&_state, UGNowSeconds()) != 0) return NO;

    NSNumber *phase = [_status objectForKey:@"Phase"];
    NSNumber *remaining = [_status objectForKey:@"Remaining"];
    NSNumber *tick = [_status objectForKey:@"LastTick"];

    if (![phase isKindOfClass:[NSNumber class]] || [phase intValue] != _state.phase) return NO;
    if (![remaining isKindOfClass:[NSNumber class]] ||
        ![tick isKindOfClass:[NSNumber class]]) {
        return NO;
    }

    long long value = [remaining longLongValue];
    long long age = UGNowSeconds() - [tick longLongValue];
    if (age > 0) value -= age;
    if (value < 0) value = 0;
    if (seconds) *seconds = value;
    return YES;
}

- (long long)phaseSecondsLeft
{
    long long live = 0;
    if ([self liveRemainingSeconds:&live]) return live;
    return _state.remaining > 0 ? _state.remaining : 0;
}

- (long long)usageSecondsLeft
{
    if (!_state.enabled) return 0;
    if (_state.phase == UGPhaseUsage) return [self phaseSecondsLeft];
    return (long long)_state.usageMinutes * 60;
}

- (long long)breakSecondsLeft
{
    if (!_state.enabled) return 0;
    return _state.phase == UGPhaseBreak ? [self phaseSecondsLeft] : 0;
}

- (NSString *)runtimeDescription
{
    if (![[self ugIPC] runtimeIsLive]) return @"Runtime: nu este detectat";

    NSNumber *inert = [_status objectForKey:@"Inert"];
    if (inert && [inert boolValue]) return @"Runtime: inactiv (pornit)";

    NSNumber *pid = [_status objectForKey:@"RuntimePID"];
    if (![pid isKindOfClass:[NSNumber class]]) return @"Runtime: nu este detectat";
    return [NSString stringWithFormat:@"Runtime: activ (pid %ld)", (long)[pid longLongValue]];
}

/* -1 when the status file has no heartbeat to age. */
- (long long)ugStatusAgeSeconds
{
    NSNumber *tick = [_status objectForKey:@"LastTick"];
    if (![tick isKindOfClass:[NSNumber class]]) return -1;

    long long age = UGNowSeconds() - [tick longLongValue];
    return age < 0 ? 0 : age;
}

- (NSString *)statusAgeDescription
{
    if (!_status) return @"fișier absent";

    long long age = [self ugStatusAgeSeconds];
    if (age < 0) return @"necunoscut";
    return [NSString stringWithFormat:@"actualizat acum %lld s", age];
}

- (NSString *)bundleVersion
{
    NSBundle *bundle = [NSBundle bundleForClass:[UGPreferencesListController class]];
    NSString *version = [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    if (version.length == 0) {
        version = [bundle objectForInfoDictionaryKey:@"CFBundleVersion"];
    }
    return version.length > 0 ? version : @UG_VERSION;
}

/* Path and size in one row: the parent needs the path to copy the file off the
 * device with 3uTools and the size to know whether anything was written. */
- (NSString *)traceLogDescription
{
    NSString *path = UGTracePath();
    if (path.length == 0) return @"cale indisponibilă";

    unsigned long long bytes = UGTraceFileSize();
    NSString *size = nil;
    if (bytes == 0) {
        size = @"absent sau gol";
    } else if (bytes < 1024ULL) {
        size = [NSString stringWithFormat:@"%llu B", bytes];
    } else {
        size = [NSString stringWithFormat:@"%.1f KB", (double)bytes / 1024.0];
    }

    return [NSString stringWithFormat:@"%@ · %@", path, size];
}

#pragma mark - Getter selectors

- (id)enabledForSpecifier:(PSSpecifier *)specifier
{
    (void)specifier;
    return [NSNumber numberWithBool:_state.enabled != 0];
}

- (id)phaseDescriptionForSpecifier:(PSSpecifier *)specifier
{
    (void)specifier;
    return [self phaseDescription];
}

- (id)usageRemainingForSpecifier:(PSSpecifier *)specifier
{
    (void)specifier;
    return UGFormatSeconds([self usageSecondsLeft]);
}

- (id)breakRemainingForSpecifier:(PSSpecifier *)specifier
{
    (void)specifier;
    return UGFormatSeconds([self breakSecondsLeft]);
}

- (id)requirePINForSpecifier:(PSSpecifier *)specifier
{
    (void)specifier;
    return [NSNumber numberWithBool:[[self ugIPC] requirePIN]];
}

- (id)versionForSpecifier:(PSSpecifier *)specifier
{
    (void)specifier;
    return @UG_VERSION;
}

- (id)runtimeForSpecifier:(PSSpecifier *)specifier
{
    (void)specifier;
    return [self runtimeDescription];
}

- (id)bundleVersionForSpecifier:(PSSpecifier *)specifier
{
    (void)specifier;
    return [self bundleVersion];
}

- (id)preferencesPathForSpecifier:(PSSpecifier *)specifier
{
    (void)specifier;
    return [[self ugIPC] preferencesPath];
}

- (id)statusAgeForSpecifier:(PSSpecifier *)specifier
{
    (void)specifier;
    return [self statusAgeDescription];
}

- (id)traceLogForSpecifier:(PSSpecifier *)specifier
{
    (void)specifier;
    return [self traceLogDescription];
}

#pragma mark - Writes

- (BOOL)ugApplyChange:(void (^)(UGState *state))change
{
    if (![[self ugIPC] applyStateChange:change]) {
        UGTrace(@"list applyChange: state write failed");
        [self showNotice:@"Setările nu au putut fi salvate. Verifică spațiul liber pe dispozitiv."
                   title:@"Eroare"];
        return NO;
    }

    [self ugReloadAndDisplay];
    return YES;
}

- (void)ugApplyEnabled:(BOOL)enabled
{
    UGTrace(@"list setEnabled: %d", (int)enabled);

    [self ugApplyChange:^(UGState *state) {
        ug_set_enabled(state, enabled ? 1 : 0, UGNowSeconds());
    }];
}

- (void)setEnabled:(id)value specifier:(PSSpecifier *)specifier
{
    (void)specifier;

    BOOL desired = [value respondsToSelector:@selector(boolValue)]
                   ? [value boolValue] : YES;
    UGTrace(@"list setEnabled selectors: %d", (int)desired);

    /* The switch has already drawn the requested position. When the change
     * needs a PIN, redraw from persisted state first so the row cannot claim
     * the guard is off while it is still enforcing. */
    if ([self authorizationRequired]) [self ugScheduleReload];
    [self requireAuthorizationThen:^{ [self ugApplyEnabled:desired]; }];
}

- (void)ugApplyRequirePIN:(BOOL)required
{
    UGTrace(@"list setRequirePIN: %d", (int)required);

    [[self ugIPC] setRequirePIN:required];
    [self ugReloadAndDisplay];
}

- (void)setRequirePIN:(id)value specifier:(PSSpecifier *)specifier
{
    (void)specifier;

    BOOL desired = [value respondsToSelector:@selector(boolValue)]
                   ? [value boolValue] : YES;
    UGTrace(@"list setRequirePIN selectors: %d", (int)desired);

    if ([self authorizationRequired]) [self ugScheduleReload];
    [self requireAuthorizationThen:^{ [self ugApplyRequirePIN:desired]; }];
}

#pragma mark - Actions

- (void)ugStartBreakNow
{
    UGTrace(@"list action: start break");
    [self requireAuthorizationThen:^{
        [self ugApplyChange:^(UGState *state) {
            ug_start_break(state, UGNowSeconds());
        }];
    }];
}

- (void)ugResetCycle
{
    UGTrace(@"list action: reset cycle");
    [self requireAuthorizationThen:^{
        [self ugApplyChange:^(UGState *state) {
            ug_reset(state, UGNowSeconds());
        }];
    }];
}

- (void)ugPauseForMinutes:(int)minutes name:(NSString *)name
{
    UGTrace(@"list action: pause %@", name);
    [self requireAuthorizationThen:^{
        [self ugApplyChange:^(UGState *state) {
            ug_pause(state, UGNowSeconds(), minutes);
        }];
    }];
}

- (void)ugPauseFifteenMinutes
{
    [self ugPauseForMinutes:15 name:@"15"];
}

- (void)ugPauseThirtyMinutes
{
    [self ugPauseForMinutes:30 name:@"30"];
}

- (void)ugPauseSixtyMinutes
{
    [self ugPauseForMinutes:60 name:@"60"];
}

- (void)ugResumeRestrictions
{
    UGTrace(@"list action: resume");
    [self requireAuthorizationThen:^{
        [self ugApplyChange:^(UGState *state) {
            ug_resume(state, UGNowSeconds());
        }];
    }];
}

- (void)ugTestOverlay
{
    /* Visual check only: no state, so no PIN and no persistence. */
    UGTrace(@"list action: test overlay");
    [[self ugIPC] postTestOverlay];
}

- (void)ugDeleteTraceLog
{
    UGTrace(@"list action: delete trace log size=%llu", UGTraceFileSize());
    UGTraceRemoveLog();
    /* Only the Jurnal row's value changes, and that comes from its get
     * selector: a table reload is enough. */
    [self reload];
}

#pragma mark - Authorization

- (BOOL)authorizationRequired
{
    if (_authorized) return NO;
    if (![[self ugIPC] hasPIN]) return NO;
    return [[self ugIPC] requirePIN];
}

- (void)requireAuthorizationThen:(void (^)(void))action
{
    UGTrace(@"list requireAuthorizationThen: needed=%d lockout=%ld",
            (int)[self authorizationRequired], (long)[[self ugIPC] lockoutRemaining]);

    if (![self authorizationRequired]) {
        if (action) action();
        return;
    }

    NSInteger lockout = [[self ugIPC] lockoutRemaining];
    if (lockout > 0) {
        [self showNotice:[NSString stringWithFormat:
                          @"Prea multe încercări. Reîncearcă în %ld secunde.", (long)lockout]
                   title:@"Cod PIN blocat"];
        return;
    }

    _pendingAuthorizedAction = [action copy];

    UIAlertView *alert = [[UIAlertView alloc]
                          initWithTitle:@"Cod PIN"
                                message:@"Introdu codul PIN pentru a modifica setările."
                               delegate:self
                      cancelButtonTitle:@"Anulează"
                      otherButtonTitles:@"Continuă", nil];
    alert.alertViewStyle = UIAlertViewStyleSecureTextInput;
    alert.tag = kUGAlertTagAuthorization;
    [self presentAlert:alert];
}

- (void)handleAuthorizationAlert:(UIAlertView *)alertView cancelled:(BOOL)cancelled
{
    UGTrace(@"list handleAuthorizationAlert: cancelled=%d", (int)cancelled);

    if (cancelled) {
        _pendingAuthorizedAction = nil;
        return;
    }

    NSString *pin = [[alertView textFieldAtIndex:0] text];
    if ([[self ugIPC] verifyPIN:pin]) {
        _authorized = YES;
        void (^action)(void) = _pendingAuthorizedAction;
        _pendingAuthorizedAction = nil;
        if (action) action();
        return;
    }

    NSInteger lockout = [[self ugIPC] lockoutRemaining];
    if (lockout > 0) {
        _pendingAuthorizedAction = nil;
        [self showNotice:[NSString stringWithFormat:
                          @"Prea multe încercări. Reîncearcă în %ld secunde.", (long)lockout]
                   title:@"Cod PIN blocat"];
        return;
    }

    void (^pending)(void) = _pendingAuthorizedAction;
    _pendingAuthorizedAction = nil;
    if (pending) {
        [self showNotice:@"Cod PIN greșit." title:@"Cod PIN" resume:^{
            [self requireAuthorizationThen:pending];
        }];
    } else {
        [self showNotice:@"Cod PIN greșit." title:@"Cod PIN"];
    }
}

#pragma mark - Limits

- (void)ugEditUsageMinutes
{
    UGTrace(@"list action: edit usage minutes");
    [self requireAuthorizationThen:^{ [self presentUsageEditor]; }];
}

- (void)ugEditBreakMinutes
{
    UGTrace(@"list action: edit break minutes");
    [self requireAuthorizationThen:^{ [self presentBreakEditor]; }];
}

- (void)presentUsageEditor
{
    UGTrace(@"list presentUsageEditor");

    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Utilizare (minute)"
                                                   message:@"Între 1 și 240 de minute."
                                                  delegate:self
                                         cancelButtonTitle:@"Anulează"
                                         otherButtonTitles:@"Salvează", nil];
    alert.alertViewStyle = UIAlertViewStylePlainTextInput;
    alert.tag = kUGAlertTagEditUsage;

    UITextField *field = [alert textFieldAtIndex:0];
    field.keyboardType = UIKeyboardTypeNumberPad;
    field.text = [NSString stringWithFormat:@"%d", _state.usageMinutes];

    [self presentAlert:alert];
}

- (void)presentBreakEditor
{
    UGTrace(@"list presentBreakEditor");

    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Pauză (minute)"
                                                   message:@"Între 1 și 240 de minute."
                                                  delegate:self
                                         cancelButtonTitle:@"Anulează"
                                         otherButtonTitles:@"Salvează", nil];
    alert.alertViewStyle = UIAlertViewStylePlainTextInput;
    alert.tag = kUGAlertTagEditBreak;

    UITextField *field = [alert textFieldAtIndex:0];
    field.keyboardType = UIKeyboardTypeNumberPad;
    field.text = [NSString stringWithFormat:@"%d", _state.breakMinutes];

    [self presentAlert:alert];
}

- (void)handleLimitAlert:(UIAlertView *)alertView usage:(BOOL)usage
{
    UGTrace(@"list handleLimitAlert: usage=%d", (int)usage);

    /* The alert can outlive the authorization that opened it; a cleared PIN
     * state must not let it write. */
    if ([self authorizationRequired]) return;

    int minutes = 0;
    if (!UGParseMinutes([[alertView textFieldAtIndex:0] text], &minutes)) {
        [self showNotice:@"Introdu un număr între 1 și 240 de minute."
                   title:@"Valoare invalidă"
                  resume:^{
                      if (usage) [self presentUsageEditor];
                      else [self presentBreakEditor];
                  }];
        return;
    }

    [self ugApplyChange:^(UGState *state) {
        if (usage) ug_set_usage_minutes(state, minutes);
        else ug_set_break_minutes(state, minutes);
    }];
}

#pragma mark - PIN

- (void)ugChangePIN
{
    UGTrace(@"list action: change PIN");
    [self requireAuthorizationThen:^{ [self presentNewPINEditor]; }];
}

- (void)presentNewPINEditor
{
    UGTrace(@"list presentNewPINEditor");

    UIAlertView *alert = [[UIAlertView alloc]
                          initWithTitle:([[self ugIPC] hasPIN] ? @"Schimbă codul PIN"
                                                              : @"Setează un cod PIN")
                                message:@"4–8 cifre. Codul rămâne doar la părinte."
                               delegate:self
                      cancelButtonTitle:@"Anulează"
                      otherButtonTitles:@"Continuă", nil];
    alert.alertViewStyle = UIAlertViewStyleSecureTextInput;
    alert.tag = kUGAlertTagNewPIN;
    [self presentAlert:alert];
}

- (void)presentConfirmPINEditor
{
    UGTrace(@"list presentConfirmPINEditor");

    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Confirmă codul PIN"
                                                   message:@"Introdu din nou codul."
                                                  delegate:self
                                         cancelButtonTitle:@"Anulează"
                                         otherButtonTitles:@"Salvează", nil];
    alert.alertViewStyle = UIAlertViewStyleSecureTextInput;
    alert.tag = kUGAlertTagConfirmPIN;
    [self presentAlert:alert];
}

- (void)handleNewPINAlert:(UIAlertView *)alertView
{
    UGTrace(@"list handleNewPINAlert");

    if ([self authorizationRequired]) return;

    NSString *pin = [[alertView textFieldAtIndex:0] text];
    if (![UGPrefs isValidPIN:pin]) {
        [self showNotice:@"Codul trebuie să aibă 4–8 cifre."
                   title:@"Cod PIN"
                  resume:^{ [self presentNewPINEditor]; }];
        return;
    }

    _pendingPIN = pin;
    [self presentConfirmPINEditor];
}

- (void)handleConfirmPINAlert:(UIAlertView *)alertView
{
    UGTrace(@"list handleConfirmPINAlert");

    if ([self authorizationRequired]) return;

    NSString *pin = [[alertView textFieldAtIndex:0] text];
    if (![pin isEqualToString:_pendingPIN]) {
        _pendingPIN = nil;
        [self showNotice:@"Codurile nu se potrivesc. Încearcă din nou."
                   title:@"Cod PIN"
                  resume:^{ [self presentNewPINEditor]; }];
        return;
    }

    _pendingPIN = nil;
    if (![[self ugIPC] setPIN:pin]) {
        [self showNotice:@"Codul PIN nu a putut fi salvat." title:@"Eroare"];
        return;
    }

    /* The parent just chose it, so the pane stays unlocked. */
    _authorized = YES;
    [self ugReloadAndDisplay];
    [self showNotice:@"Cod PIN salvat." title:@"Securitate"];
}

#pragma mark - First-run wizard

- (void)beginWizard
{
    UGTrace(@"list beginWizard: alerts=%ld", (long)_alertCount);

    if (_alertCount > 0) return;

    _wizardStep = kUGWizardStepWelcome;
    _wizardPIN = nil;
    _pendingPIN = nil;
    _wizardUsageMinutes = _state.usageMinutes;
    _wizardBreakMinutes = _state.breakMinutes;

    [self presentWizardStep];
}

- (void)abortWizard
{
    UGTrace(@"list abortWizard: step=%ld", (long)_wizardStep);

    /* Cancel at any step leaves the guard exactly as it was: nothing enforced,
     * nothing written. */
    _wizardStep = kUGWizardStepIdle;
    _wizardPIN = nil;
    _pendingPIN = nil;
    [self ugReloadAndDisplay];
}

- (void)presentWizardStep
{
    UGTrace(@"list presentWizardStep: step=%ld", (long)_wizardStep);

    UIAlertView *alert = nil;

    switch (_wizardStep) {
        case kUGWizardStepWelcome:
            alert = [[UIAlertView alloc]
                     initWithTitle:@"Bun venit la Usage Guard"
                           message:@"Usage Guard împarte timpul în cicluri: un interval de "
                                    "utilizare, apoi o pauză în care telefonul se odihnește.\n\n"
                                    "Deocamdată nu se aplică nicio restricție. Continuă pentru a "
                                    "stabili duratele și un cod PIN."
                          delegate:self
                 cancelButtonTitle:@"Anulează"
                 otherButtonTitles:@"Continuă", nil];
            alert.tag = kUGAlertTagWizardWelcome;
            break;

        case kUGWizardStepPIN:
            alert = [[UIAlertView alloc] initWithTitle:@"Setează un cod PIN"
                                               message:@"4–8 cifre. Codul rămâne doar la părinte."
                                              delegate:self
                                     cancelButtonTitle:@"Anulează"
                                     otherButtonTitles:@"Continuă", nil];
            alert.alertViewStyle = UIAlertViewStyleSecureTextInput;
            alert.tag = kUGAlertTagWizardPIN;
            break;

        case kUGWizardStepConfirmPIN:
            alert = [[UIAlertView alloc] initWithTitle:@"Confirmă codul PIN"
                                               message:@"Introdu din nou codul."
                                              delegate:self
                                     cancelButtonTitle:@"Anulează"
                                     otherButtonTitles:@"Continuă", nil];
            alert.alertViewStyle = UIAlertViewStyleSecureTextInput;
            alert.tag = kUGAlertTagWizardConfirmPIN;
            break;

        case kUGWizardStepUsage:
            alert = [[UIAlertView alloc] initWithTitle:@"Utilizare (minute)"
                                               message:@"Cât poate fi folosit telefonul între pauze. "
                                                        "Între 1 și 240."
                                              delegate:self
                                     cancelButtonTitle:@"Anulează"
                                     otherButtonTitles:@"Continuă", nil];
            alert.alertViewStyle = UIAlertViewStylePlainTextInput;
            alert.tag = kUGAlertTagWizardUsage;
            [[alert textFieldAtIndex:0] setKeyboardType:UIKeyboardTypeNumberPad];
            [[alert textFieldAtIndex:0] setText:[NSString stringWithFormat:@"%d",
                                                  _wizardUsageMinutes]];
            break;

        case kUGWizardStepBreak:
            alert = [[UIAlertView alloc] initWithTitle:@"Pauză (minute)"
                                               message:@"Cât durează pauza dintre intervalele de "
                                                        "utilizare. Între 1 și 240."
                                              delegate:self
                                     cancelButtonTitle:@"Anulează"
                                     otherButtonTitles:@"Continuă", nil];
            alert.alertViewStyle = UIAlertViewStylePlainTextInput;
            alert.tag = kUGAlertTagWizardBreak;
            [[alert textFieldAtIndex:0] setKeyboardType:UIKeyboardTypeNumberPad];
            [[alert textFieldAtIndex:0] setText:[NSString stringWithFormat:@"%d",
                                                  _wizardBreakMinutes]];
            break;

        case kUGWizardStepEmergency:
            alert = [[UIAlertView alloc] initWithTitle:@"Instrucțiuni de urgență"
                                               message:kUGEmergencyInstructions
                                              delegate:self
                                     cancelButtonTitle:@"Anulează"
                                     otherButtonTitles:@"Continuă", nil];
            alert.tag = kUGAlertTagWizardEmergency;
            break;

        case kUGWizardStepFinish:
            alert = [[UIAlertView alloc]
                     initWithTitle:@"Activează Usage Guard"
                           message:[NSString stringWithFormat:
                                    @"Se activează acum: %d min utilizare, %d min pauză, cu cod PIN.",
                                    _wizardUsageMinutes, _wizardBreakMinutes]
                          delegate:self
                 cancelButtonTitle:@"Anulează"
                 otherButtonTitles:@"Activează", nil];
            alert.tag = kUGAlertTagWizardFinish;
            break;

        default:
            break;
    }

    if (alert) [self presentAlert:alert];
}

- (void)handleWizardAlert:(UIAlertView *)alertView
{
    UGTrace(@"list handleWizardAlert: tag=%ld step=%ld",
            (long)alertView.tag, (long)_wizardStep);

    /* The wizard was torn down (cancel or an authorization clear): a late
     * dismissal must not continue it. */
    if (_wizardStep == kUGWizardStepIdle) return;

    switch (alertView.tag) {
        case kUGAlertTagWizardWelcome:
            _wizardStep = kUGWizardStepPIN;
            break;

        case kUGAlertTagWizardPIN: {
            NSString *pin = [[alertView textFieldAtIndex:0] text];
            if (![UGPrefs isValidPIN:pin]) {
                [self showNotice:@"Codul trebuie să aibă 4–8 cifre."
                           title:@"Cod PIN"
                          resume:^{ [self presentWizardStep]; }];
                return;
            }
            _wizardPIN = pin;
            _wizardStep = kUGWizardStepConfirmPIN;
            break;
        }

        case kUGAlertTagWizardConfirmPIN: {
            NSString *pin = [[alertView textFieldAtIndex:0] text];
            if (![_wizardPIN isEqualToString:pin]) {
                _wizardPIN = nil;
                _wizardStep = kUGWizardStepPIN;
                [self showNotice:@"Codurile nu se potrivesc. Încearcă din nou."
                           title:@"Cod PIN"
                          resume:^{ [self presentWizardStep]; }];
                return;
            }
            _wizardStep = kUGWizardStepUsage;
            break;
        }

        case kUGAlertTagWizardUsage: {
            int minutes = 0;
            if (!UGParseMinutes([[alertView textFieldAtIndex:0] text], &minutes)) {
                [self showNotice:@"Introdu un număr între 1 și 240 de minute."
                           title:@"Valoare invalidă"
                          resume:^{ [self presentWizardStep]; }];
                return;
            }
            _wizardUsageMinutes = minutes;
            _wizardStep = kUGWizardStepBreak;
            break;
        }

        case kUGAlertTagWizardBreak: {
            int minutes = 0;
            if (!UGParseMinutes([[alertView textFieldAtIndex:0] text], &minutes)) {
                [self showNotice:@"Introdu un număr între 1 și 240 de minute."
                           title:@"Valoare invalidă"
                          resume:^{ [self presentWizardStep]; }];
                return;
            }
            _wizardBreakMinutes = minutes;
            _wizardStep = kUGWizardStepEmergency;
            break;
        }

        case kUGAlertTagWizardEmergency:
            _wizardStep = kUGWizardStepFinish;
            break;

        case kUGAlertTagWizardFinish:
            [self finishWizard];
            return;

        default:
            return;
    }

    [self presentWizardStep];
}

- (void)finishWizard
{
    UGTrace(@"list finishWizard: step=%ld", (long)_wizardStep);

    /* The finish alert can outlive the authorization that opened the wizard. */
    if ([self authorizationRequired]) {
        [self abortWizard];
        return;
    }

    _wizardStep = kUGWizardStepIdle;

    /* An authorization clear drops the collected PIN; that is a clean cancel,
     * not a failed save. */
    if (_wizardPIN.length == 0) {
        [self abortWizard];
        return;
    }

    if (![[self ugIPC] setPIN:_wizardPIN]) {
        [self showNotice:@"Codul PIN nu a putut fi salvat." title:@"Eroare"];
        return;
    }

    BOOL saved = [self ugApplyChange:^(UGState *state) {
        ug_set_usage_minutes(state, _wizardUsageMinutes);
        ug_set_break_minutes(state, _wizardBreakMinutes);
        /* A fresh install still carries the 20-minute default allowance;
         * without this reset the first interval would not match the chosen
         * usage duration, whatever the confirmation says. */
        ug_reset(state, UGNowSeconds());
        ug_set_enabled(state, 1, UGNowSeconds());
    }];
    if (!saved) return;

    /* Persisted flags and the cycle write already announce themselves on the
     * notify(3) bus through UGSettingsIPC; the host redraws from the reload. */
    [[self ugIPC] setSetupComplete:YES];

    /* The parent just picked the PIN, so the pane stays unlocked. */
    _authorized = YES;
    _wizardPIN = nil;
    [self ugReloadAndDisplay];

    UGTrace(@"list finishWizard: setup complete");
}

#pragma mark - Alerts

- (void)presentAlert:(UIAlertView *)alert
{
    UGTrace(@"list presentAlert: tag=%ld alerts=%ld",
            (long)alert.tag, (long)_alertCount);

    alert.delegate = self;
    _activeAlert = alert;
    _alertCount++;
    [alert show];
}

- (void)showNotice:(NSString *)message title:(NSString *)title
{
    [self showNotice:message title:title resume:nil];
}

- (void)showNotice:(NSString *)message title:(NSString *)title resume:(void (^)(void))resume
{
    _resumeAfterNotice = [resume copy];

    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:title
                                                   message:message
                                                  delegate:self
                                         cancelButtonTitle:@"OK"
                                         otherButtonTitles:nil];
    alert.tag = kUGAlertTagNotice;
    [self presentAlert:alert];
}

- (void)alertViewCancel:(UIAlertView *)alertView
{
    UGTrace(@"list alertViewCancel: tag=%ld alerts=%ld",
            (long)alertView.tag, (long)_alertCount);

    /* iOS 6 dismisses an alert this way when the app leaves the foreground and
     * may skip didDismiss. Both paths decrement, and the count is clamped, so
     * the refresh loop can never be wedged by a lost dismissal. */
    if (_alertCount > 0) _alertCount--;
    if (alertView == _activeAlert) _activeAlert = nil;
    _resumeAfterNotice = nil;
    _pendingAuthorizedAction = nil;
}

/*
 * PSListController implements this delegate method for its own confirmation
 * sheets; our alerts must not reach that handler, which would act on button
 * indices it did not create. The dismissal work happens in
 * didDismissWithButtonIndex:, which runs after the button has been released.
 */
- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex
{
    (void)alertView;
    (void)buttonIndex;
}

- (void)alertView:(UIAlertView *)alertView didDismissWithButtonIndex:(NSInteger)buttonIndex
{
    UGTrace(@"list didDismiss alert tag=%ld button=%ld alerts=%ld",
            (long)alertView.tag, (long)buttonIndex, (long)_alertCount);

    if (_alertCount > 0) _alertCount--;
    if (alertView == _activeAlert) _activeAlert = nil;

    BOOL cancelled = (buttonIndex == alertView.cancelButtonIndex);

    switch (alertView.tag) {
        case kUGAlertTagNotice: {
            void (^resume)(void) = _resumeAfterNotice;
            _resumeAfterNotice = nil;
            if (resume) resume();
            break;
        }

        case kUGAlertTagAuthorization:
            [self handleAuthorizationAlert:alertView cancelled:cancelled];
            break;

        case kUGAlertTagEditUsage:
            if (!cancelled) [self handleLimitAlert:alertView usage:YES];
            break;

        case kUGAlertTagEditBreak:
            if (!cancelled) [self handleLimitAlert:alertView usage:NO];
            break;

        case kUGAlertTagNewPIN:
            if (cancelled) _pendingPIN = nil;
            else [self handleNewPINAlert:alertView];
            break;

        case kUGAlertTagConfirmPIN:
            if (cancelled) _pendingPIN = nil;
            else [self handleConfirmPINAlert:alertView];
            break;

        case kUGAlertTagWizardWelcome:
        case kUGAlertTagWizardPIN:
        case kUGAlertTagWizardConfirmPIN:
        case kUGAlertTagWizardUsage:
        case kUGAlertTagWizardBreak:
        case kUGAlertTagWizardEmergency:
        case kUGAlertTagWizardFinish:
            if (cancelled) [self abortWizard];
            else [self handleWizardAlert:alertView];
            break;

        default:
            break;
    }
}

@end
