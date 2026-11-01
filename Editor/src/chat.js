// The Chat panel: a coding agent like Claude Code, running on the device (Apple Intelligence or a
// downloaded model; App/AI/AIChatService.swift). It reads, searches and edits the project's files,
// runs commands and hands research to subagents, asking first as much as the mode says:
//   manual: asks before every edit and command
//   edit:   edits files, asks before commands
//   auto:   edits and runs commands, asks before risky ones (deleting, pushing, ...)
//   turbo:  never asks
// The model calls tools by writing a ```tool block with JSON, which works for every model. The
// header shows how full the model's context is; /compact (or near the limit) summarises the
// conversation into one message.
import { renderMarkdown } from './markdown.js';
import { forEachDiagnostic } from '@codemirror/lint';

// { native, view, current, openURL, appCommand, openFile, runCommand(command, onOutput) → exit code, problems() }
let api = null;
const $ = (id) => document.getElementById(id);
let pane = null;

let messages = [];        // { role: 'user' | 'assistant', content (the model's), shown?, kind?: 'tool' | 'summary' }
let busy = false;
let stopped = false;
let settings = { models: [], selected: 'apple', contextSize: 4096, subagentModel: '', subagentParallel: 2, mode: 'edit' };
const allowedThisChat = new Set();   // tools "Always" was picked for
const requests = new Map();          // request id → { resolve, onText }
let nextId = 1;
let frame = 0;
let liveText = null;                 // the answer being written, for the pending bubble

const MAX_STEPS = 16;
const MAX_TOOL_OUTPUT = 4000;
const MODES = [
  ['manual', 'Manual', 'Asks before every edit and command'],
  ['edit', 'Edit', 'Edits files; asks before commands'],
  ['auto', 'Auto', 'Edits and runs commands; asks before risky ones'],
  ['turbo', 'Turbo', 'Never asks'],
];

function element(tag, className, text) {
  const el = document.createElement(tag);
  if (className) el.className = className;
  if (text != null) el.textContent = text;
  return el;
}

export function setupChat(options) { api = options; }

// MARK: - The model

/** About how many tokens a text is (code runs about 3.5 characters a token). */
const tokens = (text) => Math.ceil(String(text || '').length / 3.5);

const currentModel = () => settings.models.find((m) => m.id === settings.selected) || settings.models[0];
const contextLimit = (modelId) => (settings.models.find((m) => m.id === (modelId || settings.selected)) || {}).contextSize || 4096;

function toolHelp(subagents) {
  return [
    'Tools: to use one, write a fenced block whose language is tool, holding JSON, like',
    '```tool\n{"tool": "read_file", "path": "src/main.lua"}\n```',
    'You can write several tool blocks in one reply. Their results come back in the next message.',
    '- read_file {path, start_line?, end_line?}: a file, with line numbers.',
    '- list_files {path?}: the project\'s files (or a folder\'s).',
    '- search {query, path?}: lines containing the text (any case), as path:line: text.',
    ...(subagents ? [] : [
      '- edit_file {path, old, new}: replaces the exact text old, which must appear once, with new. Read the file first; copy old exactly, with enough lines to be unique.',
      '- write_file {path, content}: creates or replaces a whole file.',
      '- run_command {command}: runs a shell command in the project folder (ls, cat, grep, git, node, npm, python, lua); returns its output.',
      '- get_problems {}: the errors and warnings in the project.',
    ]),
    ...(subagents || settings.subagentParallel < 1 ? [] : [
      '- delegate {tasks: ["...", ...]}: gives self-contained research questions to subagents, which read and search (they can\'t edit) and answer each one. Use it to look into several things at once.',
    ]),
    'Look before you change anything. When you\'re finished, answer normally, with no tool block.',
  ].join('\n');
}

function systemPrompt() {
  return 'You are the coding agent built into Mobile Studio, a code editor on iPhone and iPad. You work in the user\'s project: '
    + 'you read and change its files and run commands with the tools below. Be brief and precise. Use Markdown; put code in fenced '
    + 'blocks tagged with the language.\n\n' + toolHelp(false);
}

/** Asks the model; `onText` gets the answer as it's written. Resolves with { text, error, stopped }. */
function ask(chat, { model, maxTokens, onText } = {}) {
  const id = 'c' + nextId++;
  return new Promise((resolve) => {
    requests.set(id, { resolve, onText });
    api.native({ cmd: 'aiChat', id, messages: chat, model: model || undefined, maxTokens: maxTokens || 1536 })
      .catch((e) => { requests.delete(id); resolve({ error: String(e && e.message ? e.message : e) }); });
  });
}

/** Events from the app: an answer so far, and its end. */
export function chatEvent(name, payload) {
  const request = payload && requests.get(payload.id);
  if (!request) return;
  if (name === 'aiChatText') { if (request.onText) request.onText(payload.text || ''); return; }
  if (name === 'aiChatDone') {
    requests.delete(payload.id);
    request.resolve({ text: payload.text || '', error: payload.error });
  }
}

// MARK: - Tool calls

/** The tool calls in a reply: ```tool blocks (or ```json ones naming a tool). */
function toolCalls(text) {
  const calls = [];
  const re = /```(?:tool|json)?\s*\n([\s\S]*?)```/g;
  for (let m = re.exec(text); m; m = re.exec(text)) {
    try {
      const call = JSON.parse(m[1].trim());
      if (call && typeof call.tool === 'string') calls.push(call);
    } catch (e) { /* not a tool call */ }
  }
  return calls;
}

/** A reply without its tool blocks, for showing (the calls show as chips). */
function withoutToolBlocks(text) {
  return text.replace(/```(?:tool|json)?\s*\n[\s\S]*?(```|$)/g, (block) => (/"tool"\s*:/.test(block) ? '' : block)).trim();
}

const READ_ONLY = new Set(['read_file', 'list_files', 'search', 'get_problems', 'delegate']);
const RISKY = /(^|[\s;&|])(rm|rmdir|mv|chmod|kill|curl|wget|dd)\b|git\s+(push|reset|clean|checkout|rebase|branch\s+-D)|npm\s+(publish|uninstall)|>\s*\S/;

/** Whether a call runs without asking, in the current mode. */
function allowedWithoutAsking(call) {
  if (READ_ONLY.has(call.tool) || allowedThisChat.has(call.tool)) return true;
  const mode = settings.mode;
  if (mode === 'turbo') return true;
  if (call.tool === 'edit_file' || call.tool === 'write_file') return mode !== 'manual';
  if (call.tool === 'run_command') return mode === 'auto' && !RISKY.test(String(call.command || ''));
  return false;
}

const clip = (text, max = MAX_TOOL_OUTPUT) => (text.length > max ? text.slice(0, max) + `\n… (${text.length - max} more characters)` : text);
const cleanPath = (path) => String(path || '').replace(/^\.?\/+/, '').replace(/\/+$/, '');

async function readText(path) {
  const p = cleanPath(path);
  if (p === api.current()) return api.view.state.doc.toString();
  return api.native({ cmd: 'read', path: p });
}

async function projectFiles() {
  const list = await api.native({ cmd: 'list' }).catch(() => []);
  return Array.isArray(list) ? list : [];
}

/** Writes a file: into the editor when it's the open one (so undo works), else to disk. */
async function writeText(path, text) {
  const p = cleanPath(path);
  if (p === api.current()) {
    const { view } = api;
    const old = view.state.doc.toString();
    let start = 0;
    while (start < old.length && start < text.length && old[start] === text[start]) start++;
    let endOld = old.length, endNew = text.length;
    while (endOld > start && endNew > start && old[endOld - 1] === text[endNew - 1]) { endOld--; endNew--; }
    view.dispatch({ changes: { from: start, to: endOld, insert: text.slice(start, endNew) }, userEvent: 'input.agent' });
    return;
  }
  await api.native({ cmd: 'write', path: p, contents: text });
}

/** A short +/- view of a change, for the approval card. */
function changePreview(before, after) {
  const a = before.split('\n');
  const b = after.split('\n');
  let start = 0;
  while (start < a.length && start < b.length && a[start] === b[start]) start++;
  let endA = a.length, endB = b.length;
  while (endA > start && endB > start && a[endA - 1] === b[endB - 1]) { endA--; endB--; }
  const lines = [...a.slice(start, endA).map((l) => '- ' + l), ...b.slice(start, endB).map((l) => '+ ' + l)];
  return { line: start + 1, text: clip(lines.join('\n'), 1500) };
}

/** Runs one tool call: { summary (for the chip), output (for the model), preview? }. */
async function runTool(call, { subagent = false } = {}) {
  const t = call.tool;
  try {
    if (t === 'read_file') {
      const text = await readText(call.path);
      const lines = text.split('\n');
      const from = Math.max(1, Number(call.start_line) || 1);
      const to = Math.min(lines.length, Number(call.end_line) || lines.length);
      const numbered = lines.slice(from - 1, to).map((l, i) => `${from + i}\t${l}`).join('\n');
      return { summary: `Read ${cleanPath(call.path)} (${to - from + 1} lines)`, output: clip(numbered, 8000) };
    }
    if (t === 'list_files') {
      const dir = cleanPath(call.path);
      const files = (await projectFiles()).filter((f) => !dir || f.startsWith(dir + '/'));
      return { summary: `Listed ${dir || 'the project'} (${files.length} files)`, output: clip(files.slice(0, 400).join('\n') || '(no files)') };
    }
    if (t === 'search') {
      const query = String(call.query || '').toLowerCase();
      if (!query) return { summary: 'Search', output: 'Error: query is empty.' };
      const dir = cleanPath(call.path);
      const found = [];
      for (const file of (await projectFiles()).filter((f) => !dir || f.startsWith(dir + '/')).slice(0, 400)) {
        let text;
        try { text = await readText(file); } catch (e) { continue; }
        if (typeof text !== 'string' || text.length > 500000) continue;
        text.split('\n').forEach((line, i) => { if (found.length < 80 && line.toLowerCase().includes(query)) found.push(`${file}:${i + 1}: ${line.trim().slice(0, 200)}`); });
        if (found.length >= 80) break;
      }
      return { summary: `Searched for "${call.query}" (${found.length} found)`, output: found.join('\n') || 'No matches.' };
    }
    if (t === 'get_problems') {
      const items = [];
      for (const file of api.problems()) for (const d of file.items) items.push(`${file.path}:${(d.range?.start?.line ?? 0) + 1}: ${d.message}`);
      if (api.current()) {
        forEachDiagnostic(api.view.state, (d) => {
          items.push(`${api.current()}:${api.view.state.doc.lineAt(d.from).number}: [${d.severity}] ${d.message}`);
        });
      }
      return { summary: `Problems (${items.length})`, output: items.slice(0, 100).join('\n') || 'No problems.' };
    }
    if (subagent) return { summary: t, output: `Error: subagents can only read and search; ${t} isn't available.` };
    if (t === 'edit_file') {
      const path = cleanPath(call.path);
      const before = await readText(path);
      const old = String(call.old ?? '');
      const count = old ? before.split(old).length - 1 : 0;
      if (count !== 1) {
        return { summary: `Edit ${path} (failed)`, output: `Error: the text to replace appears ${count} times in ${path}; it must appear exactly once. Read the file and copy more of it.` };
      }
      const after = before.replace(old, () => String(call.new ?? ''));
      return { summary: `Edited ${path}`, output: `Edited ${path}.`, apply: () => writeText(path, after), preview: changePreview(before, after), path };
    }
    if (t === 'write_file') {
      const path = cleanPath(call.path);
      let before = '';
      try { before = await readText(path); } catch (e) { /* a new file */ }
      const after = String(call.content ?? '');
      return { summary: `${before ? 'Rewrote' : 'Created'} ${path}`, output: `Wrote ${path} (${after.split('\n').length} lines).`, apply: () => writeText(path, after), preview: changePreview(before, after), path };
    }
    if (t === 'run_command') {
      const command = String(call.command || '');
      return {
        summary: `Ran ${command.slice(0, 60)}`, command,
        apply: async () => {
          let out = '';
          const code = await api.runCommand(command, (text) => { out += text; });
          return `Exit code ${code}.\n${clip(out)}`;
        },
      };
    }
    if (t === 'delegate') {
      const tasks = (Array.isArray(call.tasks) ? call.tasks : [call.task]).filter(Boolean).map(String).slice(0, 8);
      if (!tasks.length) return { summary: 'Delegate', output: 'Error: no tasks.' };
      if (settings.subagentParallel < 1) return { summary: 'Delegate', output: 'Error: subagents are turned off; do the research yourself.' };
      const answers = await runSubagents(tasks);
      return { summary: `${tasks.length} subagent${tasks.length === 1 ? '' : 's'}`, output: answers.map((a, i) => `Task ${i + 1}: ${tasks[i]}\nAnswer: ${a}`).join('\n\n') };
    }
    return { summary: t, output: `Error: there's no tool called ${t}.` };
  } catch (e) {
    return { summary: `${t} (failed)`, output: `Error: ${e && e.message ? e.message : e}` };
  }
}

// MARK: - Subagents

/** Runs research tasks on the subagent model, up to the parallel setting at a time. */
async function runSubagents(tasks) {
  const model = settings.subagentModel || settings.selected;
  const answers = new Array(tasks.length);
  const card = progressCard(tasks);
  let next = 0;
  const worker = async () => {
    while (next < tasks.length && !stopped) {
      const index = next++;
      card.set(index, 'working…');
      answers[index] = await subagent(tasks[index], model);
      card.set(index, 'done');
    }
  };
  await Promise.all(Array.from({ length: Math.min(settings.subagentParallel, tasks.length) }, worker));
  return answers.map((a) => a ?? '(stopped)');
}

async function subagent(task, model) {
  const chat = [
    { role: 'system', content: 'You are a research subagent of a coding agent. Answer the task by reading and searching the project; you can\'t change anything. Answer briefly with what you found, naming files and lines.\n\n' + toolHelp(true) },
    { role: 'user', content: task },
  ];
  for (let step = 0; step < 6 && !stopped; step++) {
    const reply = await ask(chat, { model, maxTokens: 768 });
    if (reply.error) return `(failed: ${reply.error})`;
    const calls = toolCalls(reply.text);
    chat.push({ role: 'assistant', content: reply.text });
    if (!calls.length) return withoutToolBlocks(reply.text) || '(no answer)';
    const results = [];
    for (const call of calls.slice(0, 4)) results.push(`${call.tool}: ${(await runTool(call, { subagent: true })).output}`);
    chat.push({ role: 'user', content: 'Tool results:\n' + clip(results.join('\n\n'), 3000) });
  }
  return '(ran out of steps)';
}

// MARK: - The agent

function forModel() {
  return [{ role: 'system', content: systemPrompt() }, ...messages.map((m) => ({ role: m.role, content: m.content }))];
}

const usedTokens = () => tokens(systemPrompt()) + messages.reduce((n, m) => n + tokens(m.content), 0);

/** Summarises the conversation into one message, to free the context. */
async function compact(reason) {
  if (messages.length < 2) return;
  const note = element('div', 'chat-note', 'Compacting the conversation…');
  $('chat-log').append(note);
  const reply = await ask([
    { role: 'system', content: 'You summarise conversations between a user and a coding agent, for the agent to carry on from.' },
    { role: 'user', content: messages.map((m) => `${m.role === 'user' ? (m.kind === 'tool' ? 'Tool results' : 'User') : 'Agent'}: ${m.content.slice(0, 3000)}`).join('\n\n')
      + '\n\nSummarise this for the agent: what the user wants, decisions made, files read and changed (with what changed), and what is left to do. Be concise.' },
  ], { maxTokens: 700 });
  note.remove();
  if (reply.error || !reply.text.trim()) { notice('Couldn\'t compact: ' + (reply.error || 'no summary')); return; }
  messages = [{ role: 'user', kind: 'summary', content: 'Summary of the conversation so far:\n' + reply.text.trim(), shown: reply.text.trim(), reason }];
  render();
}

async function send() {
  build();
  const input = $('chat-text');
  const text = input.value.trim();
  if (!text || busy) return;
  input.value = '';
  if (text === '/compact') { busy = true; updateControls(); await compact('asked'); busy = false; updateControls(); return; }
  if (text === '/clear' || text === '/new') { newChat(); return; }
  const context = fileContext();
  messages.push({ role: 'user', content: context ? `${context}\n${text}` : text, shown: text });
  render();
  busy = true;
  stopped = false;
  updateControls();
  try {
    for (let step = 0; step < MAX_STEPS && !stopped; step++) {
      // Near the context's end, the conversation so far is summarised first.
      if (usedTokens() > contextLimit() * 0.8 && messages.length > 2) await compact('auto');
      liveText = '';
      render();
      const reply = await ask(forModel(), { onText: (t) => { liveText = t; scheduleLive(); } });
      liveText = null;
      if (reply.error) { messages.push({ role: 'assistant', content: '', shown: reply.error, kind: 'error' }); break; }
      const calls = toolCalls(reply.text);
      messages.push({ role: 'assistant', content: reply.text, shown: reply.text, calls: calls.map((c) => c.tool + (c.path ? ' ' + c.path : '')) });
      render();
      if (!calls.length || stopped) break;
      const results = [];
      for (const call of calls) {
        if (stopped) break;
        results.push(await perform(call));
      }
      messages.push({ role: 'user', kind: 'tool', content: 'Tool results:\n' + results.join('\n\n'), shown: results.length + ' tool result' + (results.length === 1 ? '' : 's') });
      render();
    }
  } finally {
    busy = false;
    liveText = null;
    updateControls();
    render();
  }
}

/** One tool call: approval when the mode asks for it, then the result for the model. */
async function perform(call) {
  const result = await runTool(call);
  if (!result.apply) { toolCard(result, 'done'); return `${call.tool}: ${result.output}`; }
  if (!allowedWithoutAsking(call)) {
    const decision = await approval(call, result);
    if (decision === 'deny') { toolCard(result, 'denied'); return `${call.tool}: The user didn't allow this.`; }
    if (decision === 'always') allowedThisChat.add(call.tool);
  }
  const output = await result.apply();
  toolCard(result, 'done', typeof output === 'string' ? output : null);
  if (result.path && result.path !== api.current() && call.tool !== 'run_command') { /* written to disk; the Explorer refreshes itself */ }
  return `${call.tool}: ${typeof output === 'string' ? output : result.output}`;
}

function stop() {
  stopped = true;
  for (const id of requests.keys()) api.native({ cmd: 'aiChatCancel', id }).catch(() => {});
  for (const [, request] of requests) request.resolve({ text: liveText || '', stopped: true });
  requests.clear();
  for (const card of document.querySelectorAll('.chat-approval:not(.decided)')) card.decide && card.decide('deny');
}

export function newChat() {
  if (busy) stop();
  messages = [];
  allowedThisChat.clear();
  if (pane) render();
}

/** The open file's name and selection, for the question (the agent reads more itself). */
function fileContext() {
  const path = api.current();
  if (!path || !$('chat-include').checked) return '';
  const { state } = api.view;
  const sel = state.selection.main;
  const lang = path.includes('.') ? path.split('.').pop() : '';
  let out = `(The open file is ${path}, at line ${state.doc.lineAt(sel.head).number}.)`;
  if (!sel.empty) out += `\nSelected (lines ${state.doc.lineAt(sel.from).number}-${state.doc.lineAt(sel.to).number}):\n\`\`\`${lang}\n${state.sliceDoc(sel.from, sel.to).slice(0, 3000)}\n\`\`\``;
  return out;
}

// MARK: - The panel

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
    if (model.value === '__more__') { api.appCommand('settings'); loadSettings(); return; }
    settings.selected = model.value;
    api.native({ cmd: 'aiChatSelect', id: model.value }).catch(() => {});
    updateMeter();
  });
  const options = element('button', 'chat-icon codicon', '');
  options.title = 'Chat Settings';
  options.addEventListener('click', () => { $('chat-settings').hidden = !$('chat-settings').hidden; });
  const fresh = element('button', 'chat-icon codicon', '');
  fresh.title = 'New Chat';
  fresh.addEventListener('click', () => newChat());
  const close = element('button', 'chat-icon codicon', '');
  close.title = 'Close Chat';
  close.addEventListener('click', () => closeChat());
  header.append(model, options, fresh, close);

  // How full the model's context is.
  const meter = element('div', 'chat-meter');
  meter.id = 'chat-meter';
  meter.title = 'Context used. /compact summarises the conversation to free it.';
  meter.append(element('div', 'chat-meter-bar'), element('span', 'chat-meter-text'));

  const panel = element('div', 'chat-settings');
  panel.id = 'chat-settings';
  panel.hidden = true;

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
  const text = element('textarea', 'chat-text');
  text.id = 'chat-text';
  text.rows = 3;
  text.placeholder = 'Ask, or tell the agent what to change. /compact, /clear';
  text.setAttribute('autocapitalize', 'sentences');
  text.addEventListener('keydown', (e) => {
    e.stopPropagation();
    if (e.key === 'Enter' && !e.shiftKey && !e.isComposing) { e.preventDefault(); send(); }
  });
  const mode = element('select', 'chat-mode');
  mode.id = 'chat-mode';
  mode.title = 'What the agent may do without asking';
  for (const [value, label, help] of MODES) {
    const option = element('option', null, label);
    option.value = value;
    option.title = help;
    mode.append(option);
  }
  mode.addEventListener('change', () => saveSetting({ mode: mode.value }));
  const context = element('label', 'chat-context');
  const box = element('input');
  box.type = 'checkbox';
  box.id = 'chat-include';
  box.checked = true;
  const contextName = element('span');
  contextName.id = 'chat-include-name';
  context.append(box, contextName);
  const sendButton = element('button', 'chat-send', 'Send');
  sendButton.id = 'chat-send';
  sendButton.addEventListener('click', () => (busy ? stop() : send()));
  const row = element('div', 'chat-row');
  row.append(mode, context, sendButton);
  form.append(text, row);

  pane.append(header, meter, panel, log, form);
  $('editor-container').append(pane);
  render();
}

function saveSetting(change) {
  Object.assign(settings, change);
  api.native({ cmd: 'aiChatSettings', ...change }).catch(() => {});
  if ('contextSize' in change) loadSettings();
  updateMeter();
  renderSettings();
}

async function loadSettings() {
  const info = await api.native({ cmd: 'aiChatModels' }).catch(() => null);
  if (!info) return;
  settings = { ...settings, ...info, models: info.models || [] };
  const select = $('chat-model');
  select.replaceChildren();
  for (const m of settings.models) {
    const option = element('option', null, m.ready ? m.name : `${m.name} (${m.detail})`);
    option.value = m.id;
    option.disabled = !m.ready;
    option.selected = m.id === settings.selected;
    select.append(option);
  }
  const more = element('option', null, 'Download More Models…');
  more.value = '__more__';
  select.append(more);
  $('chat-mode').value = settings.mode || 'edit';
  renderSettings();
  updateMeter();
}

/** Chat settings: context size, subagents, compacting. */
function renderSettings() {
  const panel = $('chat-settings');
  if (!panel) return;
  panel.replaceChildren();
  const row = (label, control, help) => {
    const r = element('label', 'chat-setting');
    r.append(element('span', 'chat-setting-label', label), control);
    if (help) r.title = help;
    panel.append(r);
  };
  const select = (values, current, onChange) => {
    const s = element('select');
    for (const [value, label] of values) {
      const o = element('option', null, label);
      o.value = String(value);
      o.selected = String(value) === String(current);
      s.append(o);
    }
    s.addEventListener('change', () => onChange(s.value));
    return s;
  };
  row('Context size', select([[2048, '2K'], [4096, '4K'], [8192, '8K'], [16384, '16K'], [32768, '32K']], settings.contextSize,
    (v) => saveSetting({ contextSize: Number(v) })), 'Tokens a downloaded model reads at once. Bigger remembers more but needs more memory. Apple Intelligence\'s is 4K.');
  row('Subagent model', select([['', 'Same as Chat'], ...settings.models.filter((m) => m.ready).map((m) => [m.id, m.name])], settings.subagentModel,
    (v) => saveSetting({ subagentModel: v })), 'The model subagents use: a small one is quicker, a big one better.');
  row('Subagents at once', select([[0, 'Off'], [1, '1'], [2, '2'], [3, '3'], [4, '4'], [6, '6'], [8, '8']], settings.subagentParallel,
    (v) => saveSetting({ subagentParallel: Number(v) })), 'How many subagents run side by side. Each local model is loaded once; Apple Intelligence runs several freely.');
  const actions = element('div', 'chat-setting-actions');
  const compactButton = element('button', 'chat-small', 'Compact Now');
  compactButton.addEventListener('click', async () => { if (busy) return; busy = true; updateControls(); await compact('asked'); busy = false; updateControls(); });
  actions.append(compactButton);
  panel.append(actions);
}

function updateMeter() {
  const meter = $('chat-meter');
  if (!meter) return;
  const used = usedTokens();
  const limit = contextLimit();
  const share = Math.min(1, used / limit);
  meter.querySelector('.chat-meter-bar').style.setProperty('--share', share);
  meter.classList.toggle('warn', share > 0.7);
  const k = (n) => (n >= 1024 ? (n / 1024).toFixed(1).replace(/\.0$/, '') + 'k' : String(n));
  meter.querySelector('.chat-meter-text').textContent = `${k(used)} / ${k(limit)} tokens`;
}

function updateControls() {
  if (!pane) return;
  $('chat-send').textContent = busy ? 'Stop' : 'Send';
}

function updateContextLabel() {
  if (!pane) return;
  const path = api.current();
  const sel = api.view.state.selection.main;
  $('chat-include-name').textContent = path ? `${path.split('/').pop()}${sel.empty ? '' : ' (selection)'}` : 'No file open';
  $('chat-include').disabled = !path;
}

export const chatOpen = () => !!pane && !pane.hidden;

/** Opens the panel (Chat: Open Chat, ⌃⌘I); `prompt` fills the box. */
export function openChat(prompt) {
  build();
  pane.hidden = false;
  $('editor-container').classList.add('chat-open');
  api.view.requestMeasure();
  loadSettings();
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

/** The selection or file changed: the "include" label follows. */
export function chatSelectionChanged() { if (chatOpen()) updateContextLabel(); }

// MARK: - Rendering

/** Reasoning models write their thinking in <think>…</think>: shown folded away. */
function renderAnswer(text) {
  const html = [];
  let rest = withoutToolBlocks(text);
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
  if (message.kind === 'tool') return null;   // shown as tool cards as they run
  if (message.kind === 'summary') return element('div', 'chat-note', message.reason === 'auto' ? 'The conversation was compacted to free the context.' : 'Conversation compacted.');
  const role = message.kind === 'error' ? 'error' : message.role;
  const el = element('div', `chat-message ${role}`);
  el.append(element('div', 'chat-who', role === 'user' ? 'You' : role === 'error' ? 'Error' : 'Agent'));
  const body = element('div', 'chat-body');
  if (role === 'assistant') {
    body.innerHTML = renderAnswer(message.shown || '');
    decorateCode(body);
    for (const call of message.calls || []) body.append(element('div', 'chat-chip', '⚙ ' + call));
  } else {
    body.textContent = message.shown ?? message.content;
  }
  el.append(body);
  return el;
}

const cards = [];   // tool cards and approvals, kept across renders

function toolCard(result, state, output) {
  const card = element('div', `chat-tool ${state}`);
  card.append(element('div', 'chat-tool-title', (state === 'denied' ? '✕ ' : '✓ ') + result.summary + (state === 'denied' ? ' (not allowed)' : '')));
  if (result.preview && result.preview.text) {
    const details = element('details');
    details.append(element('summary', null, `Changes from line ${result.preview.line}`), element('pre', 'chat-diff', result.preview.text));
    card.append(details);
  } else if (output) {
    const details = element('details');
    details.append(element('summary', null, 'Output'), element('pre', 'chat-diff', output));
    card.append(details);
  }
  if (result.path && state === 'done' && result.preview) {
    const open = element('button', 'chat-small', 'Open');
    open.addEventListener('click', () => api.openFile(result.path));
    card.append(open);
  }
  cards.push({ at: messages.length, el: card });
  $('chat-log').append(card);
  scrollToEnd();
}

/** Asks the user about a call: resolves 'allow', 'always' or 'deny'. */
function approval(call, result) {
  return new Promise((resolve) => {
    const card = element('div', 'chat-approval');
    const title = call.tool === 'run_command' ? `Run \`${result.command}\`?` : `${result.summary.replace(/^(Edited|Created|Rewrote)/, (w) => ({ Edited: 'Edit', Created: 'Create', Rewrote: 'Rewrite' })[w])}?`;
    card.append(element('div', 'chat-tool-title', title));
    if (result.preview) card.append(element('pre', 'chat-diff', result.preview.text));
    const buttons = element('div', 'chat-approval-buttons');
    const decide = (answer) => {
      if (card.classList.contains('decided')) return;
      card.classList.add('decided');
      card.remove();
      resolve(answer);
    };
    card.decide = decide;
    for (const [answer, label] of [['allow', 'Allow'], ['always', 'Always'], ['deny', 'Deny']]) {
      const b = element('button', answer === 'allow' ? 'chat-send' : 'chat-small', label);
      if (answer === 'always') b.title = `Allow ${call.tool} for the rest of this chat`;
      b.addEventListener('click', () => decide(answer));
      buttons.append(b);
    }
    card.append(buttons);
    $('chat-log').append(card);
    scrollToEnd();
  });
}

function progressCard(tasks) {
  const card = element('div', 'chat-tool');
  card.append(element('div', 'chat-tool-title', `Subagents (${tasks.length})`));
  const rows = tasks.map((task, i) => {
    const r = element('div', 'chat-subagent', `${i + 1}. ${task.slice(0, 80)} — waiting`);
    card.append(r);
    return r;
  });
  cards.push({ at: messages.length, el: card });
  $('chat-log').append(card);
  scrollToEnd();
  return { set: (i, state) => { rows[i].textContent = `${i + 1}. ${tasks[i].slice(0, 80)} — ${state}`; } };
}

function notice(text) {
  $('chat-log').append(element('div', 'chat-note', text));
  scrollToEnd();
}

function scrollToEnd() {
  const log = $('chat-log');
  if (log) log.scrollTop = log.scrollHeight;
}

function render() {
  if (!pane) return;
  const log = $('chat-log');
  if (!messages.length && liveText == null) {
    cards.length = 0;
    log.replaceChildren(element('div', 'chat-empty',
      'Ask about your code, or tell the agent what to change: it reads, searches and edits the project, runs commands and sends research to subagents. '
      + 'The mode below says what it may do without asking. Everything runs on this device.'));
    updateMeter();
    return;
  }
  const children = [];
  messages.forEach((m, i) => {
    const b = bubble(m);
    if (b) children.push(b);
    for (const card of cards) if (card.at === i + 1) children.push(card.el);
  });
  for (const card of document.querySelectorAll('.chat-approval:not(.decided)')) children.push(card);
  if (liveText != null) {
    const pending = bubble({ role: 'assistant', shown: liveText });
    pending.classList.add('pending');
    if (!liveText) pending.querySelector('.chat-body').innerHTML = '<span class="chat-typing">Thinking…</span>';
    pending.id = 'chat-live';
    children.push(pending);
  }
  log.replaceChildren(...children);
  scrollToEnd();
  updateMeter();
}

function scheduleLive() {
  if (frame) return;
  frame = requestAnimationFrame(() => {
    frame = 0;
    const el = document.getElementById('chat-live');
    if (!el || liveText == null) return render();
    const body = el.querySelector('.chat-body');
    body.innerHTML = liveText ? renderAnswer(liveText) : '<span class="chat-typing">Thinking…</span>';
    scrollToEnd();
  });
}
