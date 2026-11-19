#import <Foundation/Foundation.h>

#import "src/UGRuntime.h"

/*
 * Entry point for every injection, including one that lands after SpringBoard's
 * launch callbacks have already run. The main-queue hop runs it once UIKit's run
 * loop is up. -start is idempotent, so the hook below is a harmless second path.
 */
%ctor
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [[UGRuntime sharedRuntime] start];
    });
}

/*
 * The second entry point: hand off to the runtime once SpringBoard is up.
 * Everything else (clock, notifications, guarded swizzles, overlay) lives in
 * UGRuntime so the tweak's hook surface stays minimal.
 */
%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application
{
    %orig;
    [[UGRuntime sharedRuntime] start];
}

%end
