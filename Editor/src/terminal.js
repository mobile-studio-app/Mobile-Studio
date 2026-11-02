// The Terminal tab: xterm.js in front of a shell session in the app's Node.js (ext/node-shell.js),
// one session per terminal. The line being typed is edited here (cursor keys, history, Tab to
// complete) and sent when Return is pressed: as a command, or as input for the program running.
// The session asks back for what only the app can do: git (the app's git engine), opening a
// file in the editor, and telling the Explorer that files changed.
import { Terminal } from '@xterm/xterm';
import { FitAddon } from '@xterm/addon-fit';
import xtermCSS from '@xterm/xterm/css/xterm.css';
import { onPanelTab, showPanel } from './panel.js';

const $ = (id) => document.getElementById(id);
const terminals = [];
let active = null;
let api = null;   // { nodeAddress(), projectPath(), native, openPath(absolutePath) }
let nextNumber = 1;

export function setupTerminal(appAPI) {
  api = appAPI;
  const style = document.createElement('style');
  style.textContent = xtermCSS;
  document.head.append(style);
  onPanelTab('terminal', () => {
    if (!terminals.length) newTerminal(); else activate(active);
  });
  $('terminal-new').addEventListener('click', () => newTerminal());
  $('terminal-kill').addEventListener('click', () => { if (active) kill(active); });
  $('terminal-select').addEventListener('change', (e) => activate(terminals.find((t) => String(t.number) === e.target.value)));
  $('terminal-ctrl-c').addEventListener('click', () => { if (active) { input(active, '\x03'); active.term.focus(); } });
  $('terminal-tab-key').addEventListener('click', () => { if (active) { input(active, '\t'); active.term.focus(); } });
  new ResizeObserver(() => { if (active) fit(active); }).observe($('terminal-host'));
}

/** View: Toggle Terminal / Terminal: Create New Terminal. */
export function showTerminal(fresh = false) {
  showPanel('terminal');
  if (fresh && terminals.length) newTerminal();
}

function theme() {
  const css = getComputedStyle(document.documentElement);
  const v = (name, fallback) => (css.getPropertyValue(name) || '').trim() || fallback;
  return { background: v('--bg', '#1e1e1e'), foreground: v('--fg', '#d4d4d4'), cursor: v('--fg', '#d4d4d4'), selectionBackground: 'rgba(38, 79, 120, .6)' };
}

async function post(t, action, body) {
  const response = await fetch(`${t.base}/term/${action}`, { method: 'POST', body: JSON.stringify({ id: t.id, ...body }) });
  return response.json();
}

async function newTerminal() {
  const element = document.createElement('div');
  element.style.height = '100%';
  $('terminal-host').append(element);
  const term = new Terminal({
    fontFamily: 'ui-monospace, Menlo, Consolas, monospace', fontSize: 12, cursorBlink: true, scrollback: 5000,
    theme: theme(), allowProposedApi: false,
  });
  const fitAddon = new FitAddon();
  term.loadAddon(fitAddon);
  term.open(element);
  const t = {
    number: nextNumber++, term, fitAddon, element, base: null, id: null, events: null,
    line: '', cursor: 0, history: [], historyIndex: 0, busy: true, cwd: '', root: '', tail: '', prompt: '',
  };
  terminals.push(t);
  activate(t);
  term.onData((data) => input(t, data));

  t.base = await api.nodeAddress();
  if (!t.base) { term.write('The terminal needs Mobile Studio\'s Node.js, which isn\'t available.\r\n'); return; }
  const dir = await api.projectPath();
  const opened = await post(t, 'open', { dir }).catch(() => null);
  if (!opened) { term.write('The terminal couldn\'t start.\r\n'); return; }
  t.id = opened.id;
  term.write('\x1b[2mMobile Studio terminal: type help for the commands.\x1b[0m\r\n');
  t.events = new EventSource(`${t.base}/term/events?id=${t.id}`);
  t.events.onmessage = (e) => event(t, JSON.parse(e.data));
  renderList();
}

function activate(t) {
  if (!t) return;
  active = t;
  for (const other of terminals) other.element.style.display = other === t ? '' : 'none';
  renderList();
  requestAnimationFrame(() => { fit(t); t.term.focus(); });
}

function fit(t) {
  try { t.fitAddon.fit(); } catch (e) { /* not visible */ }
}

function renderList() {
  const select = $('terminal-select');
  select.textContent = '';
  for (const t of terminals) {
    const option = document.createElement('option');
    option.value = String(t.number);
    option.textContent = `${t.number}: ${t.cwd ? t.cwd.split('/').pop() : 'shell'}`;
    option.selected = t === active;
    select.append(option);
  }
}

function kill(t) {
  if (t.id) post(t, 'close', {}).catch(() => {});
  if (t.events) t.events.close();
  t.term.dispose();
  t.element.remove();
  terminals.splice(terminals.indexOf(t), 1);
  active = terminals[terminals.length - 1] || null;
  if (active) activate(active); else renderList();
}

// MARK: - What the session says

function event(t, message) {
  if (message.out) {
    t.term.write(message.out);
    const at = message.out.lastIndexOf('\n');
    t.tail = at >= 0 ? message.out.slice(at + 1) : t.tail + message.out;
  }
  if (message.clear) t.term.clear();
  if (message.ready) {
    t.busy = false;
    t.cwd = message.cwd;
    t.root = message.root;
    renderList();
    showPrompt(t);
  }
  if (message.call) answer(t, message.call);
}

async function answer(t, call) {
  let result = {};
  try {
    if (call.cmd === 'git') {
      result = await api.native({ cmd: 'gitCommand', args: call.args, cwd: call.cwd });
    } else if (call.cmd === 'pip') {
      result = await api.native({ cmd: 'pipCommand', args: call.args });
    } else if (call.cmd === 'open') {
      await api.openPath(call.path);
    } else if (call.cmd === 'filesChanged') {
      await api.native({ cmd: 'filesChanged' });
    }
  } catch (e) {
    result = { out: `${e.message || e}\n`, code: 1 };
  }
  if (result && result.out) result.out = String(result.out).replace(/\r?\n/g, '\r\n');
  post(t, 'reply', { call: call.id, result }).catch(() => {});
}

function promptText(t) {
  const project = t.root.split('/').pop();
  const relative = t.cwd === t.root ? '' : t.cwd.startsWith(t.root + '/') ? '/' + t.cwd.slice(t.root.length + 1) : t.cwd;
  return `\x1b[32m${project}\x1b[0m\x1b[34m${relative}\x1b[0m $ `;
}

function showPrompt(t) {
  t.prompt = promptText(t);
  t.tail = '';
  t.line = '';
  t.cursor = 0;
  if (t.term.buffer.active.cursorX > 0) t.term.write('\r\n');
  t.term.write(t.prompt);
}

/** Draws the line being typed again, after what's before it on screen (the prompt, or a
 * program's question). */
function redraw(t) {
  const before = t.busy ? t.tail : t.prompt;
  let out = '\r\x1b[K' + before + t.line;
  const back = t.line.length - t.cursor;
  if (back > 0) out += `\x1b[${back}D`;
  t.term.write(out);
}

// MARK: - Typing

function input(t, data) {
  if (data.length > 1 && !data.startsWith('\x1b')) {
    // Pasted text: lines are sent one at a time.
    for (const [i, part] of data.replace(/\r\n/g, '\r').split(/[\r\n]/).entries()) {
      if (i > 0) submit(t);
      insert(t, part.replace(/\t/g, '    '));
    }
    return;
  }
  switch (data) {
    case '\r': submit(t); return;
    case '\x7f': case '\b':
      if (t.cursor > 0) { t.line = t.line.slice(0, t.cursor - 1) + t.line.slice(t.cursor); t.cursor--; redraw(t); }
      return;
    case '\x1b[3~':
      if (t.cursor < t.line.length) { t.line = t.line.slice(0, t.cursor) + t.line.slice(t.cursor + 1); redraw(t); }
      return;
    case '\x1b[D': if (t.cursor > 0) { t.cursor--; t.term.write(data); } return;
    case '\x1b[C': if (t.cursor < t.line.length) { t.cursor++; t.term.write(data); } return;
    case '\x1b[H': case '\x01': t.cursor = 0; redraw(t); return;
    case '\x1b[F': case '\x05': t.cursor = t.line.length; redraw(t); return;
    case '\x1b[A': history(t, -1); return;
    case '\x1b[B': history(t, 1); return;
    case '\x15': t.line = t.line.slice(t.cursor); t.cursor = 0; redraw(t); return;
    case '\x0b': t.line = t.line.slice(0, t.cursor); redraw(t); return;
    case '\x0c': t.term.clear(); redraw(t); return;
    case '\x03':
      if (t.busy && t.id) { post(t, 'signal', { name: 'INT' }).catch(() => {}); return; }
      t.term.write('^C');
      showPrompt(t);
      return;
    case '\x04':
      if (t.busy && t.id) post(t, 'signal', { name: 'EOF' }).catch(() => {});
      return;
    case '\t': complete(t); return;
    default:
      if (data.startsWith('\x1b')) return;   // other keys
      insert(t, data);
  }
}

function insert(t, text) {
  if (!text) return;
  t.line = t.line.slice(0, t.cursor) + text + t.line.slice(t.cursor);
  t.cursor += text.length;
  if (t.cursor === t.line.length) t.term.write(text); else redraw(t);
}

function submit(t) {
  const line = t.line;
  t.term.write('\r\n');
  t.line = '';
  t.cursor = 0;
  if (!t.id) return;
  if (!t.busy) {
    if (line.trim()) { t.history.push(line); if (t.history.length > 500) t.history.shift(); }
    t.historyIndex = t.history.length;
    if (!line.trim()) { showPrompt(t); return; }
    t.busy = true;
    t.tail = '';
  }
  post(t, 'input', { line }).catch(() => {});
}

function history(t, step) {
  if (t.busy || !t.history.length) return;
  t.historyIndex = Math.max(0, Math.min(t.history.length, t.historyIndex + step));
  t.line = t.history[t.historyIndex] ?? '';
  t.cursor = t.line.length;
  redraw(t);
}

async function complete(t) {
  if (t.busy || !t.id) return;
  const before = t.line.slice(0, t.cursor);
  const { word, candidates } = await post(t, 'complete', { line: before }).catch(() => ({ word: '', candidates: [] }));
  if (!candidates || !candidates.length) return;
  let common = candidates[0];
  for (const c of candidates) { let i = 0; while (i < common.length && c[i] === common[i]) i++; common = common.slice(0, i); }
  if (candidates.length === 1 || common.length > word.length) {
    const text = candidates.length === 1 ? candidates[0] : common;
    t.line = before.slice(0, before.length - word.length) + text + t.line.slice(t.cursor);
    t.cursor = before.length - word.length + text.length;
    redraw(t);
    return;
  }
  t.term.write('\r\n' + candidates.map((c) => c.trimEnd()).join('  ') + '\r\n');
  t.term.write(t.prompt);
  redraw(t);
}

/** The active terminal's last lines (scrollback included), for the Chat agent's read_terminal. */
export function terminalText(maxLines = 200) {
  const t = active || terminals[terminals.length - 1];
  if (!t) return null;
  const buffer = t.term.buffer.active;
  const lines = [];
  for (let i = Math.max(0, buffer.length - maxLines); i < buffer.length; i++) {
    const line = buffer.getLine(i);
    if (line) lines.push(line.translateToString(true));
  }
  while (lines.length && !lines[lines.length - 1].trim()) lines.pop();
  return lines.join('\n');
}
