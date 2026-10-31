-- DuoCode's Lua debugger, shared by the Lua 5.4 and LÖVE runtimes (Lua 5.1/LuaJIT and 5.4).
-- Loaded by the runtime when a run is debugged, with:
--   send(json)            an event or reply for the IDE
--   receive(timeout)      the next command (JSON), or nil (timeout 0 doesn't wait, -1 waits)
--   project               the project folder ("" when sources are already project-relative)
--   config                JSON: { breakpoints = { [file] = { { line, condition, logMessage } } }, stopOnErrors }
--   shouldStop            optional: true once the user stopped the program
-- Returns the debugger: attach(thread), handler(message) for xpcall, onError(message).
--
-- It runs on debug hooks: a line hook while there are breakpoints or a step in progress, and
-- a count hook that checks for commands (pause, new breakpoints) while the program runs. When
-- it stops, it snapshots every frame's locals and upvalues and serves the IDE's requests until
-- told to continue or step. See Runtimes/common/DebugChannel.h for the protocol.

local send, receive, project, configText, shouldStop = ...
local getinfo, getlocal, getupvalue, sethook = debug.getinfo, debug.getlocal, debug.getupvalue, debug.sethook
local unpack = unpack or table.unpack
local loadChunk = loadstring or load

-- JSON ---------------------------------------------------------------------------------

local encode
local escapes = { ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
local function encodeString(s)
  return '"' .. s:gsub('[%c"\\]', function(c) return escapes[c] or string.format('\\u%04x', c:byte()) end) .. '"'
end
local function isArray(t)
  local n = 0
  for k in pairs(t) do
    if type(k) ~= 'number' or k <= 0 or k % 1 ~= 0 then return false end
    n = n + 1
  end
  return n == #t
end
encode = function(v)
  local t = type(v)
  if t == 'nil' then return 'null' end
  if t == 'boolean' then return tostring(v) end
  if t == 'number' then
    if v ~= v or v == math.huge or v == -math.huge then return 'null' end
    if v % 1 == 0 and v > -1e15 and v < 1e15 then return string.format('%d', v) end
    return string.format('%.14g', v)
  end
  if t == 'string' then return encodeString(v) end
  if t == 'table' then
    local out = {}
    if next(v) ~= nil and isArray(v) then
      for i = 1, #v do out[i] = encode(v[i]) end
      return '[' .. table.concat(out, ',') .. ']'
    end
    if next(v) == nil and getmetatable(v) == 'array' then return '[]' end
    for k, value in pairs(v) do out[#out + 1] = encodeString(tostring(k)) .. ':' .. encode(value) end
    return '{' .. table.concat(out, ',') .. '}'
  end
  return 'null'
end
local function emptyArray() return setmetatable({}, { __metatable = 'array' }) end

local function decode(s)
  local i = 1
  local value
  local function skip() i = s:find('[^ \t\r\n]', i) or #s + 1 end
  local function str()
    local out, j = {}, i + 1
    while true do
      local c = s:sub(j, j)
      if c == '"' then i = j + 1; return table.concat(out) end
      if c == '' then error('unterminated string') end
      if c == '\\' then
        local e = s:sub(j + 1, j + 1)
        local map = { b = '\b', f = '\f', n = '\n', r = '\r', t = '\t', ['"'] = '"', ['\\'] = '\\', ['/'] = '/' }
        if e == 'u' then
          local code = tonumber(s:sub(j + 2, j + 5), 16)
          j = j + 6
          if code >= 0xD800 and code < 0xDC00 and s:sub(j, j + 1) == '\\u' then
            local low = tonumber(s:sub(j + 2, j + 5), 16)
            code = 0x10000 + (code - 0xD800) * 0x400 + (low - 0xDC00)
            j = j + 6
          end
          if code < 0x80 then out[#out + 1] = string.char(code)
          elseif code < 0x800 then out[#out + 1] = string.char(0xC0 + math.floor(code / 64), 0x80 + code % 64)
          elseif code < 0x10000 then out[#out + 1] = string.char(0xE0 + math.floor(code / 4096), 0x80 + math.floor(code / 64) % 64, 0x80 + code % 64)
          else out[#out + 1] = string.char(0xF0 + math.floor(code / 262144), 0x80 + math.floor(code / 4096) % 64, 0x80 + math.floor(code / 64) % 64, 0x80 + code % 64) end
        else
          out[#out + 1] = map[e] or e
          j = j + 2
        end
      else
        local k = s:find('["\\]', j) or #s + 1
        out[#out + 1] = s:sub(j, k - 1)
        j = k
      end
    end
  end
  value = function()
    skip()
    local c = s:sub(i, i)
    if c == '{' then
      local t = {}
      i = i + 1; skip()
      if s:sub(i, i) == '}' then i = i + 1; return t end
      while true do
        skip()
        local k = str()
        skip(); i = i + 1   -- ':'
        t[k] = value()
        skip()
        local d = s:sub(i, i); i = i + 1
        if d == '}' then return t end
      end
    elseif c == '[' then
      local t = {}
      i = i + 1; skip()
      if s:sub(i, i) == ']' then i = i + 1; return t end
      while true do
        t[#t + 1] = value()
        skip()
        local d = s:sub(i, i); i = i + 1
        if d == ']' then return t end
      end
    elseif c == '"' then return str()
    elseif s:sub(i, i + 3) == 'true' then i = i + 4; return true
    elseif s:sub(i, i + 4) == 'false' then i = i + 5; return false
    elseif s:sub(i, i + 3) == 'null' then i = i + 4; return nil
    else
      local num = s:match('^-?%d+%.?%d*[eE]?[-+]?%d*', i)
      i = i + #num
      return tonumber(num)
    end
  end
  return value()
end

-- State --------------------------------------------------------------------------------

local config = (configText and configText ~= '' and decode(configText)) or {}
local breakpoints = {}      -- file -> line -> { condition, logMessage }
local breakpointLines = {}  -- line -> true, over every file (a quick first check per line)
local stopOnErrors = config.stopOnErrors ~= false
local mode = nil            -- nil (running), 'into', 'over', 'out' or 'pause'
local stepDepth, stepThread = 0, nil
local threads = setmetatable({}, { __mode = 'k' })   -- hooked coroutines
local frames, refs = {}, {}  -- while stopped: the snapshot and variable references
local baseline = {}          -- globals that existed before the program ran
for k in pairs(_G) do baseline[k] = true end

project = (project or ''):gsub('\\', '/'):gsub('/$', '')
local sourceCache = {}

--- A chunk's project-relative path, or false for code outside the project (C, strings, libraries).
local function relative(source)
  local cached = sourceCache[source]
  if cached ~= nil then return cached end
  local path = false
  if source:sub(1, 1) == '@' then
    path = source:sub(2):gsub('\\', '/'):gsub('^%./', '')
    if path:sub(1, 1) == '/' or path:match('^%a:/') then
      if project ~= '' and path:sub(1, #project + 1) == project .. '/' then
        path = path:sub(#project + 2)
      else
        path = false
      end
    end
  end
  sourceCache[source] = path
  return path
end

local function setBreakpoints(list)
  breakpoints, breakpointLines = {}, {}
  for file, entries in pairs(list or {}) do
    local byLine = {}
    for _, bp in ipairs(entries) do
      byLine[bp.line] = { condition = bp.condition ~= '' and bp.condition or nil, logMessage = bp.logMessage ~= '' and bp.logMessage or nil }
      breakpointLines[bp.line] = true
    end
    breakpoints[file:gsub('\\', '/')] = byLine
  end
end
setBreakpoints(config.breakpoints)

-- Values -------------------------------------------------------------------------------

local function newRef(entry)
  refs[#refs + 1] = entry
  return #refs
end

local function shortString(s)
  if #s > 300 then s = s:sub(1, 300) .. '…' end
  return '"' .. s:gsub('[%c"\\]', function(c) return escapes[c] or '\\' .. c:byte() end) .. '"'
end

local function keyText(k)
  if type(k) == 'string' then return k end
  return '[' .. (type(k) == 'number' and tostring(k) or tostring(k)) .. ']'
end

--- { value, type, ref } as the Variables view shows a value.
local function describe(v)
  local t = type(v)
  if t == 'string' then return { value = shortString(v), type = 'string' } end
  if t == 'table' then
    local mt = getmetatable(v)
    local preview
    if type(mt) == 'table' and rawget(mt, '__tostring') then
      local ok, text = pcall(tostring, v)
      preview = ok and tostring(text) or nil
    end
    if not preview then
      local parts, count = {}, 0
      for k, value in pairs(v) do
        count = count + 1
        if count <= 4 then
          local inner = type(value) == 'string' and shortString(value:sub(1, 20))
            or (type(value) == 'table' and '{…}') or tostring(value)
          parts[#parts + 1] = (type(k) == 'number' and #parts + 1 == k) and inner or (keyText(k) .. '=' .. inner)
        end
      end
      preview = '{' .. table.concat(parts, ', ') .. (count > 4 and ', …' or '') .. '}'
    end
    return { value = preview, type = 'table', ref = newRef({ kind = 'table', value = v }) }
  end
  if t == 'function' then
    local info = getinfo(v, 'S')
    local where = info and relative(info.source)
    return { value = where and ('function ' .. where .. ':' .. info.linedefined) or tostring(v), type = 'function' }
  end
  if t == 'userdata' then
    local ok, text = pcall(tostring, v)
    local mt = getmetatable(v)
    local ref = type(mt) == 'table' and newRef({ kind = 'table', value = mt }) or nil
    return { value = ok and tostring(text) or 'userdata', type = 'userdata', ref = ref }
  end
  return { value = tostring(v), type = t }
end

local function variable(name, v)
  local d = describe(v)
  d.name = name
  return d
end

local function sortedKeys(t)
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b)
    local ta, tb = type(a), type(b)
    if ta == 'number' and tb == 'number' then return a < b end
    if ta == 'number' then return true end
    if tb == 'number' then return false end
    return tostring(a) < tostring(b)
  end)
  return keys
end

local function children(ref)
  local entry = refs[ref]
  local out = emptyArray()
  if not entry then return out end
  if entry.kind == 'list' then
    for _, pair in ipairs(entry.items) do out[#out + 1] = variable(pair[1], pair[2]) end
  elseif entry.kind == 'globals' then
    for _, k in ipairs(sortedKeys(_G)) do
      if not baseline[k] then out[#out + 1] = variable(keyText(k), _G[k]) end
    end
  else
    local t = entry.value
    local keys = sortedKeys(t)
    for i = 1, math.min(#keys, 500) do out[#out + 1] = variable(keyText(keys[i]), rawget(t, keys[i])) end
    if #keys > 500 then out[#out + 1] = { name = '…', value = (#keys - 500) .. ' more', type = '' } end
    local mt = getmetatable(t)
    if type(mt) == 'table' then out[#out + 1] = variable('[metatable]', mt) end
  end
  return out
end

-- Frames and evaluation ----------------------------------------------------------------

--- Snapshots the stack, starting at `level` (counted from collectFrames itself).
local function collectFrames(level)
  local list = {}
  while true do
    local info = getinfo(level, 'nSlf')
    if not info then break end
    local file = relative(info.source)
    if file and info.currentline and info.currentline > 0 then
      local frame = { id = #list + 1, file = file, line = info.currentline, locals = {}, upvalues = {}, func = info.func }
      frame.name = info.name or (info.what == 'main' and 'main chunk') or ('function ' .. file .. ':' .. info.linedefined)
      local i = 1
      while true do
        local name, value = getlocal(level, i)
        if not name then break end
        if name:sub(1, 1) ~= '(' then frame.locals[#frame.locals + 1] = { name, value } end
        i = i + 1
      end
      i = 1
      while info.func do
        local name, value = getupvalue(info.func, i)
        if not name then break end
        if name == '_ENV' then frame.env = value
        elseif name ~= '' then frame.upvalues[#frame.upvalues + 1] = { name, value } end
        i = i + 1
      end
      list[#list + 1] = frame
    end
    level = level + 1
  end
  return list
end

--- An environment that sees a frame's locals and upvalues, then its globals.
local function frameEnv(frame)
  local names, values = {}, {}
  if frame then
    for _, pair in ipairs(frame.upvalues) do names[pair[1]] = true; values[pair[1]] = pair[2] end
    for _, pair in ipairs(frame.locals) do names[pair[1]] = true; values[pair[1]] = pair[2] end
  end
  local globals = (frame and frame.env) or _G
  return setmetatable({}, {
    __index = function(_, k)
      if names[k] then return values[k] end
      return globals[k]
    end,
    __newindex = function(_, k, v)
      if names[k] then values[k] = v else globals[k] = v end
    end,
  })
end

local function compile(code, env)
  if setfenv then
    local f, err = loadChunk(code, '=[debug console]')
    if f then setfenv(f, env) end
    return f, err
  end
  return load(code, '=[debug console]', 't', env)
end

--- Evaluates an expression (or runs a statement) in a frame. Returns results or nil, error.
local function evaluate(code, frame)
  local env = frameEnv(frame)
  local f, err = compile('return ' .. code, env)
  if not f then
    f, err = compile(code, env)
    if not f then return nil, (err or 'syntax error'):gsub('^%[debug console%]:%d+: ', '') end
  end
  local results = { pcall(f) }
  if not results[1] then return nil, tostring(results[2]):gsub('^%[debug console%]:%d+: ', '') end
  return true, results
end

local function interpolate(message, frame)
  return (message:gsub('{(.-)}', function(code)
    local ok, results = evaluate(code, frame)
    if not ok then return '{' .. tostring(results) .. '}' end
    local v = results[2]
    return type(v) == 'string' and v or tostring(v)
  end))
end

-- Hooks --------------------------------------------------------------------------------

local hook
local function hookMask()
  return (mode or next(breakpoints)) and 'l' or ''
end
local function applyHook(thread)
  if thread then sethook(thread, hook, hookMask(), 1000) else sethook(hook, hookMask(), 1000) end
end
local function updateHooks()
  applyHook()
  for thread in pairs(threads) do
    if coroutine.status(thread) ~= 'dead' then applyHook(thread) end
  end
end

local function reply(id, body, err)
  if id == nil then return end
  send(encode({ response = id, body = body, error = err }))
end

--- Commands that make sense while running: new breakpoints, pause.
local function handleRunning(message)
  local c = message.command
  if c == 'setBreakpoints' then
    setBreakpoints(message.breakpoints)
    if message.stopOnErrors ~= nil then stopOnErrors = message.stopOnErrors end
    updateHooks()
    reply(message.id, true)
  elseif c == 'pause' then
    mode = 'pause'
    updateHooks()
  elseif message.id then
    reply(message.id, nil, 'The program is running.')
  end
end

local function poll()
  while true do
    local raw = receive(0)
    if not raw then return end
    local ok, message = pcall(decode, raw)
    if ok and message then handleRunning(message) end
  end
end

--- Pauses the program: tells the IDE and serves its requests until it continues.
--- `level` is the first frame to show, counted from stop's caller.
local stopped = false
local function stop(reason, text, level)
  -- Stopping from an error handler runs outside a hook, so hooks would still fire in here.
  stopped = true
  frames = collectFrames(level + 2)   -- collectFrames is one call deeper than stop
  refs = {}
  mode = nil
  local depth = 0
  while getinfo(level + 1 + depth, 'l') do depth = depth + 1 end
  local list = emptyArray()
  for _, f in ipairs(frames) do list[#list + 1] = { id = f.id, name = f.name, file = f.file, line = f.line } end
  send(encode({ event = 'stopped', reason = reason, text = text, frames = list }))
  while true do
    local raw = receive(-1)
    if not raw then
      -- The run is ending: let the program go.
      breakpoints, breakpointLines, mode = {}, {}, nil
      break
    end
    local ok, message = pcall(decode, raw)
    message = ok and message or {}
    local c = message.command
    if c == 'continue' then break
    elseif c == 'next' or c == 'stepIn' or c == 'stepOut' then
      if reason ~= 'exception' then
        mode = (c == 'next' and 'over') or (c == 'stepIn' and 'into') or 'out'
        stepDepth, stepThread = depth, coroutine.running()
      end
      break
    elseif c == 'setBreakpoints' then
      setBreakpoints(message.breakpoints)
      if message.stopOnErrors ~= nil then stopOnErrors = message.stopOnErrors end
      reply(message.id, true)
    elseif c == 'scopes' then
      local frame = frames[message.frame or 1]
      if not frame then reply(message.id, emptyArray())
      else
        reply(message.id, {
          { name = 'Locals', ref = newRef({ kind = 'list', items = frame.locals }) },
          { name = 'Upvalues', ref = newRef({ kind = 'list', items = frame.upvalues }) },
          { name = 'Globals', ref = newRef({ kind = 'globals' }) },
        })
      end
    elseif c == 'variables' then
      reply(message.id, children(message.ref))
    elseif c == 'evaluate' then
      local okEval, results = evaluate(message.expression or '', frames[message.frame or 1])
      if not okEval then reply(message.id, nil, results)
      elseif #results < 2 and message.context == 'repl' then reply(message.id, { value = '', type = 'nil' })
      else
        local d = describe(results[2])
        if select('#', unpack(results)) > 2 then
          local more = {}
          for i = 2, #results do more[#more + 1] = describe(results[i]).value end
          d.value = table.concat(more, ', ')
        end
        reply(message.id, d)
      end
    elseif message.id then
      reply(message.id, nil, 'Unknown request ' .. tostring(c))
    end
  end
  frames, refs = {}, {}
  stopped = false
  send('{"event":"continued"}')
  updateHooks()
end

local count = 0
hook = function(event, line)
  if stopped then return end
  if event == 'count' then
    if shouldStop and shouldStop() then error('stopped', 0) end
    poll()
    return
  end
  if not mode and not breakpointLines[line] then return end
  local info = getinfo(2, 'S')
  local file = info and relative(info.source)
  if not file then return end
  local reason
  local byLine = breakpoints[file]
  local bp = byLine and byLine[line]
  if bp then
    local frame
    if bp.condition or bp.logMessage then frame = collectFrames(3)[1] end
    if bp.condition then
      local ok, results = evaluate(bp.condition, frame)
      if not (ok and results[2]) then bp = nil end
    end
    if bp and bp.logMessage then
      send(encode({ event = 'output', text = interpolate(bp.logMessage, frame), file = file, line = line }))
      bp = nil
    end
    if bp then reason = 'breakpoint' end
  end
  if not reason and mode then
    if mode == 'into' then reason = 'step'
    elseif mode == 'pause' then reason = 'pause'
    elseif stepThread == nil or stepThread == coroutine.running() or coroutine.status(stepThread) == 'dead' then
      if mode == 'over' and not getinfo(stepDepth + 2, 'l') then reason = 'step'
      elseif mode == 'out' and not getinfo(stepDepth + 1, 'l') then reason = 'step' end
    end
  end
  if reason then stop(reason, nil, 2) end
end

-- Coroutines get the hook too (hooks belong to a thread).
local create = coroutine.create
coroutine.create = function(f)
  local co = create(f)
  threads[co] = true
  applyHook(co)
  return co
end
coroutine.wrap = function(f)
  local co = coroutine.create(f)
  return function(...)
    local results = { n = 0 }
    local function collect(...) results = { n = select('#', ...), ... } end
    collect(coroutine.resume(co, ...))
    if not results[1] then error(results[2], 0) end
    return unpack(results, 2, results.n)
  end
end

-- The debugger -------------------------------------------------------------------------

local debugger = {}

--- Starts debugging `thread` (the current thread when nil).
function debugger.attach(thread)
  if thread then threads[thread] = true end
  applyHook(thread)
end

local reported = setmetatable({}, { __mode = 'k' })

--- Stops on an error, if the IDE asked for that. Call it from a message handler, where the
--- stack is still the one that failed.
function debugger.onError(message)
  if not stopOnErrors then return end
  local key = type(message) == 'table' and message or tostring(message)
  if reported[key] then return end
  if type(key) == 'table' then reported[key] = true end
  stop('exception', tostring(message), 2)
end

--- A message handler for xpcall: stops on the error, then returns a traceback.
function debugger.handler(message)
  debugger.onError(message)
  return debug.traceback(tostring(message), 2)
end

-- Other code (LÖVE's error handler hooks) finds the debugger here.
package.loaded['duocode.debugger'] = debugger
return debugger
