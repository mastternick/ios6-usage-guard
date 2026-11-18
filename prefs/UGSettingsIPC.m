#import "UGSettingsIPC.h"

#import <notify.h>

#import "UGNotify.h"
#import "UGPrefs.h"

/* A status file older than this is a leftover from a dead SpringBoard. */
static const long long kUGStatusFreshnessSeconds = 5;

static NSString *const kUGPreferencesPath =
    @"/var/mobile/Library/Preferences/org.usageguard.timelock.plist";
static NSString *const kUGStatusPath =
    @"/var/mobile/Library/Preferences/org.usageguard.timer.status.plist";

static NSNumber *UGNumberIn(NSDictionary *dictionary, NSString *key)
{
    id value = [dictionary objectForKey:key];
    return [value isKindOfClass:[NSNumber class]] ? value : nil;
}

@implementation UGSettingsIPC

#pragma mark - State

- (void)loadState:(UGState *)state
{
    UGPrefs *prefs = [UGPrefs sharedPrefs];
    [prefs reloadFromDisk];
    [prefs loadState:state now:UGNowSeconds()];
}

- (BOOL)applyStateChange:(void (^)(UGState *state))change
{
    if (!change) return NO;

    UGPrefs *prefs = [UGPrefs sharedPrefs];
    UGState state;

    /* Read-modify-write, never a blind overwrite of another process's save. */
    [prefs reloadFromDisk];
    [prefs loadState:&state now:UGNowSeconds()];
    change(&state);

    if (![prefs saveState:&state]) return NO;

    notify_post([kUGNotifySettingsChanged UTF8String]);
    return YES;
}

- (void)postTestOverlay
{
    notify_post([kUGNotifyTestOverlay UTF8String]);
}

#pragma mark - Runtime status

- (NSDictionary *)statusSnapshot
{
    NSDictionary *snapshot = [NSDictionary dictionaryWithContentsOfFile:[self statusPath]];
    if (![snapshot isKindOfClass:[NSDictionary class]]) return nil;
    return snapshot;
}

- (BOOL)runtimeIsLive
{
    NSDictionary *snapshot = [self statusSnapshot];
    if (!snapshot) return NO;

    NSNumber *pid = UGNumberIn(snapshot, @"RuntimePID");
    NSNumber *tick = UGNumberIn(snapshot, @"LastTick");
    if (!pid || !tick || [pid longLongValue] <= 0) return NO;

    long long age = UGNowSeconds() - [tick longLongValue];
    if (age < 0) age = -age;
    return age <= kUGStatusFreshnessSeconds;
}

#pragma mark - PIN

- (BOOL)hasPIN
{
    return [[UGPrefs sharedPrefs] hasPIN];
}

- (BOOL)setPIN:(NSString *)pin
{
    if (![[UGPrefs sharedPrefs] setPIN:pin]) return NO;
    notify_post([kUGNotifySettingsChanged UTF8String]);
    return YES;
}

- (BOOL)verifyPIN:(NSString *)pin
{
    /* Failure counters and the lockout deadline are persisted next to the hash,
     * so a verification is a write even when it fails. */
    BOOL verified = [[UGPrefs sharedPrefs] verifyPIN:pin];
    notify_post([kUGNotifySettingsChanged UTF8String]);
    return verified;
}

- (NSInteger)lockoutRemaining
{
    return [[UGPrefs sharedPrefs] PINLockoutRemainingSeconds];
}

#pragma mark - Setup flags

- (BOOL)setupComplete
{
    return [[UGPrefs sharedPrefs] setupComplete];
}

- (BOOL)setSetupComplete:(BOOL)value
{
    UGPrefs *prefs = [UGPrefs sharedPrefs];
    [prefs setSetupComplete:value];
    notify_post([kUGNotifySettingsChanged UTF8String]);
    /* Reported from the getter so the answer is the persisted value, whatever
     * the setter's BOOL turns out to mean. */
    return [prefs setupComplete];
}

- (BOOL)requirePIN
{
    return [[UGPrefs sharedPrefs] requirePIN];
}

- (BOOL)setRequirePIN:(BOOL)value
{
    UGPrefs *prefs = [UGPrefs sharedPrefs];
    [prefs setRequirePIN:value];
    notify_post([kUGNotifySettingsChanged UTF8String]);
    return [prefs requirePIN];
}

#pragma mark - Paths

- (NSString *)preferencesPath
{
    return kUGPreferencesPath;
}

- (NSString *)statusPath
{
    return kUGStatusPath;
}

@end
