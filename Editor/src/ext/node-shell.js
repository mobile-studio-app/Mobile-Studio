// The Terminal's shell. iOS has no shell to run, so this is one, in Node.js: it reads command
// lines (with quotes, $VARIABLES, ~, * and ? wildcards, |, >, >>, <, &&, || and ;), keeps a
// working folder and environment, and runs:
//   - its own commands: cd, pwd, ls, cat, echo, mkdir, rmdir, rm, cp, mv, touch, head, tail,
//     wc, grep, find, which, env, export, unset, clear, sleep, date, true, false, help
//   - node, npm, npx, packages' tools and macOS programs, as tasks do (node-tasks.js), with
//     the terminal's input and Ctrl+C
//   - git, through the app's git engine, and open/code, which open files in the editor: both
//     are asked of the page ({ call }), which asks the app.
// A session talks to its terminal over events: { out } text, { ready, cwd } when it's waiting
// for a command, { clear }, and { call } for the page to answer.
import fs from 'fs';
import path from 'path';
import { PassThrough } from 'stream';
import { runProgram } from './node-tasks.js';

const sessions = new Map();
let nextId = 1;

const C = { dir: '\x1b[1;34m', exec: '\x1b[1;32m', error: '\x1b[31m', dim: '\x1b[2m', off: '\x1b[0m' };

export function openSession(root) {
  const session = new Session(root);
  sessions.set(session.id, session);
  return session;
}

export const getSession = (id) => sessions.get(Number(id));

export function closeSession(id) {
  const session = getSession(id);
  if (!session) return;
  session.signal('INT');
  sessions.delete(session.id);
}

// MARK: - Parsing

/** Splits a line into lists joined by && || ; of pipelines (|) of commands: { words, redirects }.
 * Words come as segments { text, quote } so expansion can tell quoted text apart. */
function parse(line) {
  const lists = [];
  let pipeline = [];
  let command = { words: [], redirects: [] };
  let word = null;
  let quote = null;
  let pendingRedirect = null;
  const endWord = () => {
    if (word === null) return;
    if (pendingRedirect) { command.redirects.push({ op: pendingRedirect, target: word }); pendingRedirect = null; }
    else command.words.push(word);
    word = null;
  };
  const endCommand = () => {
    endWord();
    if (command.words.length || command.redirects.length) pipeline.push(command);
    command = { words: [], redirects: [] };
  };
  const endList = (joiner) => { endCommand(); if (pipeline.length) lists.push({ pipeline, joiner }); pipeline = []; };
  // Runs of text quoted the same way stay together, so $NAME expands as a whole.
  const add = (text, q) => {
    word = word || [];
    const last = word[word.length - 1];
    if (last && last.quote === q) last.text += text; else word.push({ text, quote: q });
  };
  for (let i = 0; i < line.length; i++) {
    const c = line[i];
    if (quote) {
      if (c === quote) { quote = null; if (!word) word = []; continue; }
      if (c === '\\' && quote === '"' && i + 1 < line.length && '"\\$`'.includes(line[i + 1])) { add(line[++i], quote); continue; }
      add(c, quote);
      continue;
    }
    if (c === '"' || c === '\'') { quote = c; if (!word) word = []; continue; }
    if (c === '\\' && i + 1 < line.length) { add(line[++i], '\\'); continue; }
    if (c === '#' && word === null) break;   // a comment
    if (/\s/.test(c)) { endWord(); continue; }
    if (c === '&' && line[i + 1] === '&') { endList('&&'); i++; continue; }
    if (c === '|' && line[i + 1] === '|') { endList('||'); i++; continue; }
    if (c === '|') { endCommand(); continue; }
    if (c === ';') { endList(';'); continue; }
    if (c === '>' || c === '<') {
      // 2> and 2>&1: a program's errors already come out with its output here.
      const fd = c === '>' && word && word.length === 1 && word[0].quote === null && /^[12]$/.test(word[0].text);
      if (fd) {
        word = null;
        if (line.startsWith('&1', i + 1) || line.startsWith('&2', i + 1)) { i += 2; continue; }
      }
      endWord();
      if (c === '>' && line[i + 1] === '>') { pendingRedirect = '>>'; i++; } else pendingRedirect = c;
      continue;
    }
    add(c, null);
  }
  if (quote) throw new Error('unterminated quote');
  endList(null);
  return lists;
}

function globToRegExp(glob) {
  let re = '';
  for (const c of glob) {
    if (c === '*') re += '[^/]*';
    else if (c === '?') re += '[^/]';
    else re += c.replace(/[.+^${}()|[\]\\]/g, '\\$&');
  }
  return new RegExp('^' + re + '$');
}

// MARK: - Sessions

class Session {
  constructor(root) {
    this.id = nextId++;
    this.root = root;
    this.cwd = root;
    this.previous = root;
    this.env = { ...process.env, HOME: root, PWD: root, SHELL: 'mobile-studio', TERM: 'xterm-256color' };
    this.listeners = new Set();
    this.backlog = [];
    this.busy = false;
    this.stdin = null;
    this.abort = null;
    this.calls = new Map();
    this.nextCall = 1;
  }

  emit(message) {
    if (!this.listeners.size) { this.backlog.push(message); return; }
    for (const listener of this.listeners) listener(message);
  }

  listen(listener) {
    this.listeners.add(listener);
    for (const message of this.backlog.splice(0)) listener(message);
    return () => this.listeners.delete(listener);
  }

  write(text) { if (text) this.emit({ out: String(text) }); }

  ready() { this.emit({ ready: true, cwd: this.cwd, root: this.root }); }

  /** A line typed at the prompt: a command, or input for the program that's running. */
  input(line) {
    if (this.busy) {
      if (this.stdin) this.stdin.write(line + '\n');
      return;
    }
    this.busy = true;
    this.execute(line).catch((e) => this.write(`${C.error}${e.message}${C.off}\r\n`)).finally(() => {
      this.busy = false;
      this.stdin = null;
      this.abort = null;
      this.ready();
    });
  }

  /** INT: Ctrl+C stops what's running. EOF: Ctrl+D ends its input. */
  signal(name) {
    if (name === 'INT' && this.abort) this.abort.abort();
    if (name === 'EOF' && this.stdin) this.stdin.end();
  }

  /** Asks the page for something only it (or the app) can do. */
  call(cmd, params) {
    const id = this.nextCall++;
    return new Promise((resolve) => {
      this.calls.set(id, resolve);
      this.emit({ call: { id, cmd, ...params } });
    });
  }

  reply(id, result) {
    const resolve = this.calls.get(Number(id));
    if (!resolve) return;
    this.calls.delete(Number(id));
    resolve(result || {});
  }

  resolve(p) {
    if (p === '~') return this.root;
    if (p.startsWith('~/')) return path.join(this.root, p.slice(2));
    return path.resolve(this.cwd, p);
  }

  /** A word's text: $VAR, ${VAR}, $? and a leading ~ expanded (not inside single quotes), then
   * unquoted * and ? matched against files. */
  expand(segments) {
    let text = '';
    let wild = false;
    for (const { text: t, quote } of segments) {
      if (quote === "'" || quote === '\\') { text += t; continue; }
      text += t.replace(/\$(\?|[A-Za-z_][A-Za-z0-9_]*|\{[A-Za-z_][A-Za-z0-9_]*\})/g, (_, name) => {
        if (name === '?') return String(this.lastCode ?? 0);
        return this.env[name.replace(/^\{|\}$/g, '')] ?? '';
      });
      if (quote === null && /[*?]/.test(t)) wild = true;
    }
    if (segments[0] && segments[0].quote === null && (text === '~' || text.startsWith('~/'))) text = this.root + text.slice(1);
    if (!wild) return [text];
    const matches = this.glob(text);
    return matches.length ? matches : [text];
  }

  /** Files matching a pattern with * and ?, sorted; relative patterns stay relative. */
  glob(pattern) {
    const absolute = path.isAbsolute(pattern);
    const parts = pattern.split('/');
    let bases = [absolute ? '/' : ''];
    for (const [i, part] of parts.entries()) {
      if (part === '' && i === 0) continue;
      const next = [];
      for (const base of bases) {
        const dir = path.resolve(this.cwd, base || '.');
        if (!/[*?]/.test(part)) { next.push(base ? path.join(base, part) : part); continue; }
        let entries = [];
        try { entries = fs.readdirSync(dir); } catch (e) { continue; }
        const re = globToRegExp(part);
        for (const entry of entries.sort()) {
          if (entry.startsWith('.') && !part.startsWith('.')) continue;
          if (re.test(entry)) next.push(base ? path.join(base, entry) : entry);
        }
      }
      bases = next;
    }
    return bases.filter((p) => fs.existsSync(path.resolve(this.cwd, p)));
  }

  async execute(line) {
    let lists;
    try { lists = parse(line); } catch (e) { this.write(`${C.error}mobile-studio: ${e.message}${C.off}\r\n`); this.lastCode = 2; return; }
    let code = this.lastCode ?? 0;
    let skip = null;
    for (const { pipeline, joiner } of lists) {
      if (skip === null || (skip === '&&' && code === 0) || (skip === '||' && code !== 0) || skip === ';') {
        code = await this.runPipeline(pipeline);
        this.lastCode = code;
      }
      skip = joiner;
    }
  }

  async runPipeline(pipeline) {
    this.abort = new AbortController();
    let input = null;
    let code = 0;
    for (const [i, command] of pipeline.entries()) {
      const last = i === pipeline.length - 1;
      const words = command.words.flatMap((w) => this.expand(w));
      // NAME=value before a command sets it for that command (or, alone, for the session).
      const env = {};
      while (words.length && /^[A-Za-z_][A-Za-z0-9_]*=/.test(words[0])) {
        const [name, ...value] = words.shift().split('=');
        env[name] = value.join('=');
      }
      if (!words.length) { Object.assign(this.env, env); continue; }

      let out = null;
      let append = false;
      for (const r of command.redirects) {
        const target = this.expand(r.target)[0];
        if (r.op === '<') {
          try { input = fs.readFileSync(this.resolve(target), 'utf8'); } catch (e) { this.write(`${C.error}${target}: No such file${C.off}\r\n`); return 1; }
        } else { out = this.resolve(target); append = r.op === '>>'; }
      }
      // Output goes on to the next command, into a file, or to the terminal.
      let captured = '';
      const toTerminal = last && !out;
      const write = toTerminal ? (text) => this.write(String(text).replace(/\r?\n/g, '\r\n')) : (text) => { captured += text; };
      const interactive = toTerminal && input === null && i === 0;
      if (interactive) this.stdin = new PassThrough();
      const io = { write, stdin: input !== null ? input : interactive ? this.stdin : '', signal: this.abort.signal, terminal: toTerminal };
      code = await this.runCommand(words, { ...env }, io);
      if (this.abort.signal.aborted) { this.write('^C\r\n'); return 130; }
      if (out) {
        try {
          if (append) fs.appendFileSync(out, captured); else fs.writeFileSync(out, captured);
        } catch (e) { this.write(`${C.error}${out}: ${e.message}${C.off}\r\n`); return 1; }
      }
      input = last ? null : captured;
    }
    return code;
  }

  async runCommand(words, env, io) {
    const [name, ...args] = words;
    const builtin = BUILTINS[name];
    if (builtin) {
      try {
        return (await builtin.call(this, args, io)) ?? 0;
      } catch (e) {
        io.write(`${name}: ${e.message}\n`);
        return 1;
      }
    }
    if (name === 'git') {
      const result = await this.call('git', { args, cwd: this.cwd });
      io.write(result.out || '');
      return result.code ?? 0;
    }
    if (name === 'open' || name === 'code') {
      for (const file of args.filter((a) => !a.startsWith('-'))) await this.call('open', { path: this.resolve(file) });
      return 0;
    }
    if (['python', 'python3', 'lua', 'love', 'pip', 'pip3'].includes(name)) {
      io.write(`${name} runs in the app, not the terminal: use Run (▶) for a project's main file, or Terminal: Start REPL for an interactive session.\n`);
      return 127;
    }
    const code = await runProgram(words, this.cwd, this.root, env, io);
    if (code === 127 && !io.signal.aborted) {
      // runProgram explained it; nothing more to add.
    }
    return code;
  }

  /** Completions for the word before the cursor: commands first, then files. */
  complete(line) {
    const match = /(\S*)$/.exec(line);
    const word = match ? match[1] : '';
    const isCommand = !line.slice(0, line.length - word.length).trim() || /[|;&]\s*$/.test(line.slice(0, line.length - word.length));
    const candidates = [];
    if (isCommand && !word.includes('/')) {
      for (const name of [...Object.keys(BUILTINS), 'git', 'node', 'npm', 'npx', 'open', 'code']) if (name.startsWith(word)) candidates.push(name + ' ');
    }
    const slash = word.lastIndexOf('/');
    const dirPart = slash >= 0 ? word.slice(0, slash + 1) : '';
    const prefix = word.slice(slash + 1);
    try {
      for (const entry of fs.readdirSync(this.resolve(dirPart || '.'), { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
        if (!entry.name.startsWith(prefix) || (entry.name.startsWith('.') && !prefix.startsWith('.'))) continue;
        candidates.push(dirPart + entry.name + (entry.isDirectory() ? '/' : ' '));
      }
    } catch (e) { /* not a folder */ }
    return { word, candidates: [...new Set(candidates)] };
  }
}

// MARK: - Commands

function flags(args, known) {
  const set = new Set();
  const rest = [];
  let options = {};
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === '--') { rest.push(...args.slice(i + 1)); break; }
    if (/^-\d+$/.test(a)) { options.n = Number(a.slice(1)); continue; }
    if (a.startsWith('-') && a.length > 1 && !/^-\d/.test(a)) {
      for (const c of a.slice(1)) {
        if (known.takes && known.takes.includes(c)) { options[c] = a.length > 2 ? a.slice(a.indexOf(c) + 1) : args[++i]; break; }
        set.add(c);
      }
      continue;
    }
    rest.push(a);
  }
  return { set, rest, options };
}

const textOf = (session, files, io) => (files.length
  ? files.map((f) => fs.readFileSync(session.resolve(f), 'utf8')).join('')
  : typeof io.stdin === 'string' ? io.stdin : '');

const lines = (text) => { const l = text.split('\n'); if (l[l.length - 1] === '') l.pop(); return l; };

function modeString(stat) {
  const bits = ['r', 'w', 'x'];
  let s = stat.isDirectory() ? 'd' : stat.isSymbolicLink() ? 'l' : '-';
  for (let i = 8; i >= 0; i--) s += stat.mode & (1 << i) ? bits[(8 - i) % 3] : '-';
  return s;
}

const BUILTINS = {
  help(args, io) {
    io.write([
      'Mobile Studio terminal. Commands:',
      '  files:    ls  cd  pwd  cat  head  tail  wc  grep  find  touch  mkdir  rmdir  rm  cp  mv',
      '  shell:    echo  env  export  unset  which  clear  sleep  date  true  false  help',
      '  programs: node  npm  npx  (and tools from node_modules), macOS programs from extensions',
      '  git:      git status|add|commit|log|diff|branch|checkout|switch|merge|stash|push|pull|...',
      '  editor:   open <file>  (or code <file>)',
      'Pipes (|), redirects (> >> <), &&, || and ; work. Ctrl+C stops a program.',
      '',
    ].join('\n'));
  },
  pwd(args, io) { io.write(this.cwd + '\n'); },
  cd(args) {
    const target = args[0] === undefined ? this.root : args[0] === '-' ? this.previous : this.resolve(args[0]);
    if (!fs.existsSync(target) || !fs.statSync(target).isDirectory()) throw new Error(`no such folder: ${args[0]}`);
    this.previous = this.cwd;
    this.cwd = target;
    this.env.PWD = target;
  },
  echo(args, io) {
    const { set, rest } = flags(args, {});
    let text = rest.join(' ');
    if (set.has('e')) text = text.replace(/\\n/g, '\n').replace(/\\t/g, '\t');
    io.write(text + (set.has('n') ? '' : '\n'));
  },
  ls(args, io) {
    const { set, rest } = flags(args, {});
    const targets = rest.length ? rest : ['.'];
    for (const [i, target] of targets.entries()) {
      const full = this.resolve(target);
      const stat = fs.statSync(full);
      let entries = stat.isDirectory() ? fs.readdirSync(full) : [path.basename(full)];
      const dir = stat.isDirectory() ? full : path.dirname(full);
      if (!set.has('a')) entries = entries.filter((e) => !e.startsWith('.'));
      entries.sort((a, b) => a.localeCompare(b));
      if (targets.length > 1) io.write(`${i ? '\n' : ''}${target}:\n`);
      const color = (name, s) => (!io.terminal ? name : s.isDirectory() ? C.dir + name + C.off : s.mode & 0o111 ? C.exec + name + C.off : name);
      if (set.has('l')) {
        for (const e of entries) {
          let s;
          try { s = fs.lstatSync(path.join(dir, e)); } catch (err) { continue; }
          const date = s.mtime.toISOString().slice(0, 16).replace('T', ' ');
          io.write(`${modeString(s)} ${String(s.size).padStart(9)} ${date} ${color(e, s)}\n`);
        }
      } else if (!io.terminal || set.has('1')) {
        for (const e of entries) io.write(e + '\n');
      } else if (entries.length) {
        io.write(entries.map((e) => { try { return color(e, fs.statSync(path.join(dir, e))); } catch (err) { return e; } }).join('  ') + '\n');
      }
    }
  },
  cat(args, io) {
    const { set, rest } = flags(args, {});
    const text = textOf(this, rest, io);
    io.write(set.has('n') ? lines(text).map((l, i) => `${String(i + 1).padStart(6)}  ${l}`).join('\n') + '\n' : text);
  },
  head(args, io) {
    const { rest, options } = flags(args, { takes: 'nc' });
    const text = textOf(this, rest, io);
    if (options.c !== undefined) { io.write(text.slice(0, Number(options.c))); return; }
    io.write(lines(text).slice(0, Number(options.n ?? 10)).map((l) => l + '\n').join(''));
  },
  tail(args, io) {
    const { rest, options } = flags(args, { takes: 'nc' });
    const text = textOf(this, rest, io);
    if (options.c !== undefined) { io.write(text.slice(Math.max(0, text.length - Number(options.c)))); return; }
    const all = lines(text);
    io.write(all.slice(Math.max(0, all.length - Number(options.n ?? 10))).map((l) => l + '\n').join(''));
  },
  wc(args, io) {
    const { set, rest } = flags(args, {});
    const text = textOf(this, rest, io);
    const counts = { l: lines(text).length, w: text.split(/\s+/).filter(Boolean).length, c: Buffer.byteLength(text) };
    const show = set.size ? ['l', 'w', 'c'].filter((k) => set.has(k)) : ['l', 'w', 'c'];
    io.write(show.map((k) => String(counts[k]).padStart(7)).join('') + (rest.length === 1 ? ' ' + rest[0] : '') + '\n');
  },
  grep(args, io) {
    const { set, rest } = flags(args, {});
    const [pattern, ...files] = rest;
    if (pattern === undefined) throw new Error('usage: grep [-inrvlc] pattern [files]');
    let re;
    try { re = new RegExp(pattern, set.has('i') ? 'i' : ''); } catch (e) { re = new RegExp(pattern.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), set.has('i') ? 'i' : ''); }
    const sources = [];
    const walk = (p) => {
      const full = this.resolve(p);
      const stat = fs.statSync(full);
      if (stat.isDirectory()) {
        if (!set.has('r')) throw new Error(`${p}: is a folder (use -r)`);
        for (const e of fs.readdirSync(full)) if (!e.startsWith('.') && e !== 'node_modules') walk(path.join(p, e));
      } else sources.push([p, fs.readFileSync(full, 'utf8')]);
    };
    if (files.length) files.forEach(walk); else if (set.has('r')) walk('.'); else sources.push([null, typeof io.stdin === 'string' ? io.stdin : '']);
    const many = sources.length > 1 || set.has('r');
    let found = 0;
    for (const [file, text] of sources) {
      let count = 0;
      for (const [i, l] of lines(text).entries()) {
        if (re.test(l) === set.has('v')) continue;
        count++;
        found++;
        if (set.has('l') || set.has('c')) continue;
        const shown = io.terminal ? l.replace(re, (m) => `\x1b[1;31m${m}${C.off}`) : l;
        io.write(`${many && file ? `\x1b[35m${file}${C.off}:` : ''}${set.has('n') ? `\x1b[32m${i + 1}${C.off}:` : ''}${shown}\n`);
      }
      if (set.has('l') && count) io.write(file + '\n');
      if (set.has('c')) io.write(`${many && file ? file + ':' : ''}${count}\n`);
    }
    return found ? 0 : 1;
  },
  find(args, io) {
    const start = args[0] && !args[0].startsWith('-') ? args[0] : '.';
    const nameAt = args.indexOf('-name');
    const typeAt = args.indexOf('-type');
    const name = nameAt >= 0 ? globToRegExp(args[nameAt + 1] || '*') : null;
    const type = typeAt >= 0 ? args[typeAt + 1] : null;
    const walk = (p) => {
      const stat = fs.lstatSync(this.resolve(p));
      const base = path.basename(p);
      if ((!name || name.test(base)) && (!type || (type === 'd') === stat.isDirectory())) io.write(p + '\n');
      if (stat.isDirectory() && base !== 'node_modules' && base !== '.git') {
        for (const e of fs.readdirSync(this.resolve(p)).sort()) walk(p === '.' ? `./${e}` : path.join(p, e));
      }
    };
    walk(start);
  },
  touch(args) {
    for (const f of args) {
      const full = this.resolve(f);
      if (fs.existsSync(full)) { const now = new Date(); fs.utimesSync(full, now, now); } else fs.writeFileSync(full, '');
    }
    this.call('filesChanged', {});
  },
  mkdir(args) {
    const { set, rest } = flags(args, {});
    for (const d of rest) fs.mkdirSync(this.resolve(d), { recursive: set.has('p') });
    this.call('filesChanged', {});
  },
  rmdir(args) { for (const d of args) fs.rmdirSync(this.resolve(d)); this.call('filesChanged', {}); },
  rm(args) {
    const { set, rest } = flags(args, {});
    for (const f of rest) {
      const full = this.resolve(f);
      if (full === this.root || full === '/') throw new Error(`refusing to remove ${f}`);
      if (!fs.existsSync(full)) { if (set.has('f')) continue; throw new Error(`${f}: No such file`); }
      if (fs.statSync(full).isDirectory() && !set.has('r') && !set.has('R')) throw new Error(`${f}: is a folder (use -r)`);
      fs.rmSync(full, { recursive: true, force: set.has('f') });
    }
    this.call('filesChanged', {});
  },
  cp(args) {
    const { set, rest } = flags(args, {});
    const target = this.resolve(rest.pop());
    const intoFolder = fs.existsSync(target) && fs.statSync(target).isDirectory();
    for (const f of rest) {
      const from = this.resolve(f);
      const to = intoFolder ? path.join(target, path.basename(from)) : target;
      if (fs.statSync(from).isDirectory() && !set.has('r') && !set.has('R')) throw new Error(`${f}: is a folder (use -r)`);
      fs.cpSync(from, to, { recursive: true });
    }
    this.call('filesChanged', {});
  },
  mv(args) {
    const files = args.filter((a) => !a.startsWith('-'));
    const target = this.resolve(files.pop());
    const intoFolder = fs.existsSync(target) && fs.statSync(target).isDirectory();
    for (const f of files) fs.renameSync(this.resolve(f), intoFolder ? path.join(target, path.basename(f)) : target);
    this.call('filesChanged', {});
  },
  env(args, io) {
    if (args.length) throw new Error('env with a command: write NAME=value command');
    for (const [k, v] of Object.entries(this.env).sort()) io.write(`${k}=${v}\n`);
  },
  export(args) {
    for (const a of args) {
      const at = a.indexOf('=');
      if (at > 0) this.env[a.slice(0, at)] = a.slice(at + 1);
    }
  },
  unset(args) { for (const a of args) delete this.env[a]; },
  which(args, io) {
    let code = 0;
    for (const a of args) {
      if (BUILTINS[a] || ['git', 'open', 'code'].includes(a)) io.write(`${a}: built in\n`);
      else if (['node', 'npm', 'npx'].includes(a)) io.write(`${a}: Mobile Studio's Node.js\n`);
      else { io.write(`${a} not found\n`); code = 1; }
    }
    return code;
  },
  clear() { this.emit({ clear: true }); },
  sleep(args, io) {
    return new Promise((resolve) => {
      const timer = setTimeout(() => resolve(0), Number(args[0] || 0) * 1000);
      io.signal.addEventListener('abort', () => { clearTimeout(timer); resolve(130); }, { once: true });
    });
  },
  date(args, io) { io.write(new Date().toString() + '\n'); },
  true() { return 0; },
  false() { return 1; },
};
