/*
 * duocode_runtime.h — DuoCode runtime plugin ABI (v3)
 *
 * Each runtime (LÖVE 11.5, LÖVE 12.0, ...) is an embedded .framework that the
 * host loads with dlopen(RTLD_LOCAL). The framework must export exactly ONE
 * public symbol: `duocode_runtime_entry`. Everything else (SDL, LuaJIT, ...)
 * must be built with hidden visibility so multiple runtimes can coexist in
 * one app bundle. Only one runtime may be *running* at a time.
 *
 * Threading: every function is called on the main thread.
 *
 * Run model: `run` BLOCKS on the main thread for the lifetime of the game.
 * The runtime MUST pump the main CFRunLoop every frame (SDL_PumpEvents does
 * this on iOS), so the IDE remains fully interactive while the game runs.
 * `run` returns when the game quits or after `request_stop` was called.
 *
 * Kinds (runtime.json "kind"): "game" runtimes render into the game pane;
 * "console" runtimes (plain Lua, Python) run a program whose output goes to
 * the console and which reads console input through `send_input`.
 *
 * v2: adds `send_input`.
 * v3: adds debugging: `debug_event`, `dc_run_options.debug_config` and `debug_command`
 *     (see Runtimes/common/DebugChannel.h for the protocol).
 */
#ifndef DUOCODE_RUNTIME_H
#define DUOCODE_RUNTIME_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define DC_RUNTIME_ABI_VERSION 3
#define DC_EXPORT __attribute__((visibility("default")))

typedef enum dc_log_level {
    DC_LOG_DEBUG = 0,
    DC_LOG_INFO  = 1,
    DC_LOG_WARN  = 2,
    DC_LOG_ERROR = 3,
    DC_LOG_GAME  = 4   /* output from the game itself, e.g. Lua print() */
} dc_log_level;

typedef enum dc_runtime_state {
    DC_STATE_IDLE     = 0,
    DC_STATE_STARTING = 1,
    DC_STATE_RUNNING  = 2,
    DC_STATE_STOPPING = 3,
    DC_STATE_STOPPED  = 4,
    DC_STATE_ERRORED  = 5
} dc_runtime_state;

/* Services the host provides to the runtime. */
typedef struct dc_host_api {
    uint32_t abi_version;           /* == DC_RUNTIME_ABI_VERSION */
    void *ctx;                      /* opaque, pass back to every callback */

    void (*log)(void *ctx, dc_log_level level, const char *message);
    void (*on_state)(void *ctx, dc_runtime_state state);
    /* Script error with optional location (file may be NULL, line may be 0). */
    void (*on_error)(void *ctx, const char *message, const char *file, int line);

    /* UIView* (bridged as void*) into which the runtime must place its
     * rendering view. The runtime must size its view to this container and
     * follow `container_resized` notifications. */
    void *(*container_view)(void *ctx);

    /* 1 if the process can map executable memory (debugger/JIT enabler
     * attached), else 0. Runtimes using LuaJIT should call jit.off() when 0. */
    int (*jit_available)(void *ctx);

    /* 1 if the game pane currently owns keyboard/mouse/controller input. */
    int (*has_input_focus)(void *ctx);

    /* v3: a debugger event or reply (JSON). Main thread. */
    void (*debug_event)(void *ctx, const char *json);
} dc_host_api;

typedef struct dc_run_options {
    const char *project_dir;        /* absolute path to the game folder */
    const char *const *argv;        /* extra args (may be NULL) */
    int argc;
    int enable_jit;                 /* host's decision (jit_available && user setting) */
    /* v3: JSON debugger configuration (breakpoints, stopOnErrors), or NULL to run
     * without debugging. */
    const char *debug_config;
} dc_run_options;

/* The runtime's vtable. */
typedef struct dc_runtime {
    uint32_t abi_version;           /* == DC_RUNTIME_ABI_VERSION */
    const char *id;                 /* "love-11.5" */
    const char *display_name;       /* "LÖVE 11.5" */
    const char *version;            /* runtime implementation version */

    /* Called once after dlopen. Return 0 on success. */
    int  (*initialize)(const dc_host_api *host);

    /* Blocking. Return process-style exit code (0 = clean). */
    int  (*run)(const dc_run_options *options);

    /* Ask a running game to quit; `run` returns soon after. */
    void (*request_stop)(void);

    /* Input focus moved to (1) / away from (0) the game pane. */
    void (*set_input_focus)(int focused);

    /* Container view changed size (points) / scale. */
    void (*container_resized)(double width, double height, double scale);

    /* Called before the host unloads/forgets the runtime. */
    void (*shutdown)(void);

    /* A line typed into the console (UTF-8, no trailing newline), for the
     * running program's stdin. NULL for runtimes that don't read input. */
    void (*send_input)(const char *line);

    /* v3: a debugger command (JSON). NULL for runtimes that can't debug. */
    void (*debug_command)(const char *json);
} dc_runtime;

typedef const dc_runtime *(*dc_runtime_entry_fn)(void);

/* The single exported symbol of every runtime framework. */
DC_EXPORT const dc_runtime *duocode_runtime_entry(void);

#ifdef __cplusplus
}
#endif

#endif /* DUOCODE_RUNTIME_H */
