#import <Foundation/Foundation.h>

#import "src/UGRuntime.h"

/*
 * The only SpringBoard hook: hand off to the runtime once SpringBoard is up.
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
