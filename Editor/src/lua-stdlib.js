// Lua 5.1 / LuaJIT standard library: signatures and one-line descriptions for completion,
// signature help and docs. Same shape as love-api.json function entries.

// name: [params, returns, description]. "x?" marks optional params, "..." varargs.
const RAW = {
  // Globals
  print: ['...: any', '', 'Prints its arguments to the console, separated by tabs.'],
  type: ['v: any', 'string', 'Returns the type of v as a string ("nil", "number", "string", "table", …).'],
  tostring: ['v: any', 'string', 'Converts v to a string.'],
  tonumber: ['e: any, base?: integer', 'number?', 'Converts e to a number, or returns nil if it can’t.'],
  pairs: ['t: table', 'function, table, nil', 'Iterates over all key–value pairs of t (any order).'],
  ipairs: ['t: table', 'function, table, integer', 'Iterates over t[1], t[2], … until the first nil.'],
  next: ['t: table, k?: any', 'any, any', 'Returns the next key–value pair of t after k.'],
  select: ['n: integer|"#", ...: any', 'any', 'Returns arguments after index n, or their count with "#".'],
  unpack: ['t: table, i?: integer, j?: integer', '...', 'Returns t[i] … t[j] as separate values.'],
  error: ['message: any, level?: integer', '', 'Raises an error with message.'],
  assert: ['v: any, message?: string', 'any', 'Raises an error if v is false or nil; otherwise returns its arguments.'],
  pcall: ['f: function, ...: any', 'boolean, ...', 'Calls f in protected mode; returns false and the error instead of raising it.'],
  xpcall: ['f: function, handler: function', 'boolean, ...', 'Like pcall, but calls handler with the error.'],
  setmetatable: ['t: table, mt: table?', 'table', 'Sets the metatable of t and returns t.'],
  getmetatable: ['v: any', 'table?', 'Returns the metatable of v.'],
  rawget: ['t: table, k: any', 'any', 'Gets t[k] without invoking metamethods.'],
  rawset: ['t: table, k: any, v: any', 'table', 'Sets t[k] = v without invoking metamethods.'],
  rawequal: ['a: any, b: any', 'boolean', 'Compares a and b without invoking metamethods.'],
  require: ['modname: string', 'any', 'Loads and returns a module (e.g. require("player") loads player.lua).'],
  dofile: ['filename?: string', '...', 'Runs a Lua file. In LÖVE, prefer love.filesystem.load.'],
  loadstring: ['code: string, chunkname?: string', 'function?, string?', 'Compiles a string of Lua code into a function.'],
  collectgarbage: ['opt?: string, arg?: number', 'any', 'Controls the garbage collector ("collect", "count", "step", …).'],
  setfenv: ['f: function|integer, env: table', 'function', 'Sets the environment of a function.'],
  getfenv: ['f?: function|integer', 'table', 'Returns the environment of a function.'],

  // string
  'string.format': ['fmt: string, ...: any', 'string', 'Formats values like C printf, e.g. ("%d fps", fps).'],
  'string.sub': ['s: string, i: integer, j?: integer', 'string', 'Returns the substring from i to j (negative counts from the end).'],
  'string.len': ['s: string', 'integer', 'Returns the length of s in bytes.'],
  'string.upper': ['s: string', 'string', 'Returns s in upper case.'],
  'string.lower': ['s: string', 'string', 'Returns s in lower case.'],
  'string.rep': ['s: string, n: integer', 'string', 'Returns s repeated n times.'],
  'string.reverse': ['s: string', 'string', 'Returns s reversed.'],
  'string.byte': ['s: string, i?: integer, j?: integer', 'integer...', 'Returns the byte values of characters i to j.'],
  'string.char': ['...: integer', 'string', 'Builds a string from byte values.'],
  'string.find': ['s: string, pattern: string, init?: integer, plain?: boolean', 'integer?, integer?, ...', 'Finds pattern in s; returns start and end indices.'],
  'string.match': ['s: string, pattern: string, init?: integer', 'string?...', 'Returns the captures of the first match of pattern in s.'],
  'string.gmatch': ['s: string, pattern: string', 'function', 'Iterates over all matches of pattern in s.'],
  'string.gsub': ['s: string, pattern: string, repl: string|table|function, n?: integer', 'string, integer', 'Replaces matches of pattern; returns the new string and the count.'],

  // table
  'table.insert': ['t: table, pos?: integer, value: any', '', 'Inserts value at pos (default: the end) of list t.'],
  'table.remove': ['t: table, pos?: integer', 'any', 'Removes and returns the element at pos (default: the last).'],
  'table.concat': ['t: table, sep?: string, i?: integer, j?: integer', 'string', 'Joins list elements into a string.'],
  'table.sort': ['t: table, comp?: function', '', 'Sorts list t in place, optionally with comp(a, b).'],
  'table.unpack': ['t: table, i?: integer, j?: integer', '...', 'LuaJIT alias of unpack.'],

  // math
  'math.floor': ['x: number', 'integer', 'Rounds x down.'],
  'math.ceil': ['x: number', 'integer', 'Rounds x up.'],
  'math.abs': ['x: number', 'number', 'Absolute value of x.'],
  'math.min': ['x: number, ...: number', 'number', 'Smallest of its arguments.'],
  'math.max': ['x: number, ...: number', 'number', 'Largest of its arguments.'],
  'math.sqrt': ['x: number', 'number', 'Square root of x.'],
  'math.sin': ['x: number', 'number', 'Sine of x (radians).'],
  'math.cos': ['x: number', 'number', 'Cosine of x (radians).'],
  'math.tan': ['x: number', 'number', 'Tangent of x (radians).'],
  'math.asin': ['x: number', 'number', 'Arc sine of x, in radians.'],
  'math.acos': ['x: number', 'number', 'Arc cosine of x, in radians.'],
  'math.atan': ['x: number', 'number', 'Arc tangent of x, in radians.'],
  'math.atan2': ['y: number, x: number', 'number', 'Angle of the vector (x, y), in radians.'],
  'math.exp': ['x: number', 'number', 'e raised to the power x.'],
  'math.log': ['x: number, base?: number', 'number', 'Logarithm of x (natural by default).'],
  'math.pow': ['x: number, y: number', 'number', 'x raised to the power y (same as x ^ y).'],
  'math.fmod': ['x: number, y: number', 'number', 'Remainder of x / y, rounding towards zero.'],
  'math.modf': ['x: number', 'number, number', 'Integer and fractional parts of x.'],
  'math.random': ['m?: integer, n?: integer', 'number', 'Random number: [0,1), [1,m] or [m,n]. Prefer love.math.random in LÖVE.'],
  'math.randomseed': ['x: number', '', 'Seeds math.random.'],
  'math.rad': ['degrees: number', 'number', 'Converts degrees to radians.'],
  'math.deg': ['radians: number', 'number', 'Converts radians to degrees.'],

  // os / io
  'os.time': ['t?: table', 'integer', 'Current time (or the time described by t) in seconds.'],
  'os.clock': ['', 'number', 'CPU time used by the program, in seconds.'],
  'os.date': ['format?: string, time?: integer', 'string|table', 'Formats a date and time.'],
  'io.write': ['...: string|number', '', 'Writes to standard output (not shown in Mobile Studio; use print).'],

  // coroutine
  'coroutine.create': ['f: function', 'thread', 'Creates a coroutine running f.'],
  'coroutine.resume': ['co: thread, ...: any', 'boolean, ...', 'Starts or continues co.'],
  'coroutine.yield': ['...: any', '...', 'Suspends the running coroutine.'],
  'coroutine.status': ['co: thread', 'string', '"running", "suspended", "normal" or "dead".'],
  'coroutine.wrap': ['f: function', 'function', 'Creates a coroutine and returns a function that resumes it.'],
  'coroutine.running': ['', 'thread?', 'Returns the running coroutine.'],
};

function parseParams(spec) {
  if (!spec) return [];
  return spec.split(/,\s*(?![^()]*\))/).map((p) => {
    const [name, type = 'any'] = p.split(/:\s*/);
    return { name: name.replace(/\?$/, ''), type, optional: name.endsWith('?'), description: '' };
  });
}

export const stdlib = {};
for (const [name, [params, returns, description]] of Object.entries(RAW)) {
  stdlib[name] = {
    description,
    signatures: [{
      params: parseParams(params),
      returns: returns ? returns.split(/,\s*/).map((type) => ({ type, name: '', description: '' })) : [],
    }],
    url: `https://www.lua.org/manual/5.1/manual.html#pdf-${name}`,
  };
}

export const stdlibNamespaces = ['string', 'table', 'math', 'os', 'io', 'coroutine', 'debug', 'bit', 'jit'];

export const keywords = ['and', 'break', 'do', 'else', 'elseif', 'end', 'false', 'for', 'function', 'goto', 'if', 'in',
  'local', 'nil', 'not', 'or', 'repeat', 'return', 'then', 'true', 'until', 'while'];
