#import "DebugChannel.h"
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <atomic>
#include <string>

static const dc_host_api *g_host = NULL;
static NSCondition *g_lock;
static NSMutableArray<NSString *> *g_commands;
static std::atomic<bool> g_active{false};
static std::string g_config;
static std::string g_resource;

void dc_debug_setup(const dc_host_api *host) {
    g_host = host;
    if (!g_lock) {
        g_lock = [NSCondition new];
        g_commands = [NSMutableArray array];
    }
}

void dc_debug_begin(const char *config_json) {
    [g_lock lock];
    [g_commands removeAllObjects];
    g_config = config_json ? config_json : "";
    g_active = config_json != NULL;
    [g_lock unlock];
}

void dc_debug_end(void) {
    [g_lock lock];
    g_active = false;
    [g_lock broadcast];
    [g_lock unlock];
    CFRunLoopWakeUp(CFRunLoopGetMain());
}

int dc_debug_active(void) {
    return g_active ? 1 : 0;
}

const char *dc_debug_config(void) {
    return g_active ? g_config.c_str() : NULL;
}

const char *dc_debug_resource_path(const char *name) {
    Dl_info info;
    if (!dladdr((const void *)&dc_debug_resource_path, &info) || !info.dli_fname) return NULL;
    NSString *binary = [NSString stringWithUTF8String:info.dli_fname];
    NSString *path = [[binary stringByDeletingLastPathComponent] stringByAppendingPathComponent:@(name)];
    g_resource = path.fileSystemRepresentation;
    return g_resource.c_str();
}

void dc_debug_command(const char *json) {
    if (!json || !g_lock) return;
    [g_lock lock];
    [g_commands addObject:[NSString stringWithUTF8String:json] ?: @"{}"];
    [g_lock signal];
    [g_lock unlock];
    CFRunLoopWakeUp(CFRunLoopGetMain());
}

void dc_debug_send(const char *json) {
    if (!json || !g_host || g_host->abi_version < 3 || !g_host->debug_event) return;
    if ([NSThread isMainThread]) {
        g_host->debug_event(g_host->ctx, json);
        return;
    }
    // In order with the program's other messages: the main queue is drained by the run loop
    // the runtime keeps turning.
    std::string copy(json);
    const dc_host_api *host = g_host;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (g_host == host && host->debug_event) host->debug_event(host->ctx, copy.c_str());
    });
}

static NSString *take_command(void) {
    if (g_commands.count == 0) return nil;
    NSString *command = g_commands.firstObject;
    [g_commands removeObjectAtIndex:0];
    return command;
}

char *dc_debug_receive(double timeout) {
    if (!g_lock) return NULL;
    NSDate *deadline = timeout < 0 ? [NSDate distantFuture] : [NSDate dateWithTimeIntervalSinceNow:timeout];
    NSString *command = nil;
    if ([NSThread isMainThread]) {
        // Paused on the main thread (LÖVE): keep the IDE responsive while waiting.
        while (true) {
            [g_lock lock];
            command = take_command();
            bool done = command || !g_active;
            [g_lock unlock];
            if (done || timeout == 0 || [deadline timeIntervalSinceNow] <= 0) break;
            @autoreleasepool {
                CFRunLoopRunInMode(kCFRunLoopDefaultMode, MIN(0.05, MAX(0.001, [deadline timeIntervalSinceNow])), true);
            }
        }
    } else {
        [g_lock lock];
        while (!(command = take_command()) && g_active && timeout != 0) {
            if (![g_lock waitUntilDate:deadline]) break;
        }
        [g_lock unlock];
    }
    return command ? strdup(command.UTF8String) : NULL;
}
