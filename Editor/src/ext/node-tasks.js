// Tasks' commands in Node.js. There's no shell on iOS, so commands are read here: each one
// joined by && (or ;) runs in turn, and these work:
//   node <script> [args]            a worker thread, as `node` would run it
//   npm install|i|ci [packages]     node-npm.js
//   npm run <script>, npm test/start, the scripts in package.json
//   npx <tool>, or a package's tool  the JavaScript file its package.json "bin" names
//   NAME=value … and cross-env       environment variables for what follows
// Other programs can't run on iOS.
//
// `io` is either a function that takes output, or { write, stdin, signal } (the Terminal: input
// for the program, and an AbortSignal for Ctrl+C).
import fs from 'fs';
import path from 'path';
import { Worker } from 'worker_threads';
import { npmInstall } from './node-npm.js';
import { nativeProgram, spawnNative } from './node-native.js';
import { fetchPreloadArgv } from './node-fetch.js';

/** Splits a command line into commands (by &&, || and ;) of words, honouring quotes. */
export function parseCommandLine(line) {
  const commands = [];
  let words = [];
  let word = null;
  let quote = null;
  const endWord = () => { if (word !== null) { words.push(word); word = null; } };
  const endCommand = (joiner) => { endWord(); if (words.length) commands.push({ words, joiner }); words = []; };
  for (let i = 0; i < line.length; i++) {
    const c = line[i];
    if (quote) {
      if (c === quote) quote = null;
      else if (c === '\\' && quote === '"' && i + 1 < line.length) word += line[++i];
      else word += c;
      continue;
    }
    if (c === '"' || c === '\'') { quote = c; word = word ?? ''; continue; }
    if (c === '\\' && i + 1 < line.length) { word = (word ?? '') + line[++i]; continue; }
    if (/\s/.test(c)) { endWord(); continue; }
    if (c === '&' && line[i + 1] === '&') { endCommand('&&'); i++; continue; }
    if (c === '|' && line[i + 1] === '|') { endCommand('||'); i++; continue; }
    if (c === ';') { endCommand(';'); continue; }
    word = (word ?? '') + c;
  }
  endCommand(null);
  return commands;
}

const readJSON = (file) => { try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch (e) { return null; } };

/** The JavaScript file behind a package tool ("eslint", "tsc"), from node_modules. */
function toolScript(name, dir) {
  for (let folder = dir; ; folder = path.dirname(folder)) {
    const modules = path.join(folder, 'node_modules');
    if (fs.existsSync(modules)) {
      const own = readJSON(path.join(modules, name, 'package.json'));
      const fromBin = (pkgDir, pkg) => {
        if (!pkg || !pkg.bin) return null;
        const file = typeof pkg.bin === 'string' ? (pkg.name === name || pkg.name?.endsWith('/' + name) ? pkg.bin : null) : pkg.bin[name];
        return file ? path.join(pkgDir, file) : null;
      };
      const direct = fromBin(path.join(modules, name), own);
      if (direct) return direct;
      for (const entry of fs.readdirSync(modules)) {
        const dirs = entry.startsWith('@') ? fs.readdirSync(path.join(modules, entry)).map((e) => path.join(entry, e)) : [entry];
        for (const d of dirs) {
          const found = fromBin(path.join(modules, d), readJSON(path.join(modules, d, 'package.json')));
          if (found) return found;
        }
      }
    }
    if (path.dirname(folder) === folder) return null;
  }
}

const ioFor = (io) => (typeof io === 'function' ? { write: io } : io);

/** Feeds `io.stdin` (a stream, or text from a pipe) to a program's stdin, or ends it. */
function connectStdin(io, stdin) {
  if (typeof io.stdin === 'string') stdin.end(io.stdin);
  else if (io.stdin) io.stdin.pipe(stdin);
  else stdin.end();
}

/** Runs a script as `node` would, in a worker thread. Resolves with its exit code. */
function runScript(file, args, cwd, env, io) {
  const { write, signal } = ioFor(io);
  return new Promise((resolve) => {
    let worker;
    try { process.chdir(cwd); } catch (e) { /* keep the old folder */ }
    // Run as the main module (require.main === module), whatever the file's extension (tools'
    // scripts often have none, which a Worker given the file refuses).
    const boot = `process.argv[1] = ${JSON.stringify(file)}; require('module').runMain();`;
    const withStdin = ioFor(io).stdin != null;
    try {
      worker = new Worker(boot, { eval: true, argv: args, env: { ...process.env, ...env }, stdout: true, stderr: true, stdin: withStdin, execArgv: fetchPreloadArgv() });
    } catch (e) {
      write(`${e.message}\n`);
      resolve(1);
      return;
    }
    if (withStdin) connectStdin(ioFor(io), worker.stdin);
    worker.stdout.setEncoding('utf8');
    worker.stderr.setEncoding('utf8');
    worker.stdout.on('data', write);
    worker.stderr.on('data', write);
    worker.on('error', (e) => write(String(e && e.stack ? e.stack : e).split('\n').filter((l) => !/node:internal/.test(l)).join('\n') + '\n'));
    let interrupted = false;
    const onAbort = () => { interrupted = true; worker.terminate(); };
    if (signal) signal.addEventListener('abort', onAbort, { once: true });
    worker.on('exit', (code) => {
      if (signal) signal.removeEventListener('abort', onAbort);
      resolve(interrupted ? 130 : code);
    });
  });
}

/** Runs a macOS program (see node-native.js). Resolves with its exit code. */
function runNative(file, args, cwd, env, io) {
  const { write, signal } = ioFor(io);
  return new Promise((resolve) => {
    const child = spawnNative(file, args, { cwd, env: { ...process.env, ...env } });
    connectStdin(ioFor(io), child.stdin);
    child.stdout.setEncoding('utf8');
    child.stderr.setEncoding('utf8');
    child.stdout.on('data', write);
    child.stderr.on('data', write);
    child.on('error', () => {});
    const onAbort = () => child.kill();
    if (signal) signal.addEventListener('abort', onAbort, { once: true });
    child.on('close', (code) => {
      if (signal) signal.removeEventListener('abort', onAbort);
      resolve(signal && signal.aborted ? 130 : code < 0 ? 127 : code);
    });
  });
}

/** Runs a task's command line in the project `dir`. Resolves with the exit code. */
export async function runCommand(line, dir, cwd, io, depth = 0) {
  const folder = cwd ? path.resolve(dir, cwd.replace(/\$\{workspaceFolder\}/g, dir)) : dir;
  let code = 0;
  for (const { words: raw, joiner } of parseCommandLine(line.replace(/\$\{workspaceFolder\}/g, dir))) {
    const env = {};
    let words = raw.slice();
    // NAME=value prefixes and cross-env set the environment.
    for (;;) {
      if (words[0] === 'cross-env' || words[0] === 'env') { words.shift(); continue; }
      const m = /^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/.exec(words[0] || '');
      if (!m) break;
      env[m[1]] = m[2];
      words.shift();
    }
    if (!words.length) continue;
    code = await runProgram(words, folder, dir, env, io, depth);
    if (joiner === '&&' && code !== 0) break;
    if (joiner === '||' && code === 0) break;
  }
  return code;
}

/** Runs one program: `node`, npm, npx, a package's tool or a macOS program. Resolves with its
 * exit code (127: there's no such program). */
export async function runProgram(words, folder, dir, env, io, depth = 0) {
  const { write } = ioFor(io);
  const [program, ...args] = words;
  if (program === 'node' || program === 'node.exe') {
    const scriptIndex = args.findIndex((a) => !a.startsWith('-'));
    if (scriptIndex < 0) { write('Mobile Studio runs `node` with a script, e.g. `node main.js`.\n'); return 1; }
    return runScript(path.resolve(folder, args[scriptIndex]), args.slice(scriptIndex + 1), folder, env, io);
  }
  if (program === 'npm' || program === 'pnpm' || program === 'yarn') {
    const [sub, ...rest] = args;
    if (!sub || ['install', 'i', 'ci', 'add'].includes(sub)) {
      return npmInstall(dir, rest.filter((a) => !a.startsWith('-')), write);
    }
    const script = sub === 'run' || sub === 'run-script' ? rest[0] : sub;
    const extra = sub === 'run' || sub === 'run-script' ? rest.slice(1) : rest;
    const pkg = readJSON(path.join(dir, 'package.json')) || {};
    const scripts = pkg.scripts || {};
    if (!script || scripts[script] == null) {
      if (script === 'start' && fs.existsSync(path.join(dir, 'server.js'))) return runScript(path.join(dir, 'server.js'), extra, folder, env, io);
      write(`package.json has no "${script}" script.\n`);
      return 1;
    }
    if (depth > 8) { write('Scripts call each other too deeply.\n'); return 1; }
    for (const step of [`pre${script}`, script, `post${script}`]) {
      if (scripts[step] == null) continue;
      write(`> ${step}: ${scripts[step]}\n`);
      const code = await runCommand(scripts[step] + (step === script && extra.length ? ' ' + extra.join(' ') : ''), dir, null, io, depth + 1);
      if (code) return code;
    }
    return 0;
  }
  if (program === 'npx') {
    const [tool, ...rest] = args.filter((a, i) => !(i === 0 && a.startsWith('-')));
    return runProgram([tool, ...rest], folder, dir, env, io, depth);
  }
  if (program === 'echo') { write(args.join(' ') + '\n'); return 0; }
  const tool = toolScript(program, dir);
  if (tool) return runScript(tool, args, folder, env, io);
  const native = nativeProgram(program, { cwd: folder, env: { ...process.env, ...env } });
  if (native) return runNative(native, args, folder, env, io);
  write(`"${program}" is a program, and iOS doesn't let apps run other programs. Mobile Studio can run node scripts, npm scripts, the tools that npm packages provide and macOS programs (with a signing certificate in Settings).\n`);
  return 127;
}
