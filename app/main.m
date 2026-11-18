#import <UIKit/UIKit.h>

/*
 * Classic iOS 6 entry point: no storyboard, no scene manifest, no
 * UIApplicationMain scene delegate API (that arrived with iOS 13). The app
 * delegate class is named as a string because its header is not imported here.
 *
 * An @autoreleasepool wraps the whole run because UIApplicationMain never
 * returns; the pool is what releases the objects the delegate creates while the
 * run loop owns them.
 */

int main(int argc, char *argv[])
{
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, @"UGAppDelegate");
    }
}
