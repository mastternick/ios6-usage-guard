#import <UIKit/UIKit.h>

@class UGOverlayController;

@protocol UGOverlayControllerDelegate <NSObject>
- (void)overlayControllerDidRequestEmergencyCall:(UGOverlayController *)controller;
- (void)overlayControllerDidRequestParentAccess:(UGOverlayController *)controller;
/* The test-mode dismiss button was tapped; the runtime ends the preview. */
- (void)overlayControllerDidRequestTestDismiss:(UGOverlayController *)controller;
@end

/*
 * Full-screen break overlay: gradient background, circular progress ring,
 * exact Romanian child-facing copy and the emergency-call valve. Frames are
 * laid out for the 320x480 screen and centered horizontally.
 */
@interface UGOverlayController : UIViewController

@property (nonatomic, weak) id<UGOverlayControllerDelegate> delegate;

/* Hides the whole overlay when locked == NO (the window may still be visible
 * to host the parent panel). */
- (void)updateLocked:(BOOL)locked
           remaining:(long long)remaining
            duration:(long long)duration;

/* Child-facing message shown in place of the minute count (for example when the
 * emergency call cannot be dialled). Cleared when the overlay hides. */
- (void)showNotice:(NSString *)notice;

/* Settings preview: shows the break screen with test copy and a dismiss button
 * instead of the emergency valve, so a preview can neither call 112 nor open
 * the parent gate. Toggling it off restores the real break copy. */
- (void)setTestMode:(BOOL)testMode;

@end

/* Window at UIWindowLevelAlert + 1000: above apps, alerts and the home screen. */
@interface UGOverlayWindow : UIWindow

@property (nonatomic, strong, readonly) UGOverlayController *overlayController;

@end
