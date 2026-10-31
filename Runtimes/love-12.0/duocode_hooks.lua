-- DuoCode hooks, run once per boot right after `require "love"` (see LoveRuntime12.mm).
-- Arguments: the love table, report(text, file, line) for script errors, warn(text), and
-- setGameMode(width, height, fills) to tell DuoCode the window size the game asked for.
--
-- 1. Error reporting: love.errorhandler / love.errhand are kept out of the love table and
--    served through __index, so whichever handler is current when an error happens (LÖVE's
--    default or the game's own) is wrapped and reported to DuoCode. Boot failures never reach
--    a handler; LÖVE only prints them as "Error: ...", so print is watched too.
-- 2. Shader compatibility: uniform initial values (`uniform float k = 1.0;`) are moved to
--    shader:send. DuoCode's LÖVE compiles shaders with desktop GLSL rules on iOS (see
--    scripts/build-love-ios.sh), but sending the values keeps them working either way.
-- 3. Window size: love.window.setMode/updateMode/setFullscreen report the size the game asked
--    for, so DuoCode can give a fixed-size game that window and scale it to fit the game pane.

local love, report, warn, setGameMode = ...
local unpack = unpack or table.unpack

local function send(text)
  text = tostring(text)
  local file, line = text:match('([^%s:"]+%.lua):(%d+):')
  pcall(report, text, file, tonumber(line))
end

-- Error handlers -------------------------------------------------------------------

local handlers = {}
local wrappers = setmetatable({}, { __mode = 'k' })
local isWrapper = setmetatable({}, { __mode = 'k' })

local function wrapped(handler)
  if type(handler) ~= 'function' or isWrapper[handler] then return handler end
  local w = wrappers[handler]
  if not w then
    w = function(msg, ...)
      send(msg)
      -- While debugging, stop where the error happened (the stack is still intact here).
      local debugger = package.loaded['duocode.debugger']
      if debugger then pcall(debugger.onError, msg) end
      return handler(msg, ...)
    end
    wrappers[handler], isWrapper[w] = w, true
  end
  return w
end

local hooked = { errorhandler = true, errhand = true }
for k in pairs(hooked) do
  handlers[k] = rawget(love, k)
  rawset(love, k, nil)
end

-- Shader uniform initialisers ----------------------------------------------------------

--- Parses a GLSL literal initialiser into a value shader:send accepts, or nil.
local function parseDefault(gltype, expr)
  expr = expr:gsub('^%s+', ''):gsub('%s+$', '')
  if gltype == 'bool' then
    if expr == 'true' then return true elseif expr == 'false' then return false end
    return nil
  end
  if gltype == 'float' or gltype == 'int' or gltype == 'uint' then
    return tonumber((expr:gsub('[fFuU]$', '')))
  end
  local size = tonumber(gltype:match('^[biu]?vec([234])$'))
  if not size then return nil end
  local inner = expr:match('^[%w_]+%s*%((.*)%)$')
  if not inner then return nil end
  local parts = {}
  for p in inner:gmatch('[^,]+') do
    local v = p:gsub('%s', ''):gsub('[fFuU]$', '')
    if v == 'true' then v = 1 elseif v == 'false' then v = 0 else v = tonumber(v) end
    if not v then return nil end
    parts[#parts + 1] = v
  end
  if #parts == 1 then
    for i = 2, size do parts[i] = parts[1] end
  end
  if #parts ~= size then return nil end
  return parts
end

--- Removes `= value` from uniform/extern declarations. Records parsed values in `defaults`
--- and names it couldn't parse in `lost`. Returns the new code and how many were changed.
local function stripUniformInitialisers(code, defaults, lost)
  local count = 0
  local out = code:gsub('[^\n]+', function(line)
    local indent, keyword, decl, name, value, rest =
      line:match('^(%s*)(%a+)%s+([^=;]-)%s+([%a_][%w_]*)%s*=%s*([^;]+);(.*)$')
    if not keyword or (keyword ~= 'uniform' and keyword ~= 'extern') then return nil end
    local gltype = decl:match('([%w_]+)%s*$')
    local parsed = gltype and parseDefault(gltype, value)
    if parsed ~= nil then defaults[name] = parsed else lost[#lost + 1] = name end
    count = count + 1
    return indent .. keyword .. ' ' .. decl .. ' ' .. name .. ';' .. rest
  end)
  return out, count
end

local function isShaderCode(s)
  return s:find('[\n;{]') ~= nil
end

local function wrapNewShader(graphics)
  local newShader = rawget(graphics, 'newShader')
  if type(newShader) ~= 'function' then return end
  graphics.newShader = function(...)
    local n = select('#', ...)
    local args = { ... }
    local defaults, lost, changed = {}, {}, 0
    for i = 1, n do
      local a = args[i]
      if type(a) == 'string' then
        local code = a
        if not isShaderCode(code) and love.filesystem and love.filesystem.getInfo(code) then
          code = love.filesystem.read(code) or code
        end
        local stripped, count = stripUniformInitialisers(code, defaults, lost)
        if count > 0 then
          args[i] = stripped
          changed = changed + count
        end
      end
    end
    local shader = newShader(unpack(args, 1, n))
    if changed > 0 then
      local names = {}
      for name, value in pairs(defaults) do
        -- Unused uniforms are optimised out, and send errors for those; that's fine.
        pcall(shader.send, shader, name, value)
        names[#names + 1] = name
      end
      table.sort(names)
      -- Only worth mentioning when a value couldn't be carried over.
      if #lost > 0 then
        pcall(warn, ('Shader: couldn’t read the initial value of %s; it starts at zero.'):format(table.concat(lost, ', ')))
      end
    end
    return shader
  end
end

-- Window size ---------------------------------------------------------------------------

local mode = { width = 0, height = 0, resizable = false, fullscreen = false }

local function reportMode()
  if type(setGameMode) ~= 'function' then return end
  local fills = mode.resizable or mode.fullscreen or mode.width <= 0 or mode.height <= 0
  pcall(setGameMode, mode.width, mode.height, fills)
end

local function applyFlags(flags)
  if type(flags) ~= 'table' then return end
  if flags.resizable ~= nil then mode.resizable = flags.resizable and true or false end
  if flags.fullscreen ~= nil then mode.fullscreen = flags.fullscreen and true or false end
end

local function wrapWindow(window)
  local setMode, updateMode, setFullscreen = rawget(window, 'setMode'), rawget(window, 'updateMode'), rawget(window, 'setFullscreen')
  if type(setMode) == 'function' then
    window.setMode = function(width, height, flags, ...)
      local results = { setMode(width, height, flags, ...) }
      mode.width, mode.height = tonumber(width) or 0, tonumber(height) or 0
      mode.resizable, mode.fullscreen = false, false
      applyFlags(flags)
      reportMode()
      return unpack(results)
    end
  end
  if type(updateMode) == 'function' then
    window.updateMode = function(width, height, flags, ...)
      local results = { updateMode(width, height, flags, ...) }
      if type(width) == 'table' then
        applyFlags(width)
      else
        mode.width, mode.height = tonumber(width) or mode.width, tonumber(height) or mode.height
        applyFlags(flags)
      end
      reportMode()
      return unpack(results)
    end
  end
  if type(setFullscreen) == 'function' then
    window.setFullscreen = function(fullscreen, ...)
      local results = { setFullscreen(fullscreen, ...) }
      mode.fullscreen = fullscreen and true or false
      reportMode()
      return unpack(results)
    end
  end
end

-- love table metatable -------------------------------------------------------------------

setmetatable(love, {
  __index = function(_, k)
    if hooked[k] then return wrapped(handlers[k]) end
  end,
  __newindex = function(t, k, v)
    if hooked[k] then
      handlers[k] = v
      return
    end
    -- love.graphics is assigned when the module loads.
    if k == 'graphics' and type(v) == 'table' then wrapNewShader(v) end
    if k == 'window' and type(v) == 'table' then wrapWindow(v) end
    rawset(t, k, v)
  end,
})

-- In case the module was already loaded before these hooks ran.
if type(rawget(love, 'graphics')) == 'table' then wrapNewShader(rawget(love, 'graphics')) end
if type(rawget(love, 'window')) == 'table' then wrapWindow(rawget(love, 'window')) end

local hostPrint = print
print = function(...)
  local first = ...
  if select('#', ...) == 1 and type(first) == 'string' and first:sub(1, 7) == 'Error: ' then
    send(first:sub(8))
  end
  return hostPrint(...)
end

-- Exposed for tests.
return { stripUniformInitialisers = stripUniformInitialisers, parseDefault = parseDefault }
