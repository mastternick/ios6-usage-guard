#import "UGPrefs.h"

#import <CommonCrypto/CommonDigest.h>
#import <CommonCrypto/CommonCryptor.h>
#import <CommonCrypto/CommonKeyDerivation.h>
#import <Security/Security.h>
#import <stdint.h>
#import <stdlib.h>
#import <string.h>

static NSString *const kUGPrefsPath =
    @"/var/mobile/Library/Preferences/org.usageguard.timelock.plist";

/*
 * Operator kill switch. When this file exists the runtime does nothing at all
 * (no overlay, no hooks, no accounting, no PIN wizard). It is only ever created
 * or removed by the operator, never by the tweak itself.
 */
static NSString *const kUGKillSwitchPath =
    @"/var/mobile/Library/Preferences/org.usageguard.timer.disable";

static NSString *const kUGStateKey = @"State";
static NSString *const kUGPINSaltKey = @"PINSalt";
static NSString *const kUGPINHashKey = @"PINHash";
static NSString *const kUGPINIterationsKey = @"PINIterations";
static NSString *const kUGPINFailuresKey = @"PINFailures";
static NSString *const kUGPINLockoutKey = @"PINLockoutUntil";
static NSString *const kUGDebugKey = @"DebugLogging";
static NSString *const kUGSetupCompleteKey = @"SetupComplete";
static NSString *const kUGRequirePINKey = @"RequirePIN";

/* Well above the 20 000 iteration floor; stored so it can be raised later. */
static const uint32_t kUGPINIterations = 25000;
enum {
    kUGPINSaltLength = 16,
    kUGPINHashLength = CC_SHA256_DIGEST_LENGTH
};
static const NSInteger kUGPINFailuresPerLockout = 5;
static const NSInteger kUGPINBaseLockoutSeconds = 30;
static const NSInteger kUGPINMaxLockoutSeconds = 480;

static BOOL sUGDebugLogging = NO;

static NSString *UGBase64Encode(NSData *data)
{
    static const char alphabet[] =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    NSUInteger length = data.length;
    NSMutableString *encoded =
        [NSMutableString stringWithCapacity:((length + 2) / 3) * 4];

    for (NSUInteger index = 0; index < length; index += 3) {
        NSUInteger left = length - index;
        uint32_t chunk = (uint32_t)bytes[index] << 16;
        if (left > 1) chunk |= (uint32_t)bytes[index + 1] << 8;
        if (left > 2) chunk |= (uint32_t)bytes[index + 2];

        [encoded appendFormat:@"%c", alphabet[(chunk >> 18) & 0x3F]];
        [encoded appendFormat:@"%c", alphabet[(chunk >> 12) & 0x3F]];
        [encoded appendFormat:@"%c", left > 1 ? alphabet[(chunk >> 6) & 0x3F] : '='];
        [encoded appendFormat:@"%c", left > 2 ? alphabet[chunk & 0x3F] : '='];
    }
    return encoded;
}

static NSData *UGBase64Decode(NSString *encoded)
{
    if (![encoded isKindOfClass:[NSString class]]) return nil;

    const char *characters = [encoded UTF8String];
    if (!characters) return nil;

    NSUInteger length = strlen(characters);
    NSMutableData *decoded = [NSMutableData dataWithCapacity:(length / 4) * 3];
    uint32_t accumulator = 0;
    int bits = 0;

    for (NSUInteger index = 0; index < length; index++) {
        char character = characters[index];
        int value;

        if (character == '=') break;
        if (character >= 'A' && character <= 'Z') value = character - 'A';
        else if (character >= 'a' && character <= 'z') value = character - 'a' + 26;
        else if (character >= '0' && character <= '9') value = character - '0' + 52;
        else if (character == '+') value = 62;
        else if (character == '/') value = 63;
        else return nil;

        accumulator = (accumulator << 6) | (uint32_t)value;
        bits += 6;
        if (bits >= 8) {
            uint8_t byte;
            bits -= 8;
            byte = (uint8_t)((accumulator >> bits) & 0xFF);
            [decoded appendBytes:&byte length:1];
        }
    }
    return decoded;
}

/*
 * PBKDF2-HMAC-SHA256. Returns nil only when CommonCrypto rejects the request,
 * which cannot happen for valid inputs; callers treat nil as failure.
 */
static NSData *UGDerivePIN(NSString *pin, NSData *salt, uint32_t iterations)
{
    const char *pinUTF8 = [pin UTF8String];
    unsigned char derived[kUGPINHashLength];
    int status;

    if (!pinUTF8 || salt.length == 0) return nil;

    status = CCKeyDerivationPBKDF(kCCPBKDF2,
                                  pinUTF8, strlen(pinUTF8),
                                  (const uint8_t *)salt.bytes, salt.length,
                                  kCCPRFHmacAlgSHA256, iterations,
                                  derived, sizeof derived);
    if (status != kCCSuccess) return nil;
    return [NSData dataWithBytes:derived length:sizeof derived];
}

static BOOL UGConstantTimeEqual(NSData *first, NSData *second)
{
    const uint8_t *firstBytes;
    const uint8_t *secondBytes;
    uint8_t difference = 0;

    if (first.length != second.length) return NO;
    firstBytes = (const uint8_t *)first.bytes;
    secondBytes = (const uint8_t *)second.bytes;
    for (NSUInteger index = 0; index < first.length; index++) {
        difference |= (uint8_t)(firstBytes[index] ^ secondBytes[index]);
    }
    return difference == 0;
}

/*
 * Every persisted value is untrusted: it may be a string, an array, a date or a
 * boolean left behind by another tool. Only real numbers are read; anything
 * else leaves the in-memory default in place instead of raising.
 */
static BOOL UGReadNumber(NSDictionary *values, NSString *key, long long *out)
{
    id value = values[key];

    if (![value isKindOfClass:[NSNumber class]]) return NO;
    *out = [(NSNumber *)value longLongValue];
    return YES;
}

long long UGNowSeconds(void)
{
    return (long long)[[NSDate date] timeIntervalSince1970];
}

BOOL UGKillSwitchEngaged(void)
{
    return [[NSFileManager defaultManager] fileExistsAtPath:kUGKillSwitchPath];
}

BOOL UGDebugLoggingEnabled(void)
{
    return sUGDebugLogging;
}

@interface UGPrefs ()
- (void)loadValuesFromDisk;
- (BOOL)writeValuesApplying:(NSDictionary *)changes;
- (void)clampLockoutWindow;
- (NSDictionary *)PINFieldsWithSalt:(NSData *)salt
                               hash:(NSData *)hash
                         iterations:(uint32_t)iterations
                           failures:(NSInteger)failures
                       lockoutUntil:(long long)lockoutUntil;
- (BOOL)commitPINFields:(NSDictionary *)fields;
- (BOOL)persistPINAttemptFields;
@end

@implementation UGPrefs {
    NSMutableDictionary *_values;
    NSData *_salt;
    NSData *_hash;
    uint32_t _iterations;
    NSInteger _failures;
    long long _lockoutUntil;
    /* Captured once, at process load: the SetupComplete migration needs to
     * tell an upgraded install from a fresh one even after the first write. */
    BOOL _fileExisted;
}

+ (instancetype)sharedPrefs
{
    /* Created on the SpringBoard main thread; every caller is main-thread. */
    static UGPrefs *shared = nil;
    if (!shared) shared = [[UGPrefs alloc] init];
    return shared;
}

- (id)init
{
    self = [super init];
    if (!self) return nil;

    _fileExisted = [[NSFileManager defaultManager] fileExistsAtPath:kUGPrefsPath];
    [self loadValuesFromDisk];
    return self;
}

- (void)reloadFromDisk
{
    [self loadValuesFromDisk];
}

/* Single reader for both -init and -reloadFromDisk: the plist on disk is the
 * only authority, so a write by another process is picked up whole. */
- (void)loadValuesFromDisk
{
    NSDictionary *stored = [NSDictionary dictionaryWithContentsOfFile:kUGPrefsPath];
    NSData *salt = nil;
    NSData *hash = nil;
    uint32_t iterations = 0;
    NSInteger failures = 0;
    long long lockoutUntil = 0;

    _values = stored ? [stored mutableCopy] : [NSMutableDictionary dictionary];

    if ([_values[kUGPINSaltKey] isKindOfClass:[NSString class]]) {
        salt = UGBase64Decode(_values[kUGPINSaltKey]);
    }
    if ([_values[kUGPINHashKey] isKindOfClass:[NSString class]]) {
        hash = UGBase64Decode(_values[kUGPINHashKey]);
    }
    {
        long long number;

        if (UGReadNumber(_values, kUGPINIterationsKey, &number) &&
            number > 0 && number <= (long long)UINT32_MAX) {
            iterations = (uint32_t)number;
        }

        if (UGReadNumber(_values, kUGPINFailuresKey, &number) && number > 0) {
            failures = (number > 1000) ? 1000 : (NSInteger)number;
        }

        if (UGReadNumber(_values, kUGPINLockoutKey, &number)) {
            lockoutUntil = number;
        }

        sUGDebugLogging = NO;
        if (UGReadNumber(_values, kUGDebugKey, &number)) {
            sUGDebugLogging = number != 0;
        }
    }

    _salt = salt;
    _hash = hash;
    _iterations = iterations;
    _failures = failures;
    _lockoutUntil = lockoutUntil;
    [self clampLockoutWindow];
}

/* The lockout is a wall-clock deadline and the clock can move. Never trust it
 * for longer than the maximum lockout the tweak itself hands out. */
- (void)clampLockoutWindow
{
    long long now = UGNowSeconds();
    long long remaining = _lockoutUntil - now;

    if (remaining > (long long)kUGPINMaxLockoutSeconds) {
        _lockoutUntil = now + kUGPINMaxLockoutSeconds;
        UGLog(@"Usage Guard: PIN lockout clamped to the maximum window");
    }
}

/*
 * Read-modify-write: re-reads the file, applies only `changes` on top of it and
 * writes the result atomically. A PIN stored from Preferences.app and a state
 * save from SpringBoard therefore never clobber each other's keys. The merged
 * dictionary becomes the in-memory cache, so a failed write never leaves the
 * cache claiming something the file does not hold.
 */
- (BOOL)writeValuesApplying:(NSDictionary *)changes
{
    NSString *directory = [kUGPrefsPath stringByDeletingLastPathComponent];
    NSDictionary *onDisk = [NSDictionary dictionaryWithContentsOfFile:kUGPrefsPath];
    NSMutableDictionary *merged;
    BOOL written;

    if (onDisk) {
        merged = [onDisk mutableCopy];
    } else {
        /* Unreadable or absent file: keep what this process already knows
         * (notably the PIN vault) instead of dropping it. */
        merged = [_values mutableCopy];
    }
    [merged addEntriesFromDictionary:changes];

    [[NSFileManager defaultManager] createDirectoryAtPath:directory
                             withIntermediateDirectories:YES
                                              attributes:nil
                                                   error:NULL];
    written = [merged writeToFile:kUGPrefsPath atomically:YES];
    if (!written) {
        UGLog(@"Usage Guard: could not write %@", kUGPrefsPath);
        return NO;
    }
    _values = merged;
    return YES;
}

- (void)loadState:(UGState *)state now:(long long)now
{
    UGState loaded;
    id encoded;

    if (!state) return;

    ug_state_defaults(&loaded, now);
    encoded = _values[kUGStateKey];
    if ([encoded isKindOfClass:[NSString class]] &&
        !ug_deserialize(&loaded, [encoded UTF8String], now)) {
        UGLog(@"Usage Guard: stored cycle state was corrupt, using defaults");
        ug_state_defaults(&loaded, now);
    }
    ug_state_startup(&loaded, now);
    *state = loaded;
}

- (BOOL)saveState:(const UGState *)state
{
    char buffer[UG_STATE_BUFFER_SIZE];
    size_t length;

    if (!state) return NO;
    length = ug_serialize(state, buffer, sizeof buffer);
    if (length == 0) return NO;

    /* Only the State key: every other key written by Preferences.app stays. */
    return [self writeValuesApplying:
        @{kUGStateKey: [NSString stringWithUTF8String:buffer]}];
}

/* The raw State string currently in the file, read fresh instead of from the
 * cache. Callers compare it with the string they last wrote to tell their own
 * write from someone else's. nil when the file or the key is missing, or when
 * the value is not a string. */
- (NSString *)diskStateString
{
    NSDictionary *stored = [NSDictionary dictionaryWithContentsOfFile:kUGPrefsPath];
    id encoded = stored[kUGStateKey];

    if (![encoded isKindOfClass:[NSString class]]) return nil;
    return encoded;
}

- (BOOL)setupComplete
{
    long long number;

    /* A migrated install must not look unfinished, and a fresh install must not
     * look finished on the next launch: both answers are pinned into the file
     * the first time it is asked. 1.0.1 always created the file, so its mere
     * existence is not proof of setup: an upgraded device that never stored a
     * PIN stays unconfigured instead of enforcing breaks with no PIN. */
    if (UGReadNumber(_values, kUGSetupCompleteKey, &number)) return number != 0;
    if (_fileExisted) {
        BOOL migrated = [self hasPIN];
        [self setSetupComplete:migrated];
        return migrated;
    }
    [self setSetupComplete:NO];
    return NO;
}

- (BOOL)setSetupComplete:(BOOL)value
{
    return [self writeValuesApplying:@{kUGSetupCompleteKey: @(value ? 1 : 0)}];
}

- (BOOL)requirePIN
{
    long long number;

    if (!UGReadNumber(_values, kUGRequirePINKey, &number)) return YES;
    return number != 0;
}

- (BOOL)setRequirePIN:(BOOL)value
{
    return [self writeValuesApplying:@{kUGRequirePINKey: @(value ? 1 : 0)}];
}

- (BOOL)hasPIN
{
    return _salt.length == (NSUInteger)kUGPINSaltLength &&
           _hash.length == (NSUInteger)kUGPINHashLength &&
           _iterations >= 20000;
}

+ (BOOL)isValidPIN:(NSString *)pin
{
    NSUInteger length;
    const char *characters;

    if (![pin isKindOfClass:[NSString class]]) return NO;
    length = pin.length;
    if (length < 4 || length > 8) return NO;

    characters = [pin UTF8String];
    if (!characters) return NO;
    for (NSUInteger index = 0; index < length; index++) {
        if (characters[index] < '0' || characters[index] > '9') return NO;
    }
    return YES;
}

/* The plist entries that describe the PIN vault, built from explicit values so
 * callers never have to mutate the ivars before the write is known to work. */
- (NSDictionary *)PINFieldsWithSalt:(NSData *)salt
                               hash:(NSData *)hash
                         iterations:(uint32_t)iterations
                           failures:(NSInteger)failures
                       lockoutUntil:(long long)lockoutUntil
{
    return @{
        kUGPINSaltKey: salt ? UGBase64Encode(salt) : @"",
        kUGPINHashKey: hash ? UGBase64Encode(hash) : @"",
        kUGPINIterationsKey: @(iterations),
        kUGPINFailuresKey: @(failures),
        kUGPINLockoutKey: @(lockoutUntil)
    };
}

/* Persists the given PIN entries. The merge writer touches only these keys, so a
 * cycle-state write racing with this one cannot undo it. */
- (BOOL)commitPINFields:(NSDictionary *)fields
{
    return [self writeValuesApplying:fields];
}

/* Persists the failure counter and the lockout deadline only. Verification
 * must never rewrite PINSalt/PINHash/PINIterations: the vault may have been
 * replaced by another process (Settings), and writing the cached copy back
 * would silently revert the new PIN. */
- (BOOL)persistPINAttemptFields
{
    return [self commitPINFields:@{
        kUGPINFailuresKey: @(_failures),
        kUGPINLockoutKey: @(_lockoutUntil)
    }];
}

- (BOOL)setPIN:(NSString *)pin
{
    unsigned char rawSalt[kUGPINSaltLength];
    NSData *salt;
    NSData *hash;
    NSDictionary *fields;

    if (![[self class] isValidPIN:pin]) return NO;

    if (SecRandomCopyBytes(kSecRandomDefault, sizeof rawSalt, rawSalt) != 0) {
        /* Security framework refused; libc entropy is the documented fallback. */
        for (NSUInteger index = 0; index < sizeof rawSalt; index++) {
            rawSalt[index] = (unsigned char)(arc4random() & 0xFF);
        }
    }

    salt = [NSData dataWithBytes:rawSalt length:sizeof rawSalt];
    hash = UGDerivePIN(pin, salt, kUGPINIterations);
    if (!hash) return NO;

    fields = [self PINFieldsWithSalt:salt
                               hash:hash
                         iterations:kUGPINIterations
                           failures:0
                       lockoutUntil:0];
    if (![self commitPINFields:fields]) return NO;

    /* Only now is the new PIN live: a failed write must leave the old one
     * working instead of diverging from the file until the next respring. */
    _salt = salt;
    _hash = hash;
    _iterations = kUGPINIterations;
    _failures = 0;
    _lockoutUntil = 0;
    return YES;
}

- (BOOL)verifyPIN:(NSString *)pin
{
    long long now;
    NSData *candidate;

    if (![self hasPIN]) return NO;
    if (![[self class] isValidPIN:pin]) return NO;

    [self clampLockoutWindow];
    now = UGNowSeconds();
    if (_lockoutUntil > now) return NO;

    candidate = UGDerivePIN(pin, _salt, _iterations);
    if (candidate && UGConstantTimeEqual(candidate, _hash)) {
        _failures = 0;
        _lockoutUntil = 0;
        [self persistPINAttemptFields];
        return YES;
    }

    if (_failures < 1000) _failures += 1;
    if (_failures % kUGPINFailuresPerLockout == 0) {
        NSInteger level = _failures / kUGPINFailuresPerLockout;
        NSInteger seconds = kUGPINBaseLockoutSeconds << MIN(level - 1, 4);
        if (seconds > kUGPINMaxLockoutSeconds) seconds = kUGPINMaxLockoutSeconds;
        _lockoutUntil = now + seconds;
        UGLog(@"Usage Guard: PIN lockout for %ld s", (long)seconds);
    }
    [self persistPINAttemptFields];
    return NO;
}

- (NSInteger)PINLockoutRemainingSeconds
{
    long long remaining;

    [self clampLockoutWindow];
    remaining = _lockoutUntil - UGNowSeconds();
    return remaining > 0 ? (NSInteger)remaining : 0;
}

@end
