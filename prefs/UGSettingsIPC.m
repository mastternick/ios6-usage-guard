#import "UGSettingsIPC.h"

#import <notify.h>
#import <spawn.h>
#import <sys/wait.h>
#import <unistd.h>

/* posix_spawn envp; declared explicitly in case the SDK header does not. */
extern char **environ;

#import "UGNotify.h"
#import "UGPrefs.h"
#import "UGVersion.h"

/* A status file older than this is a leftover from a dead SpringBoard. */
static const long long kUGStatusFreshnessSeconds = 5;

/* A ping unanswered for this long is reported as not answered. */
static const CFTimeInterval kUGPingTimeoutSeconds = 1.5;

/* Installed artifacts, where MobileSubstrate loads them from. */
#define UG_DYLIB_INSTALL_PATH "/Library/MobileSubstrate/DynamicLibraries/UsageGuard.dylib"
#define UG_FILTER_INSTALL_PATH "/Library/MobileSubstrate/DynamicLibraries/UsageGuard.plist"

static NSNumber *UGNumberIn(NSDictionary *dictionary, NSString *key)
{
    id value = [dictionary objectForKey:key];
    return [value isKindOfClass:[NSNumber class]] ? value : nil;
}

@implementation UGSettingsIPC {
    /* Pong registration and ping timestamps (CFAbsoluteTime; 0 = never). */
    BOOL _pongRegistered;
    int _pongToken;
    CFAbsoluteTime _pingSentAt;
    CFAbsoluteTime _pongAt;
}

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

#pragma mark - Runtime diagnostics

- (void)dealloc
{
    if (_pongRegistered) notify_cancel(_pongToken);
}

- (void)pingRuntime
{
    if (!_pongRegistered) {
        __weak UGSettingsIPC *weakSelf = self;
        uint32_t status = notify_register_dispatch([kUGNotifyPong UTF8String], &_pongToken,
                                                   dispatch_get_main_queue(), ^(int token) {
            (void)token;
            UGSettingsIPC *ipc = weakSelf;
            if (ipc) ipc->_pongAt = CFAbsoluteTimeGetCurrent();
        });
        _pongRegistered = (status == NOTIFY_STATUS_OK);
    }

    /* A pong answering an earlier ping must not count for this one. */
    _pongAt = 0;
    _pingSentAt = CFAbsoluteTimeGetCurrent();
    notify_post([kUGNotifyPing UTF8String]);
}

- (BOOL)pingAnswered
{
    return _pingSentAt > 0 && _pongAt >= _pingSentAt;
}

- (BOOL)pingPending
{
    return _pingSentAt > 0 && _pongAt < _pingSentAt &&
           CFAbsoluteTimeGetCurrent() - _pingSentAt < kUGPingTimeoutSeconds;
}

- (NSString *)pingStateDescription
{
    if (_pingSentAt <= 0) return @"neefectuat";
    if ([self pingAnswered]) return @"a răspuns";
    if ([self pingPending]) return @"în așteptare";
    return @"fără răspuns";
}

- (NSString *)runtimeVerdict
{
    BOOL live = [self runtimeIsLive];

    if ([self pingAnswered]) return @"Runtime activ: a răspuns la ping.";
    if ([self pingPending]) return @"Se verifică runtime-ul…";
    if (_pingSentAt > 0) {
        return live ? @"Runtime activ, dar nu a răspuns la ping."
                    : @"Runtime nu răspunde: verifică dylib-ul și filtrul, apoi repornește SpringBoard.";
    }
    if (live) return @"Runtime activ: status proaspăt cu PID.";
    return @"Neverificat: runtime nedetectat. Rulează diagnosticul.";
}

- (long long)statusAgeSeconds
{
    NSNumber *tick = UGNumberIn([self statusSnapshot], @"LastTick");
    if (!tick) return -1;

    long long age = UGNowSeconds() - [tick longLongValue];
    return age < 0 ? 0 : age;
}

- (BOOL)dylibInstalled
{
    return [[NSFileManager defaultManager] fileExistsAtPath:@UG_DYLIB_INSTALL_PATH];
}

- (BOOL)filterInstalled
{
    return [[NSFileManager defaultManager] fileExistsAtPath:@UG_FILTER_INSTALL_PATH];
}

- (NSString *)diagnosticsDescription
{
    NSDictionary *snapshot = [self statusSnapshot];
    NSString *status = @"lipsă";
    if (snapshot) {
        long long age = [self statusAgeSeconds];
        status = age < 0 ? @"fără LastTick" : [NSString stringWithFormat:@"acum %lld s", age];
    }
    NSNumber *pid = UGNumberIn(snapshot, @"RuntimePID");

    return [NSString stringWithFormat:@"dylib: %@; filtru: %@; status: %@; PID: %@; ping: %@",
            [self dylibInstalled] ? @"da" : @"lipsă",
            [self filterInstalled] ? @"da" : @"lipsă",
            status,
            pid ? [pid stringValue] : @"—",
            [self pingStateDescription]];
}

- (BOOL)respring
{
    char *const argv[] = { "killall", "SpringBoard", NULL };
    pid_t pid = 0;
    int status = 0;

    if (posix_spawn(&pid, "/usr/bin/killall", NULL, NULL, argv, environ) != 0) return NO;
    if (waitpid(pid, &status, 0) != pid) return NO;

    /* The helper running is not the same as SpringBoard dying: report only a
     * clean exit so the caller can tell the parent when the respring did not
     * happen instead of leaving the tap looking like a no-op. */
    return WIFEXITED(status) && WEXITSTATUS(status) == 0;
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
    return @UG_PREFS_PATH;
}

- (NSString *)statusPath
{
    return @UG_STATUS_PATH;
}

@end
