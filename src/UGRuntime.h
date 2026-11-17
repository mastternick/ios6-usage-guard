#import <Foundation/Foundation.h>

/* SpringBoard-side singleton: owns the state machine, the 1 Hz clock, the
 * overlay window, persistence and the emergency/PIN flows. */
@interface UGRuntime : NSObject

+ (instancetype)sharedRuntime;

- (void)start;
- (void)stop;

@end
