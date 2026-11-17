#import <UIKit/UIKit.h>

@class UGOverlayController;

@protocol UGOverlayControllerDelegate <NSObject>
- (void)overlayControllerDidRequestEmergencyCall:(UGOverlayController *)controller;
- (void)overlayControllerDidRequestParentAccess:(UGOverlayController *)controller;
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

@end

/* Window at UIWindowLevelAlert + 1000: above apps, alerts and the home screen. */
@interface UGOverlayWindow : UIWindow

@property (nonatomic, strong, readonly) UGOverlayController *overlayController;

@end
