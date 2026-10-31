// child_process for extensions in DuoCode's Node.js. iOS apps can't start processes, but most
// processes extensions start are Node.js scripts (language servers through fork(), or spawn of
// process.execPath / "node"). Those run as worker threads behind a ChildProcess-like object,
// with stdin/stdout/stderr and, for fork(), process.send/'message'. macOS programs the
// extension ships run through DuoCode's native runner (node-native.js). Anything else fails as
// a missing program would (ENOENT), which extensions usually handle.
import realChildProcess from 'child_process';
import { EventEmitter } from 'events';
import path from 'path';
import { PassThrough } from 'stream';
import { Worker } from 'worker_threads';
import { execNative, nativeProgram, spawnNative } from './node-native.js';

// Runs inside the worker: a Node.js process's view of the world, then the script.
const BOOT = `
const { parentPort, workerData } = require('worker_threads');
process.argv = [process.execPath, workerData.module, ...workerData.args];
if (workerData.ipc) {
  process.connected = true;
  process.send = (message, ...rest) => {
    parentPort.postMessage(message);
    const callback = rest.find((a) => typeof a === 'function');
    if (callback) process.nextTick(callback, null);
    return true;
  };
  process.disconnect = () => { process.connected = false; process.emit('disconnect'); };
  parentPort.on('message', (message) => process.emit('message', message));
}
try {
  require(workerData.module);
} catch (e) {
  process.stderr.write(String(e && e.stack || e) + '\\n');
  process.exit(1);
}
`;

let nextPid = 70000;

function runNode(script, args, options = {}, ipc = false) {
  const child = new EventEmitter();
  const module = path.resolve(options.cwd || process.cwd(), script);
  const worker = new Worker(BOOT, {
    eval: true,
    workerData: { module, args: (args || []).map(String), ipc },
    stdin: true, stdout: true, stderr: true,
    env: { ...process.env, ...(options.env || {}) },
    execArgv: [],
  });
  child.pid = nextPid++;
  child.stdin = worker.stdin;
  child.stdout = worker.stdout;
  child.stderr = worker.stderr;
  child.stdio = [worker.stdin, worker.stdout, worker.stderr];
  child.connected = ipc;
  child.killed = false;
  child.exitCode = null;
  child.signalCode = null;
  child.spawnfile = process.execPath;
  child.spawnargs = [process.execPath, module, ...(args || [])];
  child.send = (message, ...rest) => {
    worker.postMessage(message);
    const callback = rest.find((a) => typeof a === 'function');
    if (callback) process.nextTick(callback, null);
    return true;
  };
  child.disconnect = () => { child.connected = false; child.emit('disconnect'); };
  child.kill = () => { child.killed = true; worker.terminate(); return true; };
  child.ref = () => worker.ref();
  child.unref = () => worker.unref();
  worker.on('message', (message) => child.emit('message', message));
  worker.on('error', (e) => {
    // An uncaught exception ends the script; show it as a process would (on stderr).
    try { worker.stderr.push(String(e && e.stack ? e.stack : e) + '\n'); } catch (err) { /* closed */ }
    child.emit('error', e);
  });
  worker.on('exit', (code) => {
    child.exitCode = code;
    child.connected = false;
    child.emit('exit', code, null);
    child.emit('close', code, null);
  });
  process.nextTick(() => child.emit('spawn'));
  return child;
}

const isNode = (command) => command === process.execPath || command === 'node' || /[\\/]node(\.exe)?$/.test(command);

function notFound(command) {
  return Object.assign(new Error(`spawn ${command} ENOENT`), { code: 'ENOENT', errno: -2, syscall: 'spawn ' + command, path: command });
}

/** A process that couldn't start: an 'error' (ENOENT), then 'close'. */
function failed(command) {
  const child = new EventEmitter();
  child.stdin = new PassThrough();
  child.stdout = new PassThrough();
  child.stderr = new PassThrough();
  child.stdio = [child.stdin, child.stdout, child.stderr];
  child.pid = undefined;
  child.killed = false;
  child.exitCode = null;
  child.kill = () => false;
  child.ref = () => {};
  child.unref = () => {};
  process.nextTick(() => {
    child.emit('error', notFound(command));
    child.stdout.end();
    child.stderr.end();
    child.emit('close', -2, null);
  });
  return child;
}

/** Splits spawn's arguments: Node's own flags (--inspect...) are dropped. */
function scriptArgs(args) {
  const list = (args || []).map(String);
  const index = list.findIndex((a) => !a.startsWith('-'));
  return index < 0 ? [null, []] : [list[index], list.slice(index + 1)];
}

function spawn(command, args, options) {
  if (!Array.isArray(args)) { options = args; args = []; }
  options = options || {};
  if (isNode(String(command))) {
    const [script, rest] = scriptArgs(args);
    if (script) return runNode(script, rest, options, Array.isArray(options.stdio) && options.stdio.includes('ipc'));
  }
  const program = nativeProgram(String(command), options);
  if (program) return spawnNative(program, args, options);
  return failed(command);
}

function fork(script, args, options) {
  if (!Array.isArray(args)) { options = args; args = []; }
  return runNode(script, args, options || {}, true);
}

function exec(command, options, callback) {
  if (typeof options === 'function') { callback = options; options = {}; }
  const [first, ...rest] = String(command).match(/"[^"]*"|'[^']*'|\S+/g) || [];
  const unquote = (word) => word.replace(/^(["'])(.*)\1$/, '$2');
  const program = first && nativeProgram(unquote(first), options || {});
  if (program) return execNative(program, rest.map(unquote), options || {}, callback);
  const child = failed(String(command).split(/\s+/)[0]);
  if (callback) process.nextTick(callback, notFound(String(command).split(/\s+/)[0]), '', '');
  child.on('error', () => {});
  return child;
}

function execFile(file, args, options, callback) {
  callback = [args, options, callback].find((a) => typeof a === 'function');
  const list = Array.isArray(args) ? args : [];
  const opts = [args, options].find((a) => a && typeof a === 'object' && !Array.isArray(a)) || {};
  const program = nativeProgram(String(file), opts);
  if (program) return execNative(program, list, opts, callback);
  const child = failed(file);
  if (callback) process.nextTick(callback, notFound(file), '', '');
  child.on('error', () => {});
  return child;
}

const syncFailure = (command) => { throw notFound(command); };

export const childProcess = {
  ...realChildProcess,
  spawn,
  fork,
  exec,
  execFile,
  execSync: (command) => syncFailure(String(command).split(/\s+/)[0]),
  execFileSync: (file) => syncFailure(file),
  spawnSync: (command) => ({ pid: 0, output: [], stdout: '', stderr: '', status: null, signal: null, error: notFound(command) }),
};
