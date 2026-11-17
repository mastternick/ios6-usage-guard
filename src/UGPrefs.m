#import "UGPrefs.h"

#import <CommonCrypto/CommonDigest.h>
#import <CommonCrypto/CommonKeyDerivation.h>
#import <Security/Security.h>
#import <stdlib.h>
#import <string.h>

static NSString *const kUGPrefsPath =
    @"/var/mobile/Library/Preferences/org.usageguard.timer.plist";

static NSString *const kUGStateKey = @"State";
static NSString *const kUGPINSaltKey = @"PINSalt";
static NSString *const kUGPINHashKey = @"PINHash";
static NSString *const kUGPINIterationsKey = @"PINIterations";
static NSString *const kUGPINFailuresKey = @"PINFailures";
static NSString *const kUGPINLockoutKey = @"PINLockoutUntil";
static NSString *const kUGDebugKey = @"DebugLogging";

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

long long UGNowSeconds(void)
{
    return (long long)[[NSDate date] timeIntervalSince1970];
}

BOOL UGDebugLoggingEnabled(void)
{
    return sUGDebugLogging;
}

@implementation UGPrefs {
    NSMutableDictionary *_values;
    NSData *_salt;
    NSData *_hash;
    uint32_t _iterations;
    NSInteger _failures;
    long long _lockoutUntil;
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

    NSDictionary *stored = [NSDictionary dictionaryWithContentsOfFile:kUGPrefsPath];
    _values = stored ? [stored mutableCopy] : [NSMutableDictionary dictionary];

    if ([_values[kUGPINSaltKey] isKindOfClass:[NSString class]]) {
        _salt = UGBase64Decode(_values[kUGPINSaltKey]);
    }
    if ([_values[kUGPINHashKey] isKindOfClass:[NSString class]]) {
        _hash = UGBase64Decode(_values[kUGPINHashKey]);
    }
    _iterations = [_values[kUGPINIterationsKey] unsignedIntValue];
    _failures = [_values[kUGPINFailuresKey] integerValue];
    _lockoutUntil = [_values[kUGPINLockoutUntilKey] longLongValue];

    sUGDebugLogging = [_values[kUGDebugKey] boolValue];
    return self;
}

- (BOOL)writeValues
{
    NSString *directory = [kUGPrefsPath stringByDeletingLastPathComponent];
    BOOL written;

    [[NSFileManager defaultManager] createDirectoryAtPath:directory
                             withIntermediateDirectories:YES
                                              attributes:nil
                                                   error:NULL];
    written = [_values writeToFile:kUGPrefsPath atomically:YES];
    if (!written) UGLog(@"Usage Guard: could not write %@", kUGPrefsPath);
    return written;
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

    _values[kUGStateKey] = [NSString stringWithUTF8String:buffer];
    return [self writeValues];
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

- (BOOL)persistPINFields
{
    _values[kUGPINSaltKey] = _salt ? UGBase64Encode(_salt) : @"";
    _values[kUGPINHashKey] = _hash ? UGBase64Encode(_hash) : @"";
    _values[kUGPINIterationsKey] = @(_iterations);
    _values[kUGPINFailuresKey] = @(_failures);
    _values[kUGPINLockoutKey] = @(_lockoutUntil);
    return [self writeValues];
}

- (BOOL)setPIN:(NSString *)pin
{
    unsigned char rawSalt[kUGPINSaltLength];
    NSData *salt;
    NSData *hash;

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

    _salt = salt;
    _hash = hash;
    _iterations = kUGPINIterations;
    _failures = 0;
    _lockoutUntil = 0;
    return [self persistPINFields];
}

- (BOOL)verifyPIN:(NSString *)pin
{
    long long now = UGNowSeconds();
    NSData *candidate;

    if (![self hasPIN]) return NO;
    if (![[self class] isValidPIN:pin]) return NO;
    if (_lockoutUntil > now) return NO;

    candidate = UGDerivePIN(pin, _salt, _iterations);
    if (candidate && UGConstantTimeEqual(candidate, _hash)) {
        _failures = 0;
        _lockoutUntil = 0;
        [self persistPINFields];
        return YES;
    }

    _failures += 1;
    if (_failures % kUGPINFailuresPerLockout == 0) {
        NSInteger level = _failures / kUGPINFailuresPerLockout;
        NSInteger seconds = kUGPINBaseLockoutSeconds << MIN(level - 1, 4);
        if (seconds > kUGPINMaxLockoutSeconds) seconds = kUGPINMaxLockoutSeconds;
        _lockoutUntil = now + seconds;
        UGLog(@"Usage Guard: PIN lockout for %ld s", (long)seconds);
    }
    [self persistPINFields];
    return NO;
}

- (NSInteger)PINLockoutRemainingSeconds
{
    long long remaining = _lockoutUntil - UGNowSeconds();
    return remaining > 0 ? (NSInteger)remaining : 0;
}

@end
