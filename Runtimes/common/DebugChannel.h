/*
 * DebugChannel.h — The runtime side of DuoCode's debugger
 *
 * Every runtime speaks the same protocol: JSON messages. The host sends commands
 * (dc_runtime.debug_command: setBreakpoints, continue, next, stepIn, stepOut, pause,
 * scopes, variables, evaluate); the runtime's debugger answers and reports events
 * (stopped, continued, output) through dc_host_api.debug_event.
 *
 * The debugger itself runs in the program's language (duocode_debugger.lua for Lua and
 * LÖVE, a bdb debugger for Python) and talks through dc_debug_send/dc_debug_receive.
 * While the program is paused its thread waits in dc_debug_receive; on the main thread
 * (LÖVE) the wait keeps the run loop turning so the IDE stays usable.
 */
#ifndef DUOCODE_DEBUG_CHANNEL_H
#define DUOCODE_DEBUG_CHANNEL_H

#include "duocode_runtime.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Called from the runtime's `initialize`. */
void dc_debug_setup(const dc_host_api *host);
/* Called at the start of `run` with dc_run_options.debug_config (NULL when not debugging). */
void dc_debug_begin(const char *config_json);
/* Called when `run` ends, and on request_stop: wakes a paused program (dc_debug_receive
 * returns NULL) so it can finish. */
void dc_debug_end(void);
int dc_debug_active(void);
/* The configuration JSON from dc_debug_begin, or NULL. */
const char *dc_debug_config(void);
/* The path of a resource next to this runtime's binary (e.g. "duocode_debugger.lua"). */
const char *dc_debug_resource_path(const char *name);

/* dc_runtime.debug_command: queues a command for the debugger. Main thread. */
void dc_debug_command(const char *json);
/* Sends an event or reply to the host. Any thread. */
void dc_debug_send(const char *json);
/* The next command (free() it). Waits up to `timeout` seconds (negative: until one comes,
 * 0: doesn't wait). Returns NULL on timeout or once the run is ending. */
char *dc_debug_receive(double timeout);

#ifdef __cplusplus
}
#endif

#endif /* DUOCODE_DEBUG_CHANNEL_H */
