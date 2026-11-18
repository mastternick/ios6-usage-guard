#import <UIKit/UIKit.h>

/*
 * Application delegate for the Usage Guard companion app.
 *
 * It does nothing but own the window and put the settings controller on screen:
 * the controller is the same object the PreferenceLoader pane builds, so the app
 * and the pane cannot drift apart in behaviour.
 */

@interface UGAppDelegate : UIResponder <UIApplicationDelegate>

@property (nonatomic, strong) UIWindow *window;

@end
