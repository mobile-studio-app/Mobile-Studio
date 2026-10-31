#import "CrashLogger.h"
#import <Foundation/Foundation.h>
#include <execinfo.h>
#include <signal.h>
#include <unistd.h>

static NSString *get_crash_log_path(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *docs = paths.firstObject ?: NSTemporaryDirectory();
    return [docs stringByAppendingPathComponent:@"crash.log"];
}

static void write_crash_report(NSString *reason, NSArray<NSString *> *callStack) {
    NSString *path = get_crash_log_path();
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"yyyy-MM-dd HH:mm:ss Z";
    NSString *dateStr = [fmt stringFromDate:[NSDate date]];

    NSMutableString *log = [NSMutableString string];
    [log appendFormat:@"=== Mobile Studio Crash Report ===\nTime: %@\nReason: %@\n\nCall Stack:\n", dateStr, reason];
    for (NSString *frame in callStack) {
        [log appendFormat:@"  %@\n", frame];
    }
    [log appendString:@"============================\n\n"];

    NSData *data = [log dataUsingEncoding:NSUTF8StringEncoding];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (handle) {
        [handle seekToEndOfFile];
        [handle writeData:data];
        [handle closeFile];
    } else {
        [data writeToFile:path atomically:YES];
    }
}

static void uncaught_exception_handler(NSException *exception) {
    NSString *reason = [NSString stringWithFormat:@"Uncaught Exception '%@': %@",
                        exception.name, exception.reason ?: @"no reason"];
    write_crash_report(reason, exception.callStackSymbols ?: @[]);
}

static void signal_handler(int sig, siginfo_t *info, void *context) {
    (void)context;
    void *frames[64];
    int count = backtrace(frames, 64);
    char **symbols = backtrace_symbols(frames, count);

    NSMutableArray *callStack = [NSMutableArray arrayWithCapacity:count];
    if (symbols) {
        for (int i = 0; i < count; i++) {
            [callStack addObject:[NSString stringWithUTF8String:symbols[i]]];
        }
        free(symbols);
    }

    const char *sigName = "UNKNOWN";
    switch (sig) {
        case SIGSEGV: sigName = "SIGSEGV (Segmentation Fault)"; break;
        case SIGBUS:  sigName = "SIGBUS (Bus Error)"; break;
        case SIGABRT: sigName = "SIGABRT (Abort)"; break;
        case SIGILL:  sigName = "SIGILL (Illegal Instruction)"; break;
        case SIGFPE:  sigName = "SIGFPE (Floating Point Exception)"; break;
        case SIGTRAP: sigName = "SIGTRAP (Trace/Bpt Trap)"; break;
    }

    NSString *reason = [NSString stringWithFormat:@"Signal %d: %s at fault address %p", sig, sigName, info ? info->si_addr : NULL];
    write_crash_report(reason, callStack);

    // Re-raise default signal so system crash logger records it
    signal(sig, SIG_DFL);
    raise(sig);
}

void dc_install_crash_handlers(void) {
    NSSetUncaughtExceptionHandler(&uncaught_exception_handler);

    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = signal_handler;
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK;

    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGBUS,  &sa, NULL);
    sigaction(SIGABRT, &sa, NULL);
    sigaction(SIGILL,  &sa, NULL);
    sigaction(SIGFPE,  &sa, NULL);
    sigaction(SIGTRAP, &sa, NULL);
}

static NSString *g_lastReport = nil;

const char *dc_get_last_crash_log(void) {
    NSString *path = get_crash_log_path();
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
        g_lastReport = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
        return g_lastReport.UTF8String;
    }
    return NULL;
}

void dc_clear_last_crash_log(void) {
    NSString *path = get_crash_log_path();
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    g_lastReport = nil;
}
