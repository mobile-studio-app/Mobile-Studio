// The Chat panel: a coding agent like Claude Code, running on the device (Apple Intelligence or a
// downloaded model; App/AI/AIChatService.swift). It reads, searches and edits the project's files,
// runs commands and hands research to subagents, asking first as much as the mode says:
//   manual: asks before every edit and command
//   edit:   edits files, asks before commands
//   auto:   edits and runs commands, asks before risky ones (deleting, pushing, ...)
//   turbo:  never asks
// The model calls tools by writing them out (<tool_call><function=…>, Qwen's own format, whose values
// need no escaping), which works for every model; calls written in the other usual formats are
// read too (toolcalls.js), and ones that can't be read go back to the model to make again. The
// header shows how full the model's context is; /compact (or near the limit) summarises the
// conversation into one message.
import { renderMarkdown } from './markdown.js';
import { forEachDiagnostic } from '@codemirror/lint';
import { terminalText } from './terminal.js';
import { channelText, outputChannels } from './ext/output.js';
import { readToolCalls, withoutToolCalls, cutInventedResults, usage, STOP_AT } from './toolcalls.js';

// { native, view, current, openURL, appCommand, openFile, runCommand(command, onOutput) → exit code,
//   problems(), save() (the open file, to disk), pathMoved(from, to?) (tabs follow a move or delete) }
let api = null;
const $ = (id) => document.getElementById(id);
let pane = null;

// { role: 'user' | 'assistant', content (the model's), shown?, kind?: 'tool' | 'summary', keep?, thinking? }
let messages = [];
let busy = false;
let stopped = false;
let settings = { models: [], selected: 'apple', contextSize: 4096, subagentModel: '', subagentParallel: 2, subagentContextSize: 4096, mode: 'edit', thinking: false, kvBits: 8 };
const allowedThisChat = new Set();   // tools "Always" was picked for
const requests = new Map();          // request id → { resolve, onText }
let nextId = 1;
let frame = 0;
let liveText = null;                 // the answer being written, for the pending bubble

const MAX_STEPS = 50;
const MAX_REPEATS = 3;           // the same tool call again this many times: the agent is going in circles
const MAX_TROUBLES = 3;          // replies in a row whose calls couldn't be read: the model can't manage the format
const KEPT_TOOL_RESULTS = 2;     // the latest tool results go in full; older ones are cut short
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

/** About how many tokens a text is: code runs about 3.5 characters a token, corrected by what the
 * model last counted (local models say how long their prompt really was). */
let tokenRatio = 1;
const rawTokens = (text) => String(text || '').length / 3.5;
const tokens = (text) => Math.ceil(rawTokens(text) * tokenRatio);

const modelInfo = (id) => settings.models.find((m) => m.id === id) || {};

/** The context a model gets for a wanted size: no more than it was trained for, or than fits. */
function effectiveContext(modelId, wanted) {
  const contexts = modelInfo(modelId).contexts || [];
  if (!contexts.length) return wanted;
  // A cloud model's context is its provider's, not a memory budget.
  if (modelInfo(modelId).cloud) return contexts[0].tokens;
  const usable = contexts.filter((c) => c.fits).map((c) => c.tokens);
  return Math.min(wanted, usable.length ? Math.max(...usable) : 2048, Math.max(...contexts.map((c) => c.tokens)));
}

const contextLimit = () => effectiveContext(settings.selected, settings.contextSize);

/** Whether a model can be the agent: small ones loop and call tools wrongly, so they only chat. */
const canAgent = (id = settings.selected) => !!modelInfo(id).agent;
/** 'none', 'optional' (Think turns it on) or 'always'. */
const reasoning = (id = settings.selected) => modelInfo(id).reasoning || 'none';
const thinkingOn = () => reasoning() === 'always' || (settings.thinking && reasoning() !== 'none');
/** Whether a model can be a subagent: they only read and search, so smaller models (Apple
 * Intelligence) manage it too. */
const canSubagent = (id) => !!(modelInfo(id).subagent || modelInfo(id).agent) && modelInfo(id).ready !== false;
const subagentModel = () => (settings.subagentModel && canSubagent(settings.subagentModel) ? settings.subagentModel : settings.selected);
const subagentsOn = () => settings.subagentParallel > 0 && canSubagent(subagentModel());
/** Room kept for the answer: a quarter of the context, so a whole file can be written in one call
 * (thinking needs more). */
const answerTokens = () => {
  const base = canAgent() ? Math.max(1536, Math.min(6144, Math.floor(contextLimit() / 4))) : 1536;
  return thinkingOn() ? Math.min(8192, base + 1536) : base;
};

// MARK: - The tools

// Other names models give the arguments.
const PATH = ['file_path', 'filepath', 'file', 'filename', 'file_name', 'target_file', 'relative_path', 'uri', 'dir', 'directory', 'folder'];
const TEXT = ['contents', 'text', 'code', 'file_text', 'body', 'data', 'new_content', 'source', 'lines', 'new_text'];
const START = ['start', 'line_start', 'startline', 'from_line', 'first_line', 'begin', 'start_line_number', 'line'];
const END = ['end', 'line_end', 'endline', 'to_line', 'last_line', 'end_line_number'];
const FROM = ['source', 'src', 'old_path', 'from_path', 'oldpath', 'source_path', 'path', 'file_path'];
const TO = ['destination', 'dest', 'target', 'new_path', 'to_path', 'newpath', 'new_name', 'target_path', 'destination_path'];
const LINES = ['count', 'n', 'limit', 'tail'];
const param = (name, type = 'string', aliases = [], extra = {}) => ({ name, type, aliases, ...extra });
const optional = (name, type, aliases, extra = {}) => param(name, type, aliases, { optional: true, ...extra });
const PATH_PARAM = param('path', 'string', PATH);

// kind: read (runs without asking; subagents have these), edit, delete, run, delegate.
const TOOLS = [
  { name: 'read_file', kind: 'read', params: [PATH_PARAM, optional('start_line', 'int', START), optional('end_line', 'int', END)],
    help: 'the file with line numbers. A long file comes in parts, each saying how to read on.' },
  { name: 'read_files', kind: 'read', params: [param('paths', 'array', ['files', 'file_paths', 'path'], { splitCommas: true })], help: 'several files at once.' },
  { name: 'list_files', kind: 'read', params: [optional('path', 'string', PATH)], help: 'the project\'s files (or a folder\'s).' },
  { name: 'find_files', kind: 'read', params: [param('pattern', 'string', ['glob', 'query', 'name'])], help: 'files whose path matches a glob, like **/*.lua or src/*.js.' },
  { name: 'search', kind: 'read', params: [param('query', 'string', ['pattern', 'text', 'q', 'term', 'keyword', 'search', 'regex_pattern']),
    optional('path', 'string', PATH), optional('regex', 'bool', ['is_regex', 'use_regex'])],
  help: 'the lines containing the text (any case; a regular expression when regex is true), as path:line: text.' },
  { name: 'get_problems', kind: 'read', params: [], help: 'the errors and warnings in the project.' },
  { name: 'read_console', kind: 'read', params: [optional('lines', 'int', LINES)], help: 'the program console\'s last lines (what the program printed when it last ran).' },
  { name: 'read_terminal', kind: 'read', params: [optional('lines', 'int', LINES)], help: 'what the Terminal panel shows.' },
  { name: 'read_output', kind: 'read', params: [optional('channel', 'string', ['name'])], help: 'an Output panel channel (without one, the list of channels).' },

  { name: 'edit_file', kind: 'edit', params: [PATH_PARAM, param('old', 'text', ['old_string', 'old_str', 'old_text', 'search', 'find', 'original', 'before']),
    param('new', 'text', ['new_string', 'new_str', 'new_text', 'replace', 'replacement', 'after']), optional('replace_all', 'bool', ['all', 'replace_every'])],
  help: 'replaces the text old, copied from the file with enough lines to appear only once, with new (every place it appears with replace_all true).' },
  { name: 'replace_lines', kind: 'edit', params: [PATH_PARAM, param('start_line', 'int', START), param('end_line', 'int', END), param('content', 'text', TEXT)],
    help: 'replaces lines start_line to end_line with content.' },
  { name: 'insert_lines', kind: 'edit', params: [PATH_PARAM, param('line', 'int', ['line_number', 'at_line', 'at', 'position', 'before_line', 'insert_line', 'start_line'],
    { from: { after_line: (v) => Number(v) + 1, after: (v) => Number(v) + 1 } }), param('content', 'text', TEXT)],
  help: 'inserts content so that it starts at that line (1: the top; the line count + 1: the end).' },
  { name: 'delete_lines', kind: 'edit', params: [PATH_PARAM, param('start_line', 'int', START), param('end_line', 'int', END)], help: 'deletes lines start_line to end_line.' },
  { name: 'write_file', kind: 'edit', params: [PATH_PARAM, param('content', 'text', TEXT)], help: 'creates a file, or replaces all of one (making its folders).' },
  { name: 'append_file', kind: 'edit', params: [PATH_PARAM, param('content', 'text', TEXT)], help: 'adds content to the end of a file (or creates it).' },
  { name: 'create_folder', kind: 'edit', params: [PATH_PARAM], help: 'makes a folder.' },
  { name: 'copy_file', kind: 'edit', params: [param('from', 'string', FROM), param('to', 'string', TO)], help: 'copies a file.' },
  { name: 'move_file', kind: 'edit', params: [param('from', 'string', FROM), param('to', 'string', TO)], help: 'moves or renames a file or folder.' },
  { name: 'delete_file', kind: 'delete', params: [PATH_PARAM], help: 'deletes a file or folder.' },

  { name: 'run_command', kind: 'run', params: [param('command', 'string', ['cmd', 'script', 'shell_command', 'commands'])],
    help: 'runs a shell command in the project folder (ls, cat, grep, git, node, npm, python, lua) and returns its output.' },
  { name: 'run_program', kind: 'run', params: [optional('seconds', 'int', ['timeout', 'duration', 'time']), optional('keep_running', 'bool', ['keep_open'])],
    help: 'runs the project as the Run button does and returns what it printed and how it ended. Games keep running: their output is collected for seconds (8 unless given), then they stop unless keep_running is true.' },
  { name: 'delegate', kind: 'delegate', params: [param('tasks', 'array', ['task', 'questions', 'prompts', 'queries'])],
    help: 'gives self-contained research questions to subagents, which read and search (they can\'t change anything) and answer each one. Use it to look into several things at once.' },

  // Long-term memory, in the context cache (App/AI/ContextCache.swift): kept per project, across chats.
  // recall and load_memory are 'recall' (subagents have them too), remember and forget 'memory'.
  { name: 'remember', kind: 'memory', params: [param('title', 'string', ['name', 'topic', 'key']), param('content', 'text', TEXT)],
    help: 'saves a note to long-term memory: what you learned about the project (how it\'s organised, conventions, decisions, what the user wants) '
      + 'for later chats. A note with the same title is replaced, so keep notes up to date.' },
  { name: 'recall', kind: 'recall', params: [param('query', 'string', ['q', 'search', 'text', 'topic'])],
    help: 'searches long-term memory (your notes, and earlier conversations and long results set aside when they left your context): '
      + 'ids, titles and the passages that match.' },
  { name: 'load_memory', kind: 'recall', params: [param('id', 'string', ['memory', 'memory_id', 'name']), optional('part', 'int', ['page', 'section'])],
    help: 'loads a memory into your context (a long one in parts, each saying how to go on).' },
  { name: 'forget', kind: 'memory', params: [param('id', 'string', ['memory', 'memory_id'])], help: 'deletes a memory that\'s wrong or no longer true.' },
];
const TOOL = Object.fromEntries(TOOLS.map((t) => [t.name, t]));

const EDIT_EXAMPLE = '<tool_call>\n<function=edit_file>\n<parameter=path>\nmain.lua\n</parameter>\n<parameter=old>\n    print("hi")\n</parameter>\n'
  + '<parameter=new>\n    print("hello")\n</parameter>\n</function>\n</tool_call>';
const READ_EXAMPLE = '<tool_call>\n<function=read_file>\n<parameter=path>\nmain.lua\n</parameter>\n</function>\n</tool_call>';

function toolHelp(subagent) {
  const show = TOOLS.filter((t) => (subagent ? t.kind === 'read' || t.kind === 'recall' : t.kind !== 'delegate' || subagentsOn()));
  const line = (t) => `- ${usage(t.name, TOOL)}: ${t.help}`;
  const group = (title, kinds) => {
    const list = show.filter((t) => kinds.includes(t.kind));
    return list.length ? [title, ...list.map(line)] : [];
  };
  return [
    'Tools: call one by writing exactly this, with one <parameter> for each argument. Write each value as it is, code included: no quotes, no escaping.',
    subagent ? READ_EXAMPLE : EDIT_EXAMPLE,
    'You can make several calls in one reply: they run in order, and their results come back in the next message (never write the results yourself). '
      + 'Arguments marked ? can be left out. When you\'re finished, answer normally, with no call.',
    ...group('Looking:', ['read']),
    ...group('Changing files (each change shows the changed lines with their new numbers):', ['edit', 'delete']),
    ...group('Running:', ['run', 'delegate']),
    ...group('Long-term memory (this project\'s, kept across chats):', ['memory', 'recall']),
    ...(subagent ? [] : [
      'Look before you change anything: read a file before you edit it. For small changes use edit_file, or the line tools with line numbers from your '
        + 'latest read; use write_file for new files and rewrites, and write a long file in parts (write_file, then append_file). After changing code, '
        + 'check it with get_problems or run_program.',
      'Your context is small, but nothing in it is lost: what leaves it is kept in long-term memory. When something you need was cut short or '
        + 'happened earlier, recall it. When you learn something worth knowing next time, remember it.',
    ]),
  ].join('\n');
}

let projectList = [];   // the project's files, refreshed before each question
let memoryNotes = [];   // the project's notes in long-term memory ({ id, title }), refreshed before each question

function systemPrompt() {
  if (!canAgent()) {
    return 'You are the coding assistant built into Mobile Studio, a code editor on iPhone and iPad. Answer questions about the user\'s '
      + 'code: the open file comes with each question. You can\'t read other files or change anything yourself, so show changes as code '
      + 'for the user to apply. Be brief and precise. Use Markdown; put code in fenced blocks tagged with the language.' + thinkingNote();
  }
  const files = projectList.length
    ? `\n\nThe project's files (${projectList.length}):\n${projectList.slice(0, 150).join('\n')}${projectList.length > 150 ? '\n… (list_files or find_files for the rest)' : ''}`
    : '';
  const notes = memoryNotes.length
    ? `\n\nYour notes about this project in long-term memory (load_memory to read one):\n${memoryNotes.slice(0, 30).map((n) => `- ${n.id}: ${n.title}`).join('\n')}`
    : '';
  return 'You are the coding agent built into Mobile Studio, a code editor on iPhone and iPad. You work in the user\'s project: '
    + 'you read and change its files, run commands and run the program with the tools below. Look at the files that matter, not '
    + 'just the open one. Be brief and precise. Use Markdown; put code in fenced blocks tagged with the language.\n\n'
    + toolHelp(false) + files + notes + thinkingNote();
}

// Qwen3.5 and LFM3 (and Gemma 4, SmolLM3) reason by themselves; the app opens their thinking, or skips it, as their
// templates do. Other models are asked to reason in <think> tags when thinking is on.
const REASONS_ITSELF = /^(qwen3\.5|lfm3|gemma4|smollm3)/;

function thinkingNote() {
  if (thinkingOn() && !REASONS_ITSELF.test(settings.selected)) {
    return '\n\nThink before you answer: first reason step by step inside <think></think> tags (what is asked, what to look at, the plan), '
      + 'then write your answer and any tool blocks after </think>.';
  }
  return '';
}

/** A reply's reasoning, if it has any. */
function thinkingOf(text) {
  const close = text.indexOf('</think>');
  const open = text.lastIndexOf('<think>', close >= 0 ? close : text.length);
  if (close >= 0) return text.slice(open >= 0 ? open + 7 : 0, close).trim();
  return open >= 0 ? text.slice(open + 7).trim() : '';
}

/** A reply without its reasoning (a <think> block, or everything before </think> when the template opened it). */
function withoutThinking(text) {
  const close = text.indexOf('</think>');
  if (close >= 0 && text.lastIndexOf('<think>', close) < 0) return text.slice(close + 8).trim();
  return text.replace(/<think>[\s\S]*?(<\/think>|$)/g, '').trim();
}

/** Asks the model; `onText` gets the answer as it's written. Resolves with { text, error, stopped,
 * promptTokens, dropped }: how long the prompt really was, and how many old turns didn't fit.
 * `stop`: texts the answer ends before (where a model starts writing a tool's results itself). */
function ask(chat, { model, maxTokens, onText, contextSize, thinking = false, stop } = {}) {
  const id = 'c' + nextId++;
  return new Promise((resolve) => {
    requests.set(id, { resolve, onText });
    api.native({ cmd: 'aiChat', id, messages: chat, model: model || undefined, maxTokens: maxTokens || 1536, contextSize: contextSize || settings.contextSize, thinking, stop })
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
    request.resolve({ text: payload.text || '', error: payload.error, promptTokens: payload.promptTokens, dropped: payload.dropped || 0 });
  }
}

// MARK: - Tool calls

const NO_CALLS = { calls: [], errors: [], spans: [], attempted: false, cutOff: false };

/** What to tell the model when its calls couldn't be read. */
function callTrouble(parsed, maxTokens) {
  const lines = [...parsed.errors];
  if (parsed.cutOff) {
    lines.push(`Your reply was cut off in the middle of a tool call (a reply can be about ${maxTokens} tokens), so it wasn't run. Make it again in `
      + 'smaller parts: write a long file with write_file for its first part and append_file for the rest, or change just the lines that change.');
  } else {
    lines.push('Write each call like this, with nothing after the last one:\n' + EDIT_EXAMPLE);
  }
  return lines.join('\n');
}

// Run without asking: looking, subagents, and the agent's own memory (it doesn't touch the project).
const READ_ONLY = new Set(TOOLS.filter((t) => ['read', 'delegate', 'recall', 'memory'].includes(t.kind)).map((t) => t.name));
const CHANGES_FILES = new Set(TOOLS.filter((t) => t.kind === 'edit' || t.kind === 'delete').map((t) => t.name).concat('run_command'));
const RISKY = /(^|[\s;&|])(rm|rmdir|mv|chmod|kill|curl|wget|dd)\b|git\s+(push|reset|clean|checkout|rebase|branch\s+-D)|npm\s+(publish|uninstall)|>\s*\S/;

/** Whether a call runs without asking, in the current mode. */
function allowedWithoutAsking(call) {
  if (READ_ONLY.has(call.tool) || allowedThisChat.has(call.tool)) return true;
  const mode = settings.mode;
  if (mode === 'turbo') return true;
  const kind = TOOL[call.tool] && TOOL[call.tool].kind;
  if (kind === 'edit') return mode !== 'manual';
  if (call.tool === 'run_command') return mode === 'auto' && !RISKY.test(String(call.command || ''));
  if (call.tool === 'run_program') return mode === 'auto';
  // Deleting asks, but in Turbo.
  return false;
}

const clip = (text, max = MAX_TOOL_OUTPUT) => (text.length > max ? text.slice(0, max) + `\n… (${text.length - max} more characters)` : text);
const cleanPath = (p) => String(p || '').trim().replace(/^["'`]|["'`]$/g, '').replace(/\\/g, '/').replace(/^\.?\/+/, '').replace(/\/+$/, '').replace(/^\.$/, '');

async function readText(p) {
  const clean = cleanPath(p);
  if (clean === api.current()) return api.view.state.doc.toString();
  return api.native({ cmd: 'read', path: clean });
}

async function projectFiles() {
  const list = await api.native({ cmd: 'list' }).catch(() => []);
  return Array.isArray(list) ? list : [];
}

/** 'file', 'folder' or null. */
async function pathKind(p) {
  if (p && p === api.current()) return 'file';
  try {
    const stat = await api.native({ cmd: 'fs', op: 'stat', path: p });
    return stat && stat.type === 2 ? 'folder' : 'file';
  } catch (e) {
    return null;
  }
}

/** Writes a file: into the editor when it's the open one (so undo works), else to disk. */
async function writeText(p, text) {
  const clean = cleanPath(p);
  if (clean === api.current()) {
    const { view } = api;
    const old = view.state.doc.toString();
    let start = 0;
    while (start < old.length && start < text.length && old[start] === text[start]) start++;
    let endOld = old.length, endNew = text.length;
    while (endOld > start && endNew > start && old[endOld - 1] === text[endNew - 1]) { endOld--; endNew--; }
    view.dispatch({ changes: { from: start, to: endOld, insert: text.slice(start, endNew) }, userEvent: 'input.agent' });
    return;
  }
  await api.native({ cmd: 'write', path: clean, contents: text });
}

/** Why a path can't be read, with the files it may have meant. */
async function missing(p) {
  const files = await projectFiles();
  const name = p.split('/').pop().toLowerCase();
  const near = files.filter((f) => f.split('/').pop().toLowerCase() === name || f.toLowerCase().endsWith('/' + p.toLowerCase())).slice(0, 5);
  return `Error: ${p || 'that path'} doesn't exist.` + (near.length ? ` Did you mean ${near.join(', ')}?` : ' list_files or find_files shows the files.');
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

// Text as lines: a final newline ends the last line rather than starting another.
const linesOf = (text) => { const body = text.endsWith('\n') ? text.slice(0, -1) : text; return body === '' ? [] : body.split('\n'); };
const joinLines = (lines, finalNewline) => (lines.length ? lines.join('\n') + (finalNewline ? '\n' : '') : '');
const lineAt = (text, offset) => text.slice(0, offset).split('\n').length;
const numbered = (lines, first) => lines.map((l, i) => `${first + i}\t${l.length > 1000 ? l.slice(0, 1000) + ' …' : l}`).join('\n');

/** The lines around a change, with their numbers, so the model knows the file as it now is. */
function changedLines(path, after, first, last) {
  const lines = linesOf(after);
  if (!lines.length) return `${path} is now empty.`;
  const from = Math.max(1, first - 2);
  const to = Math.min(lines.length, Math.max(last, first) + 2);
  let shown = numbered(lines.slice(from - 1, to), from);
  if (to - from > 40) shown = numbered(lines.slice(from - 1, from + 14), from) + '\n…\n' + numbered(lines.slice(to - 15, to), to - 14);
  return `Lines ${from}-${to} now read:\n${shown}\n(${path} has ${lines.length} lines.)`;
}

/** A file to change, without its \r\n (written back as it was). */
async function loadFile(p) {
  const raw = await readText(p);
  if (typeof raw !== 'string') throw new Error(`${p} isn't a text file`);
  return { text: raw.replace(/\r\n/g, '\n'), crlf: raw.includes('\r\n') };
}
const restore = (text, crlf) => (crlf ? text.replace(/\n/g, '\r\n') : text);

/** A change to a file, for approval and then writing. */
function fileChange(p, before, after, crlf, ask, output, summary) {
  return { summary, output, ask, path: p, preview: changePreview(before, after), apply: () => writeText(p, restore(after, crlf)) };
}

/** Where `old` is in `text`: exactly; without line numbers copied from read_file or blank lines at
 * its ends; then line by line ignoring spaces at line ends, then indentation (new is re-indented to
 * match). { edits: [{ from, to, insert }] } or { error }. */
function locate(text, oldText, newText, replaceAll, p) {
  const strip = (t) => t.split('\n').map((l) => l.replace(/^\s*\d+\t/, '')).join('\n');
  const tries = [[oldText, newText]];
  const oldLines = oldText.split('\n').filter((l) => l.trim());
  if (oldLines.length && oldLines.every((l) => /^\s*\d+\t/.test(l))) tries.push([strip(oldText), strip(newText)]);
  const last = tries[tries.length - 1];
  tries.push([last[0].replace(/^\n+|\n+$/g, ''), last[1].replace(/^\n+|\n+$/g, '')]);
  const many = (count, lines) => ({ error: `the text to replace appears ${count} times in ${p} (lines ${lines.join(', ')}). Include more lines around it so it appears once, or set replace_all to true.` });
  for (const [o, n] of tries) {
    if (!o) continue;
    const at = [];
    for (let i = text.indexOf(o); i >= 0; i = text.indexOf(o, i + o.length)) at.push(i);
    if (at.length === 1 || (replaceAll && at.length)) return { edits: at.map((i) => ({ from: i, to: i + o.length, insert: n })) };
    if (at.length > 1) return many(at.length, at.map((i) => lineAt(text, i)));
  }
  const [o, n] = tries[tries.length - 1];
  if (!o.trim()) return { error: 'old is empty: say which text to replace (or use insert_lines or write_file).' };
  const file = text.split('\n');
  const starts = [0];
  for (const l of file) starts.push(starts[starts.length - 1] + l.length + 1);
  const want = o.split('\n');
  const indent = (l) => /^\s*/.exec(l)[0];
  for (const loose of [(l) => l.trimEnd(), (l) => l.trim()]) {
    const target = want.map(loose);
    const hits = [];
    for (let i = 0; i + want.length <= file.length; i++) {
      let same = true;
      for (let j = 0; j < want.length && same; j++) same = loose(file[i + j]) === target[j];
      if (same) hits.push(i);
    }
    if (hits.length > 1 && !replaceAll) return many(hits.length, hits.map((i) => i + 1));
    if (hits.length) {
      return {
        edits: hits.map((i) => {
          const k = want.findIndex((l) => l.trim());
          const was = indent(want[k]);
          const is = indent(file[i + k]);
          const insert = was === is ? n : n.split('\n').map((l) => (l.trim() && l.startsWith(was) ? is + l.slice(was.length) : l)).join('\n');
          return { from: starts[i], to: starts[i + want.length - 1] + file[i + want.length - 1].length, insert };
        }),
      };
    }
  }
  // Not there: the lines that look closest, to copy from.
  const words = (l) => new Set(l.toLowerCase().match(/\w+/g) || []);
  const first = words(want.find((l) => l.trim()) || '');
  let best = -1;
  let score = 0;
  file.forEach((l, i) => {
    const w = words(l);
    let shared = 0;
    for (const x of first) if (w.has(x)) shared++;
    if (shared > score) { score = shared; best = i; }
  });
  const near = best >= 0 && score > 0
    ? ` The closest lines are:\n${numbered(file.slice(Math.max(0, best - 3), best + want.length + 3), Math.max(1, best - 2))}\n`
    : ' ';
  return { error: `the text to replace isn't in ${p}.${near}Copy old exactly as the file has it (read_file shows it), or use replace_lines with line numbers.` };
}

/** read_file's room: about a third of the context, so a long file comes in parts. */
const readRoom = (subagent) => {
  // Apple Intelligence's 4K context keeps the task and a part of a file.
  if (subagent && subagentModel() === 'apple') return 1800;
  const context = subagent ? effectiveContext(subagentModel(), settings.subagentContextSize) : contextLimit();
  return Math.max(2500, Math.min(60000, Math.floor(context * 3.5 * 0.3)));
};

/** Runs one tool call: { summary (for the chip), output (for the model), apply? (after approval),
 * ask? (the approval's question), preview?, path? }. */
async function runTool(call, { subagent = false } = {}) {
  const t = call.tool;
  const def = TOOL[t];
  if (!def) return { summary: t, output: `Error: there's no tool called ${t}.` };
  if (subagent && def.kind !== 'read' && def.kind !== 'recall') return { summary: t, output: `Error: subagents can only read and search; ${t} isn't available.` };
  try {
    const p = cleanPath(call.path);
    if (t === 'read_file') {
      let text;
      try { text = await readText(p); } catch (e) {
        if (await pathKind(p) === 'folder') return runTool({ tool: 'list_files', path: p }, { subagent });
        return { summary: `Read ${p} (missing)`, output: await missing(p) };
      }
      const lines = text.replace(/\r\n/g, '\n').split('\n');
      if (lines.length > 1 && lines[lines.length - 1] === '') lines.pop();
      const from = Math.min(Math.max(1, Number(call.start_line) || 1), Math.max(1, lines.length));
      let to = Math.min(lines.length, Number(call.end_line) || lines.length);
      if (to < from) to = from;
      // As many lines as fit the room.
      const room = readRoom(subagent);
      let size = 0;
      let end = from - 1;
      while (end < to && size + Math.min(lines[end].length, 1000) + 8 <= room) size += Math.min(lines[end++].length, 1000) + 8;
      if (end < from) end = from;
      const more = end < to ? `\n… (lines ${from}-${end} of ${lines.length} shown; read_file with start_line ${end + 1} for the rest)` : '';
      const whole = from === 1 && end >= lines.length ? ` (all ${lines.length} lines)` : ` (lines ${from}-${end} of ${lines.length})`;
      return { summary: `Read ${p}${whole}`, output: `${p}${whole}:\n${numbered(lines.slice(from - 1, end), from)}${more}` };
    }
    if (t === 'read_files') {
      const paths = (call.paths || []).map(cleanPath).filter(Boolean).slice(0, 8);
      const room = Math.floor(readRoom(subagent) / Math.max(1, paths.length));
      const parts = [];
      for (const each of paths) {
        try {
          const text = await readText(each);
          parts.push(`== ${each} ==\n${clip(text, room)}`);
        } catch (e) {
          parts.push(`== ${each} ==\n${(await missing(each)).replace(/^Error: /, '')}`);
        }
      }
      return { summary: `Read ${paths.length} file${paths.length === 1 ? '' : 's'}`, output: parts.join('\n\n') || 'Error: give paths.' };
    }
    if (t === 'find_files') {
      const pattern = String(call.pattern || '*');
      const re = globToRegExp(pattern.includes('/') ? pattern.replace(/^\.?\//, '') : '**/' + pattern);
      const files = (await projectFiles()).filter((f) => re.test(f));
      return { summary: `Found ${files.length} file${files.length === 1 ? '' : 's'} for ${pattern}`, output: clip(files.slice(0, 300).join('\n') || 'No files match.') };
    }
    if (t === 'read_console') {
      const text = await api.native({ cmd: 'programConsole', lines: Math.min(500, Number(call.lines) || 200) });
      return { summary: 'Read the program console', output: clip(text || '(the console is empty)') };
    }
    if (t === 'read_terminal') {
      const text = terminalText(Math.min(1000, Number(call.lines) || 200));
      return { summary: 'Read the Terminal', output: text == null ? 'No terminal is open.' : clip(text || '(empty)') };
    }
    if (t === 'read_output') {
      const names = outputChannels();
      if (!call.channel) return { summary: 'Listed Output channels', output: names.join('\n') || 'No Output channels.' };
      const text = channelText(String(call.channel));
      return { summary: `Read Output: ${call.channel}`, output: text == null ? `No channel called ${call.channel}. Channels: ${names.join(', ')}` : clip(text.slice(-12000)) };
    }
    if (t === 'list_files') {
      const files = (await projectFiles()).filter((f) => !p || f.startsWith(p + '/'));
      if (p && !files.length && await pathKind(p) === 'file') return { summary: `Listed ${p}`, output: `${p} is a file, not a folder.` };
      const shown = files.slice(0, 400).join('\n') + (files.length > 400 ? `\n… (${files.length - 400} more: list a folder, or find_files)` : '');
      return { summary: `Listed ${p || 'the project'} (${files.length} files)`, output: shown || (p ? `${p} has no files (or doesn't exist).` : '(no files)') };
    }
    if (t === 'search') {
      const raw = String(call.query || '');
      if (!raw) return { summary: 'Search', output: 'Error: query is empty.' };
      let test;
      if (call.regex) {
        let re;
        try { re = new RegExp(raw, 'i'); } catch (e) { return { summary: 'Search (failed)', output: `Error: ${raw} isn't a regular expression: ${e.message}` }; }
        test = (line) => re.test(line);
      } else {
        const query = raw.toLowerCase();
        test = (line) => line.toLowerCase().includes(query);
      }
      const found = [];
      for (const file of (await projectFiles()).filter((f) => !p || f === p || f.startsWith(p + '/')).slice(0, 600)) {
        let text;
        try { text = await readText(file); } catch (e) { continue; }
        if (typeof text !== 'string' || text.length > 500000) continue;
        text.split('\n').forEach((line, i) => { if (found.length < 101 && test(line)) found.push(`${file}:${i + 1}: ${line.trim().slice(0, 200)}`); });
        if (found.length > 100) break;
      }
      const more = found.length > 100 ? '\n… (more matches: search a folder with path, or more exactly)' : '';
      return { summary: `Searched for "${raw}" (${Math.min(100, found.length)}${more ? '+' : ''} found)`, output: (found.slice(0, 100).join('\n') || 'No matches.') + more };
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

    // Changing files.
    if (t === 'edit_file') {
      let file;
      try { file = await loadFile(p); } catch (e) {
        // An empty old on a new file: creating it.
        if (!call.old && await pathKind(p) == null) return runTool({ tool: 'write_file', path: p, content: call.new }, { subagent });
        return { summary: `Edit ${p} (failed)`, output: await missing(p) };
      }
      const found = locate(file.text, String(call.old ?? '').replace(/\r\n/g, '\n'), String(call.new ?? '').replace(/\r\n/g, '\n'), !!call.replace_all, p);
      if (found.error) return { summary: `Edit ${p} (failed)`, output: `Error: ${found.error}` };
      let after = file.text;
      for (const e of [...found.edits].sort((a, b) => b.from - a.from)) after = after.slice(0, e.from) + e.insert + after.slice(e.to);
      const first = found.edits[0];
      const firstLine = lineAt(file.text, first.from);
      const lastLine = firstLine + Math.max(0, first.insert.split('\n').length - 1);
      const count = found.edits.length > 1 ? ` (${found.edits.length} places)` : '';
      return fileChange(p, file.text, after, file.crlf, `Edit ${p}?`, `Edited ${p}${count}. ${changedLines(p, after, firstLine, lastLine)}`, `Edited ${p}${count}`);
    }
    if (t === 'replace_lines' || t === 'delete_lines' || t === 'insert_lines') {
      let file;
      try { file = await loadFile(p); } catch (e) {
        if (t === 'insert_lines' && await pathKind(p) == null) return runTool({ tool: 'write_file', path: p, content: call.content }, { subagent });
        return { summary: `Edit ${p} (failed)`, output: await missing(p) };
      }
      const lines = linesOf(file.text);
      const finalNewline = file.text.endsWith('\n') || !file.text;
      const insert = t === 'delete_lines' ? [] : linesOf(String(call.content ?? '').replace(/\r\n/g, '\n'));
      let start;
      let removed;
      if (t === 'insert_lines') {
        start = Number(call.line);
        if (start < 1 || start > lines.length + 1) return { summary: `Edit ${p} (failed)`, output: `Error: line ${start} is outside ${p}, which has ${lines.length} lines: use 1 to ${lines.length + 1}.` };
        if (!insert.length) return { summary: `Edit ${p} (failed)`, output: 'Error: content is empty.' };
        removed = 0;
      } else {
        start = Number(call.start_line);
        const end = Number(call.end_line);
        if (start < 1 || end < start || start > lines.length) {
          return { summary: `Edit ${p} (failed)`, output: `Error: lines ${start}-${end} aren't in ${p}, which has ${lines.length} lines.` };
        }
        removed = Math.min(end, lines.length) - start + 1;
      }
      const changed = [...lines.slice(0, start - 1), ...insert, ...lines.slice(start - 1 + removed)];
      const after = joinLines(changed, finalNewline);
      const what = t === 'insert_lines' ? `Inserted ${insert.length} line${insert.length === 1 ? '' : 's'} at line ${start} of ${p}`
        : t === 'delete_lines' ? `Deleted lines ${start}-${start + removed - 1} of ${p}`
          : `Replaced lines ${start}-${start + removed - 1} of ${p}`;
      return fileChange(p, file.text, after, file.crlf, `Edit ${p}?`, `${what}. ${changedLines(p, after, start, start + insert.length - 1)}`, what);
    }
    if (t === 'write_file' || t === 'append_file') {
      if (!p) return { summary: t, output: 'Error: give a path.' };
      if (await pathKind(p) === 'folder') return { summary: `Write ${p} (failed)`, output: `Error: ${p} is a folder.` };
      let before = '';
      let crlf = false;
      let exists = true;
      try { ({ text: before, crlf } = await loadFile(p)); } catch (e) { exists = false; }
      let content = String(call.content ?? '').replace(/\r\n/g, '\n');
      if (content && !content.endsWith('\n')) content += '\n';
      let after = content;
      if (t === 'append_file') after = before + (before && !before.endsWith('\n') ? '\n' : '') + content;
      const lines = linesOf(after).length;
      const verb = t === 'append_file' && exists ? 'Added to' : exists ? 'Rewrote' : 'Created';
      const output = t === 'append_file' && exists
        ? `Added ${linesOf(content).length} lines to ${p}. ${changedLines(p, after, linesOf(before).length + 1, lines)}`
        : `${verb} ${p} (${lines} lines).`;
      return fileChange(p, before, after, crlf, `${verb.replace('Rewrote', 'Rewrite').replace('Created', 'Create').replace('Added to', 'Add to')} ${p}?`, output, `${verb} ${p}`);
    }
    if (t === 'create_folder') {
      if (!p) return { summary: t, output: 'Error: give a path.' };
      const kind = await pathKind(p);
      if (kind) return { summary: `Create folder ${p}`, output: kind === 'folder' ? `${p} already exists.` : `Error: ${p} is a file.` };
      return { summary: `Created folder ${p}`, output: `Created the folder ${p}.`, ask: `Create the folder ${p}?`, apply: () => api.native({ cmd: 'fs', op: 'mkdir', path: p }) };
    }
    if (t === 'move_file' || t === 'copy_file') {
      const from = cleanPath(call.from);
      const to = cleanPath(call.to);
      const verb = t === 'move_file' ? 'Move' : 'Copy';
      if (!from || !to || from === to) return { summary: `${verb} (failed)`, output: 'Error: give from and to, two different paths.' };
      await api.save?.();
      const kind = await pathKind(from);
      if (!kind) return { summary: `${verb} ${from} (failed)`, output: await missing(from) };
      if (await pathKind(to)) return { summary: `${verb} ${from} (failed)`, output: `Error: ${to} already exists. Delete it first, or pick another path.` };
      if (t === 'copy_file') {
        if (kind === 'folder') return { summary: 'Copy (failed)', output: 'Error: copy_file copies files, not folders.' };
        return {
          summary: `Copied ${from} to ${to}`, output: `Copied ${from} to ${to}.`, path: to, ask: `Copy ${from} to ${to}?`,
          apply: async () => api.native({ cmd: 'fs', op: 'write', path: to, base64: await api.native({ cmd: 'fs', op: 'read', path: from }) }),
        };
      }
      return {
        summary: `Moved ${from} to ${to}`, output: `Moved ${from} to ${to}.`, ask: `Move ${from} to ${to}?`, path: to,
        apply: async () => {
          await api.save?.();
          await api.native({ cmd: 'fs', op: 'rename', path: from, to });
          api.pathMoved?.(from, to);
        },
      };
    }
    if (t === 'delete_file') {
      if (!p) return { summary: 'Delete (failed)', output: 'Error: give a path (deleting the whole project isn\'t allowed).' };
      const kind = await pathKind(p);
      if (!kind) return { summary: `Delete ${p} (failed)`, output: await missing(p) };
      const inside = kind === 'folder' ? (await projectFiles()).filter((f) => f.startsWith(p + '/')).length : 0;
      const what = kind === 'folder' ? `the folder ${p} (${inside} file${inside === 1 ? '' : 's'})` : p;
      return {
        summary: `Deleted ${p}`, output: `Deleted ${what}.`, ask: `Delete ${what}?`,
        apply: async () => {
          await api.native({ cmd: 'fs', op: 'delete', path: p });
          api.pathMoved?.(p, null);
        },
      };
    }
    if (t === 'run_command') {
      const command = String(call.command || '');
      return {
        summary: `Ran ${command.slice(0, 60)}`, ask: `Run \`${command}\`?`,
        apply: async () => {
          await api.save?.();
          let out = '';
          const code = await api.runCommand(command, (text) => { out += text; });
          return `Exit code ${code}.\n${clip(out)}`;
        },
      };
    }
    if (t === 'run_program') {
      const seconds = Math.min(60, Math.max(1, Number(call.seconds) || 8));
      return {
        summary: 'Ran the program', ask: 'Run the program?',
        apply: async () => {
          await api.save?.();
          const r = await api.native({ cmd: 'runProgram', seconds, keepRunning: !!call.keep_running });
          const ending = r.exitCode != null ? `It ended with exit code ${r.exitCode}.`
            : r.stillRunning ? (call.keep_running ? `It's still running after ${seconds} s.` : `It was still running after ${seconds} s, so it was stopped.`)
              : 'It stopped.';
          return `${ending}\nConsole output:\n${r.output || '(nothing)'}`;
        },
      };
    }
    // Long-term memory.
    if (t === 'remember') {
      const saved = await api.native({ cmd: 'memory', op: 'save', kind: 'note', title: call.title, text: String(call.content || '') });
      return { summary: `${saved.replaced ? 'Updated' : 'Remembered'} "${call.title}"`, output: `${saved.replaced ? 'Updated the note' : 'Saved a note'} ${saved.id}: ${call.title}.` };
    }
    if (t === 'recall') {
      const found = await api.native({ cmd: 'memory', op: 'search', query: call.query, limit: 8 });
      const list = Array.isArray(found) ? found : [];
      const output = list.map((m) => `${m.id} · ${m.kind === 'note' ? 'note' : 'set aside'} · ${m.title} (${m.length} characters)`
        + (m.passage ? `\n  ${m.passage.replace(/\s+/g, ' ').slice(0, 320)}` : '')).join('\n');
      return { summary: `Recalled "${call.query}" (${list.length} found)`, output: output ? `${output}\n(load_memory with an id brings one into your context.)` : 'Nothing in memory matches.' };
    }
    if (t === 'load_memory') {
      const entry = await api.native({ cmd: 'memory', op: 'read', id: call.id });
      const text = String(entry.text || '');
      const room = readRoom(subagent);
      const parts = Math.max(1, Math.ceil(text.length / room));
      const part = Math.min(parts, Math.max(1, Number(call.part) || 1));
      const more = part < parts ? `\n… (part ${part} of ${parts}; load_memory ${entry.id} part ${part + 1} for the next)` : '';
      return { summary: `Loaded ${entry.title}${parts > 1 ? ` (part ${part} of ${parts})` : ''}`,
        output: `${entry.id}: ${entry.title}${parts > 1 ? ` (part ${part} of ${parts})` : ''}\n${text.slice((part - 1) * room, part * room)}${more}` };
    }
    if (t === 'forget') {
      await api.native({ cmd: 'memory', op: 'delete', id: call.id });
      memoryNotes = memoryNotes.filter((n) => n.id !== call.id);
      return { summary: `Forgot ${call.id}`, output: `Deleted ${call.id} from memory.` };
    }
    if (t === 'delegate') {
      const tasks = (call.tasks || []).filter(Boolean).map(String).slice(0, 8);
      if (!tasks.length) return { summary: 'Delegate', output: 'Error: no tasks.' };
      if (!subagentsOn()) return { summary: 'Delegate', output: 'Error: subagents are turned off; do the research yourself.' };
      const answers = await runSubagents(tasks);
      return { summary: `${tasks.length} subagent${tasks.length === 1 ? '' : 's'}`, output: answers.map((a, i) => `Task ${i + 1}: ${tasks[i]}\nAnswer: ${a}`).join('\n\n') };
    }
    return { summary: t, output: `Error: there's no tool called ${t}.` };
  } catch (e) {
    return { summary: `${t} (failed)`, output: `Error: ${e && e.message ? e.message : e}` };
  }
}

function globToRegExp(glob) {
  let re = '';
  for (let i = 0; i < glob.length; i++) {
    const c = glob[i];
    if (c === '*' && glob[i + 1] === '*') { re += '.*'; i++; if (glob[i + 1] === '/') i++; }
    else if (c === '*') re += '[^/]*';
    else if (c === '?') re += '[^/]';
    else re += c.replace(/[.+^${}()|[\]\\]/g, '\\$&');
  }
  return new RegExp('^' + re + '$', 'i');
}

// MARK: - Subagents

/** Runs research tasks on the subagent model, up to the parallel setting at a time. */
async function runSubagents(tasks) {
  const model = subagentModel();
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
    { role: 'system', content: 'You are a research subagent of a coding agent. Answer the task by reading and searching the project; you can\'t change anything. '
      + 'Answer briefly with what you found, naming files and lines.\n\n' + toolHelp(true) },
    { role: 'user', content: task },
  ];
  // A small model (Apple Intelligence's 4K) gets results that fit it.
  const room = model === 'apple' ? 2000 : Math.max(1500, Math.min(6000, Math.floor(effectiveContext(model, settings.subagentContextSize) * 3.5 * 0.25)));
  let troubles = 0;
  for (let step = 0; step < 8 && !stopped; step++) {
    const maxTokens = reasoning(model) === 'always' ? 2048 : 768;
    const reply = await ask(chat, { model, maxTokens, contextSize: settings.subagentContextSize, stop: STOP_AT });
    if (reply.error) return `(failed: ${reply.error})`;
    const answer = cutInventedResults(withoutThinking(reply.text));
    const parsed = readToolCalls(answer, TOOL);
    chat.push({ role: 'assistant', content: answer });
    if (!parsed.calls.length && !parsed.errors.length) return withoutToolCalls(answer, TOOL) || '(no answer)';
    const results = parsed.calls.slice(0, 4).map(async (call) => `${call.tool}: ${(await runTool(call, { subagent: true })).output}`);
    const lines = await Promise.all(results);
    if (parsed.errors.length) {
      lines.push(callTrouble(parsed, maxTokens).replace(EDIT_EXAMPLE, READ_EXAMPLE));
      if (!parsed.calls.length && ++troubles >= 3) return withoutToolCalls(answer, TOOL) || '(its tool calls couldn\'t be read)';
    }
    chat.push({ role: 'user', content: 'Tool results:\n' + clip(lines.join('\n\n'), room) });
  }
  return '(ran out of steps)';
}

// MARK: - The agent

let requestStart = 0;   // where the question being worked on starts in messages

/** The conversation for the model. The question being worked on and summaries are marked keep, so
 * they're never dropped to make room; old tool results are cut short (the latest are in full); and
 * this question's reasoning goes back in between its tool steps, so the agent keeps its plan
 * (earlier questions' reasoning is left out, as reasoning models expect). Messages moved to the
 * context cache (pageOut) are left out, with a note in their place saying what they were. */
function forModel() {
  const toolTurns = messages.map((m, i) => (m.kind === 'tool' && !m.paged ? i : -1)).filter((i) => i >= 0);
  const fullFrom = toolTurns.length > KEPT_TOOL_RESULTS ? toolTurns[toolTurns.length - KEPT_TOOL_RESULTS] : 0;
  return [{ role: 'system', content: systemPrompt() }, ...messages.flatMap((m, i) => {
    if (m.paged) return m.stub ? [{ role: 'user', content: m.stub, keep: true }] : [];
    let content = m.content;
    if (m.kind === 'tool' && i < fullFrom && content.length > 1200) {
      // The whole result was set aside in long-term memory when it came, to be loaded back.
      content = content.slice(0, 1200) + `\n… (cut short to save room: ${content.length - 1200} more characters`
        + (m.archived ? `; load_memory ${m.archived} has all of it)` : ')');
    }
    if (m.role === 'assistant' && m.thinking && i >= requestStart) content = `<think>\n${m.thinking.slice(-2000)}\n</think>\n\n${content}`;
    return [{ role: m.role, content, keep: !!m.keep }];
  })];
}

const usedTokens = () => forModel().reduce((n, m) => n + tokens(m.content), 0);

const RECENT_KEPT = 4;   // the latest messages (about two steps) never move out of the context

/** Makes room by moving the oldest messages into long-term memory, word for word, until the
 * conversation takes about half the context. They stay in the chat; the model gets, in their place,
 * a list of what they were and the memory to load them back from (a step's delay, not a loss).
 * `overflowed`: the app had to leave turns out, so the estimate was low: at least a third moves.
 * False when nothing is old enough to move (the current question and latest steps stay), and then
 * the conversation is summarised instead. */
async function pageOut(overflowed) {
  const used = usedTokens();
  const want = Math.max(used + answerTokens() - contextLimit() * 0.5, overflowed ? used * 0.33 : 0);
  if (want <= 0) return false;
  const moving = [];
  let freed = 0;
  const last = messages.length - RECENT_KEPT;
  for (let i = 0; i < last && freed < want; i++) {
    const m = messages[i];
    if (m.paged || m.kind === 'summary' || i === requestStart) continue;
    // An answer goes with its tool results, or not at all.
    const results = m.role === 'assistant' && messages[i + 1] && messages[i + 1].kind === 'tool' ? i + 1 : -1;
    if (results >= last) break;
    for (const j of results > 0 ? [i, results] : [i]) {
      moving.push(j);
      // Older tool results are already cut short in the prompt (forModel).
      freed += tokens(messages[j].kind === 'tool' ? messages[j].content.slice(0, 1300) : messages[j].content);
    }
    if (results > 0) i = results;
  }
  if (freed < 200) return false;
  const who = (m) => (m.role === 'assistant' ? 'Agent' : m.kind === 'tool' ? 'Tool results' : 'User');
  const id = await setAside(`Earlier messages: ${conversationTitle().replace(/^Conversation of /, '')}`,
    moving.map((i) => `${who(messages[i])}: ${messages[i].content}`).join('\n\n'));
  if (!id) return false;
  // What they were, in a line each: enough to know what to load.
  const gist = moving.map((i) => {
    const m = messages[i];
    if (m.kind === 'tool') return null;
    if (m.role === 'user') return `- User: ${String(m.shown ?? m.content).replace(/\s+/g, ' ').slice(0, 160)}`;
    const said = withoutToolCalls(m.content, TOOL).replace(/\s+/g, ' ').slice(0, 120);
    return `- You: ${said}${m.calls && m.calls.length ? `${said ? ' ' : ''}[${m.calls.join(', ')}]` : ''}`;
  }).filter(Boolean);
  const list = gist.length > 24 ? [...gist.slice(0, 4), `- … (${gist.length - 20} more)`, ...gist.slice(-20)] : gist;
  messages[moving[0]].stub = `(To make room, ${moving.length} earlier messages of this chat were moved to long-term memory as ${id}: `
    + `load_memory ${id} brings them back word for word, and recall searches them. They were:\n${list.join('\n')})`;
  for (const i of moving) messages[i].paged = id;
  noteCard(`${moving.length} older messages moved to the context cache to make room; the agent can load them back.`);
  return true;
}

/** Sets text aside in long-term memory (the context cache): its id, or null if it couldn't be. */
async function setAside(title, text) {
  const saved = await api.native({ cmd: 'memory', op: 'save', kind: 'archive', title: title.slice(0, 120), text }).catch(() => null);
  return saved && saved.id ? saved.id : null;
}

/** "Conversation of 4 Nov, 14:02: Fix the typo…", for a conversation set aside. */
function conversationTitle() {
  const first = messages.find((m) => m.role === 'user' && !m.kind);
  const when = new Date().toLocaleString(undefined, { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' });
  return `Conversation of ${when}: ${String(first ? first.shown || first.content : '').replace(/\s+/g, ' ').slice(0, 80)}`;
}

/** Summarises the conversation into one message, to free the context. */
async function compact(reason) {
  if (messages.length < 2) return;
  // While the agent works, its question stays word for word after the summary.
  const question = reason === 'auto' && messages[requestStart] && messages[requestStart].role === 'user' && !messages[requestStart].kind ? messages[requestStart] : null;
  const note = element('div', 'chat-note', 'Compacting the conversation…');
  $('chat-log').append(note);
  const reply = await ask([
    { role: 'system', content: 'You summarise conversations between a user and a coding agent, for the agent to carry on from.' },
    { role: 'user', content: messages.map((m) => `${m.role === 'user' ? (m.kind === 'tool' ? 'Tool results' : 'User') : 'Agent'}: ${m.content.slice(0, 3000)}`).join('\n\n')
      + '\n\nSummarise this for the agent: what the user wants, decisions made, files read and changed (with what changed), what has been tried '
      + 'and what it showed, and what is left to do. Be concise.' },
  ], { maxTokens: 700 });
  note.remove();
  if (reply.error || !withoutThinking(reply.text)) { notice('Couldn\'t compact: ' + (reply.error || 'no summary')); return; }
  const summary = withoutThinking(reply.text);
  // The whole conversation, word for word, is set aside in long-term memory, for the agent to bring
  // details back from rather than lose them.
  const archived = canAgent() ? await setAside(conversationTitle(),
    messages.map((m) => `${m.role === 'user' ? (m.kind === 'tool' ? 'Tool results' : m.kind === 'summary' ? 'Earlier' : 'User') : 'Agent'}: ${m.content}`).join('\n\n')) : null;
  const where = archived ? `\n\n(The whole conversation is in long-term memory as ${archived}: recall or load_memory brings back details.)` : '';
  messages = [{ role: 'user', kind: 'summary', content: 'Summary of the conversation so far:\n' + summary + where, shown: summary, reason, keep: true }];
  if (question) messages.push({ ...question, content: 'Carry on with this (the summary above says what has been done):\n' + question.content });
  requestStart = question ? 1 : messages.length;
  render();
}

async function send() {
  build();
  const input = $('chat-text');
  const text = input.value.trim();
  if (!text || busy) return;
  input.value = '';
  if (text === '/compact') { busy = true; updateControls(); await compact('asked'); busy = false; updateControls(); saveChat(); return; }
  if (text === '/clear' || text === '/new') { newChat(); return; }
  const context = fileContext();
  projectList = canAgent() ? await projectFiles() : [];
  const notes = canAgent() ? await api.native({ cmd: 'memory', op: 'list', limit: 200 }).catch(() => []) : [];
  memoryNotes = (Array.isArray(notes) ? notes : []).filter((n) => n.kind === 'note');
  // Only the new question is kept whatever happens; earlier ones may make way.
  for (const m of messages) if (m.kind !== 'summary') m.keep = false;
  requestStart = messages.length;
  messages.push({ role: 'user', content: context ? `${context}\n${text}` : text, shown: text, keep: true });
  render();
  busy = true;
  stopped = false;
  chatId = chatId || 'c' + Date.now().toString(36) + Math.random().toString(36).slice(2, 6);
  changeSet = canAgent() ? { files: new Map(), commands: false } : null;
  updateControls();
  const seen = new Map();   // this question's tool calls, to catch the agent going in circles
  let repeats = 0;
  let troubles = 0;
  let overflowed = false;
  try {
    for (let step = 0; step < MAX_STEPS && !stopped; step++) {
      // Before the context runs out (with room for the answer), the conversation so far is summarised.
      // Before the context runs out (with room for the answer), the oldest messages move to the
      // context cache; when nothing is old enough to move, the conversation is summarised.
      if ((overflowed || usedTokens() + answerTokens() > contextLimit() * 0.9) && messages.length > 2) {
        if (!(canAgent() && await pageOut(overflowed))) await compact('auto');
      }
      liveText = '';
      render();
      const chat = forModel();
      const maxTokens = answerTokens();
      const reply = await ask(chat, { maxTokens, thinking: thinkingOn(), stop: canAgent() ? STOP_AT : undefined, onText: (t) => { liveText = t; scheduleLive(); } });
      liveText = null;
      if (reply.error) { messages.push({ role: 'assistant', content: '', shown: reply.error, kind: 'error' }); break; }
      if (reply.promptTokens) {
        const estimate = chat.reduce((n, m) => n + rawTokens(m.content), 0);
        if (estimate > 200) tokenRatio = Math.min(3, Math.max(0.5, reply.promptTokens / estimate));
      }
      overflowed = reply.dropped > 0;
      // The reasoning shows folded; it goes back to the model only while this question is worked on,
      // and tool calls in it don't run. What the model wrote as a tool's results is its invention: cut.
      const thinking = thinkingOf(reply.text);
      const answer = canAgent() ? cutInventedResults(withoutThinking(reply.text)) : withoutThinking(reply.text);
      if (!answer && !thinking && !stopped) {
        messages.push({ role: 'assistant', content: '', kind: 'error', shown: `${modelInfo(settings.selected).name || 'The model'} gave an empty answer. Try again, or a smaller context or another model.` });
        break;
      }
      const parsed = canAgent() ? readToolCalls(answer, TOOL) : NO_CALLS;
      const { calls } = parsed;
      const shown = answer === withoutThinking(reply.text) ? reply.text : (thinking ? `<think>\n${thinking}\n</think>\n\n` : '') + answer;
      messages.push({ role: 'assistant', content: answer, shown, thinking, calls: calls.map((c) => c.tool + (c.path ? ' ' + c.path : c.from ? ` ${c.from} → ${c.to}`
        : c.title ? ` "${c.title}"` : c.query ? ` "${c.query}"` : c.id ? ' ' + c.id : '')) });
      render();
      if (stopped || (!calls.length && !parsed.errors.length)) break;
      const results = [];
      // Calls that couldn't be read go back to the model, to make again, rather than ending the turn.
      if (parsed.errors.length) {
        troubles = calls.length ? 0 : troubles + 1;
        if (troubles >= MAX_TROUBLES) {
          messages.push({ role: 'assistant', content: '', kind: 'error', shown: `${modelInfo(settings.selected).name || 'The model'} kept writing tool calls that couldn't be read, so it was stopped. Try again, or a bigger model.` });
          break;
        }
        notice(parsed.cutOff ? 'The answer was cut off in a tool call: the agent is asked to make it in smaller parts.' : 'A tool call couldn\'t be read: the agent is asked to make it again.');
      } else {
        troubles = 0;
      }
      for (const call of calls) {
        if (stopped) break;
        const key = JSON.stringify(call);
        if (seen.has(key)) {
          repeats++;
          results.push(`${call.tool}: You already made this exact call (step ${seen.get(key)}); its result is above. Don't repeat it: `
            + 'use what it returned, try something different, or give your answer.');
          continue;
        }
        seen.set(key, step + 1);
        results.push(await perform(call));
        // A change makes earlier reads worth repeating.
        if (CHANGES_FILES.has(call.tool)) seen.clear();
      }
      if (parsed.errors.length) results.push(callTrouble(parsed, maxTokens));
      const content = 'Tool results:\n' + results.join('\n\n');
      // A long result is cut short once newer ones come: it's set aside whole, to be loaded back.
      const archived = content.length > 1200 && !calls.every((c) => c.tool === 'load_memory' || c.tool === 'recall')
        ? await setAside(`Results of ${calls.map((c) => c.tool + (c.path ? ' ' + c.path : c.query ? ` "${c.query}"` : '')).join(', ')}`, content) : null;
      messages.push({ role: 'user', kind: 'tool', content, archived, shown: results.length + ' tool result' + (results.length === 1 ? '' : 's') });
      render();
      if (repeats >= MAX_REPEATS) {
        messages.push({ role: 'assistant', content: '', kind: 'error', shown: 'The agent kept repeating the same steps, so it was stopped. Try asking more specifically, or with a bigger model.' });
        break;
      }
    }
  } finally {
    busy = false;
    liveText = null;
    updateControls();
    render();
    await showChanges();
    saveChat();
  }
}

// MARK: - The agent's changes

// What each file the agent changed while answering a question was before (null: it didn't
// exist), so its changes can be reviewed and undone when it's done. Commands' changes aren't known.
let changeSet = null;   // { files: Map path → before, commands: bool }

/** The files a call changes, before it does: their contents now. */
async function recordBefore(call) {
  if (!changeSet) return;
  if (call.tool === 'run_command') { changeSet.commands = true; return; }
  const kind = TOOL[call.tool] && TOOL[call.tool].kind;
  if (kind !== 'edit' && kind !== 'delete') return;
  const paths = [];
  const withFolder = async (p) => {
    const inside = (await projectFiles()).filter((f) => f.startsWith(p + '/'));
    return inside.length ? inside : [p];
  };
  if (call.tool === 'move_file') {
    const from = cleanPath(call.from);
    const to = cleanPath(call.to);
    for (const f of await withFolder(from)) paths.push(f, to + f.slice(from.length));
  } else if (call.tool === 'copy_file') paths.push(cleanPath(call.to));
  else if (call.tool === 'delete_file') paths.push(...await withFolder(cleanPath(call.path)));
  else if (call.tool !== 'create_folder') paths.push(cleanPath(call.path));
  for (const p of paths) {
    if (!p || changeSet.files.has(p)) continue;
    let before = null;
    try { before = await readText(p); } catch (e) { /* new */ }
    changeSet.files.set(p, typeof before === 'string' ? before : null);
  }
}

/** When the agent is done: a card of what it changed, if anything. */
async function showChanges() {
  if (!changeSet) return;
  const files = [];
  for (const [path, before] of changeSet.files) {
    let after = null;
    try { after = await readText(path); } catch (e) { /* gone */ }
    if (typeof after !== 'string') after = null;
    if (after !== before) files.push({ path, before, after, state: 'changed' });
  }
  const commands = changeSet.commands;
  changeSet = null;
  if (files.length) addCard({ type: 'changes', files, commands });
}

/** "+3 −1", "new" or "deleted", for a changed file. */
function changeSize(f) {
  if (f.before === null) return `new, ${linesOf(f.after).length} lines`;
  if (f.after === null) return 'deleted';
  const a = linesOf(f.before);
  const b = linesOf(f.after);
  let start = 0;
  while (start < a.length && start < b.length && a[start] === b[start]) start++;
  let endA = a.length, endB = b.length;
  while (endA > start && endB > start && a[endA - 1] === b[endB - 1]) { endA--; endB--; }
  return `+${endB - start} −${endA - start}`;
}

function changesCard(card) {
  const r = card.record;
  const el = element('div', 'chat-tool chat-changes');
  const left = r.files.filter((f) => f.state !== 'undone');
  el.append(element('div', 'chat-tool-title', left.length
    ? `The agent changed ${r.files.length} file${r.files.length === 1 ? '' : 's'}`
    : 'The agent\'s changes were undone'));
  for (const f of r.files) {
    const row = element('div', 'chat-change' + (f.state === 'undone' ? ' undone' : ''));
    row.append(element('span', 'chat-change-path', f.path), element('span', 'chat-change-size', f.state === 'undone' ? 'undone' : changeSize(f)));
    if (f.state !== 'undone') {
      if (f.after !== null) {
        const diff = element('button', 'chat-small', 'Diff');
        diff.title = 'Compare with the file before the agent changed it';
        diff.addEventListener('click', () => (api.openDiff ? api.openDiff({ path: f.path, original: f.before ?? '', title: `${f.path.split('/').pop()} (agent's changes)` }) : api.openFile(f.path)));
        row.append(diff);
      }
      const undo = element('button', 'chat-small', f.state === 'confirm' ? 'Undo Anyway' : 'Undo');
      undo.addEventListener('click', () => undoChange(card, [f]));
      row.append(undo);
      if (f.state === 'confirm') row.append(element('div', 'chat-change-note', 'It has changed since the agent changed it: undoing loses that too.'));
    }
    el.append(row);
  }
  if (left.length > 1) {
    const all = element('button', 'chat-small', 'Undo All');
    all.addEventListener('click', () => undoChange(card, left));
    el.append(all);
  }
  if (r.commands) el.append(element('div', 'chat-change-note', 'Changes made by commands it ran aren\'t listed and can\'t be undone here.'));
  return el;
}

/** Puts files back as they were before the agent changed them. One that has changed since asks first
 * (its row says so, and Undo Anyway goes ahead). */
async function undoChange(card, files) {
  let asked = false;
  for (const f of files) {
    let now = null;
    try { now = await readText(f.path); } catch (e) { /* gone */ }
    if (typeof now !== 'string') now = null;
    if (now !== f.after && f.state !== 'confirm' && now !== f.before) {
      f.state = 'confirm';
      asked = true;
      continue;
    }
    try {
      if (f.before === null) {
        if (now !== null) {
          await api.native({ cmd: 'fs', op: 'delete', path: f.path });
          api.pathMoved?.(f.path, null);
        }
      } else if (now !== f.before) {
        await writeText(f.path, f.before);
      }
      f.state = 'undone';
    } catch (e) {
      f.state = 'changed';
      notice(`Couldn't undo ${f.path}: ${e && e.message ? e.message : e}`);
    }
  }
  redrawCard(card);
  saveChat();
  if (asked) scrollToEnd();
}

// MARK: - Saved chats

// Each chat is saved, per project, after every answer (ChatHistory.swift, apart from the context
// cache), and the history button reopens one.
let chatId = null;

function saveChat() {
  if (!chatId || !messages.length) return;
  const first = messages.find((m) => m.role === 'user' && !m.kind);
  const title = String(first ? first.shown ?? first.content : 'Chat').replace(/\s+/g, ' ').trim().slice(0, 80) || 'Chat';
  const chat = { version: 1, title, model: settings.selected, messages, cards: cards.map((c) => ({ at: c.at, ...c.record })) };
  api.native({ cmd: 'chats', op: 'save', id: chatId, chat }).catch(() => {});
}

async function openChatFromHistory(id) {
  if (busy) return;
  const chat = await api.native({ cmd: 'chats', op: 'load', id }).catch(() => null);
  if (!chat || !Array.isArray(chat.messages)) { notice('That chat couldn\'t be opened.'); return; }
  messages = chat.messages;
  cards = [];
  for (const record of Array.isArray(chat.cards) ? chat.cards : []) {
    const { at, ...rest } = record;
    const card = { at, record: rest, el: null };
    card.el = drawCard(card);
    cards.push(card);
  }
  chatId = id;
  requestStart = messages.length;
  allowedThisChat.clear();
  $('chat-history').hidden = true;
  render();
}

/** The history panel: this project's chats, newest first. */
async function showHistory() {
  const panel = $('chat-history');
  if (!panel.hidden) { panel.hidden = true; return; }
  $('chat-settings').hidden = true;
  panel.hidden = false;
  panel.replaceChildren(element('div', 'chat-setting-note', 'Loading…'));
  const list = await api.native({ cmd: 'chats', op: 'list' }).catch(() => []);
  panel.replaceChildren();
  const chats = Array.isArray(list) ? list : [];
  if (!chats.length) { panel.append(element('div', 'chat-setting-note', 'No saved chats in this project yet.')); return; }
  for (const c of chats) {
    const row = element('div', 'chat-history-row' + (c.id === chatId ? ' current' : ''));
    const open = element('button', 'chat-history-open');
    open.append(element('span', 'chat-history-title', c.title), element('span', 'chat-history-date', when(c.updated)));
    open.addEventListener('click', () => openChatFromHistory(c.id));
    const del = element('button', 'chat-icon codicon', '');
    del.title = 'Delete Chat';
    del.setAttribute('aria-label', `Delete chat: ${c.title}`);
    del.addEventListener('click', async () => {
      await api.native({ cmd: 'chats', op: 'delete', id: c.id }).catch(() => {});
      if (c.id === chatId) chatId = null;
      row.remove();
    });
    row.append(open, del);
    panel.append(row);
  }
}

/** "Today 14:02", "Yesterday", "3 Nov". */
function when(ms) {
  const d = new Date(ms);
  const today = new Date();
  const days = Math.round((new Date(today.toDateString()) - new Date(d.toDateString())) / 86400000);
  if (days === 0) return 'Today ' + d.toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit' });
  if (days === 1) return 'Yesterday';
  return d.toLocaleDateString(undefined, { day: 'numeric', month: 'short' });
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
  await recordBefore(call);
  let output;
  try {
    output = await result.apply();
  } catch (e) {
    const failed = { ...result, summary: `${result.summary} (failed)`, preview: null };
    toolCard(failed, 'denied failed', String(e && e.message ? e.message : e));
    return `${call.tool}: Error: ${e && e.message ? e.message : e}`;
  }
  toolCard(result, 'done', typeof output === 'string' ? output : null);
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
  saveChat();
  messages = [];
  chatId = null;
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
  if (!canAgent() && sel.empty) {
    // A model that can't read files gets the file itself, as much as fits in a third of its context.
    const room = Math.max(2000, Math.floor(contextLimit() / 3 * 3.5));
    const doc = state.doc.toString();
    out += `\n\`\`\`${lang}\n${doc.length > room ? doc.slice(0, room) + '\n… (the rest of the file is left out)' : doc}\n\`\`\``;
  }
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
    if (model.value === '__more__' || model.value === '__get__') {
      api.appCommand(model.value === '__get__' ? 'aiSettings' : 'settings');
      loadSettings();
      return;
    }
    settings.selected = model.value;
    tokenRatio = 1;   // each model counts differently
    api.native({ cmd: 'aiChatSelect', id: model.value }).catch(() => {});
    renderSettings();
    updateControls();
    updateMeter();
    if (!messages.length) render();
  });
  const options = element('button', 'chat-icon codicon', '');
  options.title = 'Chat Settings';
  options.addEventListener('click', () => { $('chat-history').hidden = true; $('chat-settings').hidden = !$('chat-settings').hidden; });
  const fresh = element('button', 'chat-icon codicon', '');
  fresh.title = 'New Chat';
  fresh.addEventListener('click', () => newChat());
  const close = element('button', 'chat-icon codicon', '');
  close.title = 'Close Chat';
  close.addEventListener('click', () => closeChat());
  // The icons are font glyphs: VoiceOver reads these names instead.
  const history = element('button', 'chat-icon codicon', '');
  history.title = 'Chat History';
  history.addEventListener('click', () => showHistory());
  for (const button of [options, history, fresh, close]) button.setAttribute('aria-label', button.title);
  model.setAttribute('aria-label', 'Chat model');
  header.append(model, options, history, fresh, close);

  // How full the model's context is.
  const meter = element('div', 'chat-meter');
  meter.id = 'chat-meter';
  meter.title = 'Context used. /compact summarises the conversation to free it.';
  meter.setAttribute('role', 'status');
  meter.append(element('div', 'chat-meter-bar'), element('span', 'chat-meter-text'));

  // Saved chats (showHistory).
  const historyPanel = element('div', 'chat-settings chat-history');
  historyPanel.id = 'chat-history';
  historyPanel.hidden = true;

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
  text.setAttribute('aria-label', 'Message to the agent');
  text.setAttribute('autocapitalize', 'sentences');
  text.addEventListener('keydown', (e) => {
    e.stopPropagation();
    if (e.key === 'Enter' && !e.shiftKey && !e.isComposing) { e.preventDefault(); send(); }
  });
  const mode = element('select', 'chat-mode');
  mode.id = 'chat-mode';
  mode.title = 'What the agent may do without asking';
  mode.setAttribute('aria-label', 'Mode: what the agent may do without asking');
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
  const think = element('button', 'chat-think', 'Think');
  think.id = 'chat-think';
  think.title = 'Thinking: the agent reasons before it answers (slower, better at harder tasks)';
  think.addEventListener('click', () => saveSetting({ thinking: !settings.thinking }));
  const sendButton = element('button', 'chat-send', 'Send');
  sendButton.id = 'chat-send';
  sendButton.addEventListener('click', () => (busy ? stop() : send()));
  const row = element('div', 'chat-row');
  row.append(mode, think, context, sendButton);
  form.append(text, row);

  pane.append(header, meter, historyPanel, panel, log, form);
  $('editor-container').append(pane);
  render();
}

function saveSetting(change) {
  Object.assign(settings, change);
  api.native({ cmd: 'aiChatSettings', ...change }).catch(() => {});
  if ('contextSize' in change || 'kvBits' in change) loadSettings();
  updateControls();
  updateMeter();
  renderSettings();
}

async function loadSettings() {
  const info = await api.native({ cmd: 'aiChatModels' }).catch(() => null);
  if (!info) return;
  settings = { ...settings, ...info, models: info.models || [] };
  const select = $('chat-model');
  select.replaceChildren();
  // The four tiers, in order. One not downloaded yet opens Settings → AI, where it downloads (or,
  // when it's the one picked there, shows it's downloading); one this device can't run is greyed out.
  for (const m of settings.models.filter((x) => !x.cloud)) {
    const waiting = m.suggested && m.id === settings.selected;
    const option = element('option', null, m.ready ? m.name : waiting ? `${m.name} (downloading…)` : `${m.name} (${m.detail})`);
    option.value = m.suggested && !waiting ? '__get__' : m.id;
    option.title = m.detail;
    option.disabled = !m.ready && !m.suggested || waiting;
    option.selected = m.id === settings.selected;
    select.append(option);
  }
  // Cloud models the user set up with their own key: these send the conversation to the provider.
  const cloud = settings.models.filter((x) => x.cloud);
  if (cloud.length) {
    const group = element('optgroup');
    group.label = 'Cloud (sends your code to the provider)';
    for (const m of cloud) {
      const option = element('option', null, '☁ ' + m.name);
      option.value = m.id;
      option.title = m.detail;
      option.selected = m.id === settings.selected;
      group.append(option);
    }
    select.append(group);
  }
  const more = element('option', null, 'AI Settings…');
  more.value = '__get__';
  select.append(more);
  $('chat-mode').value = settings.mode || 'edit';
  updateControls();
  renderSettings();
  if (!messages.length && liveText == null) render();
  updateMeter();
}

/** The sizes a model can have, with their memory; the ones that won't fit are greyed out. */
function contextSelect(modelId, current, onChange) {
  const s = element('select');
  const contexts = modelInfo(modelId).contexts || [];
  const k = (n) => (n < 1024 ? String(n) : n % 1024 === 0 ? n / 1024 + 'K' : Math.round(n / 1000) + 'K');
  const gb = (b) => (b >= 1e9 ? (b / 1e9).toFixed(1) + ' GB' : Math.round(b / 1e6) + ' MB');
  if (modelId === 'apple' || !contexts.some((c) => c.bytes > 0)) {
    const tokens = k((contexts[0] || {}).tokens || 4096);
    const o = element('option', null, modelInfo(modelId).cloud ? `${tokens}, the cloud model's` : `${tokens}, fixed for Apple Intelligence`);
    s.append(o);
    s.disabled = true;
    return s;
  }
  const effective = effectiveContext(modelId, current);
  for (const c of contexts) {
    const o = element('option', null, `${k(c.tokens)} · ≈${gb(c.bytes)}${c.fits ? '' : settings.memoryAvailable ? ` (won't fit: ${gb(settings.memoryAvailable * 0.9)} usable)` : ' (won\'t fit)'}`);
    o.value = String(c.tokens);
    o.disabled = !c.fits;
    o.selected = c.tokens === effective;
    s.append(o);
  }
  s.addEventListener('change', () => onChange(Number(s.value)));
  return s;
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
  row('Context size', contextSelect(settings.selected, settings.contextSize, (v) => saveSetting({ contextSize: v })),
    'Tokens the model reads at once: the conversation, files and answer. Bigger remembers more but needs more memory and takes longer to read. Each size shows its estimated memory; ones that won\'t fit this device are greyed out.');
  const info = modelInfo(settings.selected);
  if (!info.cloud && settings.selected !== 'apple') {
    row('Cache precision', select([[8, '8-bit (best)'], [4, 'Smaller (about 1.3× the context)']], settings.kvBits,
      (v) => saveSetting({ kvBits: Number(v) })),
      'How precisely the model remembers what it has read. Smaller keeps half of it at 4 bits, fitting about a third more context, a little less accurately.');
    // iOS gives an app only part of the device's memory unless the app keeps its increased memory
    // limit when it's installed (some sideloading tools drop it).
    if (settings.memoryAvailable && settings.physicalMemory && settings.memoryAvailable < settings.physicalMemory * 0.55) {
      panel.append(element('div', 'chat-setting-note', `iOS lets Mobile Studio use about ${(settings.memoryAvailable / 1e9).toFixed(1)} GB of this device's `
        + `${Math.round(settings.physicalMemory / 1e9)} GB, which limits the context. Installing with a tool that keeps the app's entitlements `
        + '(its increased memory limit) gives it more.'));
    }
  }
  // Subagents only where the agent is: they use tools too.
  if (!canAgent()) {
    panel.append(element('div', 'chat-setting-note', `${info.name || 'This model'} only answers questions: it's too small to use the agent's `
      + 'tools reliably. For the agent (and subagents and Think), pick Light, Standard or Smart, or a cloud model.'));
  } else {
    // Subagents only read and search, so models too small to be the agent (Apple Intelligence) can be one.
    const agents = settings.models.filter((m) => m.ready && !m.suggested && (m.agent || m.subagent));
    row('Subagent model', select([['', 'Same as Chat'], ...agents.map((m) => [m.id, m.name])], canSubagent(settings.subagentModel) ? settings.subagentModel : '',
      (v) => saveSetting({ subagentModel: v })), 'The model subagents use: a small one (Apple Intelligence) is quicker and leaves the memory to the agent, a big one is better.');
    row('Subagent context', contextSelect(subagentModel(), settings.subagentContextSize, (v) => saveSetting({ subagentContextSize: v })),
      'Tokens a subagent reads at once. A small subagent model can have a big context.');
    row('Subagents at once', select([[0, 'Off'], [1, '1'], [2, '2'], [3, '3'], [4, '4'], [6, '6'], [8, '8']], settings.subagentParallel,
      (v) => saveSetting({ subagentParallel: Number(v) })), 'How many subagents run side by side. Each local model is loaded once; cloud models run several freely.');
  }
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
  const size = limit % 1024 === 0 ? k(limit) : Math.round(limit / 1000) + 'k';   // 200K, not 195.3K
  meter.querySelector('.chat-meter-text').textContent = `${k(used)} / ${size} tokens`;
}

function updateControls() {
  if (!pane) return;
  $('chat-send').textContent = busy ? 'Stop' : 'Send';
  const name = modelInfo(settings.selected).name || 'This model';
  // Think: only for models that reason well.
  const think = $('chat-think');
  const r = reasoning();
  think.classList.toggle('on', thinkingOn());
  think.setAttribute('aria-pressed', String(thinkingOn()));
  think.disabled = r !== 'optional';
  think.title = r === 'always' ? `${name} always reasons before it answers`
    : r === 'none' ? `${name} doesn't reason well, so Think is off. Light, Standard, Smart and cloud models can think.`
      : 'Thinking: the agent reasons before it answers (slower, better at harder tasks)';
  // The agent's modes: only for models that can be the agent; the others just chat.
  const mode = $('chat-mode');
  const agent = canAgent();
  let chatOnly = mode.querySelector('option[value="chat"]');
  if (!agent && !chatOnly) {
    chatOnly = element('option', null, 'Chat only');
    chatOnly.value = 'chat';
    mode.prepend(chatOnly);
  } else if (agent && chatOnly) {
    chatOnly.remove();
  }
  mode.disabled = !agent;
  mode.value = agent ? (settings.mode || 'edit') : 'chat';
  mode.title = agent ? 'What the agent may do without asking'
    : `${name} only answers questions: it's too small to use tools reliably. Pick a bigger model for the agent.`;
}

function updateContextLabel() {
  if (!pane) return;
  const path = api.current();
  const sel = api.view.state.selection.main;
  $('chat-include-name').textContent = path ? `${path.split('/').pop()}${sel.empty ? '' : ' (selection)'}` : 'No file open';
  $('chat-include').disabled = !path;
}

/** Open and showing: a pane left open where it has no size counts as closed, so the toggle opens it again. */
export const chatOpen = () => !!pane && !pane.hidden && pane.getClientRects().length > 0 && pane.offsetWidth > 0;

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
  let rest = canAgent() ? withoutToolCalls(text, TOOL) : text;
  // A template that opens <think> itself leaves only the closing tag in the reply.
  if (rest.includes('</think>') && rest.lastIndexOf('<think>', rest.indexOf('</think>')) < 0) rest = '<think>' + rest;
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

// Cards between the messages: tool results, notes, subagents' progress and the agent's changes.
// Each has a record (plain data, saved with the chat) it's drawn from, and is drawn after the
// message it came with (`at`).
let cards = [];   // { at, el, record }

/** Adds a card after the latest message. */
function addCard(record) {
  const card = { at: messages.length, record, el: null };
  card.el = drawCard(card);
  cards.push(card);
  $('chat-log').append(card.el);
  scrollToEnd();
  return card;
}

function drawCard(card) {
  const r = card.record;
  if (r.type === 'note') return element('div', 'chat-note', r.text);
  if (r.type === 'subagents') {
    const el = element('div', 'chat-tool');
    el.append(element('div', 'chat-tool-title', `Subagents (${r.tasks.length})`));
    r.tasks.forEach((task, i) => el.append(element('div', 'chat-subagent', `${i + 1}. ${task.slice(0, 80)} — ${r.states[i]}`)));
    return el;
  }
  if (r.type === 'changes') return changesCard(card);
  const el = element('div', `chat-tool ${r.state}`);
  el.append(element('div', 'chat-tool-title', (r.state === 'done' ? '✓ ' : '✕ ') + r.summary + (r.state === 'denied' ? ' (not allowed)' : '')));
  if (r.preview && r.preview.text) {
    const details = element('details');
    details.append(element('summary', null, `Changes from line ${r.preview.line}`), element('pre', 'chat-diff', r.preview.text));
    el.append(details);
  } else if (r.output) {
    const details = element('details');
    details.append(element('summary', null, 'Output'), element('pre', 'chat-diff', r.output));
    el.append(details);
  }
  if (r.path && r.state === 'done' && r.preview) {
    const open = element('button', 'chat-small', 'Open');
    open.addEventListener('click', () => api.openFile(r.path));
    el.append(open);
  }
  return el;
}

/** Draws a card again after its record changed. */
function redrawCard(card) {
  const el = drawCard(card);
  card.el.replaceWith(el);
  card.el = el;
}

function toolCard(result, state, output) {
  addCard({ type: 'tool', state, summary: result.summary, preview: result.preview || null, output: output ? clip(output, 8000) : null, path: result.path || null });
}

/** A note in the chat that stays where it is when the chat is drawn again. */
function noteCard(text) {
  addCard({ type: 'note', text });
}

/** Asks the user about a call: resolves 'allow', 'always' or 'deny'. */
function approval(call, result) {
  return new Promise((resolve) => {
    const card = element('div', 'chat-approval');
    const title = result.ask || `${result.summary}?`;
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
  const card = addCard({ type: 'subagents', tasks, states: tasks.map(() => 'waiting') });
  return { set: (i, state) => { card.record.states[i] = state; redrawCard(card); } };
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
    cards = [];
    log.replaceChildren(element('div', 'chat-empty',
      (canAgent()
        ? 'Ask about your code, or tell the agent what to change: it reads, searches and edits the project, runs commands and sends research to subagents. '
          + 'The mode below says what it may do without asking. '
        : `Ask about your code: the open file goes with each question. ${modelInfo(settings.selected).name || 'This model'} only answers; for the agent, `
          + 'which reads, edits and runs your project, pick Light, Standard or Smart (or a cloud model). ')
      + (modelInfo(settings.selected).cloud
        ? 'This is a cloud model: your messages and the files the agent reads are sent to its provider.'
        : 'Everything runs on this device.')));
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
