/*
 * LoveAdapter.h — Shared embedding adapter for LÖVE runtimes (11.5 / 12.0)
 *
 * The adapter implements the duocode_runtime ABI (state changes, logging,
 * error reporting). Each runtime supplies the engine glue below: booting
 * LÖVE for a project folder, quitting it, and keeping its view over the
 * host's game pane.
 */
#ifndef DUOCODE_LOVE_ADAPTER_H
#define DUOCODE_LOVE_ADAPTER_H

#import <UIKit/UIKit.h>
#include "duocode_runtime.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct dc_love_config {
    const char *runtime_id;
    const char *display_name;
    const char *version;
    /* Runs the game in `project_dir` until it quits. Blocks; the engine pumps the run loop. */
    int (*run_game)(const char *project_dir, int enable_jit);
    /* Ask the running game to quit; run_game returns soon after. */
    void (*request_quit)(void);
    /* The host's game pane moved or resized; keep the game's view over it. */
    void (*container_changed)(UIView *container);
    /* Input focus moved to (1) / away from (0) the game. */
    void (*set_focus)(int focused);
} dc_love_config;

const dc_runtime *dc_create_love_runtime(const dc_love_config *config);

/* Services for the engine glue. */
void dc_love_log(dc_log_level level, const char *message);
void dc_love_report_error(const char *message, const char *file, int line);
UIView *dc_love_container(void);

#ifdef __cplusplus
}
#endif

#endif /* DUOCODE_LOVE_ADAPTER_H */
