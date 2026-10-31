/*
 * ConsoleAdapter.h — Shared adapter for console runtimes (plain Lua, Python)
 *
 * The adapter implements the duocode_runtime ABI for programs that print to the
 * console and read console input instead of drawing in the game pane. The
 * program runs on its own thread with a large stack while `run` keeps the main
 * run loop turning, so the IDE stays responsive and a program waiting for input
 * blocks only its own thread. Output is sent to the host on the main thread, a
 * line at a time.
 */
#ifndef DUOCODE_CONSOLE_ADAPTER_H
#define DUOCODE_CONSOLE_ADAPTER_H

#include <stddef.h>
#include "duocode_runtime.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct dc_console_config {
    const char *runtime_id;
    const char *display_name;
    const char *version;
    /* Runs the program in `project_dir` on the program thread; returns its exit code. */
    int (*run_program)(const char *project_dir);
    /* Called on the main thread when the user stops the program. dc_console_should_stop()
     * is already true; use this to break out of the interpreter (may be NULL). */
    void (*interrupt)(void);
    /* 1 for runtimes without a debugger (Start Debugging is refused). */
    int no_debugger;
} dc_console_config;

const dc_runtime *dc_create_console_runtime(const dc_console_config *config);

/* Services for the interpreter glue; callable from any thread. */
void dc_console_log(dc_log_level level, const char *message);
/* Program output (stdout/stderr). Split into lines; a partial line waits for its newline,
 * or for dc_console_flush (done before every read, so prompts show). */
void dc_console_write(dc_log_level level, const char *text, size_t length);
void dc_console_flush(void);
void dc_console_report_error(const char *message, const char *file, int line);
/* Blocks the program thread until a line is typed into the console. Returns the line without
 * its newline (free() it), or NULL once the program is being stopped. */
char *dc_console_read_line(void);
int dc_console_should_stop(void);
/* 1 when the run is an interactive session (a REPL) rather than the project's program. */
int dc_console_is_repl(void);
/* The value of a run argument "<prefix><value>" (e.g. "--node-port="), or NULL. */
const char *dc_console_option(const char *prefix);

#ifdef __cplusplus
}
#endif

#endif /* DUOCODE_CONSOLE_ADAPTER_H */
