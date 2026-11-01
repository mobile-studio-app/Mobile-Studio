// The extension host for extensions whose code needs Node.js, run by nodejs-mobile
// (App/Extensions/NodeExtensionHost.swift). It runs worker.js, the same vscode API the Web Worker
// host has, and speaks the same messages over HTTP on the loopback interface: the page posts
// messages to /in and reads the host's from /out (server-sent events).
import './node-globals.js';
import fs from 'fs';
import http from 'http';
import os from 'os';
import path from 'path';
import './worker.js';
import { servePrograms } from './node-programs.js';
import { childProcess } from './node-child.js';
import { npmInstall } from './node-npm.js';
import { runCommand } from './node-tasks.js';
import { setNativePort } from './node-native.js';
import { fetchPreloadArgv, installFetch, installHome, isUndiciWasmError, writableHome } from './node-fetch.js';
import { closeSession, getSession, openSession } from './node-shell.js';
import { servePreview } from './node-preview.js';

// Extensions get child_process that runs Node.js scripts as worker threads (see node-child.js).
globalThis.__childProcessShim = childProcess;

const port = Number(process.argv[2]) || 47831;
// JavaScript programs (the Node.js runtime) on the next port.
servePrograms(Number(process.argv[3]) || port + 1);
// Extensions' macOS programs are started through the app (App/NativeTools/NativeTools.mm).
setNativePort(process.argv[4]);
let client = null;
const backlog = [];

globalThis.postMessage = (message) => {
  const line = 'data: ' + JSON.stringify(message) + '\n\n';
  if (client) client.write(line); else backlog.push(line);
};

// The host's log, also kept in a file (written line by line, so it survives Node stopping) that
// the app can show when Node.js has stopped (EditorWebView's nodeHostLog).
const logFile = path.join(os.tmpdir(), 'mobile-studio-node-host.log');
function record(text) {
  try {
    if (fs.existsSync(logFile) && fs.statSync(logFile).size > 512 * 1024) fs.writeFileSync(logFile, '(earlier lines dropped)\n');
    fs.appendFileSync(logFile, `${new Date().toISOString().slice(11, 23)} ${String(text).slice(0, 2000)}\n`);
  } catch (e) { /* no room: carry on */ }
}
try { fs.writeFileSync(logFile, `Node.js ${process.version} extension host started (${process.platform} ${process.arch})\n`); } catch (e) { /* as above */ }
for (const level of ['log', 'info', 'warn', 'error']) {
  const original = console[level].bind(console);
  console[level] = (...args) => {
    record(`[${level}] ` + args.map((a) => (a instanceof Error ? a.stack : typeof a === 'string' ? a : (() => { try { return JSON.stringify(a); } catch (e) { return String(a); } })())).join(' '));
    original(...args);
  };
}

const log = (level, text) => {
  record(`[${level}] ${text}`);
  globalThis.postMessage({ type: 'notify', method: 'log', params: { level, text } });
};

// Node.js starts once per launch, so nothing an extension does may end it: as in VS Code's extension
// host, process.exit is refused, and so are signals and abort aimed at this process (on iOS they
// would end the whole app).
const caller = () => new Error().stack.split('\n').slice(3, 7).map((l) => l.trim()).join(' ← ');
process.exit = (code) => {
  log('warning', `An extension called process.exit(${code ?? ''}); the extension host keeps running. ${caller()}`);
};
process.abort = () => {
  log('warning', `An extension called process.abort(); the extension host keeps running. ${caller()}`);
};
const kill = process.kill.bind(process);
process.kill = (pid, signal) => {
  if (Number(pid) === process.pid || Number(pid) === 0) {
    log('warning', `An extension sent ${signal || 'SIGTERM'} to the extension host; ignored. ${caller()}`);
    return true;
  }
  return kill(pid, signal);
};
process.on('exit', (code) => record(`Node.js is exiting (code ${code}).`));
process.on('uncaughtException', (e) => log('error', 'Node.js extension host: ' + (e && e.stack ? e.stack.split('\n').slice(0, 3).join(' ') : e)));
process.on('unhandledRejection', (e) => {
  if (isUndiciWasmError(e)) return;   // see node-fetch.js
  log('error', 'Node.js extension host: ' + (e && e.message ? e.message : e));
});
// fetch() without WebAssembly, and a home folder that can be written to, here and in worker
// threads (node-fetch.js).
installFetch();
installHome(writableHome(), false);
fetchPreloadArgv();

const cors = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': '*' };

http.createServer((req, res) => {
  if (req.method === 'OPTIONS') { res.writeHead(204, cors); res.end(); return; }
  if (req.url === '/ping') { res.writeHead(200, cors); res.end('ok'); return; }
  // Live Preview of HTML pages (node-preview.js).
  if (servePreview(req, res, cors)) return;
  if (req.url === '/out') {
    res.writeHead(200, { ...cors, 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache', Connection: 'keep-alive' });
    res.write(': connected\n\n');
    if (client) client.end();
    client = res;
    for (const line of backlog.splice(0)) res.write(line);
    req.on('close', () => { if (client === res) client = null; });
    return;
  }
  // npm and tasks: progress streams back as JSON lines, { out } then { exit }.
  if ((req.url === '/npm' || req.url === '/task') && req.method === 'POST') {
    let body = '';
    req.setEncoding('utf8');
    req.on('data', (chunk) => { body += chunk; });
    req.on('end', () => {
      res.writeHead(200, { ...cors, 'Content-Type': 'application/x-ndjson', 'Cache-Control': 'no-cache' });
      const write = (text) => { if (!res.writableEnded) res.write(JSON.stringify({ out: String(text) }) + '\n'); };
      let job;
      try {
        const params = JSON.parse(body);
        job = req.url === '/npm' ? npmInstall(params.dir, params.packages || [], write) : runCommand(params.command, params.dir, params.cwd, write);
      } catch (e) {
        job = Promise.reject(e);
      }
      job.then((code) => res.end(JSON.stringify({ exit: code }) + '\n'), (e) => {
        write((e && e.message ? e.message : String(e)) + '\n');
        res.end(JSON.stringify({ exit: 1 }) + '\n');
      });
    });
    return;
  }
  // The Terminal (node-shell.js): a session per terminal, its events as server-sent events.
  if (req.url.startsWith('/term/events?')) {
    const session = getSession(new URL(req.url, 'http://x').searchParams.get('id'));
    if (!session) { res.writeHead(404, cors); res.end(); return; }
    res.writeHead(200, { ...cors, 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache', Connection: 'keep-alive' });
    res.write(': connected\n\n');
    const stop = session.listen((message) => res.write('data: ' + JSON.stringify(message) + '\n\n'));
    req.on('close', stop);
    return;
  }
  if (req.url.startsWith('/term/') && req.method === 'POST') {
    let body = '';
    req.setEncoding('utf8');
    req.on('data', (chunk) => { body += chunk; });
    req.on('end', () => {
      let params = {};
      try { params = JSON.parse(body || '{}'); } catch (e) { /* empty */ }
      const action = req.url.slice('/term/'.length);
      const session = getSession(params.id);
      let result = { ok: true };
      if (action === 'open') {
        const opened = openSession(params.dir || process.cwd());
        opened.ready();
        result = { id: opened.id, cwd: opened.cwd };
      } else if (!session) {
        res.writeHead(404, cors); res.end(); return;
      } else if (action === 'input') session.input(String(params.line ?? ''));
      else if (action === 'signal') session.signal(params.name);
      else if (action === 'reply') session.reply(params.call, params.result);
      else if (action === 'complete') result = session.complete(String(params.line ?? ''));
      else if (action === 'close') closeSession(params.id);
      res.writeHead(200, { ...cors, 'Content-Type': 'application/json' });
      res.end(JSON.stringify(result));
    });
    return;
  }
  if (req.url === '/in' && req.method === 'POST') {
    let body = '';
    req.setEncoding('utf8');
    req.on('data', (chunk) => { body += chunk; });
    req.on('end', () => {
      res.writeHead(200, cors);
      res.end('ok');
      try {
        const data = JSON.parse(body);
        Promise.resolve(globalThis.onmessage && globalThis.onmessage({ data })).catch((e) => log('error', String(e)));
      } catch (e) {
        log('error', 'Bad message: ' + e.message);
      }
    });
    return;
  }
  res.writeHead(404, cors);
  res.end();
}).listen(port, '127.0.0.1');
