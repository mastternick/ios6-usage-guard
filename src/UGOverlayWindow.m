#import "UGOverlayWindow.h"

#import <QuartzCore/QuartzCore.h>
#import <math.h>

#import "UGGuardCore.h"

static const CGFloat kUGOverlayWidth = 320.0f;
static const CGFloat kUGOverlayHeight = 480.0f;
static const NSTimeInterval kUGParentTapWindow = 3.0;
static const NSInteger kUGParentTapCount = 7;

@implementation UGOverlayController {
    UIView *_contentView;
    CAGradientLayer *_gradientLayer;
    UILabel *_titleLabel;
    UILabel *_subtitleLabel;
    UIView *_ringContainer;
    CAShapeLayer *_ringTrack;
    CAShapeLayer *_ringProgress;
    UILabel *_countdownLabel;
    UIButton *_dismissButton;
    long long _remaining;
    NSInteger _titleTapCount;
    NSTimeInterval _firstTitleTapTime;
    BOOL _testMode;
}

- (void)loadView
{
    UIView *root = [[UIView alloc] initWithFrame:CGRectMake(0.0f, 0.0f,
                                                            kUGOverlayWidth,
                                                            kUGOverlayHeight)];
    root.backgroundColor = [UIColor clearColor];
    self.view = root;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    [self buildInterface];
}

- (BOOL)shouldAutorotate
{
    return NO;
}

- (NSUInteger)supportedInterfaceOrientations
{
    return UIInterfaceOrientationMaskPortrait;
}

- (void)buildInterface
{
    CGRect bounds = self.view.bounds;
    CGFloat centerX = bounds.size.width / 2.0f;

    _contentView = [[UIView alloc] initWithFrame:bounds];
    _contentView.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                    UIViewAutoresizingFlexibleHeight;
    _contentView.backgroundColor = [UIColor clearColor];
    [self.view addSubview:_contentView];

    _gradientLayer = [CAGradientLayer layer];
    _gradientLayer.frame = bounds;
    _gradientLayer.colors =
        @[(__bridge id)[UIColor colorWithRed:0.84f green:0.92f blue:1.00f alpha:1.0f].CGColor,
          (__bridge id)[UIColor colorWithRed:1.00f green:0.91f blue:0.78f alpha:1.0f].CGColor];
    _gradientLayer.locations = @[@0.0f, @1.0f];
    [_contentView.layer addSublayer:_gradientLayer];

    UIColor *inkColor = [UIColor colorWithRed:0.11f green:0.16f blue:0.32f alpha:1.0f];
    UIColor *accentColor = [UIColor colorWithRed:0.05f green:0.55f blue:0.60f alpha:1.0f];

    _titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(centerX - 144.0f, 56.0f, 288.0f, 40.0f)];
    _titleLabel.backgroundColor = [UIColor clearColor];
    _titleLabel.textColor = inkColor;
    _titleLabel.font = [UIFont boldSystemFontOfSize:24.0f];
    _titleLabel.textAlignment = NSTextAlignmentCenter;
    _titleLabel.adjustsFontSizeToFitWidth = YES;
    _titleLabel.text = @"Pauză de la telefon!";
    _titleLabel.userInteractionEnabled = YES;
    [_contentView addSubview:_titleLabel];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(handleTitleTap:)];
    tap.numberOfTapsRequired = 1;
    [_titleLabel addGestureRecognizer:tap];

    _subtitleLabel = [[UILabel alloc] initWithFrame:CGRectMake(centerX - 144.0f, 100.0f, 288.0f, 46.0f)];
    _subtitleLabel.backgroundColor = [UIColor clearColor];
    _subtitleLabel.textColor = inkColor;
    _subtitleLabel.font = [UIFont systemFontOfSize:15.0f];
    _subtitleLabel.textAlignment = NSTextAlignmentCenter;
    _subtitleLabel.numberOfLines = 2;
    _subtitleLabel.lineBreakMode = NSLineBreakByWordWrapping;
    _subtitleLabel.adjustsFontSizeToFitWidth = YES;
    _subtitleLabel.minimumScaleFactor = 0.8f;
    [_contentView addSubview:_subtitleLabel];

    _ringContainer = [[UIView alloc] initWithFrame:CGRectMake(centerX - 100.0f, 152.0f, 200.0f, 200.0f)];
    _ringContainer.backgroundColor = [UIColor clearColor];
    [_contentView addSubview:_ringContainer];

    _ringTrack = [CAShapeLayer layer];
    _ringTrack.fillColor = [UIColor clearColor].CGColor;
    _ringTrack.strokeColor = [UIColor colorWithRed:0.72f green:0.80f blue:0.90f alpha:1.0f].CGColor;
    _ringTrack.lineWidth = 12.0f;
    [_ringContainer.layer addSublayer:_ringTrack];

    _ringProgress = [CAShapeLayer layer];
    _ringProgress.fillColor = [UIColor clearColor].CGColor;
    _ringProgress.strokeColor = accentColor.CGColor;
    _ringProgress.lineWidth = 12.0f;
    _ringProgress.lineCap = kCALineCapRound;
    _ringProgress.strokeStart = 0.0f;
    _ringProgress.strokeEnd = 1.0f;
    [_ringContainer.layer addSublayer:_ringProgress];

    _countdownLabel = [[UILabel alloc] initWithFrame:CGRectMake(0.0f, 68.0f, 200.0f, 64.0f)];
    _countdownLabel.backgroundColor = [UIColor clearColor];
    _countdownLabel.textColor = inkColor;
    _countdownLabel.font = [UIFont fontWithName:@"HelveticaNeue-Bold" size:42.0f];
    if (!_countdownLabel.font) _countdownLabel.font = [UIFont boldSystemFontOfSize:42.0f];
    _countdownLabel.textAlignment = NSTextAlignmentCenter;
    _countdownLabel.adjustsFontSizeToFitWidth = YES;
    _countdownLabel.text = @"00:00";
    [_ringContainer addSubview:_countdownLabel];

    /* Only the Settings preview shows this button; the real break screen has no
     * tappable control at all. 240x50 at y=386 leaves 44 pt below it inside the
     * 480 pt screen and keeps the touch target above 44 pt. */
    _dismissButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _dismissButton.frame = CGRectMake(centerX - 120.0f, 386.0f, 240.0f, 50.0f);
    _dismissButton.backgroundColor = accentColor;
    _dismissButton.layer.cornerRadius = 25.0f;
    _dismissButton.titleLabel.font = [UIFont boldSystemFontOfSize:17.0f];
    [_dismissButton setTitle:@"Închide" forState:UIControlStateNormal];
    [_dismissButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [_dismissButton addTarget:self
                       action:@selector(handleDismissTap:)
             forControlEvents:UIControlEventTouchUpInside];
    _dismissButton.hidden = YES;
    [_contentView addSubview:_dismissButton];

    _contentView.hidden = YES;
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];

    CGRect ringBounds = _ringContainer.bounds;
    CGPoint center = CGPointMake(CGRectGetMidX(ringBounds), CGRectGetMidY(ringBounds));
    UIBezierPath *ringPath = [UIBezierPath bezierPathWithArcCenter:center
                                                            radius:86.0f
                                                        startAngle:(CGFloat)-M_PI_2
                                                          endAngle:(CGFloat)(1.5 * M_PI)
                                                         clockwise:YES];

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _gradientLayer.frame = _contentView.bounds;
    /* Both shape layers must own the ring container's bounds and sit on its
     * centre, otherwise the scaled arc is drawn around the container's
     * top-left corner and lands off-screen. */
    _ringTrack.bounds = ringBounds;
    _ringTrack.position = center;
    _ringProgress.bounds = ringBounds;
    _ringProgress.position = center;
    _ringTrack.path = ringPath.CGPath;
    _ringProgress.path = ringPath.CGPath;
    [CATransaction commit];
}

- (void)refreshSubtitle
{
    long long minutes;

    if (_testMode) {
        _subtitleLabel.text =
            @"Ecranul de pauză arată așa. Se închide automat în 5 secunde.";
        return;
    }

    minutes = (_remaining + 59) / 60;
    if (minutes < 1) minutes = 1;
    _subtitleLabel.text = [NSString stringWithFormat:
        @"Mai ai %ld minute până poți folosi telefonul.", (long)minutes];
}

- (void)setTestMode:(BOOL)testMode
{
    if (![self isViewLoaded]) [self view];

    _testMode = testMode;
    if (testMode) {
        _contentView.hidden = NO;
        _titleLabel.text = @"Mod de test";
        _dismissButton.hidden = NO;
    } else {
        _titleLabel.text = @"Pauză de la telefon!";
        _dismissButton.hidden = YES;
    }
    [self refreshSubtitle];
}

- (void)updateLocked:(BOOL)locked
           remaining:(long long)remaining
            duration:(long long)duration
{
    if (![self isViewLoaded]) [self view];

    _contentView.hidden = !locked;
    if (!locked) {
        _remaining = 0;
        return;
    }

    if (duration <= 0) duration = 1;
    if (remaining < 0) remaining = 0;
    _remaining = remaining;

    {
        char mmss[16];
        if (ug_format_mmss(remaining, mmss, sizeof mmss) == 0) {
            _countdownLabel.text = @"00:00";
        } else {
            _countdownLabel.text = [NSString stringWithUTF8String:mmss];
        }
    }

    [self refreshSubtitle];

    {
        CGFloat fraction = (CGFloat)remaining / (CGFloat)duration;
        if (fraction < 0.0f) fraction = 0.0f;
        if (fraction > 1.0f) fraction = 1.0f;
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        _ringProgress.strokeEnd = fraction;
        [CATransaction commit];
    }
}

/* Seven taps on the title within three seconds open the parent gate. A
 * preview must not: it is nothing but a visual check, and on a fresh install
 * it would open the SpringBoard setup wizard for any child who taps the title. */
- (void)handleTitleTap:(UITapGestureRecognizer *)recognizer
{
    NSTimeInterval now = [NSProcessInfo processInfo].systemUptime;
    (void)recognizer;

    if (_testMode) return;

    if (_titleTapCount == 0 || now - _firstTitleTapTime > kUGParentTapWindow) {
        _titleTapCount = 1;
        _firstTitleTapTime = now;
        return;
    }

    _titleTapCount += 1;
    if (_titleTapCount >= kUGParentTapCount) {
        _titleTapCount = 0;
        [self.delegate overlayControllerDidRequestParentAccess:self];
    }
}

- (void)handleDismissTap:(id)sender
{
    (void)sender;
    [self.delegate overlayControllerDidRequestTestDismiss:self];
}

@end

@implementation UGOverlayWindow

- (id)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (!self) return nil;

    _overlayController = [[UGOverlayController alloc] init];
    _overlayController.view.frame = frame;
    self.rootViewController = _overlayController;
    self.windowLevel = UIWindowLevelAlert + 1000.0f;
    self.backgroundColor = [UIColor clearColor];
    self.hidden = YES;
    return self;
}

@end
