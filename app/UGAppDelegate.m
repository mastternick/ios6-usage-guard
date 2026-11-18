#import "UGAppDelegate.h"

#import "UGPreferencesController.h"
#import "UGTrace.h"

/*
 * Window setup only. The app is a host, not a second implementation: the
 * controller it pushes is the one from the settings bundle, constructed with the
 * same `initForContentSize:` initialiser Preferences calls on the pane, so the
 * frame maths and every row behave identically in both hosts.
 *
 * Logging goes through UGTrace because this app is the only way to see the pane
 * on a device where Preferences.app cannot be opened, and a crash here leaves
 * nothing else behind.
 */

@implementation UGAppDelegate

- (BOOL)application:(UIApplication *)application
didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    CGSize screenSize = [[UIScreen mainScreen] bounds].size;
    UGTrace(@"app: didFinishLaunching bounds %.0fx%.0f", screenSize.width,
            screenSize.height);

    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];

    UGPreferencesController *controller =
        [[UGPreferencesController alloc] initForContentSize:screenSize];
    UGTrace(@"app: controller=%d", (int)(controller != nil));

    UINavigationController *navigation =
        [[UINavigationController alloc] initWithRootViewController:controller];
    self.window.rootViewController = navigation;

    [self.window makeKeyAndVisible];

    UGTrace(@"app: window key=%d", (int)[self.window isKeyWindow]);

    return YES;
}

/*
 * Backgrounding must not change anything: the tweak enforces, the app only
 * configures it, and the controller resolves every value from disk each time it
 * appears. Logged so a trace exported later shows the app was suspended here.
 */
- (void)applicationDidEnterBackground:(UIApplication *)application
{
    UGTrace(@"app: didEnterBackground");
}

/*
 * ARC owns both objects; there is nothing to release here. The hook exists so the
 * teardown of the only long-lived app object is visible in the trace.
 */
- (void)dealloc
{
    UGTrace(@"app: delegate dealloc");
}

@end
