// JavaScript (Node.js) as a console runtime. Node.js runs once per launch inside the app (see
// App/Extensions/NodeExtensionHost.swift); each run is a worker thread there, started over a
// loopback connection (Editor/src/ext/node-programs.js) whose port the app passes as
// --node-port=<port>. Messages are one JSON object per line. Debugging runs over the same
// connection: commands go as { debug }, events come back as { debugEvent }.

#import <Foundation/Foundation.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <pthread.h>
#include <sys/socket.h>
#include <unistd.h>
#include <atomic>
#include <string>
#include "ConsoleAdapter.h"
#include "DebugChannel.h"

static std::atomic<int> g_socket{-1};
static NSLock *g_writeLock;

static bool send_message(NSDictionary *message) {
    int fd = g_socket;
    if (fd < 0) return false;
    NSMutableData *data = [[NSJSONSerialization dataWithJSONObject:message options:0 error:nil] mutableCopy];
    if (!data) return false;
    [data appendBytes:"\n" length:1];
    [g_writeLock lock];
    const char *bytes = (const char *)data.bytes;
    size_t left = data.length;
    bool ok = true;
    while (left > 0) {
        ssize_t n = write(fd, bytes, left);
        if (n <= 0) { ok = false; break; }
        bytes += n;
        left -= (size_t)n;
    }
    [g_writeLock unlock];
    return ok;
}

/// Lines typed into the console go to the program; Stop (NULL) stops it.
static void *input_thread(void *) {
    while (true) {
        char *line = dc_console_read_line();
        if (!line) {
            send_message(@{@"stop": @YES});
            break;
        }
        bool sent = send_message(@{@"stdin": [NSString stringWithUTF8String:line] ?: @""});
        free(line);
        if (!sent) break;
    }
    return NULL;
}

/// Debugger commands from the IDE go to Node.js (node-debug.js), until the run ends.
static void *debug_thread(void *) {
    while (char *command = dc_debug_receive(-1)) {
        bool sent = send_message(@{@"debug": [NSString stringWithUTF8String:command] ?: @"{}"});
        free(command);
        if (!sent) break;
    }
    return NULL;
}

static int connect_to(int port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_in address = {};
    address.sin_len = sizeof(address);
    address.sin_family = AF_INET;
    address.sin_port = htons((uint16_t)port);
    address.sin_addr.s_addr = inet_addr("127.0.0.1");
    // Node.js may still be starting: try for a while.
    for (int attempt = 0; attempt < 100 && !dc_console_should_stop(); attempt++) {
        if (connect(fd, (struct sockaddr *)&address, sizeof(address)) == 0) return fd;
        close(fd);
        fd = socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0) return -1;
        usleep(200 * 1000);
    }
    close(fd);
    return -1;
}

static int run_program(const char *project_dir) {
    const char *portText = dc_console_option("--node-port=");
    int port = portText ? atoi(portText) : 0;
    if (port <= 0) {
        dc_console_log(DC_LOG_ERROR, "Node.js isn't running.");
        return 1;
    }
    int fd = connect_to(port);
    if (fd < 0) {
        if (!dc_console_should_stop()) dc_console_log(DC_LOG_ERROR, "Couldn't reach Node.js.");
        return 1;
    }
    g_socket = fd;
    NSString *dir = [NSString stringWithUTF8String:project_dir] ?: @".";
    NSMutableDictionary *run = [@{@"run": dir, @"repl": @(dc_console_is_repl() != 0)} mutableCopy];
    const char *debugConfig = dc_debug_config();
    if (debugConfig) run[@"debug"] = [NSString stringWithUTF8String:debugConfig] ?: @"{}";
    send_message(run);
    if (debugConfig) {
        pthread_t debugger;
        pthread_create(&debugger, NULL, debug_thread, NULL);
        pthread_detach(debugger);
    }

    pthread_t input;
    pthread_create(&input, NULL, input_thread, NULL);
    pthread_detach(input);

    int code = 1;
    std::string buffer;
    char chunk[4096];
    bool done = false;
    while (!done) {
        ssize_t n = read(fd, chunk, sizeof(chunk));
        if (n <= 0) break;
        buffer.append(chunk, (size_t)n);
        size_t newline;
        while ((newline = buffer.find('\n')) != std::string::npos) {
            NSData *data = [NSData dataWithBytes:buffer.data() length:newline];
            buffer.erase(0, newline + 1);
            NSDictionary *message = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if (![message isKindOfClass:[NSDictionary class]]) continue;
            if (NSString *out = message[@"out"]) {
                const char *text = out.UTF8String;
                dc_console_write(DC_LOG_GAME, text, strlen(text));
            } else if (NSString *err = message[@"err"]) {
                const char *text = err.UTF8String;
                dc_console_write(DC_LOG_ERROR, text, strlen(text));
            } else if (NSString *error = message[@"error"]) {
                id file = message[@"file"];
                dc_console_report_error(error.UTF8String, [file isKindOfClass:[NSString class]] ? [file UTF8String] : NULL,
                                        [message[@"line"] intValue]);
            } else if (NSString *event = message[@"debugEvent"]) {
                dc_debug_send(event.UTF8String);
            } else if (message[@"exit"]) {
                code = [message[@"exit"] intValue];
                done = true;
                break;
            }
        }
    }
    g_socket = -1;
    close(fd);
    if (dc_console_should_stop()) dc_console_log(DC_LOG_INFO, "Stopped.");
    return code;
}

static void interrupt(void) {
    send_message(@{@"stop": @YES});
}

static const dc_console_config kNodeConfig = {
    .runtime_id = "node-18",
    .display_name = "JavaScript (Node.js 18)",
    .version = "18.20.4",
    .run_program = run_program,
    .interrupt = interrupt,
    .no_debugger = 0,
};

DC_EXPORT const dc_runtime *duocode_runtime_entry(void) {
    if (!g_writeLock) g_writeLock = [NSLock new];
    return dc_create_console_runtime(&kNodeConfig);
}
