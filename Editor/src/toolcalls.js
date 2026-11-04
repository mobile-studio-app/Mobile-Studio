// The Chat agent's tool calls, read from what the model wrote. The instructions show one format
// (Qwen's own: <tool_call><function=name><parameter=key>value</parameter></function></tool_call>,
// whose values are written as they are, so code needs no escaping), but models write calls in
// many: JSON in a ```tool block, Hermes' <tool_call>{json}</tool_call>, Gemma 4's
// <|tool_call>call:name{…}<tool_call|>, Claude's <invoke>, or bare JSON; and JSON with code in it
// is often not quite JSON (raw newlines, unescaped quotes, trailing commas). All of them are read
// here. What looks like a call but can't be read comes back as an error, which goes to the model
// so it can try again, rather than ending the turn with the call shown as text.

// MARK: - Lenient JSON

/** Reads one JSON value starting at `start`: { value, end }. Accepts what models get wrong: raw
 * newlines in strings, single quotes, unquoted keys, trailing commas, comments, Python's
 * True/False/None, Gemma 4's <|"|> quotes; with `guessQuotes`, a quote that doesn't end its string
 * (it isn't followed by , } ] or :) is taken as part of it. Throws { message, incomplete }. */
function readJSON(s, start, guessQuotes) {
  let i = start;
  const fail = (message, incomplete = i >= s.length) => { throw Object.assign(new Error(message), { incomplete }); };
  const space = () => {
    for (;;) {
      while (i < s.length && /\s/.test(s[i])) i++;
      if (s.startsWith('//', i)) { while (i < s.length && s[i] !== '\n') i++; continue; }
      if (s.startsWith('/*', i)) { const e = s.indexOf('*/', i + 2); i = e < 0 ? s.length : e + 2; continue; }
      return;
    }
  };
  // Where a quote could end a string, by what follows it.
  const ends = {
    key: /^\s*[:=]/,
    object: /^\s*(,\s*(["'][^"'\n]{0,60}["']\s*:|[A-Za-z_]\w*\s*:|\})|\}\s*(,|\}|\]|$|```|<)|$)/,
    array: /^\s*(,|\]\s*(,|\}|\]|$|```|<)|$)/,
  };
  const string = (quote, context) => {
    i++;
    let out = '';
    for (;;) {
      if (i >= s.length) fail('a string isn\'t closed');
      const c = s[i];
      if (c === '\\') {
        const n = s[i + 1];
        const simple = { n: '\n', t: '\t', r: '\r', b: '\b', f: '\f', '/': '/', '\\': '\\', '"': '"', "'": "'", '`': '`' };
        if (n in simple) { out += simple[n]; i += 2; continue; }
        if (n === 'u' && /^[0-9a-fA-F]{4}$/.test(s.slice(i + 2, i + 6))) { out += String.fromCharCode(parseInt(s.slice(i + 2, i + 6), 16)); i += 6; continue; }
        // Not a JSON escape (a regex's \d, say): the backslash was meant.
        out += c;
        i++;
        continue;
      }
      if (c === quote) {
        if (!guessQuotes || ends[context].test(s.slice(i + 1, i + 200))) { i++; return out; }
      }
      out += c;
      i++;
    }
  };
  const gemmaString = () => {
    const close = s.indexOf('<|"|>', i + 5);
    if (close < 0) { i = s.length; fail('a string isn\'t closed'); }
    const out = s.slice(i + 5, close);
    i = close + 5;
    return out;
  };
  const value = (context) => {
    space();
    if (i >= s.length) fail('it ends too soon');
    const c = s[i];
    if (c === '{') return object();
    if (c === '[') return array();
    if (s.startsWith('<|"|>', i)) return gemmaString();
    if (c === '"' || c === "'") return string(c, context);
    if (c === '`') {
      const close = s.indexOf('`', i + 1);
      if (close < 0) { i = s.length; fail('a string isn\'t closed'); }
      const out = s.slice(i + 1, close);
      i = close + 1;
      return out;
    }
    const number = /^-?\d+(\.\d+)?([eE][+-]?\d+)?/.exec(s.slice(i, i + 40));
    if (number) { i += number[0].length; return Number(number[0]); }
    const word = /^[A-Za-z_]\w*/.exec(s.slice(i, i + 40));
    if (word) {
      const words = { true: true, false: false, null: null, True: true, False: false, None: null, undefined: null };
      if (word[0] in words) { i += word[0].length; return words[word[0]]; }
    }
    return fail(`unexpected ${JSON.stringify(s.slice(i, i + 12))}`, false);
  };
  const object = () => {
    i++;
    const out = {};
    for (;;) {
      space();
      if (i >= s.length) fail('the } at its end is missing');
      if (s[i] === '}') { i++; return out; }
      if (s[i] === ',') { i++; continue; }
      let key;
      if (s[i] === '"' || s[i] === "'") key = string(s[i], 'key');
      else if (s.startsWith('<|"|>', i)) key = gemmaString();
      else {
        const word = /^[\w$.-]+/.exec(s.slice(i, i + 80));
        if (!word) fail(`expected a name in quotes, found ${JSON.stringify(s.slice(i, i + 12))}`, false);
        key = word[0];
        i += key.length;
      }
      space();
      if (s[i] !== ':' && s[i] !== '=') fail(`expected : after "${key}"`);
      i++;
      out[key] = value('object');
      space();
      if (s[i] === ',') i++;
      else if (s[i] !== '}') fail(i >= s.length ? 'the } at its end is missing' : `expected , or } after "${key}"`);
    }
  };
  const array = () => {
    i++;
    const out = [];
    for (;;) {
      space();
      if (i >= s.length) fail('the ] at its end is missing');
      if (s[i] === ']') { i++; return out; }
      if (s[i] === ',') { i++; continue; }
      out.push(value('array'));
      space();
      if (s[i] === ',') i++;
      else if (s[i] !== ']') fail(i >= s.length ? 'the ] at its end is missing' : 'expected , or ]');
    }
  };
  const result = value('object');
  return { value: result, end: i };
}

/** Lenient JSON: as written, then guessing which quotes were meant to be escaped. */
export function parseLooseJSON(s, start = 0) {
  try {
    return readJSON(s, start, false);
  } catch (first) {
    try { return readJSON(s, start, true); } catch (e) { throw first; }
  }
}

// MARK: - Names

/** Other names models use for the tools (from other agents they were trained with). */
const TOOL_ALIASES = {
  read: 'read_file', view: 'read_file', cat: 'read_file', open_file: 'read_file', view_file: 'read_file', get_file: 'read_file', read_file_content: 'read_file',
  read_multiple_files: 'read_files',
  write: 'write_file', create_file: 'write_file', create: 'write_file', save_file: 'write_file', new_file: 'write_file', overwrite_file: 'write_file',
  edit: 'edit_file', str_replace: 'edit_file', replace: 'edit_file', replace_in_file: 'edit_file', search_replace: 'edit_file',
  replace_string_in_file: 'edit_file', apply_edit: 'edit_file', modify_file: 'edit_file', update_file: 'edit_file',
  insert: 'insert_lines', insert_code: 'insert_lines', insert_text: 'insert_lines', insert_at_line: 'insert_lines', insert_line: 'insert_lines',
  replace_range: 'replace_lines', replace_line: 'replace_lines',
  remove_lines: 'delete_lines', delete_line: 'delete_lines', delete_range: 'delete_lines',
  append: 'append_file', append_to_file: 'append_file',
  delete: 'delete_file', remove: 'delete_file', rm: 'delete_file', remove_file: 'delete_file', delete_path: 'delete_file', delete_folder: 'delete_file',
  move: 'move_file', rename: 'move_file', mv: 'move_file', rename_file: 'move_file', move_path: 'move_file',
  copy: 'copy_file', cp: 'copy_file',
  mkdir: 'create_folder', make_folder: 'create_folder', create_directory: 'create_folder', make_directory: 'create_folder', create_dir: 'create_folder',
  ls: 'list_files', list: 'list_files', list_dir: 'list_files', list_directory: 'list_files', list_folder: 'list_files',
  glob: 'find_files', find: 'find_files', file_search: 'find_files', find_file: 'find_files',
  grep: 'search', search_files: 'search', grep_search: 'search', search_code: 'search', find_in_files: 'search', search_in_files: 'search',
  bash: 'run_command', shell: 'run_command', run: 'run_command', exec: 'run_command', execute: 'run_command', run_shell: 'run_command',
  execute_command: 'run_command', run_terminal_command: 'run_command', run_terminal_cmd: 'run_command',
  run_game: 'run_program', run_project: 'run_program', run_app: 'run_program',
  problems: 'get_problems', diagnostics: 'get_problems', get_errors: 'get_problems', get_diagnostics: 'get_problems', lint: 'get_problems',
  console: 'read_console',
  task: 'delegate', subagent: 'delegate', subagents: 'delegate', spawn_agents: 'delegate',
};

/** A tool's name as the agent knows it, or null. */
export function toolName(raw, schema) {
  if (typeof raw !== 'string') return null;
  const name = raw.trim().replace(/^(functions|default_api|tools)\./, '').replace(/[\s-]+/g, '_').replace(/\(\)$/, '').toLowerCase();
  if (schema[name]) return name;
  const alias = TOOL_ALIASES[name];
  return alias && schema[alias] ? alias : null;
}

const NAME_KEYS = ['tool', 'name', 'tool_name', 'function', 'action', 'recipient_name'];
const ARGUMENT_KEYS = ['arguments', 'args', 'parameters', 'params', 'input', 'tool_input', 'kwargs'];

/** { name, args } from a JSON call in any of the usual shapes. */
function fromJSON(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
  let name = null;
  let args = {};
  for (const key of NAME_KEYS) {
    const v = value[key];
    if (typeof v === 'string') { name = v; break; }
    // OpenAI's {"function": {"name", "arguments"}}, or {"tool": {"name", ...}}.
    if (v && typeof v === 'object' && typeof v.name === 'string') {
      name = v.name;
      const inner = fromJSON(v);
      if (inner) args = inner.args;
      break;
    }
  }
  if (name == null) return null;
  for (const [key, v] of Object.entries(value)) {
    if (NAME_KEYS.includes(key) || ARGUMENT_KEYS.includes(key) || key === 'type' || key === 'id') continue;
    args[key] = v;
  }
  for (const key of ARGUMENT_KEYS) {
    let v = value[key];
    if (typeof v === 'string' && /^\s*\{/.test(v)) { try { v = parseLooseJSON(v, v.indexOf('{')).value; } catch (e) { /* a plain string */ } }
    if (v && typeof v === 'object' && !Array.isArray(v)) Object.assign(args, v);
  }
  return { name, args };
}

// MARK: - Arguments

/** A value as the parameter's type wants it: { value } or { error }. */
function coerce(param, raw) {
  if (raw == null) return { value: undefined };
  switch (param.type) {
    case 'int': {
      const n = typeof raw === 'number' ? raw : Number(String(raw).trim());
      return Number.isFinite(n) ? { value: Math.round(n) } : { error: `${param.name} should be a number, not ${JSON.stringify(String(raw).slice(0, 30))}` };
    }
    case 'bool':
      return { value: raw === true || /^(true|yes|1)$/i.test(String(raw).trim()) };
    case 'array': {
      if (Array.isArray(raw)) return { value: raw.map((x) => (typeof x === 'string' ? x : JSON.stringify(x))) };
      const text = String(raw).trim();
      if (text.startsWith('[')) { try { const v = parseLooseJSON(text).value; if (Array.isArray(v)) return coerce(param, v); } catch (e) { /* lines */ } }
      const parts = text.includes('\n') ? text.split('\n') : param.splitCommas ? text.split(',') : [text];
      return { value: parts.map((x) => x.trim().replace(/^[-*]\s+/, '')).filter(Boolean) };
    }
    case 'text':
      // Code: kept as written.
      return { value: typeof raw === 'string' ? raw : typeof raw === 'object' ? JSON.stringify(raw, null, 2) : String(raw) };
    default:
      return { value: typeof raw === 'string' ? raw.trim() : String(raw) };
  }
}

/** A call's arguments by the tool's parameters (their other names too): { call } or { error }. */
function bind(name, args, schema) {
  const tool = schema[name];
  const call = { tool: name };
  const lower = {};
  for (const [k, v] of Object.entries(args || {})) lower[k.toLowerCase()] = v;
  for (const param of tool.params) {
    let raw;
    for (const key of [param.name, ...(param.aliases || [])]) {
      if (lower[key.toLowerCase()] !== undefined) { raw = lower[key.toLowerCase()]; break; }
    }
    if (raw === undefined && param.from) {
      // Another way to say it (after_line 4 for line 5).
      for (const [key, map] of Object.entries(param.from)) if (lower[key] !== undefined) { raw = map(lower[key]); break; }
    }
    const { value, error } = coerce(param, raw);
    if (error) return { error: `${name}: ${error}. Usage: ${usage(name, schema)}` };
    if (value === undefined || (param.type !== 'text' && value === '')) {
      if (!param.optional) return { error: `${name} needs ${param.name}. Usage: ${usage(name, schema)}` };
      continue;
    }
    call[param.name] = value;
  }
  return { call };
}

/** read_file(path, start_line?, end_line?) */
export function usage(name, schema) {
  return `${name}(${schema[name].params.map((p) => p.name + (p.optional ? '?' : '')).join(', ')})`;
}

// MARK: - Finding calls

/** A parameter's value written between tags: the newline after the opening tag and before the
 * closing one belong to the format, not the value. */
const tagValue = (text) => text.replace(/^\r?\n/, '').replace(/\r?\n$/, '');

/** Parameters written as <parameter=key>value</parameter> or <parameter name="key">value</parameter>. */
function tagParameters(body, pattern) {
  const args = {};
  let complete = true;
  for (const m of body.matchAll(pattern)) {
    args[m[1].trim().replace(/^["']|["']$/g, '')] = tagValue(m[2]);
    complete = !!m[3];
  }
  return { args, complete };
}

/**
 * The tool calls in a reply. `schema`: { name: { params: [{ name, type, optional?, aliases? }] } }.
 * Returns { calls: [{ tool, ...arguments }], errors: [text for the model], spans: [[from, to]]
 * (where calls are written, to hide them), attempted (it tried to call something), cutOff (a call
 * runs to the end without closing: the answer was too long) }.
 */
export function readToolCalls(text, schema) {
  const found = [];   // { at, name, args, error, incomplete }
  const spans = [];
  // What's matched is blanked out, so no call is read twice.
  let work = String(text || '');
  const take = (from, to) => {
    spans.push([from, to]);
    work = work.slice(0, from) + work.slice(from, to).replace(/[^\n]/g, ' ') + work.slice(to);
  };
  // The tool a piece of JSON starts by naming, when it's one that exists: {"tool": "read_file", …
  const namesTool = (from) => {
    const m = /^[[\s]*\{\s*["']?(?:tool|name|tool_name|function|action)["']?\s*:\s*\{?\s*(?:["']?name["']?\s*:\s*)?["']([\w.-]+)["']/.exec(work.slice(from, from + 200));
    return m ? toolName(m[1], schema) : null;
  };
  // A call in JSON at `from`: the end of it, or -1. strict: a block meant as a call (```tool,
  // <tool_call>), or JSON that names a tool, so one that can't be read is an error; otherwise
  // JSON that isn't a call is left alone.
  const json = (at, from, strict) => {
    strict = strict || !!namesTool(from);
    try {
      const { value, end } = parseLooseJSON(work, from);
      const list = Array.isArray(value) ? value : [value];
      const calls = list.map(fromJSON).filter(Boolean);
      if (!strict && (!calls.length || !calls.every((c) => toolName(c.name, schema)))) return -1;
      if (!calls.length) {
        found.push({ at, error: 'it has no "tool" naming the tool to use' });
        return end;
      }
      for (const c of calls) found.push({ at, ...c, strict });
      return end;
    } catch (e) {
      if (strict) found.push({ at, name: namesTool(from) || undefined, error: `its JSON couldn't be read (${e.message})`, incomplete: e.incomplete });
      return strict ? -2 : -1;
    }
  };

  // Qwen's format, which the instructions show: <tool_call><function=name><parameter=key>…
  for (const m of work.matchAll(/(<tool_call>\s*)?<function=([^>\n]+)>([\s\S]*?)(<\/function>|(?=<function=)|(?=<\/tool_call>)|$)(\s*<\/tool_call>)?/g)) {
    const { args, complete } = tagParameters(m[3], /<parameter=([^>\n]+)>([\s\S]*?)(<\/parameter>|(?=<parameter=)|(?=<\/function>)|$)/g);
    const closed = !!m[4] || !!m[5] || complete;
    found.push({ at: m.index, name: m[2], args, strict: true, ...(closed ? {} : { error: 'it stops before its end', incomplete: true }) });
    take(m.index, m.index + m[0].length);
  }
  // Claude's: <invoke name="…"><parameter name="…">…</parameter></invoke>.
  for (const m of work.matchAll(/<invoke name=["']?([^"'>\n]+)["']?\s*>([\s\S]*?)(<\/invoke>|$)/g)) {
    const { args, complete } = tagParameters(m[2], /<parameter name=["']?([^"'>\n]+)["']?\s*>([\s\S]*?)(<\/parameter>|$)/g);
    const closed = !!m[3] || complete;
    found.push({ at: m.index, name: m[1], args, strict: true, ...(closed ? {} : { error: 'it stops before its end', incomplete: true }) });
    take(m.index, m.index + m[0].length);
  }
  // Gemma 4's: <|tool_call>call:name{key:<|"|>value<|"|>}<tool_call|>.
  for (const m of work.matchAll(/<\|tool_call>\s*(?:call:)?([\w.-]+)\s*(?=\{)/g)) {
    try {
      const { value, end } = parseLooseJSON(work, m.index + m[0].length);
      const close = /^\s*<tool_call\|>/.exec(work.slice(end));
      found.push({ at: m.index, name: m[1], args: value, strict: true });
      take(m.index, end + (close ? close[0].length : 0));
    } catch (e) {
      found.push({ at: m.index, name: m[1], error: `its arguments couldn't be read (${e.message})`, incomplete: e.incomplete });
      take(m.index, work.length);
    }
  }
  // Hermes': <tool_call>{"name": …, "arguments": {…}}</tool_call>.
  for (const m of work.matchAll(/<tool_call>\s*(?=[{[])/g)) {
    const end = json(m.index, m.index + m[0].length, true);
    if (end < 0) { const close = work.indexOf('</tool_call>', m.index); take(m.index, close < 0 ? work.length : close + 12); continue; }
    const close = /^\s*<\/tool_call>/.exec(work.slice(end));
    take(m.index, end + (close ? close[0].length : 0));
  }
  // Fenced blocks: ```tool (the old format) or ```json holding a call. Other code blocks are code,
  // so bare JSON inside them isn't a call.
  const code = [];
  const fence = /```[ \t]*([\w-]*)[^\n]*\n?/g;
  for (let m = fence.exec(work); m; m = fence.exec(work)) {
    const lang = m[1].toLowerCase();
    const bodyStart = m.index + m[0].length;
    const callish = /^(tool|tools|tool_call|tool_code|function|function_call|call)$/.test(lang);
    const start = /^\s*/.exec(work.slice(bodyStart))[0].length + bodyStart;
    if ((callish || /^(json|jsonc|json5|)$/.test(lang)) && /[{[]/.test(work[start] || '')) {
      const end = json(m.index, start, callish);
      if (end >= 0) {
        const close = /^\s*```/.exec(work.slice(end));
        const to = close ? end + close[0].length : end;
        take(m.index, to);
        fence.lastIndex = to;
        continue;
      }
      if (end === -2) {
        // A call that can't be read: hidden up to its closing fence.
        const close = work.indexOf('```', start);
        take(m.index, close < 0 ? work.length : close + 3);
        fence.lastIndex = close < 0 ? work.length : close + 3;
        continue;
      }
    }
    // An ordinary block: skip to its end.
    const close = work.indexOf('```', bodyStart);
    if (close < 0) { code.push([m.index, work.length]); break; }
    code.push([m.index, close + 3]);
    fence.lastIndex = close + 3;
  }
  // Bare JSON in the text: {"tool": "read_file", …} (only for tools that exist, since an
  // explanation can show JSON with a "name" in it).
  const inCode = (at) => code.some(([a, b]) => at >= a && at < b);
  for (const m of work.matchAll(/\{\s*["']?(tool|name|tool_name|function|action)["']?\s*:/g)) {
    if (inCode(m.index) || work[m.index] !== '{') continue;
    const end = json(m.index, m.index, false);
    if (end >= 0) take(m.index, end);
    else if (end === -2) take(m.index, work.length);
  }

  // Each call bound to its tool.
  found.sort((a, b) => a.at - b.at);
  const calls = [];
  const errors = [];
  let cutOff = false;
  for (const f of found) {
    const name = f.name != null ? toolName(f.name, schema) : null;
    const label = f.name ? `The call to ${String(f.name).trim()}` : 'A tool call';
    if (f.error) {
      if (f.incomplete) cutOff = true;
      errors.push(`${label} couldn't be run: ${f.error}.`);
      continue;
    }
    if (!name) {
      if (f.strict) errors.push(`There's no tool called ${String(f.name).trim()}. The tools are: ${Object.keys(schema).join(', ')}.`);
      continue;
    }
    const bound = bind(name, f.args, schema);
    if (bound.error) errors.push(bound.error);
    else calls.push(bound.call);
  }
  const attempted = found.length > 0 || /<tool_call>|<function=|<\|tool_call>|<invoke\b|```tool\b/.test(text);
  if (!found.length && attempted) errors.push('A tool call was started but couldn\'t be read.');
  return { calls, errors, spans, attempted, cutOff };
}

/** A reply as shown: without its tool calls (they show as chips and cards) or their wrappers. */
export function withoutToolCalls(text, schema) {
  const source = String(text || '');
  const { spans } = readToolCalls(source, schema);
  let out = '';
  let at = 0;
  for (const [from, to] of spans.sort((a, b) => a[0] - b[0])) {
    if (from < at) continue;
    out += source.slice(at, from);
    at = to;
  }
  out += source.slice(at);
  return out.replace(/<\/?tool_call>|<\/?function_calls>|<\|tool_call>|<tool_call\|>|```(?:tool|tool_call)[ \t]*\n\s*```/g, '').trim();
}

/** Where the model began writing a tool's results itself (they come from the app, not from it):
 * the reply is cut there. */
export function cutInventedResults(text) {
  const m = /<tool_response>|<\|tool_response>|(^|\n)\s*Tool results:/.exec(text);
  return m ? text.slice(0, m.index).trimEnd() : text;
}

/** What the model's answer ends with when it begins to invent a result, for the app to stop at. */
export const STOP_AT = ['<tool_response>', '\nTool results:'];
