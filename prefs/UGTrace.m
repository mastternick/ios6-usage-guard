#import "UGTrace.h"

#import "UGVersion.h"

#include <stdio.h>
#include <time.h>
#include <unistd.h>
#include <sys/stat.h>

/* Above this the previous file is rotated to UG_TRACE_PATH ".1" before the
 * next line is appended. */
static const unsigned long long kUGTraceMaxBytes = 64ULL * 1024ULL;

/* A pathological stack should not be able to fill the file with one report. */
static const NSUInteger kUGTraceMaxStackSymbols = 64;

static void UGTraceWriteLine(NSString *message)
{
    const char *text = [message UTF8String];
    if (!text) text = "<unrepresentable>";

    /* Bound the file before appending: a full disk on the device would make
     * every Settings visit fail, which is worse than losing old trace lines.
     * The full file is rotated to <path>.1 instead of being emptied, so the
     * crash record a parent is trying to export survives one generation of
     * churn. Both names are in the same directory, so rename(2) replaces any
     * previous .1 atomically and cannot fail with EXDEV. */
    struct stat info;
    if (stat(UG_TRACE_PATH, &info) == 0 && S_ISREG(info.st_mode) &&
        (unsigned long long)info.st_size > kUGTraceMaxBytes) {
        if (rename(UG_TRACE_PATH, UG_TRACE_PATH ".1") != 0) {
            /* Rotation failed for a reason the file cannot recover from in
             * place; fall back to emptying so the bound still holds. */
            FILE *truncate = fopen(UG_TRACE_PATH, "w");
            if (truncate) fclose(truncate);
        }
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
        /* Both generations: the parent asked for an empty journal, and a
         * leftover <path>.1 is still the journal. */
        unlink(UG_TRACE_PATH);
        unlink(UG_TRACE_PATH ".1");
        struct stat info;
        return stat(UG_TRACE_PATH, &info) != 0;
    } @catch (id exception) {
        (void)exception;
    }
    return NO;
}

#pragma mark - Uncaught exceptions

/* One line per frame. The marker matters because the exception's own stack has
 * the throw site and the thread stack at handler time usually only shows the
 * rethrow path from CFRunLoopRunSpecific upwards. */
static void UGTraceStackSymbols(NSArray *symbols, NSString *marker)
{
    NSUInteger count = [symbols isKindOfClass:[NSArray class]] ? symbols.count : 0;
    if (count > kUGTraceMaxStackSymbols) count = kUGTraceMaxStackSymbols;
    for (NSUInteger index = 0; index < count; index++) {
        id symbol = [symbols objectAtIndex:index];
        if (![symbol isKindOfClass:[NSString class]]) continue;
        UGTrace(@"  stack[%lu] %@ %@", (unsigned long)index, marker, symbol);
    }
}

/*
 * Installed process-wide from +load. The handler is deliberately self-contained:
 * it writes the exception, its own stack and, as a fallback, the Objective-C
 * call stack, then returns. It does not chain to a previously installed handler,
 * so a bad handler elsewhere can neither swallow this record nor re-enter it;
 * the app is terminating anyway.
 */
static void UGTraceUncaughtExceptionHandler(NSException *exception)
{
    @try {
        NSString *name = [exception name];
        NSString *reason = [exception reason];
        UGTrace(@"EXCEPTION %@: %@",
                [name isKindOfClass:[NSString class]] ? name : @"<non-string name>",
                [reason isKindOfClass:[NSString class]] ? reason : @"<non-string reason>");

        /* The exception's own stack keeps the frame that threw; the handler's
         * thread stack is often only the rethrow path. NSException and NSThread
         * both answer callStackSymbols on iOS 4+, but ask before sending: a
         * host that lacks it must not turn a crash into a second crash. */
        NSArray *symbols = nil;
        if ([exception respondsToSelector:@selector(callStackSymbols)]) {
            symbols = [exception callStackSymbols];
        }
        if ([symbols isKindOfClass:[NSArray class]] && symbols.count > 0) {
            UGTraceStackSymbols(symbols, @"exception-stack");
        } else if ([NSThread respondsToSelector:@selector(callStackSymbols)]) {
            UGTraceStackSymbols([NSThread callStackSymbols], @"thread-stack");
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
