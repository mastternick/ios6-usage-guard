#import "UGPreferencesController.h"

#import "UGGuardCore.h"
#import "UGPrefs.h"
#import "UGSettingsIPC.h"

/* Section order, matching the pane from top to bottom. */
enum {
    kUGSectionStatus = 0,
    kUGSectionLimits = 1,
    kUGSectionActions = 2,
    kUGSectionSecurity = 3,
    kUGSectionInformation = 4,
    kUGSectionCount = 5
};

enum {
    kUGStatusRowEnabled = 0,
    kUGStatusRowPhase = 1,
    kUGStatusRowUsageLeft = 2,
    kUGStatusRowBreakLeft = 3,
    kUGStatusRowRuntime = 4,
    kUGStatusRowCount = 5
};

enum {
    kUGLimitRowUsage = 0,
    kUGLimitRowBreak = 1,
    kUGLimitRowCount = 2
};

enum {
    kUGActionRowStartBreak = 0,
    kUGActionRowReset = 1,
    kUGActionRowPause15 = 2,
    kUGActionRowPause30 = 3,
    kUGActionRowPause60 = 4,
    kUGActionRowResume = 5,
    kUGActionRowTestOverlay = 6,
    kUGActionRowCount = 7
};

enum {
    kUGSecurityRowPIN = 0,
    kUGSecurityRowRequirePIN = 1,
    kUGSecurityRowCount = 2
};

enum {
    kUGInformationRowVersion = 0,
    kUGInformationRowRuntime = 1,
    kUGInformationRowBundleVersion = 2,
    kUGInformationRowPreferencesPath = 3,
    kUGInformationRowStatusAge = 4,
    kUGInformationRowKillSwitch = 5,
    kUGInformationRowDebugLogging = 6,
    kUGInformationRowCount = 7
};

/* Switch tags survive cell reuse; the action stays attached to the switch. */
enum {
    kUGSwitchTagEnabled = 41,
    kUGSwitchTagRequirePIN = 42
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

static NSString *const kUGVersionString = @"1.0.2";
static NSString *const kUGEmergencyInstructions =
    @"Păstrează această procedură pentru situații de urgență.\n\n"
     "Prin SSH, ca root:\n"
     "touch /var/mobile/Library/Preferences/org.usageguard.timer.disable\n\n"
     "Cât timp fișierul există, Usage Guard nu face nimic: fără ecran de "
     "blocare, fără numărătoare. După ce îl ștergi, repornește SpringBoard.";

static const CGFloat kUGStandardRowHeight = 44.0f;
static const CGFloat kUGPathRowHeight = 62.0f;
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

@implementation UGPreferencesController {
    UGSettingsIPC *_ipc;

    UGState _state;
    NSDictionary *_status;
    NSString *_signature;
    NSTimer *_refreshTimer;

    NSInteger _alertCount;
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

- (id)initWithStyle:(UITableViewStyle)style
{
    (void)style;
    /* Always grouped: PreferenceLoader may instantiate us with -init, which
     * would otherwise give a plain table and lose the settings look. */
    self = [super initWithStyle:UITableViewStyleGrouped];
    if (!self) return nil;

    _ipc = [[UGSettingsIPC alloc] init];
    ug_state_defaults(&_state, UGNowSeconds());
    _wizardStep = kUGWizardStepIdle;
    self.title = @"Usage Guard";

    return self;
}

- (id)init
{
    return [self initWithStyle:UITableViewStyleGrouped];
}

- (void)dealloc
{
    [_refreshTimer invalidate];
    _refreshTimer = nil;
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    self.title = @"Usage Guard";

    /* Force one rebuild: the table may have been laid out before the state was
     * read, and the window is not attached yet during viewWillAppear. */
    _signature = nil;
    [self refreshFromDiskReloading:NO];
    [self.tableView reloadData];
    [self startRefreshTimer];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];

    if (_wizardShown) return;
    _wizardShown = YES;

    if (![_ipc setupComplete]) [self beginWizard];
}

- (void)viewWillDisappear:(BOOL)animated
{
    [self stopRefreshTimer];

    /* Whatever was on screen is gone with the pane; start clean next time. */
    _alertCount = 0;
    _resumeAfterNotice = nil;
    _pendingAuthorizedAction = nil;

    [super viewWillDisappear:animated];
}

#pragma mark - Live refresh

- (void)startRefreshTimer
{
    [self stopRefreshTimer];
    _refreshTimer = [NSTimer scheduledTimerWithTimeInterval:kUGRefreshInterval
                                                     target:self
                                                   selector:@selector(refreshTimerFired:)
                                                   userInfo:nil
                                                    repeats:YES];
}

- (void)stopRefreshTimer
{
    [_refreshTimer invalidate];
    _refreshTimer = nil;
}

- (void)refreshTimerFired:(NSTimer *)timer
{
    (void)timer;
    /* An alert owns the screen; reloading underneath it would be a flicker and
     * could yank the row the parent is looking at. */
    if (_alertCount > 0) return;
    [self refreshFromDiskReloading:YES];
}

- (void)refreshFromDiskReloading:(BOOL)reload
{
    [_ipc loadState:&_state];
    _status = [_ipc statusSnapshot];

    NSString *signature = [self signature];
    BOOL changed = ![_signature isEqualToString:signature];
    _signature = signature;

    if (changed && reload && _alertCount == 0 && [self isViewLoaded] && self.view.window) {
        [self.tableView reloadData];
    }
}

/* Everything the table renders, flattened into one comparable string. */
- (NSString *)signature
{
    NSNumber *pid = [_status objectForKey:@"RuntimePID"];
    NSNumber *tick = [_status objectForKey:@"LastTick"];
    NSNumber *killSwitch = [_status objectForKey:@"KillSwitch"];
    NSNumber *inert = [_status objectForKey:@"Inert"];
    NSNumber *debug = [_status objectForKey:@"DebugLogging"];

    return [NSString stringWithFormat:
            @"%d|%d|%lld|%lld|%d|%d|%ld|%ld|%d|%d|%d|%ld|%ld|%ld|%ld",
            _state.enabled, _state.phase, _state.remaining, _state.overrideUntil,
            _state.usageMinutes, _state.breakMinutes,
            (long)(pid ? [pid longLongValue] : -1),
            (long)(tick ? [tick longLongValue] : -1),
            (killSwitch ? [killSwitch boolValue] : 0),
            (inert ? [inert boolValue] : 0),
            (debug ? [debug boolValue] : 0),
            (long)[_ipc hasPIN], (long)[_ipc requirePIN],
            (long)[_ipc setupComplete], (long)[_ipc lockoutRemaining]];
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

- (long long)usageSecondsLeft
{
    if (!_state.enabled) return 0;
    if (_state.phase == UGPhaseUsage) return _state.remaining;
    return (long long)_state.usageMinutes * 60;
}

- (long long)breakSecondsLeft
{
    if (!_state.enabled) return 0;
    return _state.phase == UGPhaseBreak ? _state.remaining : 0;
}

- (NSString *)runtimeDescription
{
    if (![_ipc runtimeIsLive]) return @"Runtime: nu este detectat";

    NSNumber *pid = [_status objectForKey:@"RuntimePID"];
    if (![pid isKindOfClass:[NSNumber class]]) return @"Runtime: nu este detectat";
    return [NSString stringWithFormat:@"Runtime: activ (pid %ld)", (long)[pid longLongValue]];
}

- (NSString *)statusAgeDescription
{
    if (!_status) return @"fișier absent";

    NSNumber *tick = [_status objectForKey:@"LastTick"];
    if (![tick isKindOfClass:[NSNumber class]]) return @"necunoscut";

    long long age = UGNowSeconds() - [tick longLongValue];
    if (age < 0) age = 0;
    return [NSString stringWithFormat:@"actualizat acum %lld s", age];
}

- (NSString *)killSwitchDescription
{
    if (!_status) return @"fișier absent";

    NSNumber *killSwitch = [_status objectForKey:@"KillSwitch"];
    if (![killSwitch isKindOfClass:[NSNumber class]]) return @"necunoscut";
    return [killSwitch boolValue] ? @"activ" : @"dezactivat";
}

- (NSString *)debugLoggingDescription
{
    if (!_status) return @"fișier absent";

    NSNumber *debug = [_status objectForKey:@"DebugLogging"];
    if (![debug isKindOfClass:[NSNumber class]]) return @"necunoscut";
    return [debug boolValue] ? @"activ" : @"dezactivat";
}

- (NSString *)bundleVersion
{
    NSBundle *bundle = [NSBundle bundleForClass:[UGPreferencesController class]];
    NSString *version = [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    if (version.length == 0) {
        version = [bundle objectForInfoDictionaryKey:@"CFBundleVersion"];
    }
    return version.length > 0 ? version : kUGVersionString;
}

#pragma mark - Table structure

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    (void)tableView;
    return kUGSectionCount;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    (void)tableView;
    switch (section) {
        case kUGSectionStatus: return @"Status";
        case kUGSectionLimits: return @"Limite de timp";
        case kUGSectionActions: return @"Acțiuni";
        case kUGSectionSecurity: return @"Securitate";
        case kUGSectionInformation: return @"Informații";
        default: return nil;
    }
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    (void)tableView;
    switch (section) {
        case kUGSectionStatus: return kUGStatusRowCount;
        case kUGSectionLimits: return kUGLimitRowCount;
        case kUGSectionActions: return kUGActionRowCount;
        case kUGSectionSecurity: return kUGSecurityRowCount;
        case kUGSectionInformation: return kUGInformationRowCount;
        default: return 0;
    }
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    (void)tableView;
    if (indexPath.section == kUGSectionInformation &&
        indexPath.row == kUGInformationRowPreferencesPath) {
        return kUGPathRowHeight;
    }
    return kUGStandardRowHeight;
}

#pragma mark - Cell construction

- (UITableViewCell *)valueCellWithTitle:(NSString *)title detail:(NSString *)detail
{
    UITableViewCell *cell =
        [self.tableView dequeueReusableCellWithIdentifier:@"UGValueCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1
                                     reuseIdentifier:@"UGValueCell"];
    }

    cell.textLabel.text = title;
    cell.textLabel.textColor = [UIColor blackColor];
    cell.textLabel.textAlignment = NSTextAlignmentLeft;
    cell.textLabel.font = [UIFont systemFontOfSize:17.0];
    cell.detailTextLabel.text = detail;
    cell.detailTextLabel.textColor = [UIColor grayColor];
    cell.detailTextLabel.font = [UIFont systemFontOfSize:15.0];
    cell.detailTextLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    cell.detailTextLabel.numberOfLines = 1;
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    return cell;
}

- (UITableViewCell *)pathCellWithTitle:(NSString *)title detail:(NSString *)detail
{
    UITableViewCell *cell =
        [self.tableView dequeueReusableCellWithIdentifier:@"UGPathCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                     reuseIdentifier:@"UGPathCell"];
    }

    cell.textLabel.text = title;
    cell.textLabel.textColor = [UIColor blackColor];
    cell.textLabel.textAlignment = NSTextAlignmentLeft;
    cell.textLabel.font = [UIFont systemFontOfSize:17.0];
    cell.detailTextLabel.text = detail;
    cell.detailTextLabel.textColor = [UIColor grayColor];
    cell.detailTextLabel.font = [UIFont systemFontOfSize:11.0];
    /* The path has no spaces, so wrap mid-token instead of clipping it. */
    cell.detailTextLabel.lineBreakMode = NSLineBreakByCharWrapping;
    cell.detailTextLabel.numberOfLines = 2;
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    return cell;
}

- (UITableViewCell *)textCellWithTitle:(NSString *)title
{
    UITableViewCell *cell =
        [self.tableView dequeueReusableCellWithIdentifier:@"UGTextCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                     reuseIdentifier:@"UGTextCell"];
    }

    cell.textLabel.text = title;
    cell.textLabel.textColor = [UIColor blackColor];
    cell.textLabel.textAlignment = NSTextAlignmentLeft;
    cell.textLabel.font = [UIFont systemFontOfSize:15.0];
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    return cell;
}

- (UITableViewCell *)buttonCellWithTitle:(NSString *)title
{
    UITableViewCell *cell =
        [self.tableView dequeueReusableCellWithIdentifier:@"UGButtonCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                     reuseIdentifier:@"UGButtonCell"];
    }

    cell.textLabel.text = title;
    cell.textLabel.textColor = [UIColor blackColor];
    cell.textLabel.textAlignment = NSTextAlignmentLeft;
    cell.textLabel.font = [UIFont systemFontOfSize:17.0];
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleBlue;

    return cell;
}

- (UITableViewCell *)switchCellWithTitle:(NSString *)title
                                      on:(BOOL)on
                                     tag:(NSInteger)tag
                                  action:(SEL)action
                                 enabled:(BOOL)enabled
{
    UITableViewCell *cell =
        [self.tableView dequeueReusableCellWithIdentifier:@"UGSwitchCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                     reuseIdentifier:@"UGSwitchCell"];
    }

    cell.textLabel.text = title;
    cell.textLabel.textColor = enabled ? [UIColor blackColor] : [UIColor grayColor];
    cell.textLabel.textAlignment = NSTextAlignmentLeft;
    cell.textLabel.font = [UIFont systemFontOfSize:17.0];
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    UISwitch *toggle = (UISwitch *)cell.accessoryView;
    if (![toggle isKindOfClass:[UISwitch class]]) {
        toggle = [[UISwitch alloc] initWithFrame:CGRectMake(0.0f, 0.0f, 79.0f, 27.0f)];
        cell.accessoryView = toggle;
    }
    /* Rebind from scratch: a reused cell must never keep a stale target. */
    [toggle removeTarget:nil action:NULL forControlEvents:UIControlEventValueChanged];
    [toggle addTarget:self action:action forControlEvents:UIControlEventValueChanged];
    toggle.tag = tag;
    toggle.enabled = enabled;
    [toggle setOn:on animated:NO];

    return cell;
}

#pragma mark - Cells

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    (void)tableView;

    switch (indexPath.section) {
        case kUGSectionStatus:
            switch (indexPath.row) {
                case kUGStatusRowEnabled:
                    return [self switchCellWithTitle:@"Usage Guard activ"
                                                  on:_state.enabled != 0
                                                 tag:kUGSwitchTagEnabled
                                              action:@selector(enabledSwitchChanged:)
                                             enabled:YES];
                case kUGStatusRowPhase:
                    return [self valueCellWithTitle:@"Stare"
                                             detail:[self phaseDescription]];
                case kUGStatusRowUsageLeft:
                    return [self valueCellWithTitle:@"Utilizare rămasă"
                                             detail:UGFormatSeconds([self usageSecondsLeft])];
                case kUGStatusRowBreakLeft:
                    return [self valueCellWithTitle:@"Pauză rămasă"
                                             detail:UGFormatSeconds([self breakSecondsLeft])];
                case kUGStatusRowRuntime:
                    return [self textCellWithTitle:[self runtimeDescription]];
                default:
                    break;
            }
            break;

        case kUGSectionLimits:
            switch (indexPath.row) {
                case kUGLimitRowUsage:
                    return [self valueCellWithTitle:@"Utilizare (minute)"
                                             detail:[NSString stringWithFormat:@"%d",
                                                     _state.usageMinutes]];
                case kUGLimitRowBreak:
                    return [self valueCellWithTitle:@"Pauză (minute)"
                                             detail:[NSString stringWithFormat:@"%d",
                                                     _state.breakMinutes]];
                default:
                    break;
            }
            break;

        case kUGSectionActions:
            switch (indexPath.row) {
                case kUGActionRowStartBreak:
                    return [self buttonCellWithTitle:@"Începe pauza acum"];
                case kUGActionRowReset:
                    return [self buttonCellWithTitle:@"Resetează ciclul"];
                case kUGActionRowPause15:
                    return [self buttonCellWithTitle:@"Pauză 15 min"];
                case kUGActionRowPause30:
                    return [self buttonCellWithTitle:@"Pauză 30 min"];
                case kUGActionRowPause60:
                    return [self buttonCellWithTitle:@"Pauză 60 min"];
                case kUGActionRowResume:
                    return [self buttonCellWithTitle:@"Reia restricțiile"];
                case kUGActionRowTestOverlay:
                    return [self buttonCellWithTitle:@"Testează ecranul de blocare"];
                default:
                    break;
            }
            break;

        case kUGSectionSecurity:
            switch (indexPath.row) {
                case kUGSecurityRowPIN:
                    return [self buttonCellWithTitle:([_ipc hasPIN] ? @"Schimbă codul PIN"
                                                                    : @"Setează un cod PIN")];
                case kUGSecurityRowRequirePIN:
                    return [self switchCellWithTitle:@"Cere PIN pentru modificări"
                                                  on:[_ipc requirePIN]
                                                 tag:kUGSwitchTagRequirePIN
                                              action:@selector(requirePINSwitchChanged:)
                                             enabled:[_ipc hasPIN]];
                default:
                    break;
            }
            break;

        case kUGSectionInformation:
            switch (indexPath.row) {
                case kUGInformationRowVersion:
                    return [self valueCellWithTitle:@"Versiune Usage Guard"
                                             detail:kUGVersionString];
                case kUGInformationRowRuntime:
                    return [self valueCellWithTitle:@"Runtime"
                                             detail:[self runtimeDescription]];
                case kUGInformationRowBundleVersion:
                    return [self valueCellWithTitle:@"Versiune pachet"
                                             detail:[self bundleVersion]];
                case kUGInformationRowPreferencesPath:
                    return [self pathCellWithTitle:@"Fișier preferințe"
                                            detail:[_ipc preferencesPath]];
                case kUGInformationRowStatusAge:
                    return [self valueCellWithTitle:@"Stare runtime"
                                             detail:[self statusAgeDescription]];
                case kUGInformationRowKillSwitch:
                    return [self valueCellWithTitle:@"Kill switch"
                                             detail:[self killSwitchDescription]];
                case kUGInformationRowDebugLogging:
                    return [self valueCellWithTitle:@"Jurnalizare (DebugLogging)"
                                             detail:[self debugLoggingDescription]];
                default:
                    break;
            }
            break;

        default:
            break;
    }

    /* Unreachable, but a table view must always get a configured cell. */
    return [self textCellWithTitle:@""];
}

#pragma mark - Selection

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (_alertCount > 0) return;

    switch (indexPath.section) {
        case kUGSectionLimits:
            if (indexPath.row == kUGLimitRowUsage) [self beginEditingUsageMinutes];
            else if (indexPath.row == kUGLimitRowBreak) [self beginEditingBreakMinutes];
            break;

        case kUGSectionActions:
            [self performActionAtIndex:indexPath.row];
            break;

        case kUGSectionSecurity:
            if (indexPath.row == kUGSecurityRowPIN) [self beginChangingPIN];
            break;

        default:
            break;
    }
}

#pragma mark - Writes

- (BOOL)applyChange:(void (^)(UGState *state))change
{
    if (![_ipc applyStateChange:change]) {
        [self showNotice:@"Setările nu au putut fi salvate. Verifică spațiul liber pe dispozitiv."
                   title:@"Eroare"];
        return NO;
    }

    [self refreshFromDiskReloading:YES];
    return YES;
}

- (void)setEnabled:(BOOL)enabled
{
    [self applyChange:^(UGState *state) {
        ug_set_enabled(state, enabled ? 1 : 0, UGNowSeconds());
    }];
}

- (void)setRequirePIN:(BOOL)required
{
    [_ipc setRequirePIN:required];
    [self refreshFromDiskReloading:YES];
}

- (void)enabledSwitchChanged:(UISwitch *)sender
{
    BOOL desired = sender.isOn;

    if (!desired && [self authorizationRequired]) {
        /* Put the switch back before asking: the row must never claim the guard
         * is off while it is still enforcing. */
        [sender setOn:YES animated:YES];
        [self requireAuthorizationThen:^{ [self setEnabled:NO]; }];
        return;
    }

    [self setEnabled:desired];
}

- (void)requirePINSwitchChanged:(UISwitch *)sender
{
    BOOL desired = sender.isOn;

    if (!desired && [self authorizationRequired]) {
        [sender setOn:YES animated:YES];
        [self requireAuthorizationThen:^{ [self setRequirePIN:NO]; }];
        return;
    }

    [self setRequirePIN:desired];
}

- (void)performActionAtIndex:(NSInteger)row
{
    switch (row) {
        case kUGActionRowStartBreak:
            [self requireAuthorizationThen:^{
                [self applyChange:^(UGState *state) {
                    ug_start_break(state, UGNowSeconds());
                }];
            }];
            break;

        case kUGActionRowReset:
            [self requireAuthorizationThen:^{
                [self applyChange:^(UGState *state) {
                    ug_reset(state, UGNowSeconds());
                }];
            }];
            break;

        case kUGActionRowPause15:
        case kUGActionRowPause30:
        case kUGActionRowPause60: {
            NSInteger minutes = row == kUGActionRowPause15 ? 15
                              : (row == kUGActionRowPause30 ? 30 : 60);
            [self requireAuthorizationThen:^{
                [self applyChange:^(UGState *state) {
                    ug_pause(state, UGNowSeconds(), (int)minutes);
                }];
            }];
            break;
        }

        case kUGActionRowResume:
            [self requireAuthorizationThen:^{
                [self applyChange:^(UGState *state) {
                    ug_resume(state, UGNowSeconds());
                }];
            }];
            break;

        case kUGActionRowTestOverlay:
            /* Visual check only: no state, so no PIN and no persistence. */
            [_ipc postTestOverlay];
            break;

        default:
            break;
    }
}

#pragma mark - Authorization

- (BOOL)authorizationRequired
{
    if (_authorized) return NO;
    if (![_ipc hasPIN]) return NO;
    return [_ipc requirePIN];
}

- (void)requireAuthorizationThen:(void (^)(void))action
{
    if (![self authorizationRequired]) {
        if (action) action();
        return;
    }

    NSInteger lockout = [_ipc lockoutRemaining];
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
    if (cancelled) {
        _pendingAuthorizedAction = nil;
        return;
    }

    NSString *pin = [[alertView textFieldAtIndex:0] text];
    if ([_ipc verifyPIN:pin]) {
        _authorized = YES;
        void (^action)(void) = _pendingAuthorizedAction;
        _pendingAuthorizedAction = nil;
        if (action) action();
        return;
    }

    NSInteger lockout = [_ipc lockoutRemaining];
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

- (void)beginEditingUsageMinutes
{
    [self requireAuthorizationThen:^{ [self presentUsageEditor]; }];
}

- (void)beginEditingBreakMinutes
{
    [self requireAuthorizationThen:^{ [self presentBreakEditor]; }];
}

- (void)presentUsageEditor
{
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

    [self applyChange:^(UGState *state) {
        if (usage) ug_set_usage_minutes(state, minutes);
        else ug_set_break_minutes(state, minutes);
    }];
}

#pragma mark - PIN

- (void)beginChangingPIN
{
    [self requireAuthorizationThen:^{ [self presentNewPINEditor]; }];
}

- (void)presentNewPINEditor
{
    UIAlertView *alert = [[UIAlertView alloc]
                          initWithTitle:([_ipc hasPIN] ? @"Schimbă codul PIN"
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
    NSString *pin = [[alertView textFieldAtIndex:0] text];
    if (![pin isEqualToString:_pendingPIN]) {
        _pendingPIN = nil;
        [self showNotice:@"Codurile nu se potrivesc. Încearcă din nou."
                   title:@"Cod PIN"
                  resume:^{ [self presentNewPINEditor]; }];
        return;
    }

    _pendingPIN = nil;
    if (![_ipc setPIN:pin]) {
        [self showNotice:@"Codul PIN nu a putut fi salvat." title:@"Eroare"];
        return;
    }

    /* The parent just chose it, so the pane stays unlocked. */
    _authorized = YES;
    [self refreshFromDiskReloading:YES];
    [self showNotice:@"Cod PIN salvat." title:@"Securitate"];
}

#pragma mark - First-run wizard

- (void)beginWizard
{
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
    /* Cancel at any step leaves the guard exactly as it was: nothing enforced,
     * nothing written. */
    _wizardStep = kUGWizardStepIdle;
    _wizardPIN = nil;
    _pendingPIN = nil;
    [self refreshFromDiskReloading:YES];
}

- (void)presentWizardStep
{
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
    _wizardStep = kUGWizardStepIdle;

    if (![_ipc setPIN:_wizardPIN]) {
        [self showNotice:@"Codul PIN nu a putut fi salvat." title:@"Eroare"];
        return;
    }

    BOOL saved = [self applyChange:^(UGState *state) {
        ug_set_usage_minutes(state, _wizardUsageMinutes);
        ug_set_break_minutes(state, _wizardBreakMinutes);
        ug_set_enabled(state, 1, UGNowSeconds());
    }];
    if (!saved) return;

    [_ipc setSetupComplete:YES];

    /* The parent just picked the PIN, so the pane stays unlocked. */
    _authorized = YES;
    _wizardPIN = nil;
    [self refreshFromDiskReloading:YES];
}

#pragma mark - Alerts

- (void)presentAlert:(UIAlertView *)alert
{
    alert.delegate = self;
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
    /* iOS 6 dismisses an alert this way when the app leaves the foreground and
     * may skip didDismiss. Both paths decrement, and the count is clamped, so
     * the refresh loop can never be wedged by a lost dismissal. */
    (void)alertView;
    if (_alertCount > 0) _alertCount--;
    _resumeAfterNotice = nil;
    _pendingAuthorizedAction = nil;
}

- (void)alertView:(UIAlertView *)alertView didDismissWithButtonIndex:(NSInteger)buttonIndex
{
    if (_alertCount > 0) _alertCount--;

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
