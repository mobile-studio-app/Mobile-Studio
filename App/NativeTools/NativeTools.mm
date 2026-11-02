// Runs the macOS command-line programs VS Code extensions ship (language servers, linters,
// formatters) inside DuoCode. iOS can't start other processes, and only runs code signed by the
// team that signed the app, so each run:
//   1. prepares the program (NativeTools/prepare, in Rust): its ARM64 code is rewritten as a
//      library and signed with the user's own development certificate (from Plume Impactor's
//      Settings > Export P12, or any .p12 of the team that signed DuoCode). No JIT, no VPN.
//   2. dlopen()s it and runs its main() on a thread.
//   3. redirects, for that program only, the calls a program inside an app can't make for
//      itself: its stdin/stdout/stderr are its own sockets, exit() ends its thread instead of
//      the app, its arguments and environment are its own, and signal handlers it installs
//      are ignored so they can't take over the app's. Calls are matched to their program by
//      return address (the code that called), so any number of programs can run at once.
// A program that crashes still takes DuoCode with it.
//
// Node.js (Editor/src/ext/node-child.js) starts programs over a loopback connection, one JSON
// object per line:
//   -> {"run": path, "args": [...], "cwd": dir, "env": {...}}
//   <- {"fds": [stdin, stdout, stderr]}   (this process's descriptors, now owned by Node.js)
//   <- {"exit": code, "error": message?}
//   -> {"kill": true}                     (closes its stdin/stdout/stderr; closing the
//                                          connection does the same)

#import <Foundation/Foundation.h>
#include <arpa/inet.h>
#include <crt_externs.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach/mach.h>
#include <netinet/in.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/uio.h>
#include <unistd.h>
#include <algorithm>
#include <atomic>
#include <mutex>
#include <set>
#include <string>
#include <unordered_map>
#include <vector>
#include "NativeTools.h"

// NativeTools/prepare (libduocode_prepare.a).
extern "C" int dc_prepare_program(const char *input, const char *output, const uint8_t *p12, size_t p12_length,
                                  const char *password, char *error, size_t error_capacity);
extern "C" int dc_certificate_team(const uint8_t *p12, size_t length, const char *password, char *team, size_t capacity);
extern "C" int dc_sign_library(const char *path, const char *identifier, const uint8_t *p12, size_t p12_length,
                               const char *password, char *error, size_t error_capacity);

namespace {

struct Run {
    uintptr_t start = 0, end = 0;   // where its code is
    std::atomic<int> fds[3];        // its stdin, stdout, stderr (-1 once closed)
    int argc = 0;
    char **argv = nullptr;
    char **envp = nullptr;
    std::string path;
    std::string missing;            // what it imports that iOS doesn't have, for the message
    int (*main)(int, char **, char **, char **) = nullptr;
    std::mutex controlLock;
    int control = -1;               // the connection it was started over
    std::atomic<bool> finished{false};
};

// Runs are never freed: a finished program's threads may still be running its code.
constexpr int kMaxRuns = 4096;
Run *g_runs[kMaxRuns];
std::atomic<int> g_runCount{0};
std::mutex g_runsLock;
thread_local Run *t_run = nullptr;

/// The run whose code is at `address` (the caller of a redirected function).
Run *runAt(void *address) {
    uintptr_t at = (uintptr_t)address;
    int count = g_runCount.load(std::memory_order_acquire);
    for (int i = count - 1; i >= 0; i--) {
        Run *run = g_runs[i];
        if (at >= run->start && at < run->end) return run;
    }
    // A call from a system library on the program's behalf: its own threads know.
    return t_run;
}

#define CALLER() runAt(__builtin_return_address(0))
#define REDIRECT __attribute__((noinline))

void sendLine(Run *run, NSDictionary *message) {
    NSMutableData *data = [[NSJSONSerialization dataWithJSONObject:message options:0 error:nil] mutableCopy];
    [data appendBytes:"\n" length:1];
    std::lock_guard<std::mutex> lock(run->controlLock);
    if (run->control < 0) return;
    const char *bytes = (const char *)data.bytes;
    size_t left = data.length;
    while (left > 0) {
        ssize_t n = write(run->control, bytes, left);
        if (n <= 0) break;
        bytes += n;
        left -= (size_t)n;
    }
}

/// The program is done (or stopped): its streams close, and Node.js hears how it ended.
void finish(Run *run, int code, const char *message) {
    if (!run || run->finished.exchange(true)) return;
    for (auto &fd : run->fds) {
        int old = fd.exchange(-1);
        if (old >= 0) close(old);
    }
    NSMutableDictionary *reply = [@{@"exit": @(code)} mutableCopy];
    if (message) reply[@"error"] = [NSString stringWithUTF8String:message] ?: @"";
    sendLine(run, reply);
}

[[noreturn]] void endThread(Run *run, int code, const char *message) {
    finish(run, code, message);
    pthread_exit(nullptr);
}

int mapped(Run *run, int fd) {
    return run && fd >= 0 && fd <= 2 ? run->fds[fd].load() : fd;
}

// MARK: - What programs call instead

REDIRECT ssize_t my_read(int fd, void *buffer, size_t size) { return read(mapped(CALLER(), fd), buffer, size); }
REDIRECT ssize_t my_write(int fd, const void *buffer, size_t size) { return write(mapped(CALLER(), fd), buffer, size); }
REDIRECT ssize_t my_readv(int fd, const struct iovec *v, int count) { return readv(mapped(CALLER(), fd), v, count); }
REDIRECT ssize_t my_writev(int fd, const struct iovec *v, int count) { return writev(mapped(CALLER(), fd), v, count); }
REDIRECT int my_fstat(int fd, struct stat *info) { return fstat(mapped(CALLER(), fd), info); }
REDIRECT int my_dup(int fd) { return dup(mapped(CALLER(), fd)); }

REDIRECT int my_close(int fd) {
    Run *run = CALLER();
    if (run && fd >= 0 && fd <= 2) {
        int old = run->fds[fd].exchange(-1);
        return old >= 0 ? close(old) : 0;
    }
    return close(fd);
}

REDIRECT int my_dup2(int from, int to) {
    Run *run = CALLER();
    if (run && to >= 0 && to <= 2) {
        int copy = dup(mapped(run, from));
        if (copy < 0) return -1;
        int old = run->fds[to].exchange(copy);
        if (old >= 0) close(old);
        return to;
    }
    return dup2(mapped(run, from), to);
}

REDIRECT int my_isatty(int fd) {
    Run *run = CALLER();
    if (run && fd >= 0 && fd <= 2) {
        errno = ENOTTY;
        return 0;
    }
    return isatty(fd);
}

REDIRECT int my_ioctl(int fd, unsigned long request, ...) {
    va_list list;
    va_start(list, request);
    void *argument = va_arg(list, void *);
    va_end(list);
    return ioctl(mapped(CALLER(), fd), request, argument);
}

REDIRECT int my_fcntl(int fd, int command, ...) {
    va_list list;
    va_start(list, command);
    intptr_t argument = va_arg(list, intptr_t);
    va_end(list);
    return fcntl(mapped(CALLER(), fd), command, argument);
}

REDIRECT int my_poll(struct pollfd *fds, nfds_t count, int timeout) {
    Run *run = CALLER();
    if (!run) return poll(fds, count, timeout);
    std::vector<struct pollfd> copy(fds, fds + count);
    for (auto &entry : copy) entry.fd = mapped(run, entry.fd);
    int result = poll(copy.data(), count, timeout);
    for (nfds_t i = 0; i < count; i++) fds[i].revents = copy[i].revents;
    return result;
}

REDIRECT void my_exit(int code) { endThread(CALLER(), code, nullptr); }
REDIRECT void my__exit(int code) { endThread(CALLER(), code, nullptr); }
REDIRECT void my_abort(void) { endThread(CALLER(), 134, "The program stopped itself (abort)."); }

bool isFatal(int sig) {
    return sig == SIGABRT || sig == SIGKILL || sig == SIGTERM || sig == SIGINT || sig == SIGQUIT || sig == SIGHUP ||
           sig == SIGSEGV || sig == SIGBUS || sig == SIGILL || sig == SIGTRAP;
}

REDIRECT int my_raise(int sig) {
    if (isFatal(sig)) endThread(CALLER(), 128 + sig, sig == SIGABRT ? "The program stopped itself (abort)." : nullptr);
    return 0;
}

REDIRECT int my_kill(pid_t pid, int sig) {
    if (pid == getpid() || pid == 0) {
        if (isFatal(sig)) endThread(CALLER(), 128 + sig, nullptr);
        return 0;
    }
    return kill(pid, sig);
}

REDIRECT int my_sigaction(int, const struct sigaction *, struct sigaction *old) {
    if (old) memset(old, 0, sizeof(*old));
    return 0;
}

REDIRECT sig_t my_signal(int, sig_t) { return SIG_DFL; }

REDIRECT int *my_NSGetArgc(void) {
    Run *run = CALLER();
    return run ? &run->argc : _NSGetArgc();
}

REDIRECT char ***my_NSGetArgv(void) {
    Run *run = CALLER();
    return run ? &run->argv : _NSGetArgv();
}

REDIRECT char ***my_NSGetEnviron(void) {
    Run *run = CALLER();
    return run ? &run->envp : _NSGetEnviron();
}

REDIRECT char *my_getenv(const char *name) {
    Run *run = CALLER();
    if (!run) return getenv(name);
    size_t length = strlen(name);
    for (char **entry = run->envp; entry && *entry; entry++) {
        if (strncmp(*entry, name, length) == 0 && (*entry)[length] == '=') return *entry + length + 1;
    }
    return nullptr;
}

REDIRECT int my_NSGetExecutablePath(char *buffer, uint32_t *size) {
    Run *run = CALLER();
    if (!run) return _NSGetExecutablePath(buffer, size);
    uint32_t needed = (uint32_t)run->path.size() + 1;
    if (*size < needed) {
        *size = needed;
        return -1;
    }
    memcpy(buffer, run->path.c_str(), needed);
    return 0;
}

/// Where a function iOS doesn't have would have been.
REDIRECT void my_missing(void) {
    Run *run = CALLER();
    std::string message = "The program used something iOS doesn't have";
    if (run && !run->missing.empty()) message += " (one of: " + run->missing + ")";
    endThread(run, 127, (message + ".").c_str());
}

const std::unordered_map<std::string, void *> &redirections() {
    static const std::unordered_map<std::string, void *> table = {
        {"_read", (void *)my_read}, {"_read$NOCANCEL", (void *)my_read},
        {"_write", (void *)my_write}, {"_write$NOCANCEL", (void *)my_write},
        {"_readv", (void *)my_readv}, {"_writev", (void *)my_writev},
        {"_close", (void *)my_close}, {"_close$NOCANCEL", (void *)my_close},
        {"_fstat", (void *)my_fstat}, {"_dup", (void *)my_dup}, {"_dup2", (void *)my_dup2},
        {"_isatty", (void *)my_isatty}, {"_ioctl", (void *)my_ioctl},
        {"_fcntl", (void *)my_fcntl}, {"_fcntl$NOCANCEL", (void *)my_fcntl},
        {"_poll", (void *)my_poll}, {"_poll$NOCANCEL", (void *)my_poll},
        {"_exit", (void *)my_exit}, {"__exit", (void *)my__exit}, {"_abort", (void *)my_abort},
        {"_raise", (void *)my_raise}, {"_kill", (void *)my_kill},
        {"_sigaction", (void *)my_sigaction}, {"_signal", (void *)my_signal},
        {"__NSGetArgc", (void *)my_NSGetArgc}, {"__NSGetArgv", (void *)my_NSGetArgv},
        {"__NSGetEnviron", (void *)my_NSGetEnviron}, {"__NSGetExecutablePath", (void *)my_NSGetExecutablePath},
        {"_getenv", (void *)my_getenv},
    };
    return table;
}

/// Constants (kCFTypeArrayCallBacks...) can't be replaced by a function.
bool looksLikeData(const std::string &name) {
    if (name.size() > 2 && name[1] == 'k' && isupper((unsigned char)name[2])) return true;
    if (name.rfind("_OBJC_", 0) == 0 || name == "___stack_chk_guard" || name == "_environ") return true;
    auto endsWith = [&](const char *suffix) {
        size_t n = strlen(suffix);
        return name.size() >= n && name.compare(name.size() - n, n, suffix) == 0;
    };
    return endsWith("VersionNumber") || endsWith("VersionString");
}

// MARK: - Loading

std::mutex g_certificateLock;
NSData *g_certificate;
NSString *g_password;
std::atomic<unsigned> g_nextName{0};

NSString *programsFolder() {
    static NSString *folder = [] {
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"Programs"];
        // Earlier launches' copies are no longer loaded.
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        [[NSFileManager defaultManager] createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
        return path;
    }();
    return folder;
}

/// Prepares, loads and redirects a program. Returns its main(), or sets `error`.
bool load(Run *run, std::string &error) {
    NSData *certificate;
    NSString *password;
    {
        std::lock_guard<std::mutex> lock(g_certificateLock);
        certificate = g_certificate;
        password = g_password;
    }
    if (!certificate.length) {
        error = "Running macOS programs needs your signing certificate: import it in Settings > Programs from Extensions.";
        return false;
    }
    // A fresh copy for each run: a program's global state starts clean, and each run's code
    // is at its own addresses.
    char name[16];
    snprintf(name, sizeof(name), "p%06x", (g_nextName++ * 2654435761u + arc4random()) & 0xffffff);
    std::string library = std::string(programsFolder().UTF8String) + "/" + name + ".dylib";
    char reason[1024] = {0};
    if (dc_prepare_program(run->path.c_str(), library.c_str(), (const uint8_t *)certificate.bytes, certificate.length,
                           password.UTF8String ?: "", reason, sizeof(reason)) != 0) {
        error = reason;
        return false;
    }
    NSString *importsText = [NSString stringWithContentsOfFile:@((library + ".imports").c_str()) encoding:NSUTF8StringEncoding error:nil];

    void *handle = dlopen(library.c_str(), RTLD_NOW | RTLD_LOCAL);
    if (!handle) {
        const char *why = dlerror();
        error = std::string("iOS wouldn't load it: ") + (why ?: "unknown reason");
        if (strstr(error.c_str(), "code signature") || strstr(error.c_str(), "not valid for use")) {
            error += " (Is the certificate from the same Apple ID that Mobile Studio was installed with?)";
        }
        return false;
    }
    const struct mach_header_64 *header = nullptr;
    intptr_t slide = 0;
    for (uint32_t i = 0, n = _dyld_image_count(); i < n; i++) {
        const char *image = _dyld_get_image_name(i);
        if (image && strstr(image, name)) {
            header = (const struct mach_header_64 *)_dyld_get_image_header(i);
            slide = _dyld_get_image_vmaddr_slide(i);
            break;
        }
    }
    if (!header) {
        error = "It loaded, but Mobile Studio couldn't find it.";
        return false;
    }
    uintptr_t base = (uintptr_t)header;
    uintptr_t end = base;
    const struct load_command *command = (const struct load_command *)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        if (command->cmd == LC_SEGMENT_64) {
            auto segment = (const struct segment_command_64 *)command;
            if (strcmp(segment->segname, "__PAGEZERO") != 0) end = std::max(end, (uintptr_t)(segment->vmaddr + segment->vmsize + slide));
        }
        command = (const struct load_command *)((const char *)command + command->cmdsize);
    }

    // Point its imports at DuoCode's versions; missing functions at a message.
    const auto &table = redirections();
    std::set<uintptr_t> writable;
    std::set<std::string> missing;
    uint64_t entry = 0;
    for (NSString *line in [importsText componentsSeparatedByString:@"\n"]) {
        NSArray<NSString *> *parts = [line componentsSeparatedByString:@" "];
        if (parts.count >= 2 && [parts[0] isEqualToString:@"entry"]) {
            entry = strtoull(parts[1].UTF8String, nullptr, 16);
            continue;
        }
        if (parts.count < 4 || ![parts[0] isEqualToString:@"import"]) continue;
        void **slot = (void **)(base + strtoull(parts[1].UTF8String, nullptr, 16));
        std::string symbol = parts[3].UTF8String;
        auto redirect = table.find(symbol);
        void *value = nullptr;
        if (redirect != table.end()) {
            value = redirect->second;
        } else if (*slot == nullptr && [parts[2] isEqualToString:@"s"] && !looksLikeData(symbol)) {
            value = (void *)my_missing;
            missing.insert(symbol.substr(1));
        }
        if (!value) continue;
        uintptr_t page = (uintptr_t)slot & ~(uintptr_t)(vm_page_size - 1);
        if (writable.insert(page).second) {
            vm_protect(mach_task_self(), page, vm_page_size, false, VM_PROT_READ | VM_PROT_WRITE);
        }
        *slot = value;
    }
    if (!entry) {
        error = "It isn't a program (it has no main).";
        return false;
    }
    for (const auto &function : missing) {
        if (run->missing.size() > 200) { run->missing += ", ..."; break; }
        run->missing += (run->missing.empty() ? "" : ", ") + function;
    }
    run->main = (int (*)(int, char **, char **, char **))(base + entry);
    run->start = base;
    run->end = end;
    return true;
}

void *programThread(void *argument) {
    Run *run = (Run *)argument;
    t_run = run;
    std::string executable = "executable_path=" + run->path;
    char *apple[] = {strdup(executable.c_str()), nullptr};
    int code = run->main(run->argc, run->argv, run->envp, apple);
    finish(run, code, nullptr);
    return nullptr;
}

char *copyString(NSString *text) { return strdup(text.UTF8String ?: ""); }

void noSigpipe(int fd) {
    int on = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
}

/// Starts a program for a {"run"} request; its descriptors and exit go back over `control`.
Run *start(NSDictionary *request, int control, std::string &error) {
    NSString *path = request[@"run"];
    if (![path isKindOfClass:[NSString class]] || ![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        error = "There's no such program.";
        return nullptr;
    }
    Run *run = new Run();
    for (auto &fd : run->fds) fd = -1;
    run->path = path.UTF8String;
    run->control = control;

    NSArray *args = [request[@"args"] isKindOfClass:[NSArray class]] ? request[@"args"] : @[];
    run->argc = (int)args.count + 1;
    run->argv = (char **)calloc(args.count + 2, sizeof(char *));
    run->argv[0] = strdup(run->path.c_str());
    for (NSUInteger i = 0; i < args.count; i++) run->argv[i + 1] = copyString([args[i] description]);

    NSDictionary *env = [request[@"env"] isKindOfClass:[NSDictionary class]] ? request[@"env"] : @{};
    if (env.count == 0) env = [NSProcessInfo processInfo].environment;
    run->envp = (char **)calloc(env.count + 1, sizeof(char *));
    NSUInteger index = 0;
    for (NSString *key in env) {
        run->envp[index++] = copyString([NSString stringWithFormat:@"%@=%@", key, [env[key] description]]);
    }

    if (!load(run, error)) return nullptr;   // leaked: small, and its copy may be half-loaded

    // Socket pairs: [0] for Node.js, [1] for the program.
    int pairs[3][2];
    for (int i = 0; i < 3; i++) {
        if (socketpair(AF_UNIX, SOCK_STREAM, 0, pairs[i]) != 0) {
            error = "Couldn't connect the program's input and output.";
            return nullptr;
        }
        noSigpipe(pairs[i][0]);
        noSigpipe(pairs[i][1]);
        run->fds[i] = pairs[i][1];
    }
    shutdown(pairs[0][1], SHUT_WR);   // the program only reads stdin

    NSString *cwd = request[@"cwd"];
    if ([cwd isKindOfClass:[NSString class]] && cwd.length) chdir(cwd.UTF8String);

    {
        std::lock_guard<std::mutex> lock(g_runsLock);
        int count = g_runCount.load();
        if (count >= kMaxRuns) {
            error = "Too many programs have run; restart Mobile Studio.";
            return nullptr;
        }
        g_runs[count] = run;
        g_runCount.store(count + 1, std::memory_order_release);
    }
    sendLine(run, @{@"fds": @[@(pairs[0][0]), @(pairs[1][0]), @(pairs[2][0])]});

    pthread_attr_t attributes;
    pthread_attr_init(&attributes);
    pthread_attr_setstacksize(&attributes, 8 << 20);   // a program's main thread gets 8 MB
    pthread_attr_setdetachstate(&attributes, PTHREAD_CREATE_DETACHED);
    pthread_t thread;
    if (pthread_create(&thread, &attributes, programThread, run) != 0) finish(run, 1, "Couldn't start a thread for it.");
    pthread_attr_destroy(&attributes);
    return run;
}

void *serve(void *argument) {
    int fd = (int)(intptr_t)argument;
    noSigpipe(fd);
    Run *run = nullptr;
    std::string buffer;
    char chunk[4096];
    while (true) {
        ssize_t n = read(fd, chunk, sizeof(chunk));
        if (n <= 0) break;
        buffer.append(chunk, (size_t)n);
        size_t newline;
        while ((newline = buffer.find('\n')) != std::string::npos) {
            NSData *data = [NSData dataWithBytes:buffer.data() length:newline];
            buffer.erase(0, newline + 1);
            NSDictionary *message = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if (![message isKindOfClass:[NSDictionary class]]) continue;
            if (message[@"run"] && !run) {
                std::string error;
                @autoreleasepool { run = start(message, fd, error); }
                if (!run) {
                    NSString *text = [NSString stringWithUTF8String:error.c_str()] ?: @"It couldn't start.";
                    NSData *reply = [NSJSONSerialization dataWithJSONObject:@{@"error": text} options:0 error:nil];
                    write(fd, reply.bytes, reply.length);
                    write(fd, "\n", 1);
                }
            } else if (message[@"kill"] && run) {
                finish(run, 143, nullptr);
            }
        }
    }
    if (run) {
        finish(run, 143, nullptr);
        std::lock_guard<std::mutex> lock(run->controlLock);
        run->control = -1;
    }
    close(fd);
    return nullptr;
}

int g_port = 0;
std::mutex g_portLock;

}  // namespace

extern "C" void dc_native_tools_set_certificate(const void *p12, size_t length, const char *password) {
    std::lock_guard<std::mutex> lock(g_certificateLock);
    g_certificate = p12 && length ? [NSData dataWithBytes:p12 length:length] : nil;
    g_password = password ? @(password) : @"";
}

extern "C" int dc_native_tools_sign_library(const char *path, const char *identifier, char *error, size_t capacity) {
    NSData *certificate;
    NSString *password;
    {
        std::lock_guard<std::mutex> lock(g_certificateLock);
        certificate = g_certificate;
        password = g_password;
    }
    if (!certificate.length) {
        snprintf(error, capacity, "%s", "Compiled modules need your signing certificate: import it in Settings > Programs from Extensions.");
        return 3;
    }
    return dc_sign_library(path, identifier, (const uint8_t *)certificate.bytes, certificate.length, password.UTF8String ?: "", error, capacity);
}

extern "C" int dc_native_tools_certificate_team(const void *p12, size_t length, const char *password, char *out, size_t capacity) {
    return dc_certificate_team((const uint8_t *)p12, length, password ?: "", out, capacity);
}

extern "C" int dc_native_tools_start(void) {
    std::lock_guard<std::mutex> lock(g_portLock);
    if (g_port) return g_port;
    int listener = socket(AF_INET, SOCK_STREAM, 0);
    if (listener < 0) return 0;
    struct sockaddr_in address = {};
    address.sin_len = sizeof(address);
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = inet_addr("127.0.0.1");
    socklen_t length = sizeof(address);
    if (bind(listener, (struct sockaddr *)&address, sizeof(address)) != 0 || listen(listener, 16) != 0 ||
        getsockname(listener, (struct sockaddr *)&address, &length) != 0) {
        close(listener);
        return 0;
    }
    g_port = ntohs(address.sin_port);
    pthread_t thread;
    pthread_create(&thread, nullptr, [](void *argument) -> void * {
        int listener = (int)(intptr_t)argument;
        while (true) {
            int connection = accept(listener, nullptr, nullptr);
            if (connection < 0) {
                if (errno == EINTR || errno == ECONNABORTED) continue;
                usleep(100 * 1000);
                continue;
            }
            pthread_t worker;
            if (pthread_create(&worker, nullptr, serve, (void *)(intptr_t)connection) == 0) pthread_detach(worker);
            else close(connection);
        }
        return nullptr;
    }, (void *)(intptr_t)listener);
    pthread_detach(thread);
    return g_port;
}
