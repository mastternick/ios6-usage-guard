#import <Foundation/Foundation.h>

#import "UGGuardCore.h"

/*
 * Preferences and PIN vault.
 *
 * Everything lives in a single atomically written plist. The cycle state is
 * stored as the core's serialized string; the PIN is stored as a PBKDF2 hash
 * with a random salt and an explicit iteration count. No plaintext PIN is ever
 * written, logged or kept after verification.
 */

@interface UGPrefs : NSObject

+ (instancetype)sharedPrefs;

/* Restores the persisted cycle, falling back to 20/30 defaults when the file
 * is missing or corrupt. Applies startup rules (no usage credit for downtime). */
- (void)loadState:(UGState *)state now:(long long)now;

/* Atomically persists the whole cycle state. Returns NO when the write fails. */
- (BOOL)saveState:(const UGState *)state;

- (BOOL)hasPIN;
+ (BOOL)isValidPIN:(NSString *)pin;

/* Returns NO for an invalid PIN or when PBKDF2 cannot run. Rate limiting is
 * inside verifyPIN:, not here. */
- (BOOL)setPIN:(NSString *)pin;

/* Applies the persisted failure counter/lockout. */
- (BOOL)verifyPIN:(NSString *)pin;
- (NSInteger)PINLockoutRemainingSeconds;

@end

/* Wall clock shared by the tweak's timer, the panel and the PIN lockout. */
long long UGNowSeconds(void);

/*
 * Operator escape hatch: YES when the disable marker file exists. The runtime
 * must then do nothing at all — no overlay, no hooks, no accounting, no wizard.
 * The tweak never creates or removes the marker.
 */
BOOL UGKillSwitchEngaged(void);

/* Opt-in diagnostics, enabled by a "DebugLogging" boolean in the tweak plist. */
BOOL UGDebugLoggingEnabled(void);
#define UGLog(...) do { if (UGDebugLoggingEnabled()) NSLog(__VA_ARGS__); } while (0)
