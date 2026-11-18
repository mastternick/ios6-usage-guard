#import <Foundation/Foundation.h>

#import "UGGuardCore.h"

/*
 * Preferences and PIN vault.
 *
 * Everything lives in a single atomically written plist. The cycle state is
 * stored as the core's serialized string; the PIN is stored as a PBKDF2 hash
 * with a random salt and an explicit iteration count. No plaintext PIN is ever
 * written, logged or kept after verification.
 *
 * Every write is a read-modify-write of that dictionary: only the keys being
 * changed are replaced, so SpringBoard and the Preferences pane can persist at
 * the same time without dropping each other's keys.
 */

@interface UGPrefs : NSObject

+ (instancetype)sharedPrefs;

/* Restores the persisted cycle, falling back to 20/30 defaults when the file
 * is missing or corrupt. Applies startup rules (no usage credit for downtime). */
- (void)loadState:(UGState *)state now:(long long)now;

/* Atomically persists the whole cycle state. Returns NO when the write fails. */
- (BOOL)saveState:(const UGState *)state;

/* The raw `State` value read freshly from the file, bypassing the cache. nil
 * when the file, the key or a string value is missing. The runtime compares it
 * with the string it last wrote to tell its own save from a write made by the
 * Preferences pane. */
- (NSString *)diskStateString;

/* Re-reads the plist from disk, adopting keys another process wrote (the
 * Preferences pane, a second wizard instance). PIN vault fields, the lockout
 * window and the debug flag are refreshed with it. */
- (void)reloadFromDisk;

/*
 * Setup gate. YES once a PIN has been configured. An install that predates the
 * key (plist present, key absent) is migrated to YES only when a PIN is stored
 * as well, so a 1.0.1 device that never set one is treated as unconfigured
 * rather than enforcing breaks without a PIN. A fresh install is pinned to NO
 * so a later launch cannot mistake it for a configured one.
 */
- (BOOL)setupComplete;
- (BOOL)setSetupComplete:(BOOL)value;

/* Whether the Settings pane asks for the PIN before changing anything (switches,
 * limits, actions). The break overlay's parent panel is gated by the PIN itself
 * whenever one is stored, independently of this flag. Defaults to YES. */
- (BOOL)requirePIN;
- (BOOL)setRequirePIN:(BOOL)value;

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
