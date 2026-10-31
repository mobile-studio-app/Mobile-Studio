// macOS programs that extensions ship (language servers, linters, formatters), run by DuoCode's
// native runner (App/NativeTools/NativeTools.mm), which signs them with the user's certificate
// and runs them inside the app. Here they look like child processes: the runner hands back
// three socket descriptors in this process for stdin, stdout and stderr, then the exit code.
import { EventEmitter } from 'events';
import fs from 'fs';
import net from 'net';
import path from 'path';
import { PassThrough } from 'stream';

let nativePort = 0;
let nextPid = 90000;

/** The runner's loopback port (0: there's no runner, e.g. off the phone). */
export function setNativePort(port) {
  nativePort = Number(port) || 0;
}

/** Whether `file` is a macOS program: a 64-bit Mach-O or a universal binary. */
function isMachO(file) {
  let fd;
  try {
    fd = fs.openSync(file, 'r');
    const head = Buffer.alloc(4);
    if (fs.readSync(fd, head, 0, 4, 0) < 4) return false;
    const magic = head.readUInt32BE(0);
    return magic === 0xcffaedfe || magic === 0xcafebabe || magic === 0xcafebabf;
  } catch (e) {
    return false;
  } finally {
    if (fd !== undefined) fs.closeSync(fd);
  }
}

/** The macOS program `command` names (a path, or a name on PATH), or null. */
export function nativeProgram(command, options = {}) {
  if (!nativePort || !command) return null;
  const cwd = options.cwd || process.cwd();
  const candidates = /[\\/]/.test(command)
    ? [path.resolve(cwd, command)]
    : String((options.env || process.env).PATH || '').split(path.delimiter).filter(Boolean).map((dir) => path.join(dir, command));
  return candidates.find((file) => fs.existsSync(file) && fs.statSync(file).isFile() && isMachO(file)) || null;
}

/** Starts a macOS program; returns a ChildProcess-like object. */
export function spawnNative(file, args = [], options = {}) {
  const child = new EventEmitter();
  child.stdin = new PassThrough();
  child.stdout = new PassThrough();
  child.stderr = new PassThrough();
  child.stdio = [child.stdin, child.stdout, child.stderr];
  child.pid = nextPid++;
  child.killed = false;
  child.exitCode = null;
  child.signalCode = null;
  child.spawnfile = file;
  child.spawnargs = [file, ...args.map(String)];
  child.ref = () => {};
  child.unref = () => {};

  const env = {};
  for (const [key, value] of Object.entries(options.env || process.env)) if (value != null) env[key] = String(value);
  const control = net.connect(nativePort, '127.0.0.1');
  let buffer = '';
  let streams = [];
  let open = 0;
  let exited = false;
  let closed = false;
  const close = (code) => {
    if (closed) return;
    closed = true;
    child.emit('close', code, null);
  };
  // 'close' comes after the program's output has all been read.
  const streamEnded = () => { if (--open <= 0 && exited) close(child.exitCode); };

  const ended = (code, error) => {
    if (exited) return;
    exited = true;
    if (error) child.stderr.write(error + '\n');
    child.exitCode = code;
    child.connected = false;
    child.emit('exit', code, null);
    if (open <= 0) close(code);
    control.end();
  };

  control.on('connect', () => {
    control.write(JSON.stringify({ run: file, args: args.map(String), cwd: options.cwd ? path.resolve(options.cwd) : process.cwd(), env }) + '\n');
  });
  control.on('data', (chunk) => {
    buffer += chunk.toString('utf8');
    let newline;
    while ((newline = buffer.indexOf('\n')) >= 0) {
      const line = buffer.slice(0, newline);
      buffer = buffer.slice(newline + 1);
      let message;
      try { message = JSON.parse(line); } catch (e) { continue; }
      if (message.fds) {
        streams = message.fds.map((fd) => new net.Socket({ fd, readable: true, writable: true, allowHalfOpen: true }));
        const [input, output, errors] = streams;
        child.stdin.pipe(input);
        input.on('error', () => {});
        for (const [socket, target] of [[output, child.stdout], [errors, child.stderr]]) {
          open++;
          socket.on('error', () => {});
          socket.on('end', () => { target.end(); streamEnded(); });
          socket.on('close', () => { if (!target.writableEnded) { target.end(); streamEnded(); } });
          socket.pipe(target, { end: false });
        }
        child.emit('spawn');
      } else if (message.error && message.exit === undefined) {
        // It didn't start.
        const error = Object.assign(new Error(message.error), { code: 'ENOEXEC', errno: -8, syscall: 'spawn ' + file, path: file });
        child.stderr.end(message.error + '\n');
        child.stdout.end();
        exited = true;
        child.emit('error', error);
        close(-8);
        control.end();
      } else if (message.exit !== undefined) {
        ended(message.exit, message.error);
      }
    }
  });
  control.on('error', (e) => {
    if (exited) return;
    exited = true;
    child.emit('error', Object.assign(new Error(`Mobile Studio's program runner isn't reachable: ${e.message}`), { code: 'ENOENT' }));
    close(-2);
  });
  control.on('close', () => ended(child.exitCode ?? 1));

  child.kill = () => {
    if (exited) return false;
    child.killed = true;
    child.signalCode = 'SIGTERM';
    control.write('{"kill":true}\n');
    return true;
  };
  return child;
}

/** execFile for a macOS program: collects its output. */
export function execNative(file, args, options, callback) {
  const child = spawnNative(file, args, options);
  let stdout = '';
  let stderr = '';
  const encoding = options && options.encoding && options.encoding !== 'buffer' ? options.encoding : 'utf8';
  child.stdout.on('data', (d) => { stdout += d.toString(encoding); });
  child.stderr.on('data', (d) => { stderr += d.toString(encoding); });
  let done = false;
  const finish = (error) => {
    if (done) return;
    done = true;
    if (callback) callback(error, stdout, stderr);
  };
  child.on('error', (e) => finish(e));
  child.on('close', (code) => finish(code === 0 ? null : Object.assign(new Error(`Command failed: ${file} ${args.join(' ')}\n${stderr}`), { code, killed: child.killed, signal: null, cmd: file })));
  return child;
}
