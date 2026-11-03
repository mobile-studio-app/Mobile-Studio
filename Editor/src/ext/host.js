// The page side of the extension hosts: the web one (a Web Worker) and, for extensions whose
// code needs Node.js, the Node.js one (node-host.js, reached over a local HTTP port).
// The page side of the web extension host. Extensions with a `browser` entry point run in a
// Web Worker (worker.js, bundled as text); this file starts it, answers its requests (messages,
// quick picks, files, edits) and connects its providers to CodeMirror: completions, hovers,
// diagnostics, formatting, go to definition, symbols and commands for the Command Palette.
import { hoverTooltip, keymap, EditorView, Decoration, ViewPlugin, WidgetType } from '@codemirror/view';
import { RangeSetBuilder, Text } from '@codemirror/state';
import { linter, forceLinting } from '@codemirror/lint';
import { snippetCompletion } from '@codemirror/autocomplete';
import { indentRange } from '@codemirror/language';
import workerSource from '../../build/ext-worker.txt';
import { contributions, readExtensionFile } from './registry.js';
import { convertSnippet } from './snippets.js';
import { relativeRequires, candidates } from './modules.js';
import { quickPick, inputBox, closeQuickInput, notify as showNotification } from './ui.js';
import { showWebview, postToWebview, retitleWebview, closeWebview, reveal as revealWebview } from './webviews.js';
import { channelOutput } from './output.js';

let hosts = [];           // { name: 'web' | 'node', port: { postMessage, onmessage, terminate } }
let nodePort = null;      // the Node.js host's connection, kept across restarts (Node starts once)
let app = null;           // { native, view, current, openFile, reveal, save, languageIdFor, builtinCommands }
let root = '/workspace';
let nextId = 1;
const calls = new Map();
const diagnostics = new Map();   // uri -> owner -> items
const statusItems = new Map();   // id -> { text, tooltip, command }
const output = [];               // the log, newest last
const decorationTypes = new Map();   // key -> options (createTextEditorDecorationType)
const decorations = new Map();       // uri -> key -> [{ range, hover, renderOptions }]
let decorationVersion = 0;

const uriFor = (path) => 'file://' + encodeURI(root + '/' + path);
function pathFor(uri) {
  const m = /^file:\/\/[^/]*(\/.*)$/.exec(uri);
  const path = m ? decodeURI(m[1]) : uri;
  return path.startsWith(root + '/') ? path.slice(root.length + 1) : path.replace(/^\//, '');
}

export const isRunning = () => hosts.length > 0;
export const outputLog = () => output.slice();

/** Extensions' diagnostics for every file: [{ path, items }], items as the host reports them
 * (range in 0-based lines and characters, severity 0 error ... 3 hint). */
export function hostDiagnostics() {
  const out = [];
  for (const [uri, byOwner] of diagnostics) {
    const items = [...byOwner.values()].flat();
    if (items.length) out.push({ path: pathFor(uri), items });
  }
  return out;
}

let diagnosticsListener = null;
/** `fn` runs when an extension's diagnostics change (for the Problems panel). */
export function onDiagnosticsChanged(fn) { diagnosticsListener = fn; }

/** The Node.js host's address (starting it if needed), for the Terminal; null without Node.js. */
export async function nodeAddress(appAPI) {
  if (!app) app = appAPI;
  return (await connectNode()) ? nodeBase : null;
}

/** Asks one host to do something (run a provider or command). */
function callHost(host, method, params) {
  const id = nextId++;
  host.port.postMessage({ type: 'call', id, method, params });
  return new Promise((resolve, reject) => calls.set(id, { resolve, reject, host }));
}

/** Node.js stopped (it can't start again until the app does): its host's calls fail instead of
 * waiting forever, it leaves the list, and the user hears why, with the end of its log. */
let nodeStopped = false;
async function nodeHostStopped() {
  if (nodeStopped) return;
  nodeStopped = true;
  for (const [id, entry] of calls) {
    if (entry.host && entry.host.name === 'node') { calls.delete(id); entry.reject(new Error('The Node.js extension host stopped.')); }
  }
  hosts = hosts.filter((h) => h.name !== 'node');
  const tail = await app.native({ cmd: 'nodeHostLog' }).catch(() => '');
  if (tail) channelOutput('Extensions', 'append', `--- Node.js extension host log (last lines) ---\n${tail}\n`);
  log('error', 'The Node.js extension host stopped, so Node.js extensions, the Terminal and Live Preview won\'t work until Mobile Studio is restarted. Its log is in Output → Extensions.');
}

/** Keeps the first of each item with the same key. */
function unique(list, key) {
  const seen = new Set();
  return list.filter((item) => { const k = key(item); if (seen.has(k)) return false; seen.add(k); return true; });
}
const rangeKey = (r) => (r && r.start ? `${r.start.line}:${r.start.character}-${r.end.line}:${r.end.character}` : '');

/** Asks every host, and combines their answers (lists join, without duplicates; otherwise the first answer).
 * The same extension features can come from both hosts (or two extensions), so answers repeat. */
async function call(method, params) {
  if (!hosts.length) return null;
  const results = await Promise.all(hosts.map((h) => callHost(h, method, params).catch(() => null)));
  const lists = () => results.flatMap((r) => (Array.isArray(r) ? r : []));
  if (method === 'completion') return unique(lists(), (c) => `${c.label}\0${c.snippet ?? c.text ?? ''}`);
  if (method === 'symbols') return unique(lists(), (s) => `${s.name}\0${s.kind}\0${rangeKey(s.range)}`);
  if (method === 'commandList') return unique(lists(), (c) => c.command);
  if (method === 'taskList') return lists();
  if (method === 'hover') {
    const parts = unique(results.filter(Boolean).flatMap((r) => r.split('\n\n---\n\n')), (p) => p.trim());
    return parts.length ? parts.join('\n\n---\n\n') : null;
  }
  return results.find((r) => r != null) ?? null;
}

/** Document and settings changes go to every host. */
const post = (message) => { for (const h of hosts) h.port.postMessage(message); };

/** Reads an extension's browser entry point and every file it requires relatively. */
async function loadModules(id, manifest) {
  const modules = {};
  const misses = new Set();
  const read = async (choices) => {
    for (const path of choices) {
      if (path in modules) return path;
      if (misses.has(path)) continue;
      try {
        modules[path] = await readExtensionFile(id, path);
        return path;
      } catch (e) { misses.add(path); }
    }
    return null;
  };
  const main = await read(candidates('', manifest.browser));
  if (!main) return null;
  const queue = [main];
  while (queue.length && Object.keys(modules).length < 200) {
    const path = queue.shift();
    const dir = path.split('/').slice(0, -1).join('/');
    for (const name of relativeRequires(modules[path])) {
      const before = Object.keys(modules).length;
      const found = await read(candidates(dir, name));
      if (found && Object.keys(modules).length > before) queue.push(found);
    }
  }
  return { main, modules };
}

const blobURL = (source) => URL.createObjectURL(new Blob([source], { type: 'text/javascript' }));

let workerCheck = null;
/** Whether this web view runs Web Workers from blob URLs (a file:// page may not). */
function workersWork() {
  // window.__duocodeInPageExtensions forces the fallback (for testing it).
  if (window.__duocodeInPageExtensions) return Promise.resolve(false);
  if (!workerCheck) {
    workerCheck = new Promise((resolve) => {
      let probe;
      const done = (ok) => { clearTimeout(timer); try { probe && probe.terminate(); } catch (e) { /* gone */ } resolve(ok); };
      const timer = setTimeout(() => done(false), 1500);
      try {
        probe = new Worker(blobURL('postMessage("ok")'));
        probe.onmessage = () => done(true);
        probe.onerror = () => done(false);
      } catch (e) {
        done(false);
      }
    });
  }
  return workerCheck;
}

/** The worker's code run on the page instead, behind the same message interface. */
function inPageWorker(source) {
  log('info', 'Web Workers are unavailable here; extensions run on the page.');
  const scope = { onmessage: null };
  const host = {
    onmessage: null,
    onerror: null,
    postMessage: (data) => setTimeout(() => scope.onmessage && scope.onmessage({ data: structuredClone(data) })),
    terminate: () => { scope.onmessage = null; host.onmessage = null; },
  };
  const toPage = (data) => setTimeout(() => host.onmessage && host.onmessage({ data: structuredClone(data) }));
  try {
    new Function('postMessage', 'self', source)(toPage, scope);
  } catch (e) {
    log('error', `Extension host: ${e.message || e}`);
  }
  return host;
}

/** The Node.js host as a message port: posts go to /in (in order), messages come from /out. */
function nodeConnection(port) {
  const base = 'http://127.0.0.1:' + port;
  const conn = { onmessage: null, onerror: null };
  let chain = Promise.resolve();
  conn.postMessage = (message) => {
    const body = JSON.stringify(message);
    chain = chain.then(() => fetch(base + '/in', { method: 'POST', body, headers: { 'Content-Type': 'text/plain' } })).catch(() => {});
  };
  let events = null;
  const open = () => {
    events = new EventSource(base + '/out');
    events.onmessage = (e) => { try { conn.onmessage && conn.onmessage({ data: JSON.parse(e.data) }); } catch (err) { /* ignore */ } };
    events.onerror = () => checkHealth();
  };
  // EventSource reconnects by itself after a blip. When the host doesn't answer, it may be that
  // iOS took its socket while the app was in the background (the host listens again by itself), so
  // the page keeps trying for a couple of minutes, and only reports Node.js stopped when the app
  // says its thread has ended, or it never comes back.
  let checking = false;
  const ping = () => fetch(base + '/ping').then((r) => r.ok, () => false);
  async function checkHealth() {
    if (checking || nodeStopped) return;
    checking = true;
    for (let wait = 1000, waited = 0; waited < 120000; waited += wait, wait = Math.min(wait * 2, 15000)) {
      await new Promise((r) => setTimeout(r, wait));
      if (await ping()) {
        if (events.readyState === EventSource.CLOSED) open();
        checking = false;
        return;
      }
      const status = await app.native({ cmd: 'nodeHostStatus' }).catch(() => null);
      if (status && status.running === false) break;
    }
    checking = false;
    events.close();
    nodeHostStopped();
  }
  conn.checkHealth = checkHealth;
  open();
  conn.terminate = () => events.close();
  return conn;
}

/** Starts Node.js (once per launch) and waits until its host answers. */
let nodeBase = null;
async function connectNode() {
  if (nodePort) return nodePort;
  const port = await app.native({ cmd: 'nodeHostStart' }).catch(() => null);
  if (typeof port !== 'number') return null;
  for (let tries = 0; tries < 100; tries++) {
    const ok = await fetch('http://127.0.0.1:' + port + '/ping').then((r) => r.ok, () => false);
    if (ok) { nodePort = nodeConnection(port); nodeBase = 'http://127.0.0.1:' + port; return nodePort; }
    await new Promise((r) => setTimeout(r, 300));
  }
  log('error', 'Node.js didn\'t start, so extensions that need it aren\'t running.');
  return null;
}

/** (Re)starts the host with the enabled extensions that have browser code. */
export async function startHost(api) {
  app = api;
  stopHost();
  const web = contributions.extensions.filter((e) => typeof e.manifest.browser === 'string');
  // Extensions without browser code run their Node.js code in the Node.js host.
  const node = contributions.extensions.filter((e) => typeof e.manifest.browser !== 'string' && typeof e.manifest.main === 'string' && e.path);
  if (!web.length && !node.length) {
    if (nodePort) nodePort.postMessage({ type: 'init', host: 'node', workspaceRoot: root, extensions: [] });
    return;
  }
  let init = {};
  try { init = (await app.native({ cmd: 'extHostInit' })) || {}; } catch (e) { init = {}; }
  // The project's real folder, so Node.js extensions' file access works on the paths they see.
  root = init.projectPath || '/' + (init.project || 'workspace');
  if (node.length) {
    const port = await connectNode();
    if (port) {
      const host = { name: 'node', port };
      port.onmessage = ({ data }) => receive(data, host);
      hosts.push(host);
      const joinPath = (dir, file) => dir.replace(/\/$/, '') + '/' + file.replace(/^\.\//, '');
      port.postMessage({
        type: 'init', host: 'node', workspaceRoot: root, configuration: init.configuration || {}, state: init.state || {}, themeKind: themeKind(),
        extensions: node.map((e) => ({ id: e.id, manifest: e.manifest, path: e.path, nodeMain: joinPath(e.path, e.manifest.main) })),
      });
    }
  }
  const extensions = [];
  for (const e of web) {
    const loaded = await loadModules(e.id, e.manifest).catch(() => null);
    if (loaded) extensions.push({ id: e.id, manifest: e.manifest, ...loaded });
    else log('error', `${e.manifest.displayName || e.id}: its browser code is missing`);
  }
  if (extensions.length) {
    const port = (await workersWork()) ? new Worker(blobURL(workerSource)) : inPageWorker(workerSource);
    const host = { name: 'web', port };
    port.onmessage = ({ data }) => receive(data, host);
    port.onerror = (e) => log('error', `Extension host: ${e.message || e}`);
    hosts.push(host);
    port.postMessage({ type: 'init', host: 'web', workspaceRoot: root, configuration: init.configuration || {}, state: init.state || {}, themeKind: themeKind(), extensions });
  }
  if (!hosts.length) return;
  const path = app.current();
  if (path) didOpen(path, app.view.state.doc.toString());
}

/** The app came back to the foreground: the Node.js host's connection is checked (and mended). */
export function checkNodeHost() {
  if (nodePort && nodePort.checkHealth) nodePort.checkHealth();
}

export function stopHost() {
  // The Node.js host stays up (Node starts once per launch); startHost resets it.
  for (const h of hosts) if (h.name === 'web') h.port.terminate();
  hosts = [];
  for (const { reject } of calls.values()) reject(new Error('Extension host stopped'));
  calls.clear();
  diagnostics.clear();
  statusItems.clear();
  decorationTypes.clear();
  decorations.clear();
  if (app) refreshDecorations();
  renderStatus();
}

function log(level, text) {
  output.push({ level, text, time: Date.now() });
  if (output.length > 500) output.shift();
  channelOutput('Extensions', 'append', `${new Date().toLocaleTimeString()} [${level}] ${text}\n`);
  if (level === 'error') showNotification('error', text, []);
}

// MARK: - From the worker

function receive(message, host) {
  switch (message.type) {
    case 'reply': {
      const entry = calls.get(message.id);
      if (!entry) return;
      calls.delete(message.id);
      if (message.error) entry.reject(new Error(message.error)); else entry.resolve(message.result);
      return;
    }
    case 'notify':
      onNotify(message.method, message.params || {}, host);
      return;
    case 'request': {
      const handler = requests[message.method];
      Promise.resolve(handler ? handler(message.params || {}) : null).then(
        (result) => host.port.postMessage({ type: 'reply', id: message.id, result: result === undefined ? null : result }),
        (e) => host.port.postMessage({ type: 'reply', id: message.id, error: e && e.message ? e.message : String(e) }),
      );
      return;
    }
    default:
  }
}

function onNotify(method, params, host) {
  if (method === 'log') log(params.level, params.text);
  if (method === 'output') channelOutput(params.channel, params.op, params.text);
  if (method === 'treeChanged') app.native({ cmd: 'extViewChanged', viewId: params.viewId }).catch(() => {});
  if (method === 'treeReveal') app.native({ cmd: 'extViewReveal', viewId: params.viewId }).catch(() => {});
  if (method === 'runTask') runTask(params.id, params.label);
  if (method === 'taskEnd') channelOutput('Tasks', 'append', `\n${params.label || 'Task'} finished${params.code ? ` with exit code ${params.code}` : ''}.\n`);
  if (method === 'statusItem') {
    if (params.text) statusItems.set(params.id, params); else statusItems.delete(params.id);
    renderStatus();
  }
  // withProgress: shown as a status bar item until the task ends (tap to cancel, if it can be).
  if (method === 'progress') {
    if (params.done) statusItems.delete(params.id);
    else {
      const text = ['$(loading~spin)', params.title, params.message].filter(Boolean).join(' ') + (params.percent != null ? ` ${params.percent}%` : '');
      statusItems.set(params.id, { id: params.id, text, tooltip: params.cancellable ? 'Tap to cancel' : '', progress: true, cancellable: params.cancellable, host, alignment: 1, priority: 1e6 });
    }
    renderStatus();
  }
  if (method === 'webview') showWebview(params);
  if (method === 'webviewPost') postToWebview(params);
  if (method === 'webviewTitle') retitleWebview(params);
  if (method === 'webviewReveal') { app.showWebviewTab && app.showWebviewTab(params.id); revealWebview(params.id); }
  if (method === 'webviewClose') closeWebview(params.id, true);
  if (method === 'decorationType') {
    if (params.options) decorationTypes.set(params.key, params.options);
    else { decorationTypes.delete(params.key); for (const byKey of decorations.values()) byKey.delete(params.key); }
    refreshDecorations();
  }
  if (method === 'setDecorations') {
    if (!decorations.has(params.uri)) decorations.set(params.uri, new Map());
    decorations.get(params.uri).set(params.key, params.ranges);
    if (app && pathFor(params.uri) === app.current()) refreshDecorations();
  }
  if (method === 'diagnostics') {
    if (!diagnostics.has(params.uri)) diagnostics.set(params.uri, new Map());
    diagnostics.get(params.uri).set(params.owner, params.items);
    if (app && pathFor(params.uri) === app.current()) forceLinting(app.view);
    if (diagnosticsListener) diagnosticsListener();
  }
}

// Status bar items go in the tab bar, before the cursor position. "$(icon)" codicons show as text.
function renderStatus() {
  let bar = document.getElementById('ext-status');
  if (!bar) {
    const pos = document.getElementById('pos');
    if (!pos) return;
    bar = document.createElement('span');
    bar.id = 'ext-status';
    bar.className = 'ext-status';
    pos.before(bar);
  }
  bar.textContent = '';
  // Left-aligned items first; higher priority further left (VS Code's order).
  const sorted = [...statusItems.values()].sort((a, b) => ((a.alignment || 1) - (b.alignment || 1)) || ((b.priority || 0) - (a.priority || 0)));
  for (const item of sorted) {
    const el = document.createElement('button');
    el.className = 'ext-status-item';
    el.textContent = item.text.replace(/\$\(([\w-]+)(~spin)?\)/g, (_, icon) => ICON_TEXT[icon] || '');
    el.title = item.tooltip || '';
    const color = themeColor(item.color);
    if (color) el.style.color = color;
    const background = { 'statusBarItem.errorBackground': '#c72e0f', 'statusBarItem.warningBackground': '#7a6400', 'statusBarItem.prominentBackground': 'rgba(255, 255, 255, .15)' }[item.background];
    if (background) { el.style.background = background; el.style.color = '#fff'; }
    if (item.progress) {
      if (item.cancellable) el.onclick = () => item.host.port.postMessage({ type: 'progressCancel', id: item.id });
      else el.disabled = true;
    } else if (item.command) el.onclick = () => runCommand(item.command, ...(item.args || []));
    else el.disabled = true;
    bar.append(el);
  }
}
/** A colour as a CSS value: '#rrggbb', or a theme colour id ('errorForeground'). */
function themeColor(color) {
  if (!color) return '';
  if (/^(#|rgb|hsl)/.test(color)) return color;
  return THEME_COLORS[color] || '';
}
const ICON_TEXT = { check: '✓', error: '⊗', warning: '⚠', info: 'ⓘ', sync: '⟳', loading: '⟳', gear: '⚙', bell: '🔔', zap: '⚡', 'circle-slash': '⊘', play: '▶', debug: '🐞' };

// MARK: - Positions and edits

function offsetAt(doc, p) {
  const line = doc.line(Math.max(1, Math.min(p.line + 1, doc.lines)));
  return Math.min(line.from + Math.max(0, p.character), line.to);
}
function positionAt(doc, offset) {
  const line = doc.lineAt(offset);
  return { line: line.number - 1, character: offset - line.from };
}
/** LSP-style text edits on a string. */
function applyToText(text, edits) {
  const starts = [0];
  for (let i = 0; i < text.length; i++) if (text[i] === '\n') starts.push(i + 1);
  const at = (p) => Math.min((starts[Math.min(p.line, starts.length - 1)] ?? text.length) + p.character, text.length);
  const sorted = edits.map((e) => ({ from: at(e.range.start), to: at(e.range.end), text: e.newText })).sort((a, b) => b.from - a.from);
  for (const e of sorted) text = text.slice(0, e.from) + e.text + text.slice(e.to);
  return text;
}
function applyToView(edits) {
  const { view } = app;
  const doc = view.state.doc;
  const changes = edits.map((e) => ({ from: offsetAt(doc, e.range.start), to: offsetAt(doc, e.range.end), insert: e.newText }));
  view.dispatch({ changes, userEvent: 'input.extension' });
}

// MARK: - Requests from the worker

function globToRegExp(glob) {
  let re = '';
  for (let i = 0; i < glob.length; i++) {
    const c = glob[i];
    if (c === '*' && glob[i + 1] === '*') { re += glob[i + 2] === '/' ? '(?:.*/)?' : '.*'; i += glob[i + 2] === '/' ? 2 : 1; }
    else if (c === '*') re += '[^/]*';
    else if (c === '?') re += '[^/]';
    else if (c === '{') re += '(?:';
    else if (c === '}') re += ')';
    else if (c === ',') re += '|';
    else re += c.replace(/[.+^$()|[\]\\]/g, '\\$&');
  }
  return new RegExp('^' + re + '$');
}

const requests = {
  message: ({ severity, text, items }) => showNotification(severity, text, items),
  quickPick: (params) => quickPick(params),
  inputBox: (params) => inputBox(params),
  async readDocument({ uri }) {
    const path = pathFor(uri);
    const text = path === app.current() ? app.view.state.doc.toString() : await app.native({ cmd: 'read', path });
    return { text, languageId: app.languageIdFor(path) };
  },
  async applyEdit({ changes }) {
    // The files written to disk (not open here): the hosts update their copies (custom editors).
    const written = [];
    for (const { uri, edits } of changes) {
      const path = pathFor(uri);
      if (path === app.current()) applyToView(edits);
      else {
        const text = await app.native({ cmd: 'read', path }).catch(() => '');
        await app.native({ cmd: 'write', path, contents: applyToText(text, edits) });
        written.push(uri);
      }
    }
    return { written };
  },
  async findFiles({ pattern, exclude }) {
    const files = (await app.native({ cmd: 'list' })) || [];
    const test = (glob) => {
      const re = globToRegExp(glob.replace(/^\.?\//, ''));
      return (f) => re.test(f) || (!glob.includes('/') && re.test(f.split('/').pop()));
    };
    const included = test(pattern);
    const excluded = exclude ? test(exclude) : () => false;
    return files.filter((f) => included(f) && !excluded(f));
  },
  secret: (params) => app.native({ cmd: 'extSecret', ...params }),
  terminalSend: ({ text, fresh }) => app.runInTerminal(text, fresh),
  terminalShow: () => app.runInTerminal('', false).then(() => true),
  closeQuickInput: () => { closeQuickInput(); return true; },
  // TextEditor.selection set by an extension.
  select({ uri, anchor, active }) {
    if (pathFor(uri) !== app.current()) return false;
    const doc = app.view.state.doc;
    const from = offsetAt(doc, anchor);
    const to = offsetAt(doc, active);
    app.view.dispatch({ selection: { anchor: from, head: to }, effects: EditorView.scrollIntoView(to, { y: 'nearest' }) });
    return true;
  },
  showVirtualDocument: ({ uri, text, languageId }) => app.showVirtual(uri, text, languageId),
  builtinCommandList: () => app.builtinCommands().map((c) => c.command),
  extFile: ({ id, path }) => app.native({ cmd: 'extRead', id, path, binary: true }),
  fs: ({ op, uri, to, base64 }) => app.native({ cmd: 'fs', op, path: pathFor(uri), to: to && pathFor(to), base64 }),
  saveState: ({ key, value }) => app.native({ cmd: 'extSaveState', key, value }),
  saveConfiguration: ({ values }) => app.native({ cmd: 'extSaveConfiguration', values }),
  clipboardRead: () => app.native({ cmd: 'clipboardRead' }),
  clipboardWrite: ({ text }) => app.native({ cmd: 'clipboardWrite', text }),
  openExternal: ({ uri }) => app.native({ cmd: 'openExternal', uri }),
  async openFile({ uri }) { await app.openFile(pathFor(uri)); return true; },
  save: () => app.save(),
  insertSnippet({ snippet }) {
    const { view } = app;
    const completion = snippetCompletion(convertSnippet(snippet, app.current()), { label: '' });
    const { from, to } = view.state.selection.main;
    completion.apply(view, completion, from, to);
    return true;
  },
  reveal({ range }) {
    const { view } = app;
    const pos = offsetAt(view.state.doc, range.start);
    view.dispatch({ effects: EditorView.scrollIntoView(pos, { y: 'center' }) });
    return true;
  },
  languages: () => [...new Set(['lua', 'python', 'json', 'markdown', 'c', 'cpp', 'glsl', 'plaintext', ...contributions.languages.keys()])],
  async builtinCommand({ name, args }) {
    const builtin = app.builtinCommands().find((c) => c.command === name);
    if (builtin) return builtin.run(...(args || []));
    if (name === 'vscode.open' && args?.[0]) { await app.openFile(pathFor(args[0].path ? 'file://' + args[0].path : String(args[0]))); return true; }
    // Context keys decide which of an extension's view menu items show (`when` clauses).
    if (name === 'setContext' && typeof args?.[0] === 'string') { app.native({ cmd: 'extSetContext', key: args[0], value: args[1] ?? null }).catch(() => {}); return null; }
    return null;   // other workbench internals have nothing to do here
  },
};

// MARK: - Document sync

let changeTimer = 0;
let version = 1;
export function didOpen(path, text) {
  if (!hosts.length) return;
  post({ type: 'docOpen', uri: uriFor(path), languageId: app.languageIdFor(path), text, version: ++version });
}
export function didChange(path, getText) {
  if (!hosts.length) return;
  clearTimeout(changeTimer);
  changeTimer = setTimeout(() => post({ type: 'docChange', uri: uriFor(path), text: getText(), version: ++version }), 250);
}
export function didSave(path) { post({ type: 'docSave', uri: uriFor(path) }); }

/** A file or folder the app created, deleted ('delete') or moved ('rename', to): extensions' file
 * watchers hear. Paths are project-relative. */
export function didChangeFile(kind, path, to) {
  if (!hosts.length) return;
  post({ type: 'fileEvent', kind, uri: uriFor(path), to: to ? uriFor(to) : undefined });
}

/** ColorThemeKind: 1 light, 2 dark. */
const themeKind = () => (document.documentElement.style.colorScheme === 'light' ? 1 : 2);
let lastThemeKind = 0;
/** The theme changed: extensions' activeColorTheme follows. */
export function didChangeTheme() {
  const kind = themeKind();
  if (kind === lastThemeKind) return;
  lastThemeKind = kind;
  if (hosts.length) post({ type: 'theme', kind });
}
let selectionTimer = 0;
export function didSelect(path, state) {
  if (!hosts.length) return;
  clearTimeout(selectionTimer);
  selectionTimer = setTimeout(() => {
    const { anchor, head } = state.selection.main;
    post({ type: 'selection', uri: uriFor(path), anchor: positionAt(state.doc, anchor), head: positionAt(state.doc, head) });
  }, 150);
}
/** Sends any pending edit at once, before a provider runs. */
function flushChange() {
  if (!changeTimer || !app.current()) return;
  clearTimeout(changeTimer);
  changeTimer = 0;
  post({ type: 'docChange', uri: uriFor(app.current()), text: app.view.state.doc.toString(), version: ++version });
}

// MARK: - CodeMirror

const KIND_TYPES = { 1: 'method', 2: 'function', 3: 'function', 4: 'property', 5: 'variable', 6: 'class', 7: 'interface', 8: 'namespace', 9: 'property', 12: 'enum', 13: 'keyword', 19: 'enum', 20: 'constant', 21: 'class', 24: 'type' };

/** Completions from extensions' completion providers. */
export async function extensionCompletions(context) {
  if (!hosts.length || !app.current()) return null;
  const word = context.matchBefore(/[\w$]*/);
  const before = context.state.sliceDoc(Math.max(0, context.pos - 1), context.pos);
  const trigger = /[.:<"'/@#(]/.test(before) ? before : undefined;
  if (!context.explicit && !trigger && (!word || word.from === word.to)) return null;
  flushChange();
  const items = await call('completion', { uri: uriFor(app.current()), position: positionAt(context.state.doc, context.pos), triggerCharacter: trigger }).catch(() => null);
  if (!items || !items.length || context.aborted) return null;
  const from = word ? word.from : context.pos;
  return {
    from,
    options: items.map((item) => {
      const info = item.documentation || undefined;
      const base = { label: item.label, detail: item.detail, info, type: KIND_TYPES[item.kind] || 'text', boost: item.sortText ? 0 : undefined };
      if (item.snippet != null) return snippetCompletion(convertSnippet(item.snippet, app.current()), base);
      return { ...base, apply: item.text ?? item.label };
    }),
    validFor: /^[\w$]*$/,
  };
}

function escapeHTML(s) { return s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c])); }

/** Enough Markdown for hovers: code blocks, inline code, bold, italics, links and rules. */
export function renderMarkdown(md) {
  const parts = md.split(/```[\w-]*\n?([\s\S]*?)```/g);
  let html = '';
  parts.forEach((part, i) => {
    if (i % 2) { html += `<pre class="ext-code">${escapeHTML(part.replace(/\n$/, ''))}</pre>`; return; }
    for (const para of part.split(/\n\s*\n|\n?---+\n?/)) {
      if (!para.trim()) continue;
      let text = escapeHTML(para.trim());
      text = text.replace(/`([^`]+)`/g, '<code>$1</code>')
        .replace(/\*\*([^*]+)\*\*/g, '<b>$1</b>')
        .replace(/(^|\W)[*_]([^*_]+)[*_](?=\W|$)/g, '$1<i>$2</i>')
        .replace(/\[([^\]]+)\]\([^)]+\)/g, '<u>$1</u>')
        .replace(/\\([\\`*_{}[\]()#+\-.!])/g, '$1')
        .replace(/\n/g, '<br>');
      html += `<p>${text}</p>`;
    }
  });
  return html;
}

/** An extension hover for the long-press sheet (touch has no hover). */
export async function hoverAt(state, pos) {
  if (!hosts.length || !app.current()) return null;
  flushChange();
  const markdown = await call('hover', { uri: uriFor(app.current()), position: positionAt(state.doc, pos) }).catch(() => null);
  return markdown ? { title: 'Hover', html: renderMarkdown(markdown) } : null;
}

const hover = hoverTooltip(async (view, pos) => {
  if (!hosts.length || !app.current()) return null;
  flushChange();
  const markdown = await call('hover', { uri: uriFor(app.current()), position: positionAt(view.state.doc, pos) }).catch(() => null);
  if (!markdown) return null;
  return {
    pos,
    above: true,
    create() {
      const dom = document.createElement('div');
      dom.className = 'dc-hover ext-hover';
      dom.innerHTML = renderMarkdown(markdown);
      return { dom };
    },
  };
}, { hoverTime: 400 });

const SEVERITIES = ['error', 'warning', 'info', 'hint'];
const extensionLint = linter((view) => {
  if (!app || !app.current()) return [];
  const byOwner = diagnostics.get(uriFor(app.current()));
  if (!byOwner) return [];
  const doc = view.state.doc;
  const out = [];
  const seen = new Set();
  for (const items of byOwner.values()) {
    for (const d of items) {
      const from = offsetAt(doc, d.range.start);
      const to = Math.max(from, offsetAt(doc, d.range.end));
      // Two servers for one language report the same problems.
      const key = `${from}-${to}\0${d.message}`;
      if (seen.has(key)) continue;
      seen.add(key);
      // Unnecessary (1) code shows faded and Deprecated (2) struck through, as in VS Code.
      const tags = d.tags || [];
      const markClass = [tags.includes(1) ? 'cm-ext-unnecessary' : '', tags.includes(2) ? 'cm-ext-deprecated' : ''].filter(Boolean).join(' ') || undefined;
      out.push({ from, to, severity: SEVERITIES[d.severity] || 'error', message: d.code ? `${d.message} (${d.code})` : d.message, source: d.source, markClass });
    }
  }
  return out;
}, { delay: 300 });

/** Re-indents the file by its language's rules and trims trailing spaces: the formatter for
 * languages no extension formats. */
function reindent(view) {
  const { state } = view;
  const changes = [];
  const indented = indentRange(state, 0, state.doc.length);
  const after = state.update({ changes: indented }).state;
  for (let i = 1; i <= after.doc.lines; i++) {
    const line = after.doc.line(i);
    const m = /[ 	]+$/.exec(line.text);
    if (m) changes.push({ from: line.from + m.index, to: line.to });
  }
  view.dispatch({ changes: indented, userEvent: 'input.format' });
  if (changes.length) view.dispatch({ changes, userEvent: 'input.format' });
}

export async function formatDocument(view = app && app.view) {
  if (!view) return false;
  if (!hosts.length || !app.current()) { reindent(view); return true; }
  flushChange();
  const edits = await call('format', { uri: uriFor(app.current()), options: { tabSize: view.state.tabSize, insertSpaces: true } }).catch((e) => { log('error', e.message); return null; });
  if (edits && edits.length) applyToView(edits);
  else if (edits === null) reindent(view);
  return true;
}

export async function goToDefinition() {
  if (!hosts.length || !app.current()) return false;
  flushChange();
  const { view } = app;
  const target = await call('definition', { uri: uriFor(app.current()), position: positionAt(view.state.doc, view.state.selection.main.head) }).catch(() => null);
  if (!target) return false;
  const path = pathFor(target.uri);
  if (path !== app.current()) await app.openFile(path);
  const doc = app.view.state.doc;
  const from = offsetAt(doc, target.range.start);
  app.view.dispatch({ selection: { anchor: from, head: offsetAt(doc, target.range.end) }, effects: EditorView.scrollIntoView(from, { y: 'center' }) });
  return true;
}

/** Where the symbol at `pos` is defined, for Peek Definition: { path, from, to, text } or null.
 * `text` is the file's (null when it's the open file). */
export async function definitionAt(state, pos) {
  if (!hosts.length || !app.current()) return null;
  flushChange();
  const target = await call('definition', { uri: uriFor(app.current()), position: positionAt(state.doc, pos) }).catch(() => null);
  if (!target) return null;
  return locationOf(target, state);
}

/** A { uri, range } from a host, as { path, range, text } (text: the file's, null for the open file). */
async function locationOf(target, state) {
  const path = pathFor(target.uri);
  let text = null;
  if (path !== app.current()) {
    text = await app.native({ cmd: 'read', path }).catch(() => null);
    if (text == null) return null;
  }
  const doc = text == null ? state.doc : Text.of(text.split('\n'));
  return { path, from: offsetAt(doc, target.range.start), to: offsetAt(doc, target.range.end), text: text == null ? null : text };
}

/** Where the symbol at `pos` is used, for Peek References: [{ path, from, to, text }]. */
export async function referencesAt(state, pos) {
  if (!hosts.length || !app.current()) return [];
  flushChange();
  const list = (await call('references', { uri: uriFor(app.current()), position: positionAt(state.doc, pos) }).catch(() => null)) || [];
  const files = new Map();
  const out = [];
  for (const target of list) {
    const path = pathFor(target.uri);
    if (!files.has(path)) files.set(path, locationOf(target, state));
    const file = await files.get(path);
    if (!file) continue;
    const doc = file.text == null ? state.doc : Text.of(file.text.split('\n'));
    out.push({ path, from: offsetAt(doc, target.range.start), to: offsetAt(doc, target.range.end), text: file.text });
  }
  return out;
}

/** Renames the symbol at the cursor everywhere (VS Code's F2). False when no extension can. */
export async function renameSymbol(newName) {
  if (!hosts.length || !app.current()) return false;
  flushChange();
  const { view } = app;
  const params = { uri: uriFor(app.current()), position: positionAt(view.state.doc, view.state.selection.main.head), newName };
  for (const host of hosts) {
    if (await callHost(host, 'rename', params)) return true;
  }
  return false;
}

/** Quick Fix and refactorings for a range of the open file, from every host: [{ host, id, title, kind, isPreferred }].
 * `invoked`: asked for (⌘.) rather than checked for the light bulb. */
export async function codeActionsFor(state, from, to, invoked = false) {
  if (!hosts.length || !app.current()) return [];
  flushChange();
  const params = { uri: uriFor(app.current()), range: { start: positionAt(state.doc, from), end: positionAt(state.doc, to) }, invoked };
  const answers = await Promise.all(hosts.map((host) => callHost(host, 'codeActions', params).then(
    (list) => (Array.isArray(list) ? list.map((a) => ({ ...a, host })) : []), () => [])));
  return answers.flat();
}

export const runCodeAction = (action) => callHost(action.host, 'runCodeAction', { id: action.id });

/** Inlay hints for a range of the open file: [{ pos, label, kind, paddingLeft, paddingRight, tooltip }]. */
export async function inlayHintsFor(state, from, to) {
  if (!hosts.length || !app.current()) return [];
  flushChange();
  const params = { uri: uriFor(app.current()), range: { start: positionAt(state.doc, from), end: positionAt(state.doc, to) } };
  const list = (await call('inlayHints', params).catch(() => null)) || [];
  return list.map((h) => ({ ...h, pos: offsetAt(state.doc, h.position) }));
}

/** The open file's symbols from extensions' providers: [{ name, kind, depth, range }]. */
export async function documentSymbols() {
  if (!hosts.length || !app.current()) return [];
  flushChange();
  return (await call('symbols', { uri: uriFor(app.current()) }).catch(() => null)) || [];
}

export async function goToSymbol() {
  if (!hosts.length || !app.current()) return;
  flushChange();
  const symbols = (await call('symbols', { uri: uriFor(app.current()) }).catch(() => null)) || [];
  if (!symbols.length) { showNotification('info', 'No symbols found in this file.', []); return; }
  const chosen = await quickPick({
    placeholder: 'Go to symbol in editor',
    items: symbols.map((s) => ({ label: ' '.repeat(s.depth * 2) + s.name, description: SYMBOL_KINDS[s.kind] || '' })),
  });
  if (chosen == null) return;
  const s = symbols[chosen];
  const doc = app.view.state.doc;
  const from = offsetAt(doc, s.range.start);
  app.view.dispatch({ selection: { anchor: from, head: offsetAt(doc, s.range.end) }, effects: EditorView.scrollIntoView(from, { y: 'center' }) });
  app.view.focus();
}
const SYMBOL_KINDS = ['file', 'module', 'namespace', 'package', 'class', 'method', 'property', 'field', 'constructor', 'enum', 'interface', 'function', 'variable', 'constant', 'string', 'number', 'boolean', 'array', 'object', 'key', 'null', 'enum member', 'struct', 'event', 'operator', 'type parameter'];

// MARK: - Decorations (TextEditor.setDecorations)

// Workbench colours extensions use for decorations, in VS Code's dark theme.
const THEME_COLORS = {
  'editor.findMatchHighlightBackground': 'rgba(234, 92, 0, .33)', 'editor.wordHighlightBackground': 'rgba(87, 87, 87, .72)',
  'editor.selectionHighlightBackground': 'rgba(173, 214, 255, .15)', 'editor.rangeHighlightBackground': 'rgba(255, 255, 255, .04)',
  'editorError.foreground': '#f14c4c', 'editorWarning.foreground': '#cca700', 'editorInfo.foreground': '#3794ff',
  'editorCodeLens.foreground': '#999999', 'editorLineNumber.foreground': '#858585', 'editorGhostText.foreground': 'rgba(255, 255, 255, .34)',
  errorForeground: '#f48771', descriptionForeground: 'rgba(204, 204, 204, .7)', 'textLink.foreground': '#3794ff',
  'diffEditor.insertedTextBackground': 'rgba(156, 204, 44, .2)', 'diffEditor.removedTextBackground': 'rgba(255, 0, 0, .2)',
  'merge.currentContentBackground': 'rgba(64, 200, 174, .2)', 'merge.incomingContentBackground': 'rgba(64, 166, 255, .2)',
};
const color = (c) => (c && typeof c === 'object' ? THEME_COLORS[c.id] : c);

const STYLE_PROPS = {
  backgroundColor: 'background-color', color: 'color', border: 'border', borderColor: 'border-color', borderRadius: 'border-radius',
  borderSpacing: 'border-spacing', borderStyle: 'border-style', borderWidth: 'border-width', fontStyle: 'font-style', fontWeight: 'font-weight',
  textDecoration: 'text-decoration', opacity: 'opacity', outline: 'outline', outlineColor: 'outline-color', outlineStyle: 'outline-style',
  outlineWidth: 'outline-width', letterSpacing: 'letter-spacing', cursor: 'cursor',
};
function cssFor(options) {
  let css = '';
  for (const [key, prop] of Object.entries(STYLE_PROPS)) {
    const value = key.toLowerCase().includes('color') ? color(options[key]) : options[key];
    if (value != null && value !== '') css += prop + ':' + String(value).replace(/[;{}]/g, '') + ';';
  }
  return css;
}
/** The theme-specific options merged over the base ones. */
function themed(options) {
  const dark = getComputedStyle(document.documentElement).colorScheme !== 'light';
  return { ...options, ...(dark ? options.dark : options.light) };
}

class AttachmentWidget extends WidgetType {
  constructor(spec) { super(); this.spec = spec; }
  eq(other) { return JSON.stringify(other.spec) === JSON.stringify(this.spec); }
  toDOM() {
    const el = document.createElement('span');
    el.className = 'ext-attachment';
    el.textContent = this.spec.contentText || '';
    let css = cssFor(this.spec);
    for (const k of ['margin', 'width', 'height']) if (this.spec[k]) css += k + ':' + String(this.spec[k]).replace(/[;{}]/g, '') + ';';
    el.style.cssText = css;
    return el;
  }
  ignoreEvent() { return true; }
}

function buildDecorations(view) {
  const byKey = app && app.current() ? decorations.get(uriFor(app.current())) : null;
  if (!byKey) return Decoration.none;
  const doc = view.state.doc;
  const items = [];
  for (const [key, ranges] of byKey) {
    const base = decorationTypes.get(key);
    if (!base) continue;
    for (const { range, renderOptions } of ranges) {
      const options = themed({ ...base, ...(renderOptions || {}), before: { ...base.before, ...renderOptions?.before }, after: { ...base.after, ...renderOptions?.after } });
      const from = offsetAt(doc, range.start);
      const to = Math.max(from, offsetAt(doc, range.end));
      const css = cssFor(options);
      if (options.isWholeLine) {
        for (let pos = doc.lineAt(from).from; pos <= to && pos <= doc.length; ) {
          const line = doc.lineAt(pos);
          if (css) items.push({ from: line.from, to: line.from, line: true, deco: Decoration.line({ attributes: { style: css } }) });
          pos = line.to + 1;
        }
      } else if (css && to > from) {
        items.push({ from, to, deco: Decoration.mark({ attributes: { style: css } }) });
      }
      if (options.before?.contentText) items.push({ from, to: from, deco: Decoration.widget({ widget: new AttachmentWidget(options.before), side: -1 }) });
      if (options.after?.contentText) items.push({ from: to, to, deco: Decoration.widget({ widget: new AttachmentWidget(options.after), side: 1 }) });
    }
  }
  // RangeSetBuilder wants ranges in order, line decorations first at a position.
  items.sort((a, b) => a.from - b.from || (b.line ? 1 : 0) - (a.line ? 1 : 0) || a.deco.startSide - b.deco.startSide || a.to - b.to);
  const builder = new RangeSetBuilder();
  for (const { from, to, deco } of items) {
    try { builder.add(from, to, deco); } catch (e) { /* out of order: skip it */ }
  }
  return builder.finish();
}

function refreshDecorations() {
  decorationVersion++;
  if (app) app.view.dispatch({});
}

const decorationLayer = ViewPlugin.fromClass(class {
  constructor(view) { this.version = decorationVersion; this.decorations = buildDecorations(view); }
  update(u) {
    if (this.version !== decorationVersion || u.startState.doc.length === 0 && u.docChanged) {
      this.version = decorationVersion;
      this.decorations = buildDecorations(u.view);
    } else if (u.docChanged) this.decorations = this.decorations.map(u.changes);
  }
}, { decorations: (p) => p.decorations });

/** The editor extensions that connect the host to CodeMirror. */
export function hostExtensions() {
  return [
    hover,
    extensionLint,
    decorationLayer,
    EditorView.baseTheme({
      '.cm-ext-unnecessary': { opacity: '.6', backgroundImage: 'none !important' },
      '.cm-ext-deprecated': { textDecoration: 'line-through' },
    }),
    keymap.of([
      { key: 'Shift-Alt-f', run: () => { formatDocument(); return true; } },

    ]),
  ];
}

// MARK: - Commands

/** Extension commands for the Command Palette. */
export async function extensionCommands() {
  if (!hosts.length) return [];
  return (await call('commandList', {}).catch(() => [])) || [];
}

export async function runCommand(name, ...args) {
  if (!hosts.length) return null;
  flushChange();
  const path = app.current();
  if (path) {
    clearTimeout(selectionTimer);
    const { state } = app.view;
    post({ type: 'selection', uri: uriFor(path), anchor: positionAt(state.doc, state.selection.main.anchor), head: positionAt(state.doc, state.selection.main.head) });
  }
  // The host whose extension has the command runs it (else the first, for built-in commands).
  let target = hosts[0];
  for (const h of hosts) {
    if (await callHost(h, 'hasCommand', { name }).catch(() => false)) { target = h; break; }
  }
  return callHost(target, 'executeCommand', { name, args }).catch((e) => { log('error', `${name}: ${e.message}`); return null; });
}

export function setConfiguration(values) { post({ type: 'configuration', values }); }

/** For webviews: messages to the worker. */
export const postToHost = (message) => {
  // Webview ids start with their host's name.
  const host = hosts.find((h) => String(message.id || '').startsWith(h.name + '-')) || hosts[0];
  if (host) host.port.postMessage(message);
};

// MARK: - Side bar views and custom editors

/** A tree view's items under `handle` (null: the top level), with the view's title and message;
 * null when no extension provides the view. */
export function viewChildren(viewId, handle) {
  if (!hosts.length) return Promise.resolve(null);
  return call('treeChildren', { viewId, handle: handle || null });
}
/** A tree item was tapped: it's selected and its command runs. */
export const viewInvoke = (viewId, handle) => call('treeInvoke', { viewId, handle });
/** A command from an item's menu, given the item. */
export const viewMenu = (viewId, handle, command) => call('treeMenu', { viewId, handle, command });
export const viewExpand = (viewId, handle, expanded) => call('treeExpand', { viewId, handle, expanded });
export const viewCheck = (viewId, handle, checked) => call('treeCheck', { viewId, handle, checked });

/** Shows a webview view in an editor tab. False when no extension provides it. */
export async function openWebviewView(viewId, title) {
  if (!hosts.length) return false;
  return !!(await call('resolveWebviewView', { viewId, title }).catch((e) => { log('error', `${title}: ${e.message}`); return null; }));
}

/** Opens a file in an extension's custom editor. False when it couldn't. */
export async function openCustomEditor(viewType, path, title) {
  if (!hosts.length) return false;
  return !!(await call('openCustomEditor', { viewType, uri: uriFor(path), title }).catch((e) => { log('error', `${title}: ${e.message}`); return null; }));
}

// MARK: - Node.js jobs (npm, tasks)

/** Runs a job in Node.js ("npm" or "task"), its output going to an Output channel as it comes.
 * Resolves with the exit code. */
export async function nodeJob(kind, params, channel, onOutput) {
  if (!app) return 1;
  const init = (await app.native({ cmd: 'extHostInit' }).catch(() => null)) || {};
  if (!(await connectNode())) {
    channelOutput(channel, 'append', 'Node.js isn\'t running, so this can\'t run.\n');
    return 1;
  }
  let code = 0;
  try {
    const response = await fetch(nodeBase + '/' + kind, { method: 'POST', body: JSON.stringify({ dir: init.projectPath, ...params }) });
    const reader = response.body.getReader();
    const decoder = new TextDecoder();
    let buffer = '';
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, { stream: true });
      let newline;
      while ((newline = buffer.indexOf('\n')) >= 0) {
        const line = buffer.slice(0, newline);
        buffer = buffer.slice(newline + 1);
        let message;
        try { message = JSON.parse(line); } catch (e) { continue; }
        if (message.out != null) { channelOutput(channel, 'append', message.out); if (onOutput) onOutput(message.out); }
        if (message.exit != null) code = message.exit;
      }
    }
  } catch (e) {
    channelOutput(channel, 'append', `${e.message || e}\n`);
    return 1;
  }
  return code;
}

/** Extensions' tasks: [{ id, label, source, detail, group }]. */
export async function extensionTasks() {
  if (!hosts.length) return [];
  return (await call('taskList', {}).catch(() => [])) || [];
}

/** Runs an extension's task; shell and process tasks run in Node.js where they can. */
export async function runTask(id, label) {
  channelOutput('Tasks', 'show', true);
  channelOutput('Tasks', 'append', `> ${label}\n`);
  const result = await call('runTask', { id }).catch((e) => ({ error: e.message }));
  if (!result) return;
  if (result.error) { channelOutput('Tasks', 'append', result.error + '\n'); return; }
  if (result.shell) {
    const code = await nodeJob('task', { command: result.shell, cwd: result.cwd }, 'Tasks');
    channelOutput('Tasks', 'append', `\n${label} finished${code ? ` with exit code ${code}` : ''}.\n`);
  }
}

/** The installed extension a webview resource path belongs to ("/.duocode/extensions/<id>/<file>"). */
export function extensionFileAt(path) {
  const m = /^\/\.duocode\/extensions\/([^/]+)\/(.+)$/.exec(path);
  if (m) return { id: m[1], path: m[2] };
  // Node.js extensions see their real folder (a URI's path for C:\… is /C:/…).
  const file = path.replace(/^\/([A-Za-z]:)/, '$1');
  for (const e of contributions.extensions) {
    const dir = (e.path || '').replace(/\/$/, '');
    if (dir && file.startsWith(dir + '/')) return { id: e.id, path: file.slice(dir.length + 1) };
  }
  return null;
}
