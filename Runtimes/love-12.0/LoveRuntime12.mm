// LÖVE 12 engine glue.
//
// Runs LÖVE's boot sequence (the same steps as love.cpp's runlove) against the
// project folder, routes print() to the host, installs duocode_hooks.lua (error
// reporting, shader compatibility, window size tracking), and keeps SDL's game
// UIWindow lined up with the host's game pane, just below the host's window.
#import "../common/LoveAdapter.h"
#import "../common/DebugChannel.h"
#import <UIKit/UIKit.h>

#define SDL_MAIN_HANDLED
#include <SDL3/SDL.h>
#include <SDL3/SDL_main.h>

#include <string>

extern "C" {
#include "lua.h"
#include "lualib.h"
#include "lauxlib.h"
}
#include "modules/love/love.h"

static __weak UIWindow *g_gameWindow;
static id g_windowObserver;

// The window size the game asked for (conf.lua, love.window.setMode/updateMode). A fixed-size
// game gets exactly that window, scaled to fit the pane; resizable and fullscreen games fill it.
static double g_modeWidth = 0, g_modeHeight = 0;
static bool g_modeFills = true;

// MARK: - Game window placement

/// Returns SDL's UIWindow if `candidate` is one (or any SDL window when nil).
static UIWindow *sdl_uikit_window(UIWindow *candidate) {
    int count = 0;
    SDL_Window **windows = SDL_GetWindows(&count);
    UIWindow *found = nil;
    if (windows) {
        for (int i = 0; i < count && !found; i++) {
            SDL_PropertiesID props = SDL_GetWindowProperties(windows[i]);
            UIWindow *w = (__bridge UIWindow *)SDL_GetPointerProperty(props, SDL_PROP_WINDOW_UIKIT_WINDOW_POINTER, NULL);
            if (w && (!candidate || w == candidate)) found = w;
        }
        SDL_free(windows);
    }
    return found;
}

static void love12_container_changed(UIView *container) {
    UIWindow *game = g_gameWindow;
    UIWindow *host = container.window;
    if (!game || !host) return;
    // Window coordinates of a full-screen host window match the scene's, which UIWindow.frame uses.
    CGRect frame = [container convertRect:container.bounds toView:nil];
    // Below the host window, which leaves the game pane transparent and passes its touches
    // through: the host's sheets, alerts and menus then cover the game, as they should.
    game.windowLevel = host.windowLevel - 1;
    game.hidden = container.alpha < 0.01 || container.hidden;
    game.transform = CGAffineTransformIdentity;
    if (g_modeFills || g_modeWidth <= 0 || g_modeHeight <= 0 || frame.size.width <= 0 || frame.size.height <= 0) {
        game.frame = frame;
        return;
    }
    // Keep the game's own resolution (and coordinates), scaled to fit with its aspect ratio.
    CGFloat scale = MIN(frame.size.width / g_modeWidth, frame.size.height / g_modeHeight);
    game.frame = CGRectMake(0, 0, g_modeWidth, g_modeHeight);
    game.center = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
    game.transform = CGAffineTransformMakeScale(scale, scale);
}

static void love12_set_focus(int focused) {
    UIWindow *game = g_gameWindow;
    if (!game) return;
    if (focused) {
        [game makeKeyWindow];
    } else {
        [dc_love_container().window makeKeyWindow];
    }
}

static void begin_tracking_game_window(void) {
    g_windowObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:UIWindowDidBecomeVisibleNotification
                    object:nil
                     queue:nil
                usingBlock:^(NSNotification *note) {
        UIWindow *w = sdl_uikit_window(note.object);
        if (!w) return;
        g_gameWindow = w;
        love12_container_changed(dc_love_container());
    }];
}

static void end_tracking_game_window(void) {
    if (g_windowObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:g_windowObserver];
        g_windowObserver = nil;
    }
    g_gameWindow = nil;
    g_modeWidth = g_modeHeight = 0;
    g_modeFills = true;
    [dc_love_container().window makeKeyWindow];
}

// MARK: - Lua hooks

/// print() replacement: tab-joined tostring() of each argument, sent to the host console.
static int dc_lua_print(lua_State *L) {
    int n = lua_gettop(L);
    std::string line;
    lua_getglobal(L, "tostring");
    for (int i = 1; i <= n; i++) {
        lua_pushvalue(L, -1);
        lua_pushvalue(L, i);
        lua_call(L, 1, 1);
        size_t len = 0;
        const char *s = lua_tolstring(L, -1, &len);
        if (!s) return luaL_error(L, "'tostring' must return a string to 'print'");
        if (i > 1) line += '\t';
        line.append(s, len);
        lua_pop(L, 1);
    }
    lua_pop(L, 1);
    dc_love_log(DC_LOG_GAME, line.c_str());
    return 0;
}

static int dc_lua_report_error(lua_State *L) {
    const char *message = luaL_optstring(L, 1, "unknown error");
    const char *file = lua_isstring(L, 2) ? lua_tostring(L, 2) : NULL;
    int line = (int)luaL_optinteger(L, 3, 0);
    dc_love_report_error(message, file, line);
    return 0;
}

static int dc_lua_warn(lua_State *L) {
    dc_love_log(DC_LOG_WARN, luaL_checkstring(L, 1));
    return 0;
}

/// setGameMode(width, height, fills) from duocode_hooks.lua after the game sets its window mode.
static int dc_lua_set_game_mode(lua_State *L) {
    g_modeWidth = luaL_optnumber(L, 1, 0);
    g_modeHeight = luaL_optnumber(L, 2, 0);
    g_modeFills = lua_toboolean(L, 3);
    if ([NSThread isMainThread]) {
        love12_container_changed(dc_love_container());
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{ love12_container_changed(dc_love_container()); });
    }
    return 0;
}

// The debugger's channel (duocode_debugger.lua).
static int dc_lua_debug_send(lua_State *L) {
    dc_debug_send(luaL_checkstring(L, 1));
    return 0;
}

static int dc_lua_debug_receive(lua_State *L) {
    char *message = dc_debug_receive(luaL_optnumber(L, 1, -1));
    if (!message) {
        lua_pushnil(L);
        return 1;
    }
    lua_pushstring(L, message);
    free(message);
    return 1;
}

/// Loads duocode_debugger.lua when this run is debugged. Returns a registry reference to the
/// debugger table, or LUA_NOREF.
static int start_debugger(lua_State *L) {
    if (!dc_debug_active()) return LUA_NOREF;
    const char *path = dc_debug_resource_path("duocode_debugger.lua");
    if (!path || luaL_loadfile(L, path) != 0) {
        std::string msg = std::string("The debugger couldn't start: ") + (path ? (lua_tostring(L, -1) ?: "?") : "duocode_debugger.lua is missing");
        dc_love_log(DC_LOG_ERROR, msg.c_str());
        if (path) lua_pop(L, 1);
        return LUA_NOREF;
    }
    lua_pushcfunction(L, dc_lua_debug_send);
    lua_pushcfunction(L, dc_lua_debug_receive);
    lua_pushstring(L, "");   // LÖVE names sources relative to the game folder already
    lua_pushstring(L, dc_debug_config());
    if (lua_pcall(L, 4, 1, 0) != 0) {
        std::string msg = std::string("The debugger couldn't start: ") + (lua_tostring(L, -1) ?: "?");
        dc_love_log(DC_LOG_ERROR, msg.c_str());
        lua_pop(L, 1);
        return LUA_NOREF;
    }
    return luaL_ref(L, LUA_REGISTRYINDEX);
}

/// debugger.attach(thread)
static void attach_debugger(lua_State *L, int debugger, lua_State *thread) {
    if (debugger == LUA_NOREF) return;
    lua_rawgeti(L, LUA_REGISTRYINDEX, debugger);
    lua_getfield(L, -1, "attach");
    lua_pushthread(thread);
    lua_xmove(thread, L, 1);
    if (lua_pcall(L, 1, 0, 0) != 0) {
        dc_love_log(DC_LOG_ERROR, lua_tostring(L, -1) ?: "The debugger couldn't attach");
        lua_pop(L, 1);
    }
    lua_pop(L, 1);
}

/// Anchors NSBundle lookups to this framework (for duocode_hooks.lua).
@interface DCLove12Bundle : NSObject
@end
@implementation DCLove12Bundle
@end

/// Runs duocode_hooks.lua (error reporting + shader compatibility) with the love table on
/// top of the stack, which it consumes. Without the file the game still runs, unhooked.
static void install_hooks(lua_State *L) {
    NSString *path = [[NSBundle bundleForClass:[DCLove12Bundle class]] pathForResource:@"duocode_hooks" ofType:@"lua"];
    if (!path || luaL_loadfile(L, path.fileSystemRepresentation) != 0) {
        std::string msg = std::string("Mobile Studio hooks unavailable: ") + (path ? (lua_tostring(L, -1) ?: "?") : "duocode_hooks.lua missing");
        dc_love_log(DC_LOG_WARN, msg.c_str());
        lua_pop(L, path ? 2 : 1);  // error message (if any) and the love table
        return;
    }
    lua_insert(L, -2);                         // chunk, love
    lua_pushcfunction(L, dc_lua_report_error);
    lua_pushcfunction(L, dc_lua_warn);
    lua_pushcfunction(L, dc_lua_set_game_mode);
    if (lua_pcall(L, 4, 0, 0) != 0) {
        std::string msg = std::string("Mobile Studio hooks failed: ") + (lua_tostring(L, -1) ?: "?");
        dc_love_log(DC_LOG_WARN, msg.c_str());
        lua_pop(L, 1);
    }
}

static void preload(lua_State *L, lua_CFunction f, const char *name) {
    lua_getglobal(L, "package");
    lua_getfield(L, -1, "preload");
    lua_pushcfunction(L, f);
    lua_setfield(L, -2, name);
    lua_pop(L, 2);
}

/// require(name) in protected mode. Leaves `nresults` values on success.
static bool require(lua_State *L, const char *name, int nresults) {
    lua_getglobal(L, "require");
    lua_pushstring(L, name);
    if (lua_pcall(L, 1, nresults, 0) != 0) {
        std::string msg = std::string("Failed to load ") + name + ": " + (lua_tostring(L, -1) ?: "?");
        dc_love_log(DC_LOG_ERROR, msg.c_str());
        lua_pop(L, 1);
        return false;
    }
    return true;
}

static bool run_chunk(lua_State *L, const char *code, const char *chunkname, int nargs) {
    if (luaL_loadbuffer(L, code, strlen(code), chunkname) != 0) {
        dc_love_log(DC_LOG_ERROR, lua_tostring(L, -1));
        lua_pop(L, 1 + nargs);
        return false;
    }
    lua_insert(L, -(nargs + 1));
    if (lua_pcall(L, nargs, 0, 0) != 0) {
        dc_love_log(DC_LOG_ERROR, lua_tostring(L, -1));
        lua_pop(L, 1);
        return false;
    }
    return true;
}

// MARK: - Boot

enum class BootResult { quit, restart, failed };

/// One pass of LÖVE's boot (love.cpp runlove). `retval` receives the game's exit code.
static BootResult boot_love(const char *project_dir, int enable_jit, int &retval) {
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);

    // LuaJIT tuning first, as love.cpp does, then honour the host's JIT decision.
    preload(L, luaopen_love_jitsetup, "love.jitsetup");
    require(L, "love.jitsetup", 0);
    lua_pushboolean(L, enable_jit);
    run_chunk(L, "local on = ...\nif jit then if on then pcall(jit.on) else jit.off() end end",
              "=[Mobile Studio jit]", 1);

    // Same `arg` layout as stand-alone LÖVE: `love <project_dir>`.
    lua_newtable(L);
    lua_pushstring(L, "love");
    lua_rawseti(L, -2, -2);
    lua_pushstring(L, "embedded boot.lua");
    lua_rawseti(L, -2, -1);
    lua_pushstring(L, project_dir);
    lua_rawseti(L, -2, 1);
    lua_setglobal(L, "arg");

    lua_pushcfunction(L, dc_lua_print);
    lua_setglobal(L, "print");

    preload(L, luaopen_love, "love");
    if (!require(L, "love", 1)) {
        lua_close(L);
        return BootResult::failed;
    }
    lua_pushboolean(L, 1);
    lua_setfield(L, -2, "_exe");
    install_hooks(L);  // consumes the love table

    if (!require(L, "love.boot", 1)) {
        lua_close(L);
        return BootResult::failed;
    }
    int debugger = start_debugger(L);

    // Drive the boot function as a coroutine; it yields once per frame.
    lua_State *co = lua_newthread(L);
    lua_pushvalue(L, -2);
    lua_xmove(L, co, 1);
    attach_debugger(L, debugger, co);
    int status;
    while ((status = lua_resume(co, 0)) == LUA_YIELD) {
        lua_settop(co, 0);
    }

    BootResult result = BootResult::quit;
    retval = 0;
    if (status != 0) {
        dc_love_log(DC_LOG_ERROR, lua_tostring(co, -1) ?: "LÖVE boot failed");
        retval = 1;
    } else if (lua_gettop(co) >= 1) {
        if (lua_type(co, 1) == LUA_TSTRING && strcmp(lua_tostring(co, 1), "restart") == 0) {
            result = BootResult::restart;
        } else if (lua_isnumber(co, 1)) {
            retval = (int)lua_tonumber(co, 1);
        }
    }

    lua_close(L);
    return result;
}

static int love12_run_game(const char *project_dir, int enable_jit) {
    SDL_SetMainReady();
    // Without this SDL locks orientation to the game's window shape, rotating the whole IDE.
    SDL_SetHintWithPriority(SDL_HINT_ORIENTATIONS, "LandscapeLeft LandscapeRight Portrait PortraitUpsideDown", SDL_HINT_OVERRIDE);

    begin_tracking_game_window();

    int retval = 0;
    BootResult result;
    do {
        result = boot_love(project_dir, enable_jit, retval);
    } while (result == BootResult::restart);

    end_tracking_game_window();
    SDL_Quit();
    return result == BootResult::failed ? 1 : retval;
}

static void love12_request_quit(void) {
    SDL_Event e;
    SDL_zero(e);
    e.type = SDL_EVENT_QUIT;
    SDL_PushEvent(&e);
}

static const dc_love_config kLove12Config = {
    .runtime_id = "love-12.0",
    .display_name = "LÖVE 12.0",
    .version = "12.0",
    .run_game = love12_run_game,
    .request_quit = love12_request_quit,
    .container_changed = love12_container_changed,
    .set_focus = love12_set_focus,
};

DC_EXPORT const dc_runtime *duocode_runtime_entry(void) {
    return dc_create_love_runtime(&kLove12Config);
}
