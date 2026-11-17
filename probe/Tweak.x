#import <UIKit/UIKit.h>
#import <dispatch/dispatch.h>

/*
 * UsageGuardProbe - deliberately minimal, recoverable smoke test.
 *
 * Purpose: prove (a) the CI toolchain produces a loadable armv7 iOS 6 tweak and
 * (b) MobileSubstrate injection into SpringBoard is safe on the target device.
 *
 * It hooks exactly one method, shows a 3 second non-blocking label, logs one
 * line, and does nothing else:
 *   - never writes files, preferences or caches (nothing persists);
 *   - never touches system state, daemons or other processes;
 *   - never installs a gesture recognizer, button or key window, so input is
 *     never intercepted or delayed;
 *   - removes its own label from the view hierarchy when the timer fires;
 *   - uninstalls cleanly with `dpkg -r org.usageguard.probe` (dylib + plist
 *     only, no layout files, no launch daemons, no model/objc runtime changes).
 *
 * Hard kill-switch: if the marker file below exists the hook returns right
 * after %orig, so a bad device can be made inert without uninstalling:
 *     touch /var/mobile/Library/Preferences/org.usageguard.probe.disable
 */

static NSString *const UGProbeDisableFile = @"/var/mobile/Library/Preferences/org.usageguard.probe.disable";
static const NSTimeInterval UGProbeBannerDuration = 3.0;

/*
 * Adds a label to the existing SpringBoard window. The label is not
 * interactive, does not become key window and is removed after
 * UGProbeBannerDuration, so it can never block or steal input.
 */
static void UGProbeShowBanner(void)
{
	UIApplication *application = [UIApplication sharedApplication];
	UIWindow *host = [application keyWindow];

	if (host == nil) {
		NSArray *windows = [application windows];
		if ([windows count] > 0) {
			host = [windows objectAtIndex:0];
		}
	}
	if (host == nil) {
		NSLog(@"[UsageGuardProbe] no host window available, banner skipped");
		return;
	}

	CGRect screenBounds = [[UIScreen mainScreen] bounds];
	UILabel *banner = [[UILabel alloc] initWithFrame:CGRectMake(0.0, 20.0, screenBounds.size.width, 40.0)];
	banner.text = @"Usage Guard Probe: injection OK";
	banner.textAlignment = NSTextAlignmentCenter;
	banner.textColor = [UIColor whiteColor];
	banner.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.75];
	banner.font = [UIFont boldSystemFontOfSize:14.0];
	banner.userInteractionEnabled = NO; /* never intercept touches */
	banner.opaque = NO;
	banner.alpha = 0.0;

	[host addSubview:banner];

	[UIView animateWithDuration:0.25 animations:^{
		banner.alpha = 1.0;
	}];

#if !__has_feature(objc_arc)
	/* Blocks do not retain captured objects under MRC; hold our own reference so
	 * the label survives even if the window goes away before the timer fires. */
	[banner retain];
#endif

	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(UGProbeBannerDuration * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		[UIView animateWithDuration:0.25 animations:^{
			banner.alpha = 0.0;
		} completion:^(BOOL finished) {
			[banner removeFromSuperview];
#if !__has_feature(objc_arc)
			[banner release]; /* explicit retain above */
			[banner release]; /* alloc/init reference */
#endif
		}];
	});
}

%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application
{
	%orig;

	if ([[NSFileManager defaultManager] fileExistsAtPath:UGProbeDisableFile]) {
		NSLog(@"[UsageGuardProbe] kill-switch present at %@, doing nothing", UGProbeDisableFile);
		return;
	}

	NSLog(@"[UsageGuardProbe] SpringBoard did finish launching, showing %.0fs banner",
	      UGProbeBannerDuration);
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		UGProbeShowBanner();
	});
}

%end
