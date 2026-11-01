// Live Preview (as VS Code's Live Preview extension): the project's files over HTTP for the editor's
// preview of an HTML page. Unsaved edits are served in place of the saved files, and the page
// reloads when anything changes (a stylesheet is swapped without a reload). Pages get a small
// script for that, which also passes their console output and errors to the editor.
import fs from 'fs';
import path from 'path';

let root = null;
const buffers = new Map();   // project-relative path → unsaved text
const listeners = new Set();
let timer = 0;
let changed = new Set();

const MIME = {
  html: 'text/html', htm: 'text/html', css: 'text/css', js: 'text/javascript', mjs: 'text/javascript',
  json: 'application/json', map: 'application/json', svg: 'image/svg+xml', png: 'image/png',
  jpg: 'image/jpeg', jpeg: 'image/jpeg', gif: 'image/gif', webp: 'image/webp', ico: 'image/x-icon',
  bmp: 'image/bmp', avif: 'image/avif', woff: 'font/woff', woff2: 'font/woff2', ttf: 'font/ttf',
  otf: 'font/otf', mp3: 'audio/mpeg', wav: 'audio/wav', ogg: 'audio/ogg', mp4: 'video/mp4',
  webm: 'video/webm', txt: 'text/plain', md: 'text/markdown', xml: 'application/xml',
  wasm: 'application/wasm', glsl: 'text/plain', csv: 'text/csv', pdf: 'application/pdf',
};
const mimeOf = (file) => MIME[path.extname(file).slice(1).toLowerCase()] || 'application/octet-stream';
const isText = (mime) => /^text\/|json|xml|svg|javascript/.test(mime);

// In every HTML page: reload on changes (keeping the scroll position), swap stylesheets in place,
// and pass console output and errors to the editor (the page is in an iframe of the editor).
const CLIENT = `<script>(() => {
  const send = (level, args) => {
    try {
      const text = Array.from(args, (a) => {
        if (a instanceof Error) return a.stack || String(a);
        if (typeof a === 'object' && a !== null) { try { return JSON.stringify(a); } catch (e) { return String(a); } }
        return String(a);
      }).join(' ');
      parent.postMessage({ mobileStudioPreview: 'console', level, text, page: location.pathname }, '*');
    } catch (e) { /* the editor isn't listening */ }
  };
  for (const level of ['log', 'info', 'warn', 'error', 'debug']) {
    const original = console[level];
    console[level] = function (...args) { send(level, args); return original.apply(this, args); };
  }
  addEventListener('error', (e) => send('error', [e.error || (e.message + ' (' + e.filename + ':' + e.lineno + ')')]));
  addEventListener('unhandledrejection', (e) => send('error', ['Unhandled rejection:', e.reason]));
  const key = 'mobile-studio-scroll:' + location.pathname;
  try {
    const saved = JSON.parse(sessionStorage.getItem(key) || 'null');
    if (saved) addEventListener('load', () => scrollTo(saved[0], saved[1]));
  } catch (e) { /* no storage */ }
  const events = new EventSource('/preview/events');
  events.onmessage = (e) => {
    const paths = JSON.parse(e.data);
    const sheets = Array.from(document.querySelectorAll('link[rel~="stylesheet"][href]'));
    // Only stylesheets changed: swap them rather than reloading.
    if (paths.length && paths.every((p) => /\\.css$/i.test(p)) && sheets.length) {
      for (const link of sheets) {
        const url = new URL(link.href);
        url.searchParams.set('mobile-studio-reload', Date.now());
        link.href = url.href;
      }
      return;
    }
    try { sessionStorage.setItem(key, JSON.stringify([scrollX, scrollY])); } catch (err) { /* no storage */ }
    location.reload();
  };
})();</script>`;

function inject(html) {
  const head = /<head[^>]*>/i.exec(html);
  if (head) return html.slice(0, head.index + head[0].length) + CLIENT + html.slice(head.index + head[0].length);
  const doctype = /<!doctype[^>]*>/i.exec(html);
  if (doctype) return html.slice(0, doctype.index + doctype[0].length) + CLIENT + html.slice(doctype.index + doctype[0].length);
  return CLIENT + html;
}

function notify(paths) {
  for (const p of paths) changed.add(p);
  clearTimeout(timer);
  timer = setTimeout(() => {
    const message = 'data: ' + JSON.stringify([...changed]) + '\n\n';
    changed = new Set();
    for (const res of listeners) res.write(message);
  }, 150);
}

function readBody(req) {
  return new Promise((resolve) => {
    let body = '';
    req.setEncoding('utf8');
    req.on('data', (chunk) => { body += chunk; });
    req.on('end', () => { try { resolve(JSON.parse(body || '{}')); } catch (e) { resolve({}); } });
  });
}

function serveFile(req, res, cors, relative) {
  if (!root) { res.writeHead(404, cors); res.end('No project'); return; }
  let file = path.resolve(root, '.' + path.posix.normalize('/' + relative));
  if (file !== root && !file.startsWith(root + path.sep)) { res.writeHead(403, cors); res.end(); return; }
  let stat = null;
  try { stat = fs.statSync(file); } catch (e) { /* missing, or only in the editor */ }
  if (stat && stat.isDirectory()) {
    if (!req.url.split('?')[0].endsWith('/')) {
      res.writeHead(301, { ...cors, Location: req.url.split('?')[0] + '/' });
      res.end();
      return;
    }
    file = path.join(file, 'index.html');
  }
  const key = path.relative(root, file).split(path.sep).join('/');
  const mime = mimeOf(file);
  const headers = { ...cors, 'Content-Type': mime + (isText(mime) ? '; charset=utf-8' : ''), 'Cache-Control': 'no-store' };
  let data;
  if (buffers.has(key)) data = Buffer.from(buffers.get(key), 'utf8');
  else {
    try { data = fs.readFileSync(file); } catch (e) {
      res.writeHead(404, { ...headers, 'Content-Type': 'text/html; charset=utf-8' });
      res.end(inject(`<!doctype html><title>Not found</title><p style="font:14px -apple-system,sans-serif;padding:16px">${key.replace(/[<&]/g, '')} wasn't found.</p>`));
      return;
    }
  }
  if (mime === 'text/html') data = Buffer.from(inject(data.toString('utf8')), 'utf8');
  res.writeHead(200, { ...headers, 'Content-Length': data.length });
  res.end(req.method === 'HEAD' ? undefined : data);
}

/** Handles /preview/… requests; false for anything else. */
export function servePreview(req, res, cors) {
  const url = req.url.split('?')[0];
  if (!url.startsWith('/preview/')) return false;
  const action = url.slice('/preview/'.length);
  if (action === 'events') {
    res.writeHead(200, { ...cors, 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache', Connection: 'keep-alive' });
    res.write(': connected\n\n');
    listeners.add(res);
    req.on('close', () => listeners.delete(res));
    return true;
  }
  if (action.startsWith('files/')) {
    let relative = action.slice('files/'.length);
    try { relative = decodeURIComponent(relative); } catch (e) { /* as it is */ }
    serveFile(req, res, cors, relative);
    return true;
  }
  if (req.method !== 'POST') { res.writeHead(404, cors); res.end(); return true; }
  readBody(req).then((params) => {
    // root {dir}: the project; buffer {path, text}: unsaved text (null: saved); changed {paths}.
    if (action === 'root') {
      const next = params.dir ? path.resolve(params.dir) : null;
      if (next !== root) buffers.clear();
      root = next;
    } else if (action === 'buffer' && params.path) {
      if (typeof params.text === 'string') {
        if (buffers.get(params.path) !== params.text) { buffers.set(params.path, params.text); notify([params.path]); }
      } else if (buffers.delete(params.path)) {
        // Saved: the file has what the buffer had, so nothing changes.
      }
    } else if (action === 'changed') notify(params.paths || []);
    res.writeHead(200, { ...cors, 'Content-Type': 'application/json' });
    res.end('{"ok":true}');
  });
  return true;
}
