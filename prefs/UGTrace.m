#import "UGTrace.h"

#import "UGVersion.h"

#include <stdio.h>
#include <time.h>
#include <unistd.h>
#include <sys/stat.h>

/* Above this the file is emptied before the next line is appended. */
static const unsigned long long kUGTraceMaxBytes = 64ULL * 1024ULL;

/* A pathological stack should not be able to fill the file with one report. */
static const NSUInteger kUGTraceMaxStackSymbols = 64;

static void UGTraceWriteLine(NSString *message)
{
    const char *text = [message UTF8String];
    if (!text) text = "<unrepresentable>";

    /* Bound the file before appending: a full disk on the device would make
     * every Settings visit fail, which is worse than losing old trace lines. */
    struct stat info;
    if (stat(UG_TRACE_PATH, &info) == 0 && S_ISREG(info.st_mode) &&
        (unsigned long long)info.st_size > kUGTraceMaxBytes) {
        FILE *truncate = fopen(UG_TRACE_PATH, "w");
        if (truncate) fclose(truncate);
    }

    /* Opened per line on purpose: no handle outlives the call, so a crash in
     * another thread (or in this one) cannot leave the file locked. */
    FILE *file = fopen(UG_TRACE_PATH, "a");
    if (!file) return;

    time_t now = time(NULL);
    struct tm breakdown;
    char stamp[32] = "1970-01-01T00:00:00Z";
    if (gmtime_r(&now, &breakdown)) {
        strftime(stamp, sizeof stamp, "%Y-%m-%dT%H:%M:%SZ", &breakdown);
    }

    fprintf(file, "%lld %s [%d] %s\n", (long long)now, stamp, (int)getpid(), text);
    fclose(file);
}

void UGTrace(NSString *format, ...)
{
    @try {
        if (![format isKindOfClass:[NSString class]]) return;

        /* Formatting is the only part that can raise (a malformed format is
         * caught by NS_FORMAT_FUNCTION at compile time, not here); va_end must
         * run on both paths. */
        NSString *message = nil;
        va_list arguments;
        va_start(arguments, format);
        @try {
            message = [[NSString alloc] initWithFormat:format arguments:arguments];
        } @finally {
            va_end(arguments);
        }

        if (![message isKindOfClass:[NSString class]]) return;
        UGTraceWriteLine(message);
    } @catch (id exception) {
        /* Silent by design: tracing must never change control flow. */
        (void)exception;
    }
}

NSString *UGTracePath(void)
{
    @try {
        return @UG_TRACE_PATH;
    } @catch (id exception) {
        (void)exception;
    }
    return nil;
}

unsigned long long UGTraceFileSize(void)
{
    @try {
        struct stat info;
        if (stat(UG_TRACE_PATH, &info) == 0 && S_ISREG(info.st_mode) && info.st_size > 0) {
            return (unsigned long long)info.st_size;
        }
    } @catch (id exception) {
        (void)exception;
    }
    return 0;
}

BOOL UGTraceRemoveLog(void)
{
    @try {
        unlink(UG_TRACE_PATH);
        struct stat info;
        return stat(UG_TRACE_PATH, &info) != 0;
    } @catch (id exception) {
        (void)exception;
    }
    return NO;
}

#pragma mark - Uncaught exceptions

/*
 * Installed process-wide from +load. The handler is deliberately self-contained:
 * it writes the exception plus the Objective-C call stack and returns. It does
 * not chain to a previously installed handler, so a bad handler elsewhere can
 * neither swallow this record nor re-enter it; the app is terminating anyway.
 */
static void UGTraceUncaughtExceptionHandler(NSException *exception)
{
    @try {
        NSString *name = [exception name];
        NSString *reason = [exception reason];
        UGTrace(@"EXCEPTION %@: %@",
                [name isKindOfClass:[NSString class]] ? name : @"<non-string name>",
                [reason isKindOfClass:[NSString class]] ? reason : @"<non-string reason>");

        /* NSThread.callStackSymbols exists on iOS 4+, but ask before sending:
         * a host that lacks it must not turn a crash into a second crash. */
        if ([NSThread respondsToSelector:@selector(callStackSymbols)]) {
            NSArray *symbols = [NSThread callStackSymbols];
            NSUInteger count = [symbols isKindOfClass:[NSArray class]] ? symbols.count : 0;
            if (count > kUGTraceMaxStackSymbols) count = kUGTraceMaxStackSymbols;
            for (NSUInteger index = 0; index < count; index++) {
                id symbol = [symbols objectAtIndex:index];
                if (![symbol isKindOfClass:[NSString class]]) continue;
                UGTrace(@"  stack[%lu] %@", (unsigned long)index, symbol);
            }
        }
    } @catch (id ignored) {
        (void)ignored;
    }
}

/* A class only so +load runs at bundle load, before PreferenceLoader asks for
 * the controller. */
@interface UGTraceInstaller : NSObject
@end

@implementation UGTraceInstaller

+ (void)load
{
    @try {
        /* Chained nowhere: see the handler's comment. */
        NSSetUncaughtExceptionHandler(&UGTraceUncaughtExceptionHandler);
        UGTrace(@"bundle loaded: %@", [[NSBundle bundleForClass:self] bundlePath]);
    } @catch (id ignored) {
        (void)ignored;
    }
}

@end
