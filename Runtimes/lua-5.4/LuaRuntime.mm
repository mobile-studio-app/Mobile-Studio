// Standard Lua 5.4 as a console runtime: runs the project's main.lua with print and io
// wired to DuoCode's console (io.read reads what's typed into it).

#import <Foundation/Foundation.h>
#include <string>
#include <unistd.h>
#include "ConsoleAdapter.h"
#include "DebugChannel.h"

extern "C" {
#include "lua/lua.h"
#include "lua/lualib.h"
#include "lua/lauxlib.h"
}

static int lua_print(lua_State *L) {
    int n = lua_gettop(L);
    std::string line;
    for (int i = 1; i <= n; i++) {
        size_t length = 0;
        const char *s = luaL_tolstring(L, i, &length);
        if (i > 1) line += '\t';
        line.append(s, length);
        lua_pop(L, 1);
    }
    line += '\n';
    dc_console_write(DC_LOG_GAME, line.data(), line.size());
    return 0;
}

/// io.write / io.stdout:write / io.stderr:write: strings and numbers, no newline added.
static int write_values(lua_State *L, int first, dc_log_level level) {
    int n = lua_gettop(L);
    for (int i = first; i <= n; i++) {
        size_t length = 0;
        const char *s = luaL_checklstring(L, i, &length);
        dc_console_write(level, s, length);
    }
    return 0;
}

static int lua_write(lua_State *L) { return write_values(L, 1, DC_LOG_GAME); }

/// read_line(): the next line typed into the console, or nil once the program is stopping.
static int lua_read_line(lua_State *L) {
    char *line = dc_console_read_line();
    if (!line) {
        lua_pushnil(L);
        return 1;
    }
    lua_pushstring(L, line);
    free(line);
    return 1;
}

/// Checked between instructions so Stop ends loops that never read input.
static void stop_hook(lua_State *L, lua_Debug *) {
    if (dc_console_should_stop()) luaL_error(L, "stopped");
}

// The debugger's channel (duocode_debugger.lua).
static int debug_send(lua_State *L) {
    dc_debug_send(luaL_checkstring(L, 1));
    return 0;
}

static int debug_receive(lua_State *L) {
    char *message = dc_debug_receive(luaL_optnumber(L, 1, -1));
    if (!message) {
        lua_pushnil(L);
        return 1;
    }
    lua_pushstring(L, message);
    free(message);
    return 1;
}

static int debug_should_stop(lua_State *L) {
    lua_pushboolean(L, dc_console_should_stop());
    return 1;
}

/// Loads duocode_debugger.lua and attaches it to the main thread. Leaves its message handler on
/// the stack (for lua_pcall), or nothing if it couldn't start.
static bool start_debugger(lua_State *L, const char *project_dir) {
    const char *path = dc_debug_resource_path("duocode_debugger.lua");
    if (!path || luaL_loadfile(L, path) != LUA_OK) {
        std::string message = std::string("The debugger couldn't start: ") + (path ? lua_tostring(L, -1) : "duocode_debugger.lua is missing");
        dc_console_log(DC_LOG_ERROR, message.c_str());
        if (path) lua_pop(L, 1);
        return false;
    }
    lua_pushcfunction(L, debug_send);
    lua_pushcfunction(L, debug_receive);
    lua_pushstring(L, project_dir);
    lua_pushstring(L, dc_debug_config());
    lua_pushcfunction(L, debug_should_stop);
    if (lua_pcall(L, 5, 1, 0) != LUA_OK) {
        std::string message = std::string("The debugger couldn't start: ") + (lua_tostring(L, -1) ?: "?");
        dc_console_log(DC_LOG_ERROR, message.c_str());
        lua_pop(L, 1);
        return false;
    }
    lua_getfield(L, -1, "attach");
    lua_call(L, 0, 0);
    lua_getfield(L, -1, "handler");
    lua_remove(L, -2);
    return true;
}

static int traceback(lua_State *L) {
    const char *message = lua_tostring(L, 1);
    luaL_traceback(L, L, message ? message : "(error object is not a string)", 1);
    return 1;
}

// Routes io.read, io.write and the standard handles through the console. Formats follow
// io.read: "l"/"L" lines, "n" a number; "a" reads one line (there's no end of input).
static const char *kPrelude = R"LUA(
local readLine, write, project = ...
local function readOne(fmt)
  fmt = type(fmt) == 'string' and fmt:gsub('^%*', '') or fmt
  if fmt == 'n' then
    local line = readLine()
    return line and tonumber(line)
  end
  local line = readLine()
  if line and (fmt == 'L') then line = line .. '\n' end
  return line
end
io.read = function(...)
  local n = select('#', ...)
  if n == 0 then return readOne('l') end
  local out = {}
  for i = 1, n do out[i] = readOne((select(i, ...))) end
  return table.unpack(out, 1, n)
end
io.write = function(...)
  write(...)
  return io.stdout
end
local stdin, stdout = io.stdin, io.stdout
local console = setmetatable({}, { __index = function(_, k)
  if k == 'write' then return function(self, ...) write(...); return self end end
  if k == 'read' then return function(_, ...) return io.read(...) end end
  if k == 'lines' then return function() return function() return readLine() end end end
  local v = stdout[k]
  if type(v) == 'function' then return function(_, ...) return v(stdout, ...) end end
  return v
end })
io.stdout, io.stderr, io.stdin = console, console, console
io.lines = function(file, ...)
  if file == nil then return function() return readLine() end end
  local handle = assert(io.open(file, 'r'))
  return handle:lines(...)
end
package.path = project .. '/?.lua;' .. project .. '/?/init.lua;' .. package.path
arg = { [0] = 'main.lua' }
)LUA";

// The interactive session: each line runs as Lua, an expression's value is printed, and an
// unfinished statement (a function, a loop) carries on over the next lines, as in lua.c.
static const char *kREPL = R"LUA(
-- The console's input field is the prompt, so none is printed.
local readLine = ...
local load, pack, unpack = load, table.pack, table.unpack
print(_VERSION .. ' in Mobile Studio. Type Lua and press Return; Stop ends the session.')
while true do
  local chunk = readLine()
  if not chunk then break end
  local function compile(code)
    local f, err = load('return ' .. code, '=stdin')
    if not f then f, err = load(code, '=stdin') end
    return f, err
  end
  local f, err = compile(chunk)
  while not f and err and err:find('<eof>', 1, true) do
    local more = readLine()
    if not more then break end
    chunk = chunk .. '\n' .. more
    f, err = compile(chunk)
  end
  if not f then
    print(err)
  else
    local results = pack(pcall(f))
    if not results[1] then
      print(results[2])
    elseif results.n > 1 then
      print(unpack(results, 2, results.n))
    end
  end
end
)LUA";

static int run_program(const char *project_dir) {
    lua_State *L = luaL_newstate();
    if (!L) {
        dc_console_log(DC_LOG_ERROR, "Lua couldn't start (out of memory).");
        return 1;
    }
    luaL_openlibs(L);
    lua_pushcfunction(L, lua_print);
    lua_setglobal(L, "print");

    // Relative paths in io.open and require resolve against the project, as when run with `lua main.lua`.
    char previous[PATH_MAX];
    bool hadCwd = getcwd(previous, sizeof(previous)) != NULL;
    chdir(project_dir);

    int code = 0;
    if (luaL_loadbuffer(L, kPrelude, strlen(kPrelude), "=[Mobile Studio]") != LUA_OK) {
        dc_console_log(DC_LOG_ERROR, lua_tostring(L, -1));
        code = 1;
    } else {
        lua_pushcfunction(L, lua_read_line);
        lua_pushcfunction(L, lua_write);
        lua_pushstring(L, project_dir);
        if (lua_pcall(L, 3, 0, 0) != LUA_OK) {
            dc_console_log(DC_LOG_ERROR, lua_tostring(L, -1));
            code = 1;
        }
    }

    // The debugger's hook checks for Stop itself; otherwise a count hook does.
    bool debugging = code == 0 && dc_debug_active() && start_debugger(L, project_dir);
    if (!debugging) lua_sethook(L, stop_hook, LUA_MASKCOUNT, 10000);

    if (code == 0 && dc_console_is_repl()) {
        if (luaL_loadbuffer(L, kREPL, strlen(kREPL), "=[REPL]") != LUA_OK) {
            dc_console_log(DC_LOG_ERROR, lua_tostring(L, -1));
        } else {
            lua_pushcfunction(L, lua_read_line);
            if (lua_pcall(L, 1, 0, 0) != LUA_OK && !dc_console_should_stop()) dc_console_log(DC_LOG_ERROR, lua_tostring(L, -1));
        }
        lua_close(L);
        if (hadCwd) chdir(previous);
        return 0;
    }

    if (code == 0) {
        if (!debugging) lua_pushcfunction(L, traceback);
        if (luaL_loadfile(L, "main.lua") != LUA_OK) {
            const char *message = lua_tostring(L, -1);
            dc_console_log(DC_LOG_ERROR, message);
            dc_console_report_error(message, NULL, 0);
            code = 1;
        } else if (lua_pcall(L, 0, 0, -2) != LUA_OK) {
            std::string message = lua_tostring(L, -1) ?: "error";
            if (dc_console_should_stop()) {
                dc_console_log(DC_LOG_INFO, "Stopped.");
            } else {
                dc_console_log(DC_LOG_ERROR, message.c_str());
                // "main.lua:12: message" -> file and line for the editor.
                std::string first = message.substr(0, message.find('\n'));
                std::string file;
                int line = 0;
                size_t lua = first.find(".lua:");
                if (lua != std::string::npos) {
                    file = first.substr(0, lua + 4);
                    line = atoi(first.c_str() + lua + 5);
                }
                dc_console_report_error(first.c_str(), file.empty() ? NULL : file.c_str(), line);
            }
            code = 1;
        }
    }

    lua_close(L);
    if (hadCwd) chdir(previous);
    return code;
}

static const dc_console_config kLuaConfig = {
    .runtime_id = "lua-5.4",
    .display_name = "Lua 5.4",
    .version = LUA_VERSION_MAJOR "." LUA_VERSION_MINOR "." LUA_VERSION_RELEASE,
    .run_program = run_program,
    .interrupt = NULL,
};

DC_EXPORT const dc_runtime *duocode_runtime_entry(void) {
    return dc_create_console_runtime(&kLuaConfig);
}
