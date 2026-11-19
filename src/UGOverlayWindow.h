#import <UIKit/UIKit.h>

@class UGOverlayController;

@protocol UGOverlayControllerDelegate <NSObject>
- (void)overlayControllerDidRequestParentAccess:(UGOverlayController *)controller;
/* The test-mode dismiss button was tapped; the runtime ends the preview. */
- (void)overlayControllerDidRequestTestDismiss:(UGOverlayController *)controller;
@end

/*
 * Full-screen break overlay: gradient background, circular progress ring and
 * exact Romanian child-facing copy. There is deliberately no dialing control
 * here: a child taps such a button by mistake. Placing a call lives behind the
 * PIN-gated parent panel instead. Frames are laid out for the 320x480 screen
 * and centered horizontally.
 */
@interface UGOverlayController : UIViewController

@property (nonatomic, weak) id<UGOverlayControllerDelegate> delegate;

/* Hides the whole overlay when locked == NO (the window may still be visible
 * to host the parent panel). */
- (void)updateLocked:(BOOL)locked
           remaining:(long long)remaining
            duration:(long long)duration;

/* Settings preview: shows the break screen with test copy and a dismiss button,
 * so a preview can neither open the parent gate nor act on the guard. Toggling
 * it off restores the real break copy. */
- (void)setTestMode:(BOOL)testMode;

@end

/* Window at UIWindowLevelAlert + 1000: above apps, alerts and the home screen. */
@interface UGOverlayWindow : UIWindow

@property (nonatomic, strong, readonly) UGOverlayController *overlayController;

@end
