// The Chat panel, like VS Code's: ask about the code with the open file (and selection) included,
// answers stream in as Markdown, and code blocks can be copied or inserted into the editor. The
// model is on the device: Apple Intelligence or a downloaded one (App/AI/AIChatService.swift);
// nothing is sent anywhere.
import { renderMarkdown } from './markdown.js';

let api = null;   // { native, view, current, openURL, appCommand }
const $ = (id) => document.getElementById(id);
let pane = null;
let messages = [];    // { role, content (what the model gets), shown (what the panel shows) }
let pending = null;   // { id, el, text }
let nextId = 1;
let frame = 0;

const SYSTEM = 'You are the coding assistant built into Mobile Studio, a code editor on iPhone and iPad. '
  + 'Answer briefly and precisely. Use Markdown; put code in fenced blocks tagged with the language. '
  + 'When changing the user\'s code, show the changed part, not the whole file.';
const MAX_CONTEXT = 4000;   // characters of the open file; local models have small context windows

function element(tag, className, text) {
  const el = document.createElement(tag);
  if (className) el.className = className;
  if (text != null) el.textContent = text;
  return el;
}

function build() {
  if (pane) return;
  pane = element('div', 'chat-pane');
  pane.id = 'chat-pane';
  pane.hidden = true;
  const header = element('div', 'chat-header');
  header.append(element('span', 'chat-title', 'CHAT'));
  const model = element('select', 'chat-model');
  model.id = 'chat-model';
  model.title = 'Model';
  model.addEventListener('change', () => {
    if (model.value === '__more__') { api.appCommand('settings'); loadModels(); return; }
    api.native({ cmd: 'aiChatSelect', id: model.value }).catch(() => {});
  });
  const fresh = element('button', 'chat-icon codicon', '');
  fresh.title = 'New Chat';
  fresh.addEventListener('click', () => newChat());
  const close = element('button', 'chat-icon codicon', '');
  close.title = 'Close Chat';
  close.addEventListener('click', () => closeChat());
  header.append(model, fresh, close);

  const log = element('div', 'chat-log');
  log.id = 'chat-log';
  log.addEventListener('click', (e) => {
    const link = e.target.closest('a[href]');
    if (link) {
      e.preventDefault();
      if (/^https?:/.test(link.getAttribute('href'))) api.openURL(link.getAttribute('href'));
    }
  });

  const form = element('div', 'chat-input');
  const context = element('label', 'chat-context');
  const box = element('input');
  box.type = 'checkbox';
  box.id = 'chat-include';
  box.checked = true;
  const contextName = element('span');
  contextName.id = 'chat-include-name';
  context.append(box, contextName);
  const text = element('textarea', 'chat-text');
  text.id = 'chat-text';
  text.rows = 3;
  text.placeholder = 'Ask about your code. Runs on this device.';
  text.setAttribute('autocapitalize', 'sentences');
  text.addEventListener('keydown', (e) => {
    e.stopPropagation();
    if (e.key === 'Enter' && !e.shiftKey && !e.isComposing) { e.preventDefault(); send(); }
  });
  const sendButton = element('button', 'chat-send', 'Send');
  sendButton.id = 'chat-send';
  sendButton.addEventListener('click', () => (pending ? stop() : send()));
  const row = element('div', 'chat-row');
  row.append(context, sendButton);
  form.append(text, row);

  pane.append(header, log, form);
  $('editor-container').append(pane);
  renderEmpty();
}

export function setupChat(options) { api = options; }

function renderEmpty() {
  const log = $('chat-log');
  if (messages.length) return;
  log.replaceChildren(element('div', 'chat-empty',
    'Ask a question about your code, or ask for a change. The open file (and what\'s selected) is included when the box below is ticked. Everything runs on this device.'));
}

async function loadModels() {
  const select = $('chat-model');
  const info = await api.native({ cmd: 'aiChatModels' }).catch(() => null);
  if (!info) return;
  select.replaceChildren();
  for (const m of info.models) {
    const option = element('option', null, m.ready ? m.name : `${m.name} (${m.detail})`);
    option.value = m.id;
    option.disabled = !m.ready;
    option.selected = m.id === info.selected;
    select.append(option);
  }
  const more = element('option', null, 'Download More Models…');
  more.value = '__more__';
  select.append(more);
}

function updateContextLabel() {
  if (!pane) return;
  const path = api.current();
  const sel = api.view.state.selection.main;
  const label = $('chat-include-name');
  label.textContent = path ? `Include ${path.split('/').pop()}${sel.empty ? '' : ' (selection)'}` : 'No file open';
  $('chat-include').disabled = !path;
}

export const chatOpen = () => !!pane && !pane.hidden;

/** Opens the panel (Chat: Open Chat, ⌃⌘I); `prompt` fills the box. */
export function openChat(prompt) {
  build();
  pane.hidden = false;
  $('editor-container').classList.add('chat-open');
  api.view.requestMeasure();
  loadModels();
  updateContextLabel();
  if (prompt) $('chat-text').value = prompt;
  $('chat-text').focus();
}

export function closeChat() {
  if (!pane) return;
  pane.hidden = true;
  $('editor-container').classList.remove('chat-open');
  api.view.requestMeasure();
  api.view.focus();
}

export function toggleChat() { if (chatOpen()) closeChat(); else openChat(); }

export function newChat() {
  if (pending) stop();
  messages = [];
  if (pane) renderEmpty();
}

/** The open file (around the selection or cursor), for the question. */
function fileContext() {
  const path = api.current();
  if (!path || !$('chat-include').checked) return '';
  const { state } = api.view;
  const sel = state.selection.main;
  const doc = state.doc;
  const lang = path.includes('.') ? path.split('.').pop() : '';
  let out = '';
  if (!sel.empty) {
    const from = doc.lineAt(sel.from).number;
    const to = doc.lineAt(sel.to).number;
    out += `I've selected lines ${from}-${to} of ${path}:\n\`\`\`${lang}\n${state.sliceDoc(sel.from, sel.to).slice(0, MAX_CONTEXT)}\n\`\`\`\n`;
  }
  let text = doc.toString();
  if (text.length > MAX_CONTEXT) {
    // The part around the cursor.
    const at = Math.max(0, Math.min(sel.head - MAX_CONTEXT / 2, text.length - MAX_CONTEXT));
    text = (at > 0 ? '…\n' : '') + text.slice(at, at + MAX_CONTEXT) + (at + MAX_CONTEXT < doc.length ? '\n…' : '');
  }
  if (sel.empty || out.length < MAX_CONTEXT) out += `The file ${path}:\n\`\`\`${lang}\n${text}\n\`\`\`\n`;
  return out;
}

function send() {
  build();
  const input = $('chat-text');
  const question = input.value.trim();
  if (!question || pending) return;
  input.value = '';
  const context = fileContext();
  messages.push({ role: 'user', content: context ? `${context}\n${question}` : question, shown: question });
  const id = String(nextId++);
  pending = { id, text: '', el: null };
  render();
  const outgoing = [{ role: 'system', content: SYSTEM }, ...messages.map((m) => ({ role: m.role, content: m.content }))];
  $('chat-send').textContent = 'Stop';
  api.native({ cmd: 'aiChat', id, messages: outgoing }).catch((e) => finish({ id, error: String(e && e.message ? e.message : e) }));
}

function stop() {
  api.native({ cmd: 'aiChatCancel' }).catch(() => {});
  if (pending) finish({ id: pending.id, text: pending.text, stopped: true });
}

function finish({ id, text, error, stopped }) {
  if (!pending || pending.id !== id) return;
  const answer = text ?? pending.text;
  pending = null;
  $('chat-send').textContent = 'Send';
  if (error) messages.push({ role: 'error', content: error, shown: error });
  else if (answer || !stopped) messages.push({ role: 'assistant', content: answer, shown: answer + (stopped ? '\n\n*(stopped)*' : '') });
  render();
}

/** Events from the app: the answer so far, and the end. */
export function chatEvent(name, payload) {
  if (!pending || !payload || payload.id !== pending.id) return;
  if (name === 'aiChatText') {
    pending.text = payload.text || '';
    if (!frame) frame = requestAnimationFrame(() => { frame = 0; renderPending(); });
  } else if (name === 'aiChatDone') {
    finish(payload);
  }
}

/** Reasoning models write their thinking in <think>…</think>: shown folded away. */
function renderAnswer(text) {
  const html = [];
  let rest = text;
  const open = rest.indexOf('<think>');
  if (open >= 0) {
    const close = rest.indexOf('</think>', open);
    const thinking = close >= 0 ? rest.slice(open + 7, close) : rest.slice(open + 7);
    html.push(`<details class="chat-thinking"${close < 0 ? ' open' : ''}><summary>${close < 0 ? 'Thinking…' : 'Thought'}</summary>${renderMarkdown(thinking.trim())}</details>`);
    rest = rest.slice(0, open) + (close >= 0 ? rest.slice(close + 8) : '');
  }
  html.push(renderMarkdown(rest.trim()));
  return html.join('');
}

/** Copy and Insert buttons on each code block. */
function decorateCode(container) {
  for (const pre of container.querySelectorAll('pre')) {
    const bar = element('div', 'chat-code-bar');
    const copy = element('button', null, 'Copy');
    copy.addEventListener('click', () => {
      const code = pre.querySelector('code').textContent;
      navigator.clipboard?.writeText(code).catch(() => {});
      api.native({ cmd: 'clipboardWrite', text: code }).catch(() => {});
      copy.textContent = 'Copied';
      setTimeout(() => { copy.textContent = 'Copy'; }, 1200);
    });
    const insert = element('button', null, 'Insert');
    insert.title = 'Insert at the cursor (replacing the selection)';
    insert.addEventListener('click', () => {
      const { view } = api;
      if (!api.current()) return;
      view.dispatch({ ...view.state.replaceSelection(pre.querySelector('code').textContent), userEvent: 'input.paste', scrollIntoView: true });
      view.focus();
    });
    bar.append(copy, insert);
    pre.before(bar);
  }
}

function bubble(message) {
  const el = element('div', `chat-message ${message.role}`);
  const who = element('div', 'chat-who', message.role === 'user' ? 'You' : message.role === 'error' ? 'Error' : 'Chat');
  const body = element('div', 'chat-body');
  if (message.role === 'assistant') {
    body.innerHTML = renderAnswer(message.shown);
    decorateCode(body);
  } else {
    body.textContent = message.shown;
  }
  el.append(who, body);
  return el;
}

function render() {
  const log = $('chat-log');
  if (!messages.length && !pending) { renderEmpty(); return; }
  log.replaceChildren(...messages.map(bubble));
  if (pending) {
    pending.el = bubble({ role: 'assistant', shown: pending.text });
    pending.el.classList.add('pending');
    log.append(pending.el);
    renderPending();
  }
  log.scrollTop = log.scrollHeight;
}

function renderPending() {
  if (!pending || !pending.el) return;
  const log = $('chat-log');
  const atEnd = log.scrollTop + log.clientHeight >= log.scrollHeight - 24;
  const body = pending.el.querySelector('.chat-body');
  body.innerHTML = pending.text ? renderAnswer(pending.text) : '<span class="chat-typing">Thinking…</span>';
  if (atEnd) log.scrollTop = log.scrollHeight;
}

/** The selection or file changed: the "Include" label follows. */
export function chatSelectionChanged() { if (chatOpen()) updateContextLabel(); }
