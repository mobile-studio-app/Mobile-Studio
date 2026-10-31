#import "ConsoleAdapter.h"
#import "DebugChannel.h"
#import <Foundation/Foundation.h>
#include <pthread.h>
#include <atomic>
#include <string>
#include <vector>

static const dc_host_api *g_host = NULL;
static const dc_console_config *g_config = NULL;

static std::atomic<bool> g_stop{false};
static std::atomic<bool> g_finished{false};
static int g_exitCode = 0;
static bool g_repl = false;
static std::vector<std::string> g_arguments;
static std::string g_projectDir;

static NSCondition *g_inputLock;
static NSMutableArray<NSString *> *g_input;

static NSLock *g_outputLock;
static std::string g_partial[5];   // per log level, text after the last newline

// Messages from the program thread, delivered on the main thread in order (see deliver_pending).
struct PendingMessage {
    bool isError;
    dc_log_level level;
    std::string text;
    std::string file;
    bool hasFile;
    int line;
};
static NSLock *g_pendingLock;
static std::vector<PendingMessage> g_pending;

static void enqueue(PendingMessage message) {
    [g_pendingLock lock];
    g_pending.push_back(std::move(message));
    [g_pendingLock unlock];
    CFRunLoopWakeUp(CFRunLoopGetMain());
}

/// Hands queued output to the host. Main thread only.
static void deliver_pending(void) {
    [g_pendingLock lock];
    std::vector<PendingMessage> messages;
    messages.swap(g_pending);
    [g_pendingLock unlock];
    for (const PendingMessage &m : messages) {
        if (!g_host) break;
        if (m.isError) {
            if (g_host->on_error) g_host->on_error(g_host->ctx, m.text.c_str(), m.hasFile ? m.file.c_str() : NULL, m.line);
        } else if (g_host->log) {
            g_host->log(g_host->ctx, m.level, m.text.c_str());
        }
    }
}

// MARK: - Host calls (queued, delivered on the main thread)

void dc_console_log(dc_log_level level, const char *message) {
    if (!g_host || !message) return;
    enqueue({false, level, message, "", false, 0});
}

void dc_console_report_error(const char *message, const char *file, int line) {
    if (!g_host) return;
    enqueue({true, DC_LOG_ERROR, message ?: "error", file ?: "", file != NULL, line});
}

void dc_console_write(dc_log_level level, const char *text, size_t length) {
    if (!text || level > DC_LOG_GAME) return;
    [g_outputLock lock];
    std::string &partial = g_partial[level];
    partial.append(text, length);
    size_t start = 0, newline;
    while ((newline = partial.find('\n', start)) != std::string::npos) {
        dc_console_log(level, partial.substr(start, newline - start).c_str());
        start = newline + 1;
    }
    partial.erase(0, start);
    [g_outputLock unlock];
}

void dc_console_flush(void) {
    [g_outputLock lock];
    for (int level = 0; level <= DC_LOG_GAME; level++) {
        if (!g_partial[level].empty()) {
            dc_console_log((dc_log_level)level, g_partial[level].c_str());
            g_partial[level].clear();
        }
    }
    [g_outputLock unlock];
}

// MARK: - Input

char *dc_console_read_line(void) {
    dc_console_flush();   // show the prompt before waiting
    [g_inputLock lock];
    while (g_input.count == 0 && !g_stop) [g_inputLock wait];
    NSString *line = nil;
    if (!g_stop && g_input.count > 0) {
        line = g_input.firstObject;
        [g_input removeObjectAtIndex:0];
    }
    [g_inputLock unlock];
    return line ? strdup(line.UTF8String) : NULL;
}

int dc_console_should_stop(void) {
    return g_stop ? 1 : 0;
}

int dc_console_is_repl(void) {
    return g_repl ? 1 : 0;
}

const char *dc_console_option(const char *prefix) {
    size_t length = strlen(prefix);
    for (const std::string &argument : g_arguments) {
        if (argument.compare(0, length, prefix) == 0) return argument.c_str() + length;
    }
    return NULL;
}

static void console_send_input(const char *line) {
    if (!line) return;
    [g_inputLock lock];
    [g_input addObject:[NSString stringWithUTF8String:line] ?: @""];
    [g_inputLock signal];
    [g_inputLock unlock];
}

// MARK: - Runtime

static void *program_thread(void *) {
    @autoreleasepool {
        g_exitCode = g_config->run_program(g_projectDir.c_str());
        dc_console_flush();
    }
    g_finished = true;
    // Wake the main run loop so console_run notices straight away.
    CFRunLoopWakeUp(CFRunLoopGetMain());
    return NULL;
}

static int console_init(const dc_host_api *host) {
    if (!host || host->abi_version != DC_RUNTIME_ABI_VERSION) return -1;
    g_host = host;
    dc_debug_setup(host);
    g_inputLock = [NSCondition new];
    g_input = [NSMutableArray array];
    g_outputLock = [NSLock new];
    g_pendingLock = [NSLock new];
    return 0;
}

static int console_run(const dc_run_options *opt) {
    if (!g_host || !g_config || !g_config->run_program) return -1;
    g_host->on_state(g_host->ctx, DC_STATE_STARTING);
    g_stop = false;
    g_finished = false;
    g_exitCode = 0;
    g_projectDir = (opt && opt->project_dir) ? opt->project_dir : ".";
    dc_debug_begin(opt ? opt->debug_config : NULL);
    g_repl = false;
    g_arguments.clear();
    for (int i = 0; opt && opt->argv && i < opt->argc; i++) {
        if (!opt->argv[i]) continue;
        g_arguments.push_back(opt->argv[i]);
        if (strcmp(opt->argv[i], "--repl") == 0) g_repl = true;
    }
    [g_inputLock lock];
    [g_input removeAllObjects];
    [g_inputLock unlock];

    // Interpreters recurse deeply (Python especially); give the program a big stack.
    pthread_attr_t attributes;
    pthread_attr_init(&attributes);
    pthread_attr_setstacksize(&attributes, 16 * 1024 * 1024);
    pthread_t thread;
    if (pthread_create(&thread, &attributes, program_thread, NULL) != 0) {
        pthread_attr_destroy(&attributes);
        g_host->on_state(g_host->ctx, DC_STATE_STOPPED);
        return -1;
    }
    pthread_attr_destroy(&attributes);
    g_host->on_state(g_host->ctx, DC_STATE_RUNNING);

    // Keep the IDE running (and deliver the program's output) until the program ends.
    while (!g_finished) {
        @autoreleasepool {
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, true);
            deliver_pending();
        }
    }
    pthread_join(thread, NULL);
    dc_debug_end();
    deliver_pending();   // everything the program printed, before the exit is reported

    g_host->on_state(g_host->ctx, DC_STATE_STOPPING);
    g_host->on_state(g_host->ctx, DC_STATE_STOPPED);
    return g_exitCode;
}

static void console_request_stop(void) {
    g_stop = true;
    dc_debug_end();   // a program paused in the debugger lets go
    [g_inputLock lock];
    [g_inputLock broadcast];
    [g_inputLock unlock];
    if (g_config && g_config->interrupt) g_config->interrupt();
}

static void console_set_focus(int) {}
static void console_container_resized(double, double, double) {}

static void console_shutdown(void) {
    g_host = NULL;
}

const dc_runtime *dc_create_console_runtime(const dc_console_config *config) {
    g_config = config;
    static dc_runtime rt;
    rt.abi_version = DC_RUNTIME_ABI_VERSION;
    rt.id = config->runtime_id;
    rt.display_name = config->display_name;
    rt.version = config->version;
    rt.initialize = console_init;
    rt.run = console_run;
    rt.request_stop = console_request_stop;
    rt.set_input_focus = console_set_focus;
    rt.container_resized = console_container_resized;
    rt.shutdown = console_shutdown;
    rt.send_input = console_send_input;
    rt.debug_command = config->no_debugger ? NULL : dc_debug_command;
    return &rt;
}
