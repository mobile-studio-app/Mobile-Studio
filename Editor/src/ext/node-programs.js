// JavaScript programs for the Node.js runtime (Runtimes/node/NodeRuntime.mm). Node.js starts
// once per launch, so each run is a worker thread: a fresh JavaScript world that Stop
// terminates. The runtime connects to this port and sends one JSON message per line:
//   { run: <project folder>, repl, debug: <debug configuration> }, { stdin: <line> },
//   { debug: <debugger command> }, { stop: true }
// and receives { out }, { err }, { error, file, line }, { debugEvent } and { exit: <code> }.
import net from 'net';
import { fetchPreloadArgv } from './node-fetch.js';
import fs from 'fs';
import path from 'path';
import { Worker } from 'worker_threads';
import { ProgramDebugger, debuggingAvailable } from './node-debug.js';

const REPL = `
const repl = require('repl');
console.log('Node.js ' + process.version + ' in Mobile Studio. Type JavaScript and press Return; Stop ends the session.');
repl.start({ prompt: '', input: process.stdin, output: process.stdout, terminal: false, useGlobal: true, ignoreUndefined: true });
`;

/** The innermost stack frame in the project: { file, line }. */
function locate(error, dir) {
  const stack = String((error && error.stack) || '');
  for (const m of stack.matchAll(/\(?((?:file:\/\/)?\/[^():\s]+):(\d+):\d+\)?/g)) {
    const file = m[1].replace(/^file:\/\//, '');
    if (file.startsWith(dir + '/')) return { file: file.slice(dir.length + 1), line: Number(m[2]) };
  }
  return { file: null, line: 0 };
}

export function servePrograms(port) {
  net.createServer((socket) => {
    let worker = null;
    let debug = null;
    let buffer = '';
    const send = (message) => { if (!socket.destroyed) socket.write(JSON.stringify(message) + '\n'); };

    const start = async ({ run: dir, repl, debug: debugConfig }) => {
      const entry = repl ? null : ['main.js', 'main.mjs', 'main.cjs', 'index.js'].map((f) => path.join(dir, f)).find((f) => fs.existsSync(f));
      if (!repl && !entry) {
        send({ err: 'There is no main.js in this project.\n' });
        send({ exit: 1 });
        return;
      }
      // Relative paths in the program resolve against the project, as with `node main.js`.
      try { process.chdir(dir); } catch (e) { /* keep the old folder */ }
      if (debugConfig && !repl) {
        if (debuggingAvailable()) {
          debug = new ProgramDebugger(debugConfig, dir, (json) => send({ debugEvent: json }));
          try { await debug.start(); } catch (e) { send({ err: `The debugger couldn't start: ${e.message}\n` }); debug = null; }
        } else {
          send({ err: 'This Node.js can\'t debug, so the program runs without stopping at breakpoints.\n' });
        }
      }
      // A debugged program starts from the event loop: started directly, Node.js's worker code
      // around it would catch its errors, so the debugger wouldn't stop at them as uncaught.
      const source = repl ? REPL : debug ? `setImmediate(() => { process.argv[1] = ${JSON.stringify(entry)}; require('module').runMain(); });` : entry;
      try {
        worker = new Worker(source, { eval: !!repl || !!debug, stdin: true, stdout: true, stderr: true, argv: [], execArgv: fetchPreloadArgv() });
      } catch (e) {
        send({ err: (e.stack || String(e)) + '\n' });
        send({ exit: 1 });
        if (debug) { debug.stop(); debug = null; }
        return;
      }
      if (debug) debug.setProgramThread(worker.threadId);
      worker.stdout.setEncoding('utf8');
      worker.stderr.setEncoding('utf8');
      worker.stdout.on('data', (text) => send({ out: text }));
      worker.stderr.on('data', (text) => send({ err: text }));
      worker.on('error', (e) => {
        const where = locate(e, dir);
        // The stack without Node's own frames.
        const stack = String(e && e.stack ? e.stack : e).split('\n').filter((l) => !/\(node:|node:internal/.test(l)).join('\n');
        send({ err: stack + '\n' });
        send({ error: `${e && e.name ? e.name : 'Error'}: ${e && e.message ? e.message : e}`, file: where.file, line: where.line });
      });
      worker.on('exit', (code) => {
        if (debug) { debug.stop(); debug = null; }
        send({ exit: code });
        worker = null;
      });
    };

    socket.setEncoding('utf8');
    socket.on('data', (chunk) => {
      buffer += chunk;
      let newline;
      while ((newline = buffer.indexOf('\n')) >= 0) {
        const line = buffer.slice(0, newline);
        buffer = buffer.slice(newline + 1);
        let message;
        try { message = JSON.parse(line); } catch (e) { continue; }
        if (message.run) start(message);
        else if (message.stdin != null && worker) worker.stdin.write(message.stdin + '\n');
        else if (typeof message.debug === 'string' && debug) debug.command(message.debug);
        else if (message.stop && worker) {
          // A program paused in the debugger lets go first.
          if (debug) debug.request('Debugger.resume').catch(() => {});
          worker.terminate();
        }
      }
    });
    socket.on('error', () => {});
    socket.on('close', () => { if (worker) worker.terminate(); });
  }).listen(port, '127.0.0.1');
}
