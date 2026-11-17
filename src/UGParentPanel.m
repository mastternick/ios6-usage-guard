#import "UGParentPanel.h"

#import <QuartzCore/QuartzCore.h>

#import "UGPrefs.h"

typedef enum {
    UGPanelModeGate = 0,
    UGPanelModeWizard = 1,
    UGPanelModePanel = 2
} UGPanelMode;

static const CGFloat kUGPanelWidth = 320.0f;
static const CGFloat kUGPanelHeight = 480.0f;
static const CGFloat kUGKeypadHeight = 206.0f;
static const NSInteger kUGKeypadDeleteTag = 10;
static const NSInteger kUGKeypadConfirmTag = 11;
static const NSUInteger kUGPINMinLength = 4;
static const NSUInteger kUGPINMaxLength = 8;

@implementation UGParentPanelController {
    UGState _state;
    BOOL _requiresSetup;
    UGPanelMode _mode;
    NSMutableString *_pinEntry;
    NSString *_pendingPIN;
    NSInteger _wizardStep;
    BOOL _returnToPanel;
    BOOL _gateError;

    UIView *_gateView;
    UILabel *_gateTitle;
    UILabel *_gateDots;
    UILabel *_gateHint;
    UILabel *_gateMessageLabel;

    UIView *_wizardView;
    UILabel *_wizardTitle;
    UILabel *_wizardHint;
    UILabel *_wizardDots;
    UILabel *_wizardMessageLabel;
    UIButton *_wizardCancelButton;

    UIView *_panelView;
    UILabel *_panelStatus;
    UILabel *_usageValue;
    UILabel *_breakValue;
    UISwitch *_enabledSwitch;
}

- (id)initWithDelegate:(id<UGParentPanelDelegate>)delegate
         requiresSetup:(BOOL)requiresSetup
{
    self = [super initWithNibName:nil bundle:nil];
    if (!self) return nil;

    _delegate = delegate;
    _requiresSetup = requiresSetup;
    _state = [delegate panelCurrentState];
    _pinEntry = [[NSMutableString alloc] init];
    return self;
}

- (void)loadView
{
    UIView *root = [[UIView alloc] initWithFrame:CGRectMake(0.0f, 0.0f,
                                                            kUGPanelWidth,
                                                            kUGPanelHeight)];
    root.backgroundColor = [UIColor colorWithRed:0.07f green:0.09f blue:0.15f alpha:1.0f];
    self.view = root;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    [self buildInterface];

    if (_requiresSetup) {
        [self beginWizardForChange:NO];
    } else {
        [self showMode:UGPanelModeGate];
    }
    [self refreshStatus];
}

- (BOOL)shouldAutorotate
{
    return NO;
}

- (NSUInteger)supportedInterfaceOrientations
{
    return UIInterfaceOrientationMaskPortrait;
}

#pragma mark - Construction helpers

- (UILabel *)labelWithFrame:(CGRect)frame
                       font:(UIFont *)font
                      color:(UIColor *)color
                  alignment:(NSTextAlignment)alignment
{
    UILabel *label = [[UILabel alloc] initWithFrame:frame];
    label.backgroundColor = [UIColor clearColor];
    label.font = font;
    label.textColor = color;
    label.textAlignment = alignment;
    return label;
}

- (UIButton *)buttonWithFrame:(CGRect)frame
                        title:(NSString *)title
                          tag:(NSInteger)tag
                       action:(SEL)action
{
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    button.frame = frame;
    button.tag = tag;
    button.titleLabel.font = [UIFont boldSystemFontOfSize:16.0f];
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    button.backgroundColor = [UIColor colorWithWhite:1.0f alpha:0.13f];
    button.layer.cornerRadius = 8.0f;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (UIView *)buildKeypadAtY:(CGFloat)top
{
    NSArray *titles = @[@"1", @"2", @"3", @"4", @"5", @"6", @"7", @"8", @"9",
                        @"Șterge", @"0", @"OK"];
    UIView *keypad = [[UIView alloc] initWithFrame:CGRectMake(0.0f, top,
                                                              kUGPanelWidth,
                                                              kUGKeypadHeight)];

    for (NSUInteger index = 0; index < titles.count; index++) {
        NSUInteger row = index / 3;
        NSUInteger column = index % 3;
        NSInteger tag;

        if (index < 9) tag = (NSInteger)index + 1;
        else if (index == 9) tag = kUGKeypadDeleteTag;
        else if (index == 10) tag = 0;
        else tag = kUGKeypadConfirmTag;

        UIButton *button = [self buttonWithFrame:CGRectMake(36.0f + (CGFloat)column * 88.0f,
                                                            (CGFloat)row * 54.0f,
                                                            72.0f, 44.0f)
                                           title:titles[index]
                                             tag:tag
                                          action:@selector(keypadButtonTapped:)];
        button.titleLabel.font = (tag == kUGKeypadConfirmTag)
            ? [UIFont boldSystemFontOfSize:18.0f]
            : [UIFont boldSystemFontOfSize:22.0f];
        [keypad addSubview:button];
    }
    return keypad;
}

- (void)buildInterface
{
    CGRect full = CGRectMake(0.0f, 0.0f, kUGPanelWidth, kUGPanelHeight);
    UIColor *light = [UIColor colorWithWhite:0.96f alpha:1.0f];
    UIColor *muted = [UIColor colorWithWhite:0.62f alpha:1.0f];
    UIColor *accent = [UIColor colorWithRed:0.30f green:0.78f blue:0.80f alpha:1.0f];
    UIColor *warning = [UIColor colorWithRed:0.95f green:0.52f blue:0.45f alpha:1.0f];

    /* PIN gate */
    _gateView = [[UIView alloc] initWithFrame:full];
    _gateTitle = [self labelWithFrame:CGRectMake(16.0f, 40.0f, 288.0f, 34.0f)
                                 font:[UIFont boldSystemFontOfSize:24.0f]
                                color:light
                            alignment:NSTextAlignmentCenter];
    _gateTitle.text = @"Introdu codul PIN";
    _gateDots = [self labelWithFrame:CGRectMake(16.0f, 82.0f, 288.0f, 30.0f)
                                font:[UIFont boldSystemFontOfSize:22.0f]
                               color:accent
                           alignment:NSTextAlignmentCenter];
    _gateHint = [self labelWithFrame:CGRectMake(16.0f, 114.0f, 288.0f, 20.0f)
                                font:[UIFont systemFontOfSize:13.0f]
                               color:muted
                           alignment:NSTextAlignmentCenter];
    _gateHint.text = @"4–8 cifre";
    _gateMessageLabel = [self labelWithFrame:CGRectMake(16.0f, 358.0f, 288.0f, 30.0f)
                                        font:[UIFont systemFontOfSize:12.0f]
                                       color:warning
                                   alignment:NSTextAlignmentCenter];
    _gateMessageLabel.numberOfLines = 2;
    _gateMessageLabel.text = @"";
    [_gateView addSubview:_gateTitle];
    [_gateView addSubview:_gateDots];
    [_gateView addSubview:_gateHint];
    [_gateView addSubview:[self buildKeypadAtY:150.0f]];
    [_gateView addSubview:_gateMessageLabel];
    [_gateView addSubview:[self buttonWithFrame:CGRectMake(36.0f, 390.0f, 248.0f, 44.0f)
                                          title:@"Anulează"
                                            tag:0
                                         action:@selector(cancelTapped:)]];
    [self.view addSubview:_gateView];

    /* Mandatory first-run PIN wizard / change PIN */
    _wizardView = [[UIView alloc] initWithFrame:full];
    _wizardTitle = [self labelWithFrame:CGRectMake(16.0f, 40.0f, 288.0f, 34.0f)
                                   font:[UIFont boldSystemFontOfSize:22.0f]
                                  color:light
                              alignment:NSTextAlignmentCenter];
    _wizardHint = [self labelWithFrame:CGRectMake(16.0f, 78.0f, 288.0f, 22.0f)
                                  font:[UIFont systemFontOfSize:13.0f]
                                 color:muted
                             alignment:NSTextAlignmentCenter];
    _wizardDots = [self labelWithFrame:CGRectMake(16.0f, 106.0f, 288.0f, 28.0f)
                                  font:[UIFont boldSystemFontOfSize:22.0f]
                                 color:accent
                             alignment:NSTextAlignmentCenter];
    _wizardMessageLabel = [self labelWithFrame:CGRectMake(16.0f, 352.0f, 288.0f, 34.0f)
                                          font:[UIFont systemFontOfSize:12.0f]
                                         color:warning
                                     alignment:NSTextAlignmentCenter];
    _wizardMessageLabel.numberOfLines = 2;
    _wizardMessageLabel.text = @"";
    _wizardCancelButton = [self buttonWithFrame:CGRectMake(36.0f, 388.0f, 248.0f, 44.0f)
                                           title:@"Mai târziu"
                                             tag:0
                                          action:@selector(cancelTapped:)];
    [_wizardView addSubview:_wizardTitle];
    [_wizardView addSubview:_wizardHint];
    [_wizardView addSubview:_wizardDots];
    [_wizardView addSubview:[self buildKeypadAtY:142.0f]];
    [_wizardView addSubview:_wizardMessageLabel];
    [_wizardView addSubview:_wizardCancelButton];
    [self.view addSubview:_wizardView];

    /* Parent panel */
    _panelView = [[UIView alloc] initWithFrame:full];
    UILabel *panelTitle = [self labelWithFrame:CGRectMake(16.0f, 24.0f, 210.0f, 32.0f)
                                          font:[UIFont boldSystemFontOfSize:22.0f]
                                         color:light
                                     alignment:NSTextAlignmentLeft];
    panelTitle.text = @"Panou părinți";
    [_panelView addSubview:panelTitle];
    [_panelView addSubview:[self buttonWithFrame:CGRectMake(244.0f, 24.0f, 60.0f, 32.0f)
                                           title:@"Închide"
                                             tag:0
                                          action:@selector(closeTapped:)]];

    _panelStatus = [self labelWithFrame:CGRectMake(16.0f, 64.0f, 288.0f, 42.0f)
                                   font:[UIFont systemFontOfSize:15.0f]
                                  color:light
                              alignment:NSTextAlignmentLeft];
    _panelStatus.numberOfLines = 2;
    [_panelView addSubview:_panelStatus];

    UILabel *usageLabel = [self labelWithFrame:CGRectMake(16.0f, 112.0f, 148.0f, 36.0f)
                                          font:[UIFont systemFontOfSize:15.0f]
                                         color:muted
                                     alignment:NSTextAlignmentLeft];
    usageLabel.text = @"Utilizare (min)";
    [_panelView addSubview:usageLabel];
    [_panelView addSubview:[self buttonWithFrame:CGRectMake(176.0f, 112.0f, 36.0f, 36.0f)
                                           title:@"-"
                                             tag:0
                                          action:@selector(usageMinus:)]];
    _usageValue = [self labelWithFrame:CGRectMake(216.0f, 112.0f, 44.0f, 36.0f)
                                  font:[UIFont boldSystemFontOfSize:17.0f]
                                 color:light
                             alignment:NSTextAlignmentCenter];
    [_panelView addSubview:_usageValue];
    [_panelView addSubview:[self buttonWithFrame:CGRectMake(264.0f, 112.0f, 36.0f, 36.0f)
                                           title:@"+"
                                             tag:0
                                          action:@selector(usagePlus:)]];

    UILabel *breakLabel = [self labelWithFrame:CGRectMake(16.0f, 156.0f, 148.0f, 36.0f)
                                          font:[UIFont systemFontOfSize:15.0f]
                                         color:muted
                                     alignment:NSTextAlignmentLeft];
    breakLabel.text = @"Pauză (min)";
    [_panelView addSubview:breakLabel];
    [_panelView addSubview:[self buttonWithFrame:CGRectMake(176.0f, 156.0f, 36.0f, 36.0f)
                                           title:@"-"
                                             tag:0
                                          action:@selector(breakMinus:)]];
    _breakValue = [self labelWithFrame:CGRectMake(216.0f, 156.0f, 44.0f, 36.0f)
                                  font:[UIFont boldSystemFontOfSize:17.0f]
                                 color:light
                             alignment:NSTextAlignmentCenter];
    [_panelView addSubview:_breakValue];
    [_panelView addSubview:[self buttonWithFrame:CGRectMake(264.0f, 156.0f, 36.0f, 36.0f)
                                           title:@"+"
                                             tag:0
                                          action:@selector(breakPlus:)]];

    UILabel *enabledLabel = [self labelWithFrame:CGRectMake(16.0f, 202.0f, 190.0f, 31.0f)
                                            font:[UIFont systemFontOfSize:15.0f]
                                           color:light
                                       alignment:NSTextAlignmentLeft];
    enabledLabel.text = @"Usage Guard activ";
    [_panelView addSubview:enabledLabel];
    _enabledSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(248.0f, 202.0f, 51.0f, 31.0f)];
    [_enabledSwitch addTarget:self
                       action:@selector(enabledSwitchChanged:)
             forControlEvents:UIControlEventValueChanged];
    [_panelView addSubview:_enabledSwitch];

    UILabel *overrideCaption = [self labelWithFrame:CGRectMake(16.0f, 244.0f, 288.0f, 20.0f)
                                               font:[UIFont systemFontOfSize:13.0f]
                                              color:muted
                                          alignment:NSTextAlignmentLeft];
    overrideCaption.text = @"Pauză PIN (ascunde timerul)";
    [_panelView addSubview:overrideCaption];

    NSArray *overrideTitles = @[@"15 min", @"30 min", @"60 min"];
    NSArray *overrideValues = @[@15, @30, @60];
    for (NSUInteger index = 0; index < overrideTitles.count; index++) {
        UIButton *button = [self buttonWithFrame:CGRectMake(16.0f + (CGFloat)index * 100.0f,
                                                            268.0f, 88.0f, 40.0f)
                                           title:overrideTitles[index]
                                             tag:[overrideValues[index] integerValue]
                                          action:@selector(overrideTapped:)];
        button.titleLabel.font = [UIFont boldSystemFontOfSize:15.0f];
        [_panelView addSubview:button];
    }

    [_panelView addSubview:[self buttonWithFrame:CGRectMake(16.0f, 320.0f, 288.0f, 42.0f)
                                           title:@"Începe pauza acum"
                                             tag:0
                                          action:@selector(startBreakTapped:)]];
    [_panelView addSubview:[self buttonWithFrame:CGRectMake(16.0f, 368.0f, 288.0f, 42.0f)
                                           title:@"Resetează ciclul"
                                             tag:0
                                          action:@selector(resetTapped:)]];
    [_panelView addSubview:[self buttonWithFrame:CGRectMake(16.0f, 416.0f, 288.0f, 42.0f)
                                           title:@"Schimbă codul PIN"
                                             tag:0
                                          action:@selector(changePINTapped:)]];
    [self.view addSubview:_panelView];

    _gateView.hidden = YES;
    _wizardView.hidden = YES;
    _panelView.hidden = YES;
}

#pragma mark - Mode handling

- (void)showMode:(UGPanelMode)mode
{
    _mode = mode;
    _gateView.hidden = mode != UGPanelModeGate;
    _wizardView.hidden = mode != UGPanelModeWizard;
    _panelView.hidden = mode != UGPanelModePanel;

    [_pinEntry setString:@""];
    [self refreshEntryDots];

    if (mode == UGPanelModeGate) {
        _gateError = NO;
        [self refreshGateMessage];
    } else if (mode == UGPanelModePanel) {
        [self refreshStatus];
    }
}

- (void)refreshEntryDots
{
    NSMutableString *dots = [NSMutableString string];
    for (NSUInteger index = 0; index < _pinEntry.length; index++) {
        [dots appendString:@"●"];
    }
    _gateDots.text = dots;
    _wizardDots.text = dots;
}

- (void)refreshGateMessage
{
    NSInteger lockout = [self.delegate panelPINLockoutSeconds];
    if (lockout > 0) {
        _gateMessageLabel.text = [NSString stringWithFormat:
            @"Prea multe încercări. Reîncearcă în %ld secunde.", (long)lockout];
    } else if (_gateError) {
        _gateMessageLabel.text = @"Cod PIN greșit.";
    } else {
        _gateMessageLabel.text = @"";
    }
}

- (void)refreshStatus
{
    if (!_panelStatus) return;

    {
        char mmss[16];
        NSString *status;
        if (!_state.enabled) {
            status = @"Oprit";
        } else {
            ug_format_mmss(_state.remaining, mmss, sizeof mmss);
            status = [NSString stringWithFormat:@"%@ · %s rămase",
                      _state.phase == UGPhaseBreak ? @"Pauză" : @"Utilizare", mmss];
        }

        {
            long long overrideLeft = _state.overrideUntil - UGNowSeconds();
            if (overrideLeft > 0) {
                ug_format_mmss(overrideLeft, mmss, sizeof mmss);
                status = [status stringByAppendingFormat:@" · PIN %s", mmss];
            }
        }
        _panelStatus.text = status;
    }

    _usageValue.text = [NSString stringWithFormat:@"%d", _state.usageMinutes];
    _breakValue.text = [NSString stringWithFormat:@"%d", _state.breakMinutes];
    [_enabledSwitch setOn:_state.enabled != 0 animated:NO];
}

- (void)updateState:(UGState)state
{
    _state = state;
    if (_mode == UGPanelModePanel) {
        [self refreshStatus];
    } else if (_mode == UGPanelModeGate) {
        [self refreshGateMessage];
    }
}

#pragma mark - PIN entry

- (void)keypadButtonTapped:(UIButton *)sender
{
    NSInteger tag = sender.tag;

    if (tag == kUGKeypadDeleteTag) {
        if (_pinEntry.length > 0) {
            [_pinEntry deleteCharactersInRange:NSMakeRange(_pinEntry.length - 1, 1)];
        }
        [self refreshEntryDots];
        return;
    }

    if (tag == kUGKeypadConfirmTag) {
        [self submitEntry];
        return;
    }

    if (_pinEntry.length >= kUGPINMaxLength) return;
    [_pinEntry appendFormat:@"%ld", (long)tag];
    [self refreshEntryDots];
}

- (void)submitEntry
{
    if (_mode == UGPanelModePanel) return;
    if (_pinEntry.length < kUGPINMinLength) {
        if (_mode == UGPanelModeGate) {
            _gateError = NO;
            _gateMessageLabel.text = @"Introdu 4–8 cifre.";
        } else {
            _wizardMessageLabel.text = @"Codul trebuie să aibă 4–8 cifre.";
        }
        return;
    }

    if (_mode == UGPanelModeGate) {
        if ([self.delegate panelPINLockoutSeconds] > 0) {
            [self refreshGateMessage];
            return;
        }
        if ([self.delegate panelVerifyPIN:_pinEntry]) {
            [self showMode:UGPanelModePanel];
        } else {
            [_pinEntry setString:@""];
            [self refreshEntryDots];
            _gateError = YES;
            [self refreshGateMessage];
        }
        return;
    }

    /* Wizard */
    if (_wizardStep == 1) {
        _pendingPIN = [_pinEntry copy];
        [_pinEntry setString:@""];
        [self refreshEntryDots];
        _wizardStep = 2;
        _wizardTitle.text = @"Confirmă codul PIN";
        _wizardHint.text = @"Introdu din nou codul";
        _wizardMessageLabel.text = @"";
        return;
    }

    {
        BOOL matches = _pendingPIN != nil && [_pendingPIN isEqualToString:_pinEntry];
        [_pinEntry setString:@""];
        [self refreshEntryDots];

        if (!matches) {
            _pendingPIN = nil;
            _wizardStep = 1;
            _wizardTitle.text = @"Setează un cod PIN";
            _wizardHint.text = @"4–8 cifre, păstrat doar de părinte";
            _wizardMessageLabel.text = @"Codurile nu se potrivesc. Încearcă din nou.";
            return;
        }
    }

    if ([self.delegate panelStorePIN:_pendingPIN]) {
        _pendingPIN = nil;
        [self showMode:UGPanelModePanel];
    } else {
        _pendingPIN = nil;
        _wizardStep = 1;
        _wizardTitle.text = @"Setează un cod PIN";
        _wizardHint.text = @"4–8 cifre, păstrat doar de părinte";
        _wizardMessageLabel.text = @"Codul PIN nu a putut fi salvat.";
    }
}

- (void)beginWizardForChange:(BOOL)change
{
    _returnToPanel = change;
    _wizardStep = 1;
    _pendingPIN = nil;
    _wizardTitle.text = @"Setează un cod PIN";
    _wizardHint.text = @"4–8 cifre, păstrat doar de părinte";
    _wizardMessageLabel.text = @"";
    [_wizardCancelButton setTitle:(change ? @"Anulează" : @"Mai târziu")
                         forState:UIControlStateNormal];
    [self showMode:UGPanelModeWizard];
}

- (void)cancelTapped:(id)sender
{
    (void)sender;
    if (_mode == UGPanelModeWizard && _returnToPanel) {
        [self showMode:UGPanelModePanel];
        return;
    }
    [self.delegate panelRequestDismiss];
}

#pragma mark - Panel actions

- (void)commitState
{
    [self refreshStatus];
    [self.delegate panelApplyState:_state];
}

- (void)usageMinus:(id)sender
{
    (void)sender;
    ug_set_usage_minutes(&_state, _state.usageMinutes - 1);
    [self commitState];
}

- (void)usagePlus:(id)sender
{
    (void)sender;
    ug_set_usage_minutes(&_state, _state.usageMinutes + 1);
    [self commitState];
}

- (void)breakMinus:(id)sender
{
    (void)sender;
    ug_set_break_minutes(&_state, _state.breakMinutes - 1);
    [self commitState];
}

- (void)breakPlus:(id)sender
{
    (void)sender;
    ug_set_break_minutes(&_state, _state.breakMinutes + 1);
    [self commitState];
}

- (void)enabledSwitchChanged:(UISwitch *)sender
{
    ug_set_enabled(&_state, sender.isOn, UGNowSeconds());
    [self commitState];
}

- (void)overrideTapped:(UIButton *)sender
{
    ug_pause(&_state, UGNowSeconds(), (int)sender.tag);
    [self commitState];
}

- (void)startBreakTapped:(id)sender
{
    (void)sender;
    ug_start_break(&_state, UGNowSeconds());
    [self commitState];
}

- (void)resetTapped:(id)sender
{
    (void)sender;
    ug_reset(&_state, UGNowSeconds());
    [self commitState];
}

- (void)changePINTapped:(id)sender
{
    (void)sender;
    [self beginWizardForChange:YES];
}

- (void)closeTapped:(id)sender
{
    (void)sender;
    [self.delegate panelRequestDismiss];
}

@end
