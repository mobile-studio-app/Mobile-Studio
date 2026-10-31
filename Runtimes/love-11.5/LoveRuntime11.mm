#import "../common/LoveAdapter.h"
#import <UIKit/UIKit.h>

// LÖVE 11.5 is not bundled yet; only the 12.0 runtime links the real engine.
static int love11_run_game(const char *project_dir, int enable_jit) {
    (void)project_dir; (void)enable_jit;
    dc_love_log(DC_LOG_WARN, "LÖVE 11.5 is not bundled in this build yet. Remove t.version = \"11.5\" from conf.lua to use LÖVE 12.0.");
    return 1;
}

static const dc_love_config kLove11Config = {
    .runtime_id = "love-11.5",
    .display_name = "LÖVE 11.5",
    .version = "11.5",
    .run_game = love11_run_game,
    .request_quit = NULL,
    .container_changed = NULL,
    .set_focus = NULL,
};

DC_EXPORT const dc_runtime *duocode_runtime_entry(void) {
    return dc_create_love_runtime(&kLove11Config);
}
