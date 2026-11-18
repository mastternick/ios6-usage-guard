#import <Foundation/Foundation.h>

#import "UGGuardCore.h"

/*
 * The only object in the settings bundle that touches the preferences file, the
 * runtime status file or the notify(3) bus. The controller asks for values and
 * hands mutations back as a block, so persistence rules (read, modify, write,
 * announce) live in exactly one place.
 *
 * Both files belong to the tweak; their locations come from UGVersion.h:
 *   UG_PREFS_PATH   cycle state, PIN vault, SetupComplete,
 *                   RequirePIN (written by us, read by SpringBoard)
 *   UG_STATUS_PATH  runtime snapshot (written by SpringBoard)
 */

@interface UGSettingsIPC : NSObject

/* Reads the persisted cycle state. Applies the same startup rules as the tweak,
 * so the pane never shows a stale or over-credited allowance. */
- (void)loadState:(UGState *)state;

/* Load -> mutate -> save -> kUGNotifySettingsChanged. Returns NO when the write
 * failed; in that case nothing is announced. */
- (BOOL)applyStateChange:(void (^)(UGState *state))change;

/* Asks SpringBoard to raise the break overlay for a moment. No state change. */
- (void)postTestOverlay;

/* Runtime status file contents, or nil when it is missing or unreadable. */
- (NSDictionary *)statusSnapshot;

/* YES when SpringBoard ticked within the freshness window and reported a pid. */
- (BOOL)runtimeIsLive;

/* PIN vault pass-throughs. setPIN: and verifyPIN: announce the write they cause
 * (the failure counter and lockout deadline live in the same file). */
- (BOOL)hasPIN;
- (BOOL)setPIN:(NSString *)pin;
- (BOOL)verifyPIN:(NSString *)pin;
- (NSInteger)lockoutRemaining;

- (BOOL)setupComplete;
- (BOOL)setSetupComplete:(BOOL)value;

- (BOOL)requirePIN;
- (BOOL)setRequirePIN:(BOOL)value;

/* Read-only paths for the information section. */
- (NSString *)preferencesPath;
- (NSString *)statusPath;

@end
