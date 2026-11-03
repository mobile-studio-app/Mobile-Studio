// The web extension host: runs extensions' browser code in a Web Worker, as vscode.dev does,
// against DuoCode's implementation of the vscode API. Requests that need the editor or the app
// (messages, files, edits) go to the page with `request`; the page asks the host to run
// providers and commands with `call` messages.
/* eslint-disable no-restricted-globals */
import { resolveModule } from './modules.js';

let nextId = 1;
const pending = new Map();
let HOST = 'web';
// Node.js's require and fs, when this runs in the Node.js host (node-host.js sets __nodeRequire).
const nodeRequire = globalThis.__nodeRequire || null;
const nodeFs = nodeRequire ? nodeRequire('fs').promises : null;
function request(method, params) {
  const id = nextId++;
  postMessage({ type: 'request', id, method, params });
  return new Promise((resolve, reject) => pending.set(id, { resolve, reject }));
}
const notify = (method, params) => postMessage({ type: 'notify', method, params });

// MARK: - Events and basics

class Disposable {
  constructor(fn) { this._fn = fn; }
  static from(...items) { return new Disposable(() => items.forEach((d) => d && d.dispose && d.dispose())); }
  dispose() { if (this._fn) { this._fn(); this._fn = null; } }
}

class EventEmitter {
  constructor() {
    this._listeners = new Set();
    this.event = (listener, thisArg, disposables) => {
      const entry = thisArg ? listener.bind(thisArg) : listener;
      this._listeners.add(entry);
      const d = new Disposable(() => this._listeners.delete(entry));
      if (Array.isArray(disposables)) disposables.push(d);
      return d;
    };
  }
  fire(data) { for (const l of [...this._listeners]) { try { l(data); } catch (e) { console.error(e); } } }
  dispose() { this._listeners.clear(); }
}

class CancellationTokenSource {
  constructor() {
    const changed = new EventEmitter();
    this.token = { isCancellationRequested: false, onCancellationRequested: changed.event };
    this._changed = changed;
  }
  cancel() { this.token.isCancellationRequested = true; this._changed.fire(); }
  dispose() {}
}
const noCancel = new CancellationTokenSource().token;

class Position {
  constructor(line, character) { this.line = line; this.character = character; }
  isBefore(o) { return this.line < o.line || (this.line === o.line && this.character < o.character); }
  isAfter(o) { return o.isBefore(this); }
  isEqual(o) { return this.line === o.line && this.character === o.character; }
  isBeforeOrEqual(o) { return !this.isAfter(o); }
  isAfterOrEqual(o) { return !this.isBefore(o); }
  compareTo(o) { return this.isBefore(o) ? -1 : this.isAfter(o) ? 1 : 0; }
  translate(a = 0, b = 0) {
    if (typeof a === 'object') return new Position(this.line + (a.lineDelta || 0), this.character + (a.characterDelta || 0));
    return new Position(this.line + a, this.character + b);
  }
  with(a, b) {
    if (a && typeof a === 'object') return new Position(a.line ?? this.line, a.character ?? this.character);
    return new Position(a ?? this.line, b ?? this.character);
  }
}

class Range {
  constructor(a, b, c, d) {
    if (typeof a === 'number') { a = new Position(a, b); b = new Position(c, d); }
    [this.start, this.end] = a.isBefore(b) || a.isEqual(b) ? [a, b] : [b, a];
  }
  get isEmpty() { return this.start.isEqual(this.end); }
  get isSingleLine() { return this.start.line === this.end.line; }
  contains(x) {
    if (x instanceof Range) return this.contains(x.start) && this.contains(x.end);
    return x.isAfterOrEqual(this.start) && x.isBeforeOrEqual(this.end);
  }
  isEqual(o) { return this.start.isEqual(o.start) && this.end.isEqual(o.end); }
  intersection(o) {
    const s = this.start.isAfter(o.start) ? this.start : o.start;
    const e = this.end.isBefore(o.end) ? this.end : o.end;
    return s.isAfter(e) ? undefined : new Range(s, e);
  }
  union(o) { return new Range(this.start.isBefore(o.start) ? this.start : o.start, this.end.isAfter(o.end) ? this.end : o.end); }
  with(a, b) {
    if (a && !(a instanceof Position)) return new Range(a.start || this.start, a.end || this.end);
    return new Range(a || this.start, b || this.end);
  }
}

class Selection extends Range {
  constructor(a, b, c, d) {
    if (typeof a === 'number') { a = new Position(a, b); b = new Position(c, d); }
    super(a, b);
    this.anchor = a;
    this.active = b;
  }
  get isReversed() { return this.anchor.isAfter(this.active); }
}

class Uri {
  constructor(scheme, authority, path, query, fragment) {
    this.scheme = scheme || 'file'; this.authority = authority || ''; this.path = path || '/';
    this.query = query || ''; this.fragment = fragment || '';
  }
  static file(path) { return new Uri('file', '', path.startsWith('/') ? path : '/' + path); }
  static parse(value) {
    const m = /^([a-zA-Z][\w+.-]*):(?:\/\/([^/?#]*))?([^?#]*)(?:\?([^#]*))?(?:#(.*))?/.exec(value);
    if (!m) return Uri.file(value);
    return new Uri(m[1], m[2], decodeURIComponent(m[3] || '/'), m[4], m[5]);
  }
  static joinPath(base, ...parts) {
    const segments = base.path.split('/');
    for (const p of parts.join('/').split('/')) {
      if (p === '..') segments.pop(); else if (p && p !== '.') segments.push(p);
    }
    return base.with({ path: segments.join('/') || '/' });
  }
  static from(c) { return new Uri(c.scheme, c.authority, c.path, c.query, c.fragment); }
  // As VS Code: "/C:/x" is "C:/x" on Windows (the Node.js host is tested there).
  get fsPath() { return /^\/[A-Za-z]:\//.test(this.path) ? this.path.slice(1) : this.path; }
  with(c) { return new Uri(c.scheme ?? this.scheme, c.authority ?? this.authority, c.path ?? this.path, c.query ?? this.query, c.fragment ?? this.fragment); }
  toString() { return `${this.scheme}://${this.authority}${encodeURI(this.path)}${this.query ? '?' + this.query : ''}${this.fragment ? '#' + this.fragment : ''}`; }
  toJSON() { return { scheme: this.scheme, authority: this.authority, path: this.path, query: this.query, fragment: this.fragment }; }
}

class TextEdit {
  constructor(range, newText) { this.range = range; this.newText = newText; }
  static replace(range, text) { return new TextEdit(range, text); }
  static insert(position, text) { return new TextEdit(new Range(position, position), text); }
  static delete(range) { return new TextEdit(range, ''); }
}

/** A snippet's text without its tab stops and placeholders ("${1:x}" -> "x"), for edits that can't be snippets. */
function snippetText(value) {
  let text = String(value);
  for (let i = 0; i < 5; i++) text = text.replace(/\$\{\d+:([^{}]*)\}/g, '$1').replace(/\$\{\d+\|([^,|]*)[^}]*\|\}/g, '$1');
  return text.replace(/\$\{\d+\}|\$\d+/g, '').replace(/\\([$}\\])/g, '$1');
}

class WorkspaceEdit {
  constructor() { this._edits = []; this._files = []; }
  replace(uri, range, newText) { this._edits.push({ uri, edit: new TextEdit(range, newText) }); }
  insert(uri, position, text) { this.replace(uri, new Range(position, position), text); }
  delete(uri, range) { this.replace(uri, range, ''); }
  set(uri, edits) {
    for (const e of edits || []) {
      // [edit, metadata] pairs, and snippet edits (as plain text).
      const edit = Array.isArray(e) ? e[0] : e;
      if (edit && edit.snippet) this._edits.push({ uri, edit: new TextEdit(edit.range, snippetText(edit.snippet.value ?? edit.snippet)) });
      else if (edit && edit.range) this._edits.push({ uri, edit });
    }
  }
  createFile(uri, options = {}) { this._files.push({ op: 'create', uri, options }); }
  deleteFile(uri, options = {}) { this._files.push({ op: 'delete', uri, options }); }
  renameFile(oldUri, newUri, options = {}) { this._files.push({ op: 'rename', uri: oldUri, to: newUri, options }); }
  has(uri) { return this._edits.some((e) => e.uri.toString() === uri.toString()); }
  entries() {
    const map = new Map();
    for (const { uri, edit } of this._edits) {
      const key = uri.toString();
      if (!map.has(key)) map.set(key, [uri, []]);
      map.get(key)[1].push(edit);
    }
    return [...map.values()];
  }
  get size() { return this.entries().length + this._files.length; }
}

class MarkdownString {
  constructor(value = '', supportThemeIcons = false) { this.value = value; this.supportThemeIcons = supportThemeIcons; this.isTrusted = false; }
  appendText(text) { this.value += text.replace(/[\\`*_{}[\]()#+\-.!]/g, '\\$&'); return this; }
  appendMarkdown(text) { this.value += text; return this; }
  appendCodeblock(code, language = '') { this.value += '\n```' + language + '\n' + code + '\n```\n'; return this; }
}

class SnippetString {
  constructor(value = '') { this.value = value; this._n = 1; }
  appendText(text) { this.value += text.replace(/[$}\\]/g, '\\$&'); return this; }
  appendTabstop(n = this._n++) { this.value += '$' + n; return this; }
  appendPlaceholder(value, n = this._n++) { this.value += '${' + n + ':' + (typeof value === 'string' ? value : '') + '}'; return this; }
  appendChoice(values, n = this._n++) { this.value += '${' + n + '|' + values.join(',') + '|}'; return this; }
  appendVariable(name, fallback) { this.value += '${' + name + (fallback ? ':' + fallback : '') + '}'; return this; }
}

const CompletionItemKind = { Text: 0, Method: 1, Function: 2, Constructor: 3, Field: 4, Variable: 5, Class: 6, Interface: 7, Module: 8, Property: 9, Unit: 10, Value: 11, Enum: 12, Keyword: 13, Snippet: 14, Color: 15, File: 16, Reference: 17, Folder: 18, EnumMember: 19, Constant: 20, Struct: 21, Event: 22, Operator: 23, TypeParameter: 24, User: 25, Issue: 26 };
class CompletionItem { constructor(label, kind) { this.label = label; this.kind = kind; } }
class CompletionList { constructor(items = [], isIncomplete = false) { this.items = items; this.isIncomplete = isIncomplete; } }
class Hover { constructor(contents, range) { this.contents = Array.isArray(contents) ? contents : [contents]; this.range = range; } }
const DiagnosticSeverity = { Error: 0, Warning: 1, Information: 2, Hint: 3 };
class Diagnostic {
  constructor(range, message, severity = DiagnosticSeverity.Error) { this.range = range; this.message = message; this.severity = severity; }
}
class DiagnosticRelatedInformation { constructor(location, message) { this.location = location; this.message = message; } }
class CancellationError extends Error { constructor() { super('Canceled'); this.name = 'Canceled'; } }
class FileDecoration { constructor(badge, tooltip, color) { Object.assign(this, { badge, tooltip, color, propagate: false }); } }
class CallHierarchyIncomingCall { constructor(item, fromRanges) { this.from = item; this.fromRanges = fromRanges; } }
class CallHierarchyOutgoingCall { constructor(item, fromRanges) { this.to = item; this.fromRanges = fromRanges; } }
class TerminalLink { constructor(startIndex, length, tooltip) { Object.assign(this, { startIndex, length, tooltip }); } }
class TerminalProfile { constructor(options) { this.options = options; } }
class TimelineItem { constructor(label, timestamp) { this.label = label; this.timestamp = timestamp; } }
class TelemetryTrustedValue { constructor(value) { this.value = value; } }
class DebugAdapterServer { constructor(port, host) { this.port = port; this.host = host; } }
class DebugAdapterNamedPipeServer { constructor(path) { this.path = path; } }
class TestTag { constructor(id) { this.id = id; } }
class TestRunRequest { constructor(include, exclude, profile, continuous) { Object.assign(this, { include, exclude, profile, continuous }); } }
class TestCoverageCount { constructor(covered, total) { this.covered = covered; this.total = total; } }
class LanguageModelError extends Error {
  constructor(message, code = 'Unknown') { super(message); this.code = code; }
  static NoPermissions(m) { return new LanguageModelError(m || 'No permission', 'NoPermissions'); }
  static Blocked(m) { return new LanguageModelError(m || 'Blocked', 'Blocked'); }
  static NotFound(m) { return new LanguageModelError(m || 'No language models', 'NotFound'); }
}
class LanguageModelTextPart { constructor(value) { this.value = value; } }
class LanguageModelChatMessage {
  constructor(role, content, name) { Object.assign(this, { role, content: typeof content === 'string' ? [new LanguageModelTextPart(content)] : content, name }); }
  static User(content, name) { return new LanguageModelChatMessage(1, content, name); }
  static Assistant(content, name) { return new LanguageModelChatMessage(2, content, name); }
}
class Location { constructor(uri, rangeOrPosition) { this.uri = uri; this.range = rangeOrPosition instanceof Position ? new Range(rangeOrPosition, rangeOrPosition) : rangeOrPosition; } }
const SymbolKind = { File: 0, Module: 1, Namespace: 2, Package: 3, Class: 4, Method: 5, Property: 6, Field: 7, Constructor: 8, Enum: 9, Interface: 10, Function: 11, Variable: 12, Constant: 13, String: 14, Number: 15, Boolean: 16, Array: 17, Object: 18, Key: 19, Null: 20, EnumMember: 21, Struct: 22, Event: 23, Operator: 24, TypeParameter: 25 };
class DocumentSymbol { constructor(name, detail, kind, range, selectionRange) { Object.assign(this, { name, detail, kind, range, selectionRange, children: [] }); } }
class SymbolInformation { constructor(name, kind, containerName, location) { Object.assign(this, { name, kind, containerName, location }); } }
class ThemeColor { constructor(id) { this.id = id; } }
class ThemeIcon { constructor(id, color) { this.id = id; this.color = color; } }
ThemeIcon.File = new ThemeIcon('file');
ThemeIcon.Folder = new ThemeIcon('folder');
class CodeAction { constructor(title, kind) { this.title = title; this.kind = kind; } }
class CodeActionKind {
  constructor(value) { this.value = value; }
  append(part) { return new CodeActionKind(this.value ? this.value + '.' + part : part); }
  contains(other) { return this.value === other.value || other.value.startsWith(this.value + '.'); }
  intersects(other) { return this.contains(other) || other.contains(this); }
}
for (const [k, v] of Object.entries({ Empty: '', QuickFix: 'quickfix', Refactor: 'refactor', RefactorExtract: 'refactor.extract', RefactorInline: 'refactor.inline', RefactorRewrite: 'refactor.rewrite', Source: 'source', SourceOrganizeImports: 'source.organizeImports', SourceFixAll: 'source.fixAll' })) CodeActionKind[k] = new CodeActionKind(v);
class SignatureHelp { constructor() { this.signatures = []; this.activeSignature = 0; this.activeParameter = 0; } }
class SignatureInformation { constructor(label, documentation) { this.label = label; this.documentation = documentation; this.parameters = []; } }
class ParameterInformation { constructor(label, documentation) { this.label = label; this.documentation = documentation; } }
class FoldingRange { constructor(start, end, kind) { Object.assign(this, { start, end, kind }); } }
class Color { constructor(red, green, blue, alpha) { Object.assign(this, { red, green, blue, alpha }); } }
class ColorInformation { constructor(range, color) { this.range = range; this.color = color; } }
class DocumentLink { constructor(range, target) { this.range = range; this.target = target; } }
class InlayHint { constructor(position, label, kind) { Object.assign(this, { position, label, kind }); } }
class TreeItem {
  // (label, state) or (resourceUri, state).
  constructor(label, collapsibleState) {
    if (label instanceof Uri) this.resourceUri = label; else this.label = label;
    this.collapsibleState = collapsibleState;
  }
}
class RelativePattern { constructor(base, pattern) { this.base = base; this.pattern = pattern; } }
class DocumentDropOrPasteEditKind {
  constructor(value) { this.value = value; }
  append(...parts) { return new DocumentDropOrPasteEditKind([this.value, ...parts].filter(Boolean).join('.')); }
  contains(other) { return this.value === other.value || other.value.startsWith(this.value + '.'); }
  intersects(other) { return this.contains(other) || other.contains(this); }
}
DocumentDropOrPasteEditKind.Empty = new DocumentDropOrPasteEditKind('');
DocumentDropOrPasteEditKind.Text = new DocumentDropOrPasteEditKind('text');
DocumentDropOrPasteEditKind.TextUpdateImports = new DocumentDropOrPasteEditKind('text.updateImports');
class DocumentDropEdit { constructor(insertText, title, kind) { Object.assign(this, { insertText, title, kind }); } }
class DocumentPasteEdit { constructor(insertText, title, kind) { Object.assign(this, { insertText, title, kind }); } }
class SemanticTokensLegend { constructor(tokenTypes, tokenModifiers = []) { this.tokenTypes = tokenTypes; this.tokenModifiers = tokenModifiers; } }
class SemanticTokens { constructor(data, resultId) { this.data = data; this.resultId = resultId; } }
class SemanticTokensBuilder {
  constructor(legend) { this._legend = legend; this._data = []; this._prevLine = 0; this._prevChar = 0; }
  push(a, b, c, d, e) {
    let line, char, length, type, mods;
    if (a instanceof Range) {
      line = a.start.line; char = a.start.character; length = a.end.character - a.start.character;
      type = this._legend ? this._legend.tokenTypes.indexOf(b) : 0;
      mods = (c || []).reduce((m, x) => m | (1 << this._legend.tokenModifiers.indexOf(x)), 0);
    } else { [line, char, length, type, mods] = [a, b, c, d, e || 0]; }
    const deltaLine = line - this._prevLine;
    this._data.push(deltaLine, deltaLine ? char : char - this._prevChar, length, type, mods);
    this._prevLine = line; this._prevChar = char;
  }
  build(resultId) { return new SemanticTokens(new Uint32Array(this._data), resultId); }
}
class SemanticTokensEdit { constructor(start, deleteCount, data) { Object.assign(this, { start, deleteCount, data }); } }
class SemanticTokensEdits { constructor(edits, resultId) { this.edits = edits; this.resultId = resultId; } }
class CodeLens { constructor(range, command) { this.range = range; this.command = command; } get isResolved() { return !!this.command; } }
class DocumentHighlight { constructor(range, kind = 0) { this.range = range; this.kind = kind; } }
class SelectionRange { constructor(range, parent) { this.range = range; this.parent = parent; } }
class CallHierarchyItem { constructor(kind, name, detail, uri, range, selectionRange) { Object.assign(this, { kind, name, detail, uri, range, selectionRange }); } }
class TypeHierarchyItem extends CallHierarchyItem {}
class InlineCompletionItem { constructor(insertText, range, command) { Object.assign(this, { insertText, range, command }); } }
class InlineCompletionList { constructor(items) { this.items = items; } }
class LinkedEditingRanges { constructor(ranges, wordPattern) { this.ranges = ranges; this.wordPattern = wordPattern; } }
class ColorPresentation { constructor(label) { this.label = label; } }
class EvaluatableExpression { constructor(range, expression) { this.range = range; this.expression = expression; } }
class InlayHintLabelPart { constructor(value) { this.value = value; } }
class SnippetTextEdit { constructor(range, snippet) { this.range = range; this.snippet = snippet; } static replace(r, s) { return new SnippetTextEdit(r, s); } static insert(p, s) { return new SnippetTextEdit(new Range(p, p), s); } }
class TextDocumentEdit { constructor(uri, edits) { this.uri = uri; this.edits = edits; } }
class DataTransferItem { constructor(value) { this.value = value; } asString() { return Promise.resolve(typeof this.value === 'string' ? this.value : JSON.stringify(this.value)); } asFile() { return undefined; } }
class DataTransfer { constructor() { this._items = new Map(); } get(m) { return this._items.get(m); } set(m, v) { this._items.set(m, v); } forEach(f) { this._items.forEach(f); } [Symbol.iterator]() { return this._items[Symbol.iterator](); } }
class TaskGroup { constructor(id, label) { this.id = id; this.label = label; } }
TaskGroup.Build = new TaskGroup('build', 'Build'); TaskGroup.Test = new TaskGroup('test', 'Test'); TaskGroup.Clean = new TaskGroup('clean', 'Clean'); TaskGroup.Rebuild = new TaskGroup('rebuild', 'Rebuild');
class Task {
  constructor(definition, scope, name, source, execution, problemMatchers) {
    // The older form has no scope: (definition, name, source, execution, problemMatchers).
    if (typeof scope === 'string') [scope, name, source, execution, problemMatchers] = [undefined, scope, name, source, execution];
    Object.assign(this, { definition, scope, name, source, execution, problemMatchers, group: undefined, detail: undefined, presentationOptions: {}, isBackground: false });
  }
}
class ShellExecution {
  // (commandLine, options) or (command, args, options).
  constructor(a, b, c) { if (Array.isArray(b)) Object.assign(this, { command: a, args: b, options: c }); else Object.assign(this, { commandLine: a, options: b }); }
}
class ProcessExecution { constructor(process, args, options) { Object.assign(this, { process, args, options }); } }
class CustomExecution { constructor(callback) { this.callback = callback; } }
class Breakpoint { constructor(enabled = true, condition, hitCondition, logMessage) { Object.assign(this, { enabled, condition, hitCondition, logMessage, id: String(Math.random()) }); } }
class SourceBreakpoint extends Breakpoint { constructor(location, ...rest) { super(...rest); this.location = location; } }
class FunctionBreakpoint extends Breakpoint { constructor(functionName, ...rest) { super(...rest); this.functionName = functionName; } }
class DebugAdapterExecutable { constructor(command, args, options) { Object.assign(this, { command, args, options }); } }
class DebugAdapterInlineImplementation { constructor(implementation) { this.implementation = implementation; } }
class FileSystemError extends Error {
  constructor(message, code = 'Unknown') { super(typeof message === 'string' ? message : String(message)); this.code = code; this.name = `${code} (FileSystemError)`; }
  static FileNotFound(m) { return new FileSystemError(m || 'File not found', 'FileNotFound'); }
  static FileExists(m) { return new FileSystemError(m || 'File exists', 'FileExists'); }
  static FileNotADirectory(m) { return new FileSystemError(m || 'Not a directory', 'FileNotADirectory'); }
  static FileIsADirectory(m) { return new FileSystemError(m || 'Is a directory', 'FileIsADirectory'); }
  static NoPermissions(m) { return new FileSystemError(m || 'No permissions', 'NoPermissions'); }
  static Unavailable(m) { return new FileSystemError(m || 'Unavailable', 'Unavailable'); }
}
class TestMessage { constructor(message) { this.message = message; } }
class TabInputText { constructor(uri) { this.uri = uri; } }
// The other kinds of tab (extensions check tab.input with instanceof).
class TabInputTextDiff { constructor(original, modified) { this.original = original; this.modified = modified; } }
class TabInputCustom { constructor(uri, viewType) { this.uri = uri; this.viewType = viewType; } }
class TabInputWebview { constructor(viewType) { this.viewType = viewType; } }
class TabInputNotebook { constructor(uri, notebookType) { this.uri = uri; this.notebookType = notebookType; } }
class TabInputNotebookDiff { constructor(original, modified, notebookType) { this.original = original; this.modified = modified; this.notebookType = notebookType; } }
class TabInputTerminal { constructor() {} }
class TabInputInteractiveWindow { constructor(uri, inputBoxUri) { this.uri = uri; this.inputBoxUri = inputBoxUri; } }
class QuickInputButtons {}
QuickInputButtons.Back = { iconPath: new ThemeIcon('arrow-left') };
// Notebooks aren't shown yet; these let extensions that build notebook data load and run.
class NotebookCellOutputItem {
  constructor(data, mime) { this.data = data; this.mime = mime; }
  static text(v, mime = 'text/plain') { return new NotebookCellOutputItem(new TextEncoder().encode(v), mime); }
  static json(v, mime = 'application/json') { return NotebookCellOutputItem.text(JSON.stringify(v, undefined, '\t'), mime); }
  static stdout(v) { return NotebookCellOutputItem.text(v, 'application/vnd.code.notebook.stdout'); }
  static stderr(v) { return NotebookCellOutputItem.text(v, 'application/vnd.code.notebook.stderr'); }
  static error(e) {
    const error = { name: (e && e.name) || 'Error', message: (e && e.message) || String(e), stack: e && e.stack };
    return NotebookCellOutputItem.json(error, 'application/vnd.code.notebook.error');
  }
}
class NotebookCellOutput { constructor(items, idOrMetadata, metadata) { this.items = items; if (typeof idOrMetadata === 'string') { this.id = idOrMetadata; this.metadata = metadata; } else { this.metadata = idOrMetadata; } } }
class NotebookCellData { constructor(kind, value, languageId) { Object.assign(this, { kind, value, languageId }); } }
class NotebookData { constructor(cells) { this.cells = cells; } }
class NotebookRange {
  constructor(start, end) { this.start = Math.min(start, end); this.end = Math.max(start, end); }
  get isEmpty() { return this.start === this.end; }
  with(change = {}) { return new NotebookRange(change.start ?? this.start, change.end ?? this.end); }
}
class NotebookEdit {
  constructor(range, newCells) { this.range = range; this.newCells = newCells; }
  static replaceCells(range, newCells) { return new NotebookEdit(range, newCells); }
  static insertCells(index, newCells) { return new NotebookEdit(new NotebookRange(index, index), newCells); }
  static deleteCells(range) { return new NotebookEdit(range, []); }
  static updateCellMetadata(index, newCellMetadata) { return Object.assign(new NotebookEdit(new NotebookRange(index, index), []), { newCellMetadata }); }
  static updateNotebookMetadata(newNotebookMetadata) { return Object.assign(new NotebookEdit(new NotebookRange(0, 0), []), { newNotebookMetadata }); }
}

const enums = {
  StatusBarAlignment: { Left: 1, Right: 2 },
  ViewColumn: { Active: -1, Beside: -2, One: 1, Two: 2, Three: 3 },
  EndOfLine: { LF: 1, CRLF: 2 },
  TextEditorRevealType: { Default: 0, InCenter: 1, InCenterIfOutsideViewport: 2, AtTop: 3 },
  ConfigurationTarget: { Global: 1, Workspace: 2, WorkspaceFolder: 3 },
  ProgressLocation: { SourceControl: 1, Window: 10, Notification: 15 },
  FileType: { Unknown: 0, File: 1, Directory: 2, SymbolicLink: 64 },
  OverviewRulerLane: { Left: 1, Center: 2, Right: 4, Full: 7 },
  DecorationRangeBehavior: { OpenOpen: 0, ClosedClosed: 1, OpenClosed: 2, ClosedOpen: 3 },
  TreeItemCollapsibleState: { None: 0, Collapsed: 1, Expanded: 2 },
  CompletionTriggerKind: { Invoke: 0, TriggerCharacter: 1, TriggerForIncompleteCompletions: 2 },
  SignatureHelpTriggerKind: { Invoke: 1, TriggerCharacter: 2, ContentChange: 3 },
  DiagnosticTag: { Unnecessary: 1, Deprecated: 2 },
  CompletionItemTag: { Deprecated: 1 },
  SymbolTag: { Deprecated: 1 },
  FoldingRangeKind: { Comment: 1, Imports: 2, Region: 3 },
  ExtensionMode: { Production: 1, Development: 2, Test: 3 },
  ColorThemeKind: { Light: 1, Dark: 2, HighContrast: 3, HighContrastLight: 4 },
  InlayHintKind: { Type: 1, Parameter: 2 },
  QuickPickItemKind: { Separator: -1, Default: 0 },
  UIKind: { Desktop: 1, Web: 2 },
  LanguageStatusSeverity: { Information: 0, Warning: 1, Error: 2 },
  TextDocumentSaveReason: { Manual: 1, AfterDelay: 2, FocusOut: 3 },
  TextEditorLineNumbersStyle: { Off: 0, On: 1, Relative: 2 },
  TextEditorCursorStyle: { Line: 1, Block: 2, Underline: 3, LineThin: 4, BlockOutline: 5, UnderlineThin: 6 },
  IndentAction: { None: 0, Indent: 1, IndentOutdent: 2, Outdent: 3 },
  DocumentHighlightKind: { Text: 0, Read: 1, Write: 2 },
  CodeActionTriggerKind: { Invoke: 1, Automatic: 2 },
  TextDocumentChangeReason: { Undo: 1, Redo: 2 },
  ExtensionKind: { UI: 1, Workspace: 2 },
  EnvironmentVariableMutatorType: { Replace: 1, Append: 2, Prepend: 3 },
  CommentThreadCollapsibleState: { Collapsed: 0, Expanded: 1 },
  TaskRevealKind: { Always: 1, Silent: 2, Never: 3 },
  TaskPanelKind: { Shared: 1, Dedicated: 2, New: 3 },
  FileChangeType: { Changed: 1, Created: 2, Deleted: 3 },
  FilePermission: { Readonly: 1 },
  LogLevel: { Off: 0, Trace: 1, Debug: 2, Info: 3, Warning: 4, Error: 5 },
  TextEditorSelectionChangeKind: { Keyboard: 1, Mouse: 2, Command: 3 },
  InlineCompletionTriggerKind: { Invoke: 0, Automatic: 1 },
  InputBoxValidationSeverity: { Info: 1, Warning: 2, Error: 3 },
  TerminalLocation: { Panel: 1, Editor: 2 },
  TerminalExitReason: { Unknown: 0, Shutdown: 1, Process: 2, User: 3, Extension: 4 },
  TerminalShellExecutionCommandLineConfidence: { Low: 0, Medium: 1, High: 2 },
  CommentThreadState: { Unresolved: 0, Resolved: 1 },
  CommentThreadApplicability: { Current: 0, Outdated: 1 },
  DebugConsoleMode: { Separate: 0, MergeWithParent: 1 },
  DebugConfigurationProviderTriggerKind: { Initial: 1, Dynamic: 2 },
  SourceControlInputBoxValidationType: { Error: 0, Warning: 1, Information: 2 },
  LanguageModelChatMessageRole: { User: 1, Assistant: 2 },
  ChatResultFeedbackKind: { Unhelpful: 0, Helpful: 1 },
  SyntaxTokenType: { Other: 0, Comment: 1, String: 2, RegEx: 3 },
  TextDocumentChangeReasonKind: { Undo: 1, Redo: 2 },
  TestMessageStackFrame: undefined,
  PortAutoForwardAction: { Notify: 1, OpenBrowser: 2, OpenPreview: 3, Silent: 4, Ignore: 5 },
};

// MARK: - Documents

const documents = new Map();   // uri string -> TextDocument
const onDidOpenTextDocument = new EventEmitter();
const onDidCloseTextDocument = new EventEmitter();
const onDidChangeTextDocument = new EventEmitter();
const onDidSaveTextDocument = new EventEmitter();
const onDidChangeActiveTextEditor = new EventEmitter();
const onDidChangeTextEditorSelection = new EventEmitter();
const onDidChangeConfiguration = new EventEmitter();
const onDidChangeVisibleTextEditors = new EventEmitter();
const onDidChangeDiagnostics = new EventEmitter();
const onDidChangeTabs = new EventEmitter();
const onDidChangeActiveColorTheme = new EventEmitter();

/** The editor's tabs as VS Code's tab group: one tab per open document. */
function tabGroup() {
  const group = { isActive: true, viewColumn: 1, tabs: [] };
  for (const doc of documents.values()) {
    const active = !!activeEditor && activeEditor.document === doc;
    const tab = { label: doc.uri.path.split('/').pop(), group, input: new TabInputText(doc.uri), isActive: active, isDirty: doc.isDirty, isPinned: false, isPreview: false };
    group.tabs.push(tab);
    if (active) group.activeTab = tab;
  }
  return group;
}
const diagnosticCollections = new Set();   // each collection's uri -> Diagnostic[] map
let collectionId = 0;
let workspaceRoot = '/';
let activeEditor;
let themeKind = 2;
const contentProviders = new Map();   // scheme -> TextDocumentContentProvider
const languageStatusItems = new Set();

/** Language status items show while the open file matches their selector. */
function updateLanguageStatus() {
  for (const item of languageStatusItems) {
    const show = activeEditor && matches(item.selector, activeEditor.document) > 0;
    if (show) item.show(); else item.hide();
  }
}

/** A language for a path by its extension, for virtual documents. */
function languageFor(path) {
  const ext = (path.split('.').pop() || '').toLowerCase();
  for (const e of extensions.values()) {
    for (const lang of e.manifest.contributes?.languages || []) if ((lang.extensions || []).includes('.' + ext)) return lang.id;
  }
  return { js: 'javascript', ts: 'typescript', json: 'json', md: 'markdown', lua: 'lua', py: 'python', html: 'html', css: 'css', diff: 'diff' }[ext] || 'plaintext';
}

class TextDocument {
  constructor(uri, languageId, text, version) {
    this.uri = uri; this.languageId = languageId; this.version = version;
    this.isDirty = false; this.isClosed = false; this.isUntitled = false; this.eol = 1;
    this._set(text);
  }
  _set(text) { this._text = text; this._lines = text.split(/\r?\n/); this._starts = []; let o = 0; for (const l of text.split('\n')) { this._starts.push(o); o += l.length + 1; } }
  get fileName() { return this.uri.fsPath; }
  get lineCount() { return this._lines.length; }
  getText(range) { return range ? this._text.slice(this.offsetAt(range.start), this.offsetAt(range.end)) : this._text; }
  lineAt(x) {
    const line = typeof x === 'number' ? x : x.line;
    const text = this._lines[line] ?? '';
    const indent = /^\s*/.exec(text)[0].length;
    return { lineNumber: line, text, range: new Range(line, 0, line, text.length), rangeIncludingLineBreak: new Range(line, 0, line + 1, 0),
      firstNonWhitespaceCharacterIndex: indent, isEmptyOrWhitespace: indent === text.length };
  }
  offsetAt(p) { const line = Math.max(0, Math.min(p.line, this._starts.length - 1)); return Math.min(this._starts[line] + p.character, this._text.length); }
  positionAt(offset) {
    offset = Math.max(0, Math.min(offset, this._text.length));
    let lo = 0, hi = this._starts.length - 1;
    while (lo < hi) { const mid = (lo + hi + 1) >> 1; if (this._starts[mid] <= offset) lo = mid; else hi = mid - 1; }
    return new Position(lo, offset - this._starts[lo]);
  }
  getWordRangeAtPosition(p, regex = /[\w$]+/g) {
    const text = this.lineAt(p.line).text;
    const re = new RegExp(regex.source, regex.flags.includes('g') ? regex.flags : regex.flags + 'g');
    let m;
    while ((m = re.exec(text))) {
      if (m.index <= p.character && p.character <= m.index + m[0].length) return new Range(p.line, m.index, p.line, m.index + m[0].length);
      if (!m[0].length) re.lastIndex++;
    }
    return undefined;
  }
  validateRange(r) { return r; }
  validatePosition(p) { return p; }
  save() { return request('save', { uri: this.uri.toString() }); }
}

let decorationTypeId = 0;

/** Decoration options without class instances (ThemeColor -> { id }, Uri -> string). */
function plainOptions(options) {
  return JSON.parse(JSON.stringify(options || {}, (k, v) => (v instanceof Uri ? v.toString() : v)));
}
function plainHover(message) {
  if (!message) return undefined;
  const list = Array.isArray(message) ? message : [message];
  return list.map((m) => (typeof m === 'string' ? m : m.value || '')).join('\n\n');
}

function toPosition(p) { return new Position(p.line, p.character); }
function toRange(r) { return new Range(toPosition(r.start), toPosition(r.end)); }

// MARK: - Extensions and activation

const extensions = new Map();   // id -> { id, manifest, code, active, exports, context }
const commands = new Map();     // command -> { fn, thisArg }
const providers = {};           // kind -> [{ selector, provider, extra }]

function addProvider(kind, selector, provider, extra) {
  const entry = { selector, provider, extra };
  (providers[kind] = providers[kind] || []).push(entry);
  return new Disposable(() => { providers[kind] = providers[kind].filter((e) => e !== entry); });
}

function matches(selector, doc) {
  if (!selector) return 0;
  if (Array.isArray(selector)) return Math.max(0, ...selector.map((s) => matches(s, doc)));
  if (typeof selector === 'string') return selector === '*' ? 5 : selector === doc.languageId ? 10 : 0;
  if (selector.language && selector.language !== '*' && selector.language !== doc.languageId) return 0;
  if (selector.scheme && selector.scheme !== '*' && selector.scheme !== doc.uri.scheme) return 0;
  if (selector.pattern) {
    const pattern = typeof selector.pattern === 'string' ? selector.pattern : selector.pattern.pattern;
    const ext = /\*\.(\w+)$/.exec(pattern || '');
    if (ext && !doc.uri.path.endsWith('.' + ext[1])) return 0;
  }
  return selector.language === '*' ? 5 : 10;
}

function providersFor(kind, doc) {
  return (providers[kind] || []).filter((e) => matches(e.selector, doc) > 0);
}

function configurationDefaults() {
  const values = {};
  for (const ext of extensions.values()) {
    const config = ext.manifest.contributes?.configuration;
    for (const section of Array.isArray(config) ? config : config ? [config] : []) {
      for (const [key, prop] of Object.entries(section.properties || {})) {
        if ('default' in prop) values[key] = prop.default;
      }
    }
  }
  return values;
}
let userConfiguration = {};

function getConfiguration(section) {
  const all = { ...configurationDefaults(), ...userConfiguration };
  const prefix = section ? section + '.' : '';
  const get = (key, fallback) => {
    const full = key ? prefix + key : section || '';
    if (full in all) return all[full];
    // A section: an object built from its dotted keys ("css" -> { lint: { validProperties } }).
    const inner = Object.keys(all).filter((k) => !full || k.startsWith(full + '.'));
    if (inner.length) {
      const out = {};
      for (const k of inner) {
        const parts = (full ? k.slice(full.length + 1) : k).split('.');
        let node = out;
        parts.slice(0, -1).forEach((p) => { node = node[p] = node[p] && typeof node[p] === 'object' ? node[p] : {}; });
        node[parts[parts.length - 1]] = all[k];
      }
      return out;
    }
    // Values set as nested objects ("editor": { "tabSize": 4 }).
    let value = all;
    for (const p of full.split('.')) { if (value && typeof value === 'object' && p in value) value = value[p]; else return fallback; }
    return value;
  };
  return {
    get,
    has: (key) => get(key) !== undefined,
    inspect: (key) => ({ key: prefix + key, defaultValue: configurationDefaults()[prefix + key], globalValue: userConfiguration[prefix + key] }),
    update: (key, value) => { userConfiguration[prefix + key] = value; request('saveConfiguration', { values: userConfiguration }); onDidChangeConfiguration.fire({ affectsConfiguration: (s) => (prefix + key).startsWith(s) }); return Promise.resolve(); },
    ...Object.fromEntries(Object.keys(all).filter((k) => !section || k.startsWith(prefix)).map((k) => [k.slice(prefix.length).split('.')[0], get(k.slice(prefix.length).split('.')[0])])),
  };
}

function memento(storeKey) {
  let data = {};
  try { data = JSON.parse(self.__state?.[storeKey] || '{}'); } catch (e) { data = {}; }
  return {
    get: (key, fallback) => (key in data ? data[key] : fallback),
    update: (key, value) => { if (value === undefined) delete data[key]; else data[key] = value; return request('saveState', { key: storeKey, value: JSON.stringify(data) }); },
    keys: () => Object.keys(data),
    setKeysForSync() {},
  };
}

// MARK: - Workers

// Extensions start language servers with new Worker(<a file in the extension>). Those files
// aren't URLs a worker can load, so the code is read and run from a blob URL; messages sent
// before it's ready wait.
const NativeWorker = self.Worker;
class ExtensionWorker extends EventTarget {
  constructor(url, options) {
    super();
    this.onmessage = null;
    this.onerror = null;
    this.onmessageerror = null;
    this._queue = [];
    this._worker = null;
    this._terminated = false;
    const href = String(url);
    const start = (scriptURL) => {
      if (this._terminated) return;
      const worker = new NativeWorker(scriptURL, options);
      worker.onmessage = (e) => this._emit('message', new MessageEvent('message', { data: e.data, ports: [...(e.ports || [])] }));
      worker.onerror = (e) => this._emit('error', e);
      this._worker = worker;
      for (const [message, transfer] of this._queue) worker.postMessage(message, transfer);
      this._queue = [];
    };
    if (/^(blob:|data:|https?:)/.test(href)) { start(href); return; }
    const bytes = extensionFile(Uri.parse(href));
    if (!bytes) { start(href); return; }
    bytes.then((data) => start(URL.createObjectURL(new Blob([data], { type: 'text/javascript' }))),
      (e) => this._emit('error', new ErrorEvent('error', { message: `Couldn't load ${href}: ${e && e.message}` })));
  }
  _emit(type, event) {
    const handler = type === 'message' ? this.onmessage : this.onerror;
    if (handler) handler.call(this, event);
    this.dispatchEvent(type === 'message' ? new MessageEvent('message', { data: event.data }) : new Event('error'));
  }
  postMessage(message, transfer) {
    if (this._worker) this._worker.postMessage(message, transfer);
    else this._queue.push([message, transfer]);
  }
  terminate() {
    this._terminated = true;
    if (this._worker) this._worker.terminate();
  }
}
if (NativeWorker) self.Worker = ExtensionWorker;

// MARK: - Extension files

// Installed extensions' files appear under this folder (extensionUri), read through the app.
const EXTENSIONS_ROOT = '/.duocode/extensions';
const extensionUriOf = (id) => {
  const ext = extensions.get(id);
  return ext && ext.path && nodeRequire ? Uri.file(ext.path) : Uri.file(EXTENSIONS_ROOT + '/' + id);
};

// VS Code's built-in language extensions, reduced to what other extensions read from them:
// each language's comment syntax and brackets (language-configuration.json).
const C_STYLE = { lineComment: '//', blockComment: ['/*', '*/'] };
const HASH = { lineComment: '#' };
const BUILTIN_COMMENTS = {
  javascript: C_STYLE, javascriptreact: C_STYLE, typescript: C_STYLE, typescriptreact: C_STYLE, json: C_STYLE, jsonc: C_STYLE,
  c: C_STYLE, cpp: C_STYLE, 'objective-c': C_STYLE, 'objective-cpp': C_STYLE, csharp: C_STYLE, java: C_STYLE, go: C_STYLE,
  rust: C_STYLE, swift: C_STYLE, kotlin: C_STYLE, glsl: C_STYLE, php: C_STYLE, scss: C_STYLE, less: C_STYLE, dart: C_STYLE,
  css: { blockComment: ['/*', '*/'] },
  lua: { lineComment: '--', blockComment: ['--[[', ']]'] }, sql: { lineComment: '--', blockComment: ['/*', '*/'] },
  python: HASH, shellscript: HASH, yaml: HASH, toml: HASH, ruby: HASH, perl: HASH, r: HASH, dockerfile: HASH, makefile: HASH, ini: { lineComment: ';' },
  html: { blockComment: ['<!--', '-->'] }, xml: { blockComment: ['<!--', '-->'] }, markdown: { blockComment: ['<!--', '-->'] },
};
const BUILTIN_ID = 'vscode.builtin-languages';
function builtinExtensions() {
  const extensionUri = extensionUriOf(BUILTIN_ID);
  const packageJSON = {
    name: 'builtin-languages', publisher: 'vscode', displayName: 'Built-in languages',
    contributes: { languages: Object.keys(BUILTIN_COMMENTS).map((id) => ({ id, configuration: './' + id + '.language-configuration.json' })) },
  };
  return [{ id: BUILTIN_ID, packageJSON, isActive: true, exports: undefined, activate: async () => undefined, extensionUri, extensionPath: extensionUri.path, extensionKind: 1 }];
}

/** The bytes of a file inside an installed extension, or null when the uri is elsewhere. */
function extensionFile(uri) {
  if (uri.scheme !== 'file' || !uri.path.startsWith(EXTENSIONS_ROOT + '/')) return null;
  const [id, ...rest] = uri.path.slice(EXTENSIONS_ROOT.length + 1).split('/');
  const path = rest.join('/');
  if (id === BUILTIN_ID) {
    const lang = path.replace(/\.language-configuration\.json$/, '');
    if (!BUILTIN_COMMENTS[lang]) return Promise.reject(FileSystemError.FileNotFound(uri));
    const config = { comments: BUILTIN_COMMENTS[lang], brackets: [['{', '}'], ['[', ']'], ['(', ')']] };
    return Promise.resolve(new TextEncoder().encode(JSON.stringify(config)));
  }
  return request('extFile', { id, path }).then(
    (base64) => Uint8Array.from(atob(base64), (c) => c.charCodeAt(0)),
    () => { throw FileSystemError.FileNotFound(uri); },
  );
}

async function activate(ext) {
  if (ext.active) return ext.active;
  ext.active = (async () => {
    // CommonJS over the files the page preloaded (ext.modules: path -> source).
    const cache = new Map();
    const load = (path) => {
      if (cache.has(path)) return cache.get(path).exports;
      const module = { exports: {} };
      cache.set(path, module);
      const dir = path.split('/').slice(0, -1).join('/');
      const require = (name) => {
        if (name === 'vscode') return vscode;
        if (name.startsWith('.')) {
          const target = resolveModule(ext.modules, dir, name);
          if (target) return load(target);
        }
        throw new Error(`"${name}" isn't available to web extensions in Mobile Studio`);
      };
      new Function('module', 'exports', 'require', '__filename', '__dirname', ext.modules[path])(module, module.exports, require, path, dir);
      return module.exports;
    };
    const extensionUri = extensionUriOf(ext.id);
    const context = {
      subscriptions: [],
      extensionUri,
      extensionPath: extensionUri.fsPath,
      asAbsolutePath: (p) => Uri.joinPath(extensionUri, p).fsPath,
      globalState: memento(`global:${ext.id}`),
      workspaceState: memento(`workspace:${ext.id}`),
      secrets: secretStorage(ext.id),
      globalStorageUri: Uri.parse(`duocode-ext-storage://${ext.id}/global`),
      storageUri: Uri.parse(`duocode-ext-storage://${ext.id}/workspace`),
      logUri: Uri.parse(`duocode-ext-storage://${ext.id}/log`),
      extensionMode: enums.ExtensionMode.Production,
      environmentVariableCollection: { replace() {}, append() {}, prepend() {}, get() {}, forEach() {}, delete() {}, clear() {} },
      extension: { id: ext.id, extensionUri, packageJSON: ext.manifest, isActive: true, exports: undefined, extensionKind: 2 },
    };
    ext.context = context;
    try {
      const main = ext.nodeMain ? nodeLoad(ext.nodeMain) : load(ext.main);
      if (typeof main.activate === 'function') ext.exports = await main.activate(context);
      notify('log', { level: 'info', text: `Activated ${ext.manifest.displayName || ext.id}` });
    } catch (e) {
      notify('log', { level: 'error', text: `${ext.manifest.displayName || ext.id} failed to start: ${e && e.message ? e.message : e}` });
    }
    return ext.exports;
  })();
  return ext.active;
}

let vscodeHooked = false;
/** Requires a Node.js extension's main file, giving it this vscode API for require('vscode'). */
function nodeLoad(file) {
  const Module = nodeRequire('module');
  if (!vscodeHooked) {
    vscodeHooked = true;
    const load = Module._load;
    Module._load = function (request, ...rest) {
      if (request === 'vscode') return vscode;
      if ((request === 'child_process' || request === 'node:child_process') && globalThis.__childProcessShim) return globalThis.__childProcessShim;
      return load.call(this, request, ...rest);
    };
  }
  return nodeRequire(file);
}

function activateFor(event) {
  const work = [];
  for (const ext of extensions.values()) {
    const events = ext.manifest.activationEvents || [];
    const c = ext.manifest.contributes || {};
    // VS Code adds these by itself (since 1.74): a contributed command, language, view or custom
    // editor activates its extension when it's used.
    const implicit = [
      ...(c.commands || []).map((x) => 'onCommand:' + x.command),
      ...(c.languages || []).map((x) => 'onLanguage:' + x.id),
      ...Object.values(c.views || {}).flat().map((x) => 'onView:' + x.id),
      ...(c.customEditors || []).map((x) => 'onCustomEditor:' + x.viewType),
      ...(c.authentication || []).map((x) => 'onAuthenticationRequest:' + x.id),
    ];
    if (events.includes(event) || implicit.includes(event) || events.includes('*')) work.push(activate(ext));
  }
  return Promise.all(work);
}

/** workspaceContains:<glob> activation: an extension starts when the project has a matching file. */
async function activateForWorkspaceContents() {
  const work = [];
  for (const ext of extensions.values()) {
    const patterns = (ext.manifest.activationEvents || []).filter((e) => e.startsWith('workspaceContains:')).map((e) => e.slice(18));
    if (!patterns.length) continue;
    work.push((async () => {
      for (const pattern of patterns) {
        const found = await request('findFiles', { pattern, maxResults: 1 }).catch(() => []);
        if (found && found.length) { await activate(ext); return; }
      }
    })());
  }
  await Promise.all(work);
}

// MARK: - Files, watchers and secrets

const fileWatchers = new Set();   // { re, events: { create, change, delete }, ignore }
const onDidCreateFiles = new EventEmitter();
const onDidDeleteFiles = new EventEmitter();
const onDidRenameFiles = new EventEmitter();
const onWillSaveTextDocument = new EventEmitter();

function watcherPattern(pattern) {
  const glob = typeof pattern === 'string' ? pattern : pattern?.pattern || '**/*';
  const base = typeof pattern === 'object' && pattern?.base ? (typeof pattern.base === 'string' ? pattern.base : pattern.base.uri?.path || pattern.base.path) : '';
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
  return { re: new RegExp('(^|/)' + re + '$'), base };
}

/** A file was created, changed or deleted (by an extension, the editor or the app): watchers hear. */
function fileEvent(kind, uri) {
  const path = uri.path;
  for (const w of fileWatchers) {
    if (w.base && !path.startsWith(w.base)) continue;
    if (!w.re.test(path)) continue;
    if (w.ignore[kind]) continue;
    w.events[kind].fire(uri);
  }
}

function createFileSystemWatcher(pattern, ignoreCreate = false, ignoreChange = false, ignoreDelete = false) {
  const { re, base } = watcherPattern(pattern);
  const watcher = { re, base, ignore: { create: ignoreCreate, change: ignoreChange, delete: ignoreDelete },
    events: { create: new EventEmitter(), change: new EventEmitter(), delete: new EventEmitter() } };
  fileWatchers.add(watcher);
  return {
    ignoreCreateEvents: ignoreCreate, ignoreChangeEvents: ignoreChange, ignoreDeleteEvents: ignoreDelete,
    onDidCreate: watcher.events.create.event, onDidChange: watcher.events.change.event, onDidDelete: watcher.events.delete.event,
    dispose: () => fileWatchers.delete(watcher),
  };
}

/** context.secrets: kept by the app (in the iOS Keychain), per extension. */
function secretStorage(id) {
  const changed = new EventEmitter();
  return {
    get: (key) => request('secret', { op: 'get', id, key }).then((v) => v ?? undefined, () => undefined),
    store: (key, value) => request('secret', { op: 'store', id, key, value: String(value) }).then(() => changed.fire({ key })),
    delete: (key) => request('secret', { op: 'delete', id, key }).then(() => changed.fire({ key })),
    keys: () => request('secret', { op: 'keys', id }).then((v) => v || [], () => []),
    onDidChange: changed.event,
  };
}

// MARK: - Terminals

const terminals = [];
const onDidOpenTerminal = new EventEmitter();
const onDidCloseTerminal = new EventEmitter();
const onDidChangeActiveTerminal = new EventEmitter();
let terminalId = 0;

/** An extension's terminal: commands it sends run in a Terminal tab (the app's shell); a
 * pseudoterminal's output goes to an Output channel of the terminal's name. */
function createTerminal(a, b, c) {
  const options = typeof a === 'object' && a ? a : { name: a, shellPath: b, shellArgs: c };
  const name = options.name || 'Terminal';
  const id = ++terminalId;
  let fresh = true;
  const terminal = {
    name, creationOptions: options, processId: Promise.resolve(undefined), exitStatus: undefined,
    state: { isInteractedWith: false, shell: undefined }, shellIntegration: undefined,
    sendText(text, addNewLine = true) {
      request('terminalSend', { text: String(text), fresh, name }).catch(() => {});
      fresh = false;
      terminal.state = { ...terminal.state, isInteractedWith: true };
      void addNewLine;
    },
    show() { request('terminalShow', {}).catch(() => {}); },
    hide() {},
    dispose() {
      const i = terminals.indexOf(terminal);
      if (i >= 0) { terminals.splice(i, 1); onDidCloseTerminal.fire(terminal); }
    },
  };
  const pty = options.pty;
  if (pty) {
    const channel = outputChannel(name);
    if (pty.onDidWrite) pty.onDidWrite((data) => channel.append(String(data).replace(/\x1b\[[0-9;?]*[A-Za-z]/g, '').replace(/\r\n?/g, '\n')));
    if (pty.onDidClose) pty.onDidClose((code) => { terminal.exitStatus = { code, reason: 4 }; terminal.dispose(); });
    terminal.sendText = (text) => { if (pty.handleInput) pty.handleInput(String(text) + '\r'); };
    terminal.show = () => channel.show(true);
    Promise.resolve().then(() => pty.open && pty.open({ columns: 80, rows: 24 }));
  }
  terminals.push(terminal);
  onDidOpenTerminal.fire(terminal);
  onDidChangeActiveTerminal.fire(terminal);
  void id;
  return terminal;
}

// MARK: - Quick picks and input boxes

/** window.createQuickPick: shown with the items it has when show() is called (or once they arrive,
 * while it's busy loading them); accepting fires onDidAccept with selectedItems set. */
function createQuickPick() {
  const accept = new EventEmitter(), hide = new EventEmitter(), changeValue = new EventEmitter(), changeActive = new EventEmitter();
  const changeSelection = new EventEmitter(), trigger = new EventEmitter(), triggerItem = new EventEmitter();
  let shown = false, waiting = 0, disposed = false;
  const pick = {
    title: undefined, step: undefined, totalSteps: undefined, enabled: true, busy: false, ignoreFocusOut: false,
    placeholder: undefined, value: '', items: [], activeItems: [], selectedItems: [], canSelectMany: false,
    matchOnDescription: false, matchOnDetail: false, keepScrollPosition: false, buttons: [], sortByLabel: true,
    onDidAccept: accept.event, onDidHide: hide.event, onDidChangeValue: changeValue.event, onDidChangeActive: changeActive.event,
    onDidChangeSelection: changeSelection.event, onDidTriggerButton: trigger.event, onDidTriggerItemButton: triggerItem.event,
    async show() {
      if (shown || disposed) return;
      shown = true;
      // Items still loading: wait for them (up to a few seconds).
      while (!pick.items.length && waiting < 40 && !disposed) { waiting++; await new Promise((r) => setTimeout(r, 100)); }
      const list = pick.items.filter((x) => x.kind !== -1);
      const chosen = await request('quickPick', {
        items: list.map((x) => ({ label: x.label, description: x.description, detail: x.detail, picked: !!x.picked })),
        placeholder: pick.placeholder || pick.title || '', canPickMany: !!pick.canSelectMany, value: pick.value,
      });
      shown = false;
      if (chosen == null) { hide.fire(); return; }
      pick.selectedItems = Array.isArray(chosen) ? chosen.map((i) => list[i]) : [list[chosen]];
      pick.activeItems = pick.selectedItems;
      changeSelection.fire(pick.selectedItems);
      accept.fire();
    },
    hide() { request('closeQuickInput', {}).catch(() => {}); },
    dispose() { disposed = true; },
  };
  return pick;
}

function createInputBox() {
  const accept = new EventEmitter(), hide = new EventEmitter(), changeValue = new EventEmitter(), trigger = new EventEmitter();
  let disposed = false;
  const box = {
    title: undefined, step: undefined, totalSteps: undefined, enabled: true, busy: false, ignoreFocusOut: false,
    value: '', valueSelection: undefined, placeholder: undefined, password: false, prompt: undefined,
    validationMessage: undefined, buttons: [],
    onDidAccept: accept.event, onDidHide: hide.event, onDidChangeValue: changeValue.event, onDidTriggerButton: trigger.event,
    async show() {
      if (disposed) return;
      const value = await request('inputBox', {
        prompt: [box.validationMessage?.message ?? box.validationMessage, box.prompt || box.title].filter(Boolean).join(' — '),
        value: box.value || '', placeholder: box.placeholder || '', password: !!box.password,
      });
      if (value == null) { hide.fire(); return; }
      box.value = value;
      changeValue.fire(value);
      accept.fire();
    },
    hide() { request('closeQuickInput', {}).catch(() => {}); },
    dispose() { disposed = true; },
  };
  return box;
}

// MARK: - Progress

let progressId = 0;

/** window.withProgress: the title, message and percentage in the status bar (tap to cancel). */
async function withProgress(options, task) {
  const id = `${HOST}-progress-${++progressId}`;
  const source = new CancellationTokenSource();
  progressCancels.set(id, source);
  let done = 0;
  let text = '';
  const show = () => notify('progress', { id, title: options.title || '', message: text, percent: done ? Math.round(done) : null, cancellable: !!options.cancellable });
  show();
  try {
    return await task({ report(update) { if (update.message !== undefined) text = update.message; if (update.increment) done = Math.min(100, done + update.increment); show(); } }, source.token);
  } finally {
    progressCancels.delete(id);
    notify('progress', { id, done: true });
  }
}
const progressCancels = new Map();

// MARK: - Source control

const sourceControls = new Set();

function createSourceControl(id, label, rootUri) {
  const groups = [];
  const control = {
    id, label, rootUri,
    inputBox: { value: '', placeholder: '', enabled: true, visible: true, validateInput: undefined },
    count: undefined, quickDiffProvider: undefined, commitTemplate: undefined, acceptInputCommand: undefined, statusBarCommands: undefined,
    createResourceGroup(groupId, groupLabel) {
      const group = { id: groupId, label: groupLabel, resourceStates: [], hideWhenEmpty: false, contextValue: undefined, dispose() { groups.splice(groups.indexOf(group), 1); } };
      groups.push(group);
      return group;
    },
    dispose() { sourceControls.delete(control); },
  };
  sourceControls.add(control);
  return control;
}

// MARK: - Tests, comments, chat and language models

/** Test controllers keep their items so extensions work; the app doesn't show a Testing view yet. */
function itemCollection() {
  const items = new Map();
  return {
    get size() { return items.size; },
    add(item) { items.set(item.id, item); },
    delete(id) { items.delete(id); },
    get: (id) => items.get(id),
    replace(list) { items.clear(); for (const item of list) items.set(item.id, item); },
    forEach(fn) { items.forEach((item) => fn(item, this)); },
    [Symbol.iterator]() { return [...items.entries()][Symbol.iterator](); },
  };
}

function createTestController(id, label) {
  const runs = [];
  return {
    id, label, items: itemCollection(), resolveHandler: undefined, refreshHandler: undefined, invalidateTestResults() {},
    createRunProfile(profileLabel, kind, runHandler, isDefault = false, tag, supportsContinuousRun = false) {
      return { label: profileLabel, kind, runHandler, isDefault, tag, supportsContinuousRun, configureHandler: undefined, onDidChangeDefault: new EventEmitter().event, dispose() {} };
    },
    createTestItem(itemId, itemLabel, uri) {
      return { id: itemId, label: itemLabel, uri, children: itemCollection(), parent: undefined, tags: [], canResolveChildren: false, busy: false, range: undefined, error: undefined, description: undefined, sortText: undefined };
    },
    createTestRun(request, name, persist = true) {
      const output = outputChannel('Test Results');
      const run = {
        name, token: noCancel, isPersisted: persist,
        enqueued() {}, started(t) { output.appendLine(`▶ ${t.label}`); }, skipped(t) { output.appendLine(`○ ${t.label} skipped`); },
        passed(t, ms) { output.appendLine(`✓ ${t.label}${ms != null ? ` (${Math.round(ms)} ms)` : ''}`); },
        failed(t, messages) { output.appendLine(`✗ ${t.label}: ${[].concat(messages || []).map((m) => plainText(m.message)).join('; ')}`); },
        errored(t, messages) { output.appendLine(`⚠ ${t.label}: ${[].concat(messages || []).map((m) => plainText(m.message)).join('; ')}`); },
        appendOutput(text) { output.append(String(text).replace(/\r\n/g, '\n')); }, addCoverage() {},
        end() {}, onDidDispose: new EventEmitter().event,
      };
      runs.push(run);
      return run;
    },
    dispose() {},
  };
}

function createCommentController(id, label) {
  return {
    id, label, options: undefined, commentingRangeProvider: undefined, reactionHandler: undefined,
    createCommentThread(uri, range, comments) {
      return { uri, range, comments, collapsibleState: 0, canReply: true, contextValue: undefined, label: undefined, state: 0, dispose() {} };
    },
    dispose() {},
  };
}

// MARK: - The vscode namespace

// Output channels show in the page's Output panel, one channel per name.
const outputChannels = new Map();
function outputChannel(name) {
  if (!outputChannels.has(name)) {
    const send = (op, text = '') => notify('output', { channel: name, op, text: String(text) });
    const line = (level) => (message, ...args) => send('append', `${new Date().toISOString().replace('T', ' ').slice(0, 23)} [${level}] ${[message, ...args].map((x) => (x instanceof Error ? x.stack || x.message : typeof x === 'string' ? x : JSON.stringify(x))).join(' ')}\n`);
    const channel = {
      name,
      append: (text) => send('append', text),
      appendLine: (text) => send('append', text + '\n'),
      replace: (text) => send('replace', text),
      clear: () => send('clear'),
      show: (a, b) => send('show', typeof a === 'boolean' ? a : !!b),
      hide() {},
      dispose: () => { outputChannels.delete(name); send('dispose'); },
      trace: line('trace'), debug: line('debug'), info: line('info'), warn: line('warning'), error: line('error'),
      logLevel: 3, onDidChangeLogLevel: new EventEmitter().event,
    };
    outputChannels.set(name, channel);
  }
  return outputChannels.get(name);
}

let statusItemId = 0;
function createStatusBarItem(a, b) {
  const id = `${HOST}-status-${++statusItemId}`;
  // (alignment, priority) or (id, alignment, priority).
  const item = typeof a === 'string'
    ? { id, text: '', tooltip: '', command: undefined, alignment: b || 1, priority: arguments[2], visible: false, name: undefined }
    : { id, text: '', tooltip: '', command: undefined, alignment: a || 1, priority: b, visible: false, name: undefined };
  const update = () => notify('statusItem', {
    id, text: item.visible ? item.text : '', tooltip: String(item.tooltip?.value ?? item.tooltip ?? ''),
    command: typeof item.command === 'string' ? item.command : item.command?.command,
    args: typeof item.command === 'object' && item.command?.arguments ? JSON.parse(JSON.stringify(item.command.arguments)) : [],
    alignment: item.alignment, priority: item.priority ?? 0,
    color: item.color && typeof item.color === 'object' ? item.color.id : item.color,
    background: item.backgroundColor && item.backgroundColor.id,
  });
  return new Proxy(item, {
    get(t, k) {
      if (k === 'show') return () => { t.visible = true; update(); };
      if (k === 'hide') return () => { t.visible = false; update(); };
      if (k === 'dispose') return () => { t.visible = false; update(); if (t.onDispose) t.onDispose(); };
      return t[k];
    },
    set(t, k, v) { t[k] = v; if (t.visible) update(); return true; },
  });
}

function message(severity) {
  return async (text, ...rest) => {
    const items = rest.filter((x) => typeof x === 'string' || (x && x.title));
    const chosen = await request('message', { severity, text: String(text), items: items.map((x) => (typeof x === 'string' ? x : x.title)) });
    return chosen == null ? undefined : items[chosen];
  };
}

const api = {
  version: '1.95.0',
  Disposable, EventEmitter, CancellationTokenSource, Position, Range, Selection, Uri, TextEdit, WorkspaceEdit, MarkdownString, SnippetString,
  CompletionItem, CompletionItemKind, CompletionList, Hover, Diagnostic, DiagnosticSeverity, Location, SymbolKind, DocumentSymbol, SymbolInformation,
  ThemeColor, ThemeIcon, CodeAction, CodeActionKind, DocumentDropOrPasteEditKind, DocumentDropEdit, DocumentPasteEdit, SignatureHelp, SignatureInformation, ParameterInformation, FoldingRange, Color, ColorInformation,
  DocumentLink, InlayHint, TreeItem, RelativePattern,
  SemanticTokensLegend, SemanticTokens, SemanticTokensBuilder, SemanticTokensEdit, SemanticTokensEdits, CodeLens, DocumentHighlight,
  SelectionRange, CallHierarchyItem, TypeHierarchyItem, InlineCompletionItem, InlineCompletionList, LinkedEditingRanges, ColorPresentation,
  EvaluatableExpression, InlayHintLabelPart, SnippetTextEdit, TextDocumentEdit, DataTransfer, DataTransferItem, TaskGroup, Task,
  ShellExecution, ProcessExecution, CustomExecution, Breakpoint, SourceBreakpoint, FunctionBreakpoint, DebugAdapterExecutable,
  DebugAdapterInlineImplementation, FileSystemError, TestMessage, TabInputText, TabInputTextDiff, TabInputCustom, TabInputWebview, TabInputNotebook,
  TabInputNotebookDiff, TabInputTerminal, TabInputInteractiveWindow, QuickInputButtons,
  NotebookCellOutputItem, NotebookCellOutput, NotebookCellData, NotebookData, NotebookRange, NotebookEdit,
  DiagnosticRelatedInformation, CancellationError, FileDecoration, CallHierarchyIncomingCall, CallHierarchyOutgoingCall, TerminalLink,
  TerminalProfile, TimelineItem, TelemetryTrustedValue, DebugAdapterServer, DebugAdapterNamedPipeServer, TestTag, TestRunRequest,
  TestCoverageCount, LanguageModelError, LanguageModelTextPart, LanguageModelChatMessage,
  TreeItemCheckboxState: { Unchecked: 0, Checked: 1 },
  NotebookCellKind: { Markup: 1, Code: 2 },
  NotebookEditorRevealType: { Default: 0, InCenter: 1, InCenterIfOutsideViewport: 2, AtTop: 3 },
  NotebookCellExecutionState: { Idle: 1, Pending: 2, Executing: 3 },
  NotebookControllerAffinity: { Default: 1, Preferred: 2 },
  NotebookCellStatusBarAlignment: { Left: 1, Right: 2 },
  TaskScope: { Global: 1, Workspace: 2 },
  ShellQuoting: { Escape: 1, Strong: 2, Weak: 3 },
  CommentMode: { Editing: 0, Preview: 1 },
  TestRunProfileKind: { Run: 1, Debug: 2, Coverage: 3 },
  ...enums,
  commands: {
    registerCommand(name, fn, thisArg) { commands.set(name, { fn, thisArg }); return new Disposable(() => commands.delete(name)); },
    // The edits the command makes with its edit builder are applied when it returns.
    registerTextEditorCommand(name, fn, thisArg) {
      commands.set(name, {
        fn: async (...args) => {
          if (!activeEditor) return undefined;
          const edits = [];
          const builder = {
            replace: (r, t) => edits.push({ range: r instanceof Position ? new Range(r, r) : r, newText: t }),
            insert: (p, t) => edits.push({ range: new Range(p, p), newText: t }),
            delete: (r) => edits.push({ range: r, newText: '' }),
            setEndOfLine() {},
          };
          const result = await fn.call(thisArg, activeEditor, builder, ...args);
          if (edits.length) await request('applyEdit', { changes: [{ uri: activeEditor.document.uri.toString(), edits }] });
          return result;
        },
      });
      return new Disposable(() => commands.delete(name));
    },
    executeCommand: (name, ...args) => executeCommand(name, args),
    async getCommands(filterInternal) {
      const contributed = [...extensions.values()].flatMap((ext) => (ext.manifest.contributes?.commands || []).map((c) => c.command));
      const builtins = (await request('builtinCommandList', {}).catch(() => [])) || [];
      const all = [...new Set([...commands.keys(), ...contributed, ...builtins])];
      return filterInternal ? all.filter((c) => !c.startsWith('_')) : all;
    },
  },
  window: {
    showInformationMessage: message('info'),
    showWarningMessage: message('warning'),
    showErrorMessage: message('error'),
    async showQuickPick(items, options = {}) {
      // Separators (kind -1) aren't choices.
      const list = (await items).filter((x) => typeof x === 'string' || x.kind !== -1);
      const labels = list.map((x) => (typeof x === 'string' ? { label: x } : { label: x.label, description: x.description, detail: x.detail, picked: !!x.picked }));
      const chosen = await request('quickPick', { items: labels, placeholder: options.placeHolder || options.title || '', canPickMany: !!options.canPickMany });
      if (chosen == null) return undefined;
      const picked = Array.isArray(chosen) ? chosen.map((i) => list[i]) : list[chosen];
      if (options.onDidSelectItem && !Array.isArray(picked)) options.onDidSelectItem(picked);
      return picked;
    },
    // validateInput: asked again, with the problem shown, until the value is fine or it's cancelled.
    async showInputBox(options = {}) {
      let value = options.value || '';
      let problem = '';
      for (;;) {
        const answer = await request('inputBox', { prompt: [problem, options.prompt || options.title || ''].filter(Boolean).join(' — '), value, placeholder: options.placeHolder || '', password: !!options.password });
        if (answer == null) return undefined;
        if (!options.validateInput) return answer;
        const result = await options.validateInput(answer);
        const text = typeof result === 'string' ? result : result?.message;
        // Warnings and information don't stop it.
        if (!text || (typeof result === 'object' && result.severity && result.severity < 3)) return answer;
        problem = '⚠ ' + text;
        value = answer;
      }
    },
    createQuickPick,
    createInputBox,
    async showOpenDialog(options = {}) {
      const folders = options.canSelectFolders && !options.canSelectFiles;
      const files = (await request('findFiles', { pattern: '**/*' }).catch(() => [])) || [];
      const filters = Object.values(options.filters || {}).flat().map((x) => '.' + String(x).toLowerCase());
      const choices = folders ? [...new Set(files.map((f) => f.split('/').slice(0, -1).join('/')).filter(Boolean))].sort()
        : files.filter((f) => !filters.length || filters.some((x) => f.toLowerCase().endsWith(x)));
      const chosen = await request('quickPick', { items: [...(folders ? ['.'] : []), ...choices].map((label) => ({ label })), placeholder: options.title || options.openLabel || 'Open', canPickMany: !!options.canSelectMany });
      if (chosen == null) return undefined;
      const all = [...(folders ? ['.'] : []), ...choices];
      return [].concat(chosen).map((i) => Uri.file(workspaceRoot + (all[i] === '.' ? '' : '/' + all[i])));
    },
    async showSaveDialog(options = {}) {
      const suggested = options.defaultUri ? vscode.workspace.asRelativePath(options.defaultUri) : '';
      const path = await request('inputBox', { prompt: options.title || options.saveLabel || 'Save as (a path in the project)', value: suggested, placeholder: 'folder/file.txt' });
      return path ? Uri.file(workspaceRoot + '/' + String(path).replace(/^\/+/, '')) : undefined;
    },
    showWorkspaceFolderPick: async () => vscode.workspace.workspaceFolders[0],
    get terminals() { return [...terminals]; },
    get activeTerminal() { return terminals[terminals.length - 1]; },
    onDidOpenTerminal: onDidOpenTerminal.event,
    onDidCloseTerminal: onDidCloseTerminal.event,
    onDidChangeActiveTerminal: onDidChangeActiveTerminal.event,
    onDidChangeTerminalState: new EventEmitter().event,
    onDidChangeTerminalShellIntegration: new EventEmitter().event,
    onDidStartTerminalShellExecution: new EventEmitter().event,
    onDidEndTerminalShellExecution: new EventEmitter().event,
    visibleNotebookEditors: [],
    activeNotebookEditor: undefined,
    onDidChangeVisibleNotebookEditors: new EventEmitter().event,
    onDidChangeActiveNotebookEditor: new EventEmitter().event,
    createOutputChannel: (name) => outputChannel(name),
    createStatusBarItem,
    setStatusBarMessage(text, timeout) {
      const item = createStatusBarItem();
      item.text = text; item.show();
      const d = new Disposable(() => item.hide());
      if (typeof timeout === 'number') setTimeout(() => d.dispose(), timeout);
      else if (timeout && timeout.then) timeout.then(() => d.dispose());
      return d;
    },
    withProgress,
    get activeTextEditor() { return activeEditor; },
    get visibleTextEditors() { return activeEditor ? [activeEditor] : []; },
    onDidChangeActiveTextEditor: onDidChangeActiveTextEditor.event,
    onDidChangeVisibleTextEditors: onDidChangeVisibleTextEditors.event,
    onDidChangeTextEditorSelection: onDidChangeTextEditorSelection.event,
    onDidChangeTextEditorVisibleRanges: new EventEmitter().event,
    onDidChangeWindowState: new EventEmitter().event,
    state: { focused: true, active: true },
    get activeColorTheme() { return { kind: themeKind }; },
    onDidChangeActiveColorTheme: onDidChangeActiveColorTheme.event,
    createTextEditorDecorationType(options) {
      const key = HOST + '-dec-' + (++decorationTypeId);
      notify('decorationType', { key, options: plainOptions(options) });
      return { key, dispose: () => notify('decorationType', { key, options: null }) };
    },
    async showTextDocument(doc, options) {
      const uri = (doc.uri || doc).toString();
      // A virtual document (a content provider's): shown read-only.
      if (!uri.startsWith('file:')) {
        const virtual = doc.getText ? doc : await vscode.workspace.openTextDocument(doc);
        await request('showVirtualDocument', { uri, text: virtual.getText(), languageId: virtual.languageId });
        return activeEditor;
      }
      await request('openFile', { uri });
      const selection = options && !(typeof options === 'number') ? options.selection : undefined;
      if (selection && activeEditor) activeEditor.selection = new Selection(selection.start, selection.end);
      return activeEditor;
    },
    registerTreeDataProvider: (viewId, provider) => { const view = createTreeView(viewId, { treeDataProvider: provider }); return new Disposable(() => view.dispose()); },
    createTreeView,
    registerWebviewViewProvider(viewId, provider, options) {
      webviewViewProviders.set(viewId, { provider, options: options || {} });
      notify('viewsChanged', {});
      return new Disposable(() => webviewViewProviders.delete(viewId));
    },
    registerCustomEditorProvider(viewType, provider, options) {
      customEditorProviders.set(viewType, { provider, options: options || {} });
      return new Disposable(() => customEditorProviders.delete(viewType));
    },
    registerUriHandler: () => new Disposable(),
    createWebviewPanel: (viewType, title, showOptions, options) => createWebviewPanel(viewType, title, options),
    createTerminal,
    tabGroups: {
      get all() { return [tabGroup()]; },
      get activeTabGroup() { return tabGroup(); },
      onDidChangeTabs: onDidChangeTabs.event,
      onDidChangeTabGroups: new EventEmitter().event,
      close: async () => true,
    },
  },
  workspace: {
    get workspaceFolders() { return [{ uri: Uri.file(workspaceRoot), name: workspaceRoot.split('/').pop(), index: 0 }]; },
    get rootPath() { return workspaceRoot; },
    get name() { return workspaceRoot.split('/').pop(); },
    getWorkspaceFolder: () => vscode.workspace.workspaceFolders[0],
    get textDocuments() { return [...documents.values()]; },
    notebookDocuments: [],
    getConfiguration,
    onDidChangeConfiguration: onDidChangeConfiguration.event,
    onDidOpenTextDocument: onDidOpenTextDocument.event,
    onDidCloseTextDocument: onDidCloseTextDocument.event,
    onDidChangeTextDocument: onDidChangeTextDocument.event,
    onDidSaveTextDocument: onDidSaveTextDocument.event,
    onWillSaveTextDocument: onWillSaveTextDocument.event,
    onDidChangeWorkspaceFolders: new EventEmitter().event,
    onDidCreateFiles: onDidCreateFiles.event,
    onDidDeleteFiles: onDidDeleteFiles.event,
    onDidRenameFiles: onDidRenameFiles.event,
    onWillCreateFiles: new EventEmitter().event,
    onWillDeleteFiles: new EventEmitter().event,
    onWillRenameFiles: new EventEmitter().event,
    async openTextDocument(arg) {
      if (arg && arg.content !== undefined) return new TextDocument(Uri.parse('untitled:Untitled'), arg.language || 'plaintext', arg.content, 1);
      const uri = typeof arg === 'string' ? Uri.file(arg) : arg;
      const open = documents.get(uri.toString());
      if (open) return open;
      // A virtual document from an extension's content provider.
      const provider = contentProviders.get(uri.scheme);
      if (provider) {
        const text = (await provider.provideTextDocumentContent(uri, noCancel)) || '';
        const doc = new TextDocument(uri, languageFor(uri.path), text, 1);
        documents.set(uri.toString(), doc);
        onDidOpenTextDocument.fire(doc);
        return doc;
      }
      const { text, languageId } = await request('readDocument', { uri: uri.toString() });
      return new TextDocument(uri, languageId, text, 1);
    },
    async applyEdit(edit) {
      // File operations first, in order, then text edits.
      for (const op of edit._files || []) {
        const fs = vscode.workspace.fs;
        try {
          if (op.op === 'create') {
            const exists = await fs.stat(op.uri).then(() => true, () => false);
            if (exists && op.options.ignoreIfExists) continue;
            if (exists && !op.options.overwrite) return false;
            await fs.writeFile(op.uri, op.options.contents || new Uint8Array());
          } else if (op.op === 'delete') {
            const exists = await fs.stat(op.uri).then(() => true, () => false);
            if (!exists) { if (op.options.ignoreIfNotExists) continue; return false; }
            await fs.delete(op.uri, { recursive: !!op.options.recursive });
          } else if (op.op === 'rename') {
            if (!op.options.overwrite && await fs.stat(op.to).then(() => true, () => false)) { if (op.options.ignoreIfExists) continue; return false; }
            await fs.rename(op.uri, op.to, { overwrite: !!op.options.overwrite });
            onDidRenameFiles.fire({ files: [{ oldUri: op.uri, newUri: op.to }] });
          }
        } catch (e) {
          return false;
        }
      }
      const changes = edit.entries().map(([uri, edits]) => ({ uri: uri.toString(), edits: edits.map((e) => ({ range: e.range, newText: e.newText })) }));
      if (!changes.length) return true;
      const result = await request('applyEdit', { changes });
      for (const uri of (result && result.written) || []) {
        const doc = documents.get(uri);
        const change = changes.find((c) => c.uri === uri);
        if (doc && change) applyToDocument(doc, change.edits);
      }
      return !!result;
    },
    async findFiles(include, exclude, maxResults) {
      const pattern = typeof include === 'string' ? include : include?.pattern || '**/*';
      const base = typeof include === 'object' && include?.base ? (typeof include.base === 'string' ? include.base : include.base.uri?.path || include.base.path) : '';
      const prefix = base && base.startsWith(workspaceRoot + '/') ? base.slice(workspaceRoot.length + 1) + '/' : '';
      const excludePattern = typeof exclude === 'string' ? exclude : exclude?.pattern;
      let paths = await request('findFiles', { pattern: prefix + pattern, exclude: excludePattern || null });
      if (maxResults) paths = paths.slice(0, maxResults);
      return paths.map((p) => Uri.file(workspaceRoot + '/' + p));
    },
    async save(uri) { await request('save', { uri: uri.toString() }); return uri; },
    async saveAll() { await request('save', {}); return true; },
    async saveAs(uri) { return vscode.window.showSaveDialog({ defaultUri: uri }); },
    updateWorkspaceFolders: () => false,
    workspaceFile: undefined,
    decode: async (content) => new TextDecoder().decode(content),
    encode: async (text) => new TextEncoder().encode(text),
    asRelativePath(x) { const p = typeof x === 'string' ? x : x.path; return p.startsWith(workspaceRoot + '/') ? p.slice(workspaceRoot.length + 1) : p; },
    createFileSystemWatcher,
    registerTextDocumentContentProvider(scheme, provider) {
      contentProviders.set(scheme, provider);
      // A changed virtual document is read again.
      const changes = provider.onDidChange && provider.onDidChange(async (uri) => {
        const doc = documents.get(uri.toString());
        if (!doc) return;
        const text = (await provider.provideTextDocumentContent(uri, noCancel)) || '';
        const oldEnd = doc.positionAt(doc._text.length);
        const oldLength = doc._text.length;
        doc._set(text);
        doc.version++;
        onDidChangeTextDocument.fire({ document: doc, contentChanges: [{ range: new Range(new Position(0, 0), oldEnd), rangeOffset: 0, rangeLength: oldLength, text }], reason: undefined });
      });
      return new Disposable(() => { contentProviders.delete(scheme); if (changes) changes.dispose(); });
    },
    registerFileSystemProvider: () => new Disposable(),
    isTrusted: true,
    onDidGrantWorkspaceTrust: new EventEmitter().event,
    fs: {
      readFile: async (uri) => {
        if (nodeFs) return new Uint8Array(await nodeFs.readFile(uri.fsPath));
        const own = extensionFile(uri);
        if (own) return own;
        const base64 = await request('fs', { op: 'read', uri: uri.toString() });
        return Uint8Array.from(atob(base64), (c) => c.charCodeAt(0));
      },
      writeFile: async (uri, bytes) => {
        const existed = await vscode.workspace.fs.stat(uri).then(() => true, () => false);
        if (nodeFs) await nodeFs.mkdir(nodeRequire('path').dirname(uri.fsPath), { recursive: true }).then(() => nodeFs.writeFile(uri.fsPath, bytes));
        else {
          let binary = '';
          for (const b of bytes) binary += String.fromCharCode(b);
          await request('fs', { op: 'write', uri: uri.toString(), base64: btoa(binary) });
        }
        fileEvent(existed ? 'change' : 'create', uri);
        if (!existed) onDidCreateFiles.fire({ files: [uri] });
      },
      stat: async (uri) => {
        if (nodeFs) {
          const st = await nodeFs.stat(uri.fsPath);
          return { type: st.isDirectory() ? enums.FileType.Directory : enums.FileType.File, size: st.size, ctime: st.ctimeMs, mtime: st.mtimeMs };
        }
        if (uri.path.startsWith(EXTENSIONS_ROOT + '/')) {
          await vscode.workspace.fs.readFile(uri);
          return { type: enums.FileType.File, size: 0, ctime: 0, mtime: 0 };
        }
        return request('fs', { op: 'stat', uri: uri.toString() });
      },
      readDirectory: async (uri) => {
        if (!nodeFs) return request('fs', { op: 'list', uri: uri.toString() });
        const entries = await nodeFs.readdir(uri.fsPath, { withFileTypes: true });
        return entries.map((e) => [e.name, e.isDirectory() ? enums.FileType.Directory : enums.FileType.File]);
      },
      createDirectory: (uri) => (nodeFs ? nodeFs.mkdir(uri.fsPath, { recursive: true }) : request('fs', { op: 'mkdir', uri: uri.toString() })),
      delete: async (uri, options) => {
        await (nodeFs ? nodeFs.rm(uri.fsPath, { recursive: !!(options && options.recursive), force: false }) : request('fs', { op: 'delete', uri: uri.toString() }));
        fileEvent('delete', uri);
        onDidDeleteFiles.fire({ files: [uri] });
      },
      rename: async (from, to) => {
        await (nodeFs ? nodeFs.rename(from.fsPath, to.fsPath) : request('fs', { op: 'rename', uri: from.toString(), to: to.toString() }));
        fileEvent('delete', from);
        fileEvent('create', to);
      },
      // Folders too, file by file.
      copy: async (from, to) => {
        const st = await vscode.workspace.fs.stat(from);
        if (st.type !== enums.FileType.Directory) return vscode.workspace.fs.writeFile(to, await vscode.workspace.fs.readFile(from));
        await vscode.workspace.fs.createDirectory(to);
        for (const [name] of await vscode.workspace.fs.readDirectory(from)) await vscode.workspace.fs.copy(Uri.joinPath(from, name), Uri.joinPath(to, name));
      },
      isWritableFileSystem: () => true,
    },
  },
  languages: {
    registerCompletionItemProvider: (sel, provider, ...triggers) => addProvider('completion', sel, provider, { triggers }),
    registerHoverProvider: (sel, provider) => addProvider('hover', sel, provider),
    registerDocumentFormattingEditProvider: (sel, provider) => addProvider('formatting', sel, provider),
    registerDocumentRangeFormattingEditProvider: (sel, provider) => addProvider('rangeFormatting', sel, provider),
    registerOnTypeFormattingEditProvider: (sel, provider, ...triggers) => addProvider('onTypeFormatting', sel, provider, { triggers }),
    registerDefinitionProvider: (sel, provider) => addProvider('definition', sel, provider),
    registerDocumentSymbolProvider: (sel, provider) => addProvider('symbols', sel, provider),
    registerSignatureHelpProvider: (sel, provider, ...rest) => addProvider('signature', sel, provider,
      rest[0] && typeof rest[0] === 'object' ? { triggers: rest[0].triggerCharacters || [], retriggers: rest[0].retriggerCharacters || [] } : { triggers: rest, retriggers: [] }),
    registerCodeActionsProvider: (sel, provider) => addProvider('codeActions', sel, provider),
    registerColorProvider: (sel, provider) => addProvider('colors', sel, provider),
    registerFoldingRangeProvider: (sel, provider) => addProvider('folding', sel, provider),
    registerDocumentLinkProvider: (sel, provider) => addProvider('links', sel, provider),
    registerReferenceProvider: (sel, provider) => addProvider('references', sel, provider),
    registerRenameProvider: (sel, provider) => addProvider('rename', sel, provider),
    registerDocumentHighlightProvider: (sel, provider) => addProvider('highlights', sel, provider),
    registerInlayHintsProvider: (sel, provider) => addProvider('inlayHints', sel, provider),
    registerCodeLensProvider: (sel, provider) => addProvider('codeLens', sel, provider),
    registerTypeDefinitionProvider: (sel, provider) => addProvider('typeDefinition', sel, provider),
    registerImplementationProvider: (sel, provider) => addProvider('implementation', sel, provider),
    registerWorkspaceSymbolProvider: (provider) => addProvider('workspaceSymbols', '*', provider),
    registerDeclarationProvider: (sel, provider) => addProvider('declaration', sel, provider),
    registerCallHierarchyProvider: (sel, provider) => addProvider('callHierarchy', sel, provider),
    registerTypeHierarchyProvider: (sel, provider) => addProvider('typeHierarchy', sel, provider),
    registerEvaluatableExpressionProvider: () => new Disposable(),
    registerInlineValuesProvider: () => new Disposable(),
    registerLinkedEditingRangeProvider: () => new Disposable(),
    registerDocumentDropEditProvider: () => new Disposable(),
    registerDocumentPasteEditProvider: () => new Disposable(),
    registerDocumentRangeSemanticTokensProvider: () => new Disposable(),
    registerSelectionRangeProvider: (sel, provider) => addProvider('selectionRanges', sel, provider),
    registerDocumentSemanticTokensProvider: (sel, provider, legend) => addProvider('semanticTokens', sel, provider, { legend }),
    registerInlineCompletionItemProvider: (sel, provider) => addProvider('inlineCompletions', sel, provider),
    setLanguageConfiguration: () => new Disposable(),
    async setTextDocumentLanguage(doc, languageId) {
      onDidCloseTextDocument.fire(doc);
      doc.languageId = languageId;
      onDidOpenTextDocument.fire(doc);
      await activateFor('onLanguage:' + languageId);
      return doc;
    },
    createLanguageStatusItem(id, selector) {
      // Shown in the status bar while the open file matches its selector.
      const item = createStatusBarItem(enums.StatusBarAlignment.Right);
      item.selector = selector;
      item.severity = 0;
      item.id = id;
      item.busy = false;
      item.detail = '';
      languageStatusItems.add(item);
      item.onDispose = () => languageStatusItems.delete(item);
      updateLanguageStatus();
      return item;
    },
    getLanguages: async () => request('languages', {}),
    match: (selector, doc) => matches(selector, doc),
    createDiagnosticCollection(name = 'extension') {
      const entries = new Map();
      const owner = HOST + ':' + name + '#' + (++collectionId);
      diagnosticCollections.add(entries);
      const publish = (uri) => {
        const list = entries.get(uri.toString()) || [];
        onDidChangeDiagnostics.fire({ uris: [uri] });
        notify('diagnostics', {
          owner, uri: uri.toString(),
          items: list.map((d) => ({ range: d.range, message: d.message, severity: d.severity ?? 0, source: d.source,
            code: d.code == null ? undefined : String(typeof d.code === 'object' ? d.code.value : d.code), tags: d.tags || [] })),
        });
      };
      return {
        name,
        set(uri, list) {
          if (Array.isArray(uri)) { for (const [u, l] of uri) this.set(u, l); return; }
          entries.set(uri.toString(), list || []); publish(uri);
        },
        delete(uri) { entries.delete(uri.toString()); publish(uri); },
        clear() { for (const key of [...entries.keys()]) { entries.delete(key); publish(Uri.parse(key)); } },
        get: (uri) => entries.get(uri.toString()),
        has: (uri) => entries.has(uri.toString()),
        forEach(fn) { for (const [k, v] of entries) fn(Uri.parse(k), v, this); },
        dispose() { this.clear(); diagnosticCollections.delete(entries); },
      };
    },
    getDiagnostics(uri) {
      if (uri) return [...diagnosticCollections].flatMap((entries) => entries.get(uri.toString()) || []);
      const byUri = new Map();
      for (const entries of diagnosticCollections) {
        for (const [key, list] of entries) byUri.set(key, [...(byUri.get(key) || []), ...list]);
      }
      return [...byUri].map(([key, list]) => [Uri.parse(key), list]);
    },
    onDidChangeDiagnostics: onDidChangeDiagnostics.event,
  },
  env: {
    appName: 'Mobile Studio', appRoot: '/', language: 'en', machineId: 'duocode', sessionId: String(Date.now()), uriScheme: 'duocode',
    uiKind: enums.UIKind.Web, shell: '/bin/sh', remoteName: undefined, isTelemetryEnabled: false,
    appHost: 'desktop', logLevel: 3, onDidChangeLogLevel: new EventEmitter().event, isNewAppInstall: false, isAppPortable: false,
    onDidChangeTelemetryEnabled: new EventEmitter().event,
    clipboard: { readText: () => request('clipboardRead', {}), writeText: (text) => request('clipboardWrite', { text }) },
    openExternal: (uri) => request('openExternal', { uri: uri.toString() }),
    asExternalUri: async (uri) => uri,
    createTelemetryLogger: () => ({ logUsage() {}, logError() {}, dispose() {}, onDidChangeEnableStates: new EventEmitter().event }),
  },
  extensions: {
    getExtension(id) {
      const ext = extensions.get(id.toLowerCase());
      if (!ext) return builtinExtensions().find((b) => b.id === id.toLowerCase());
      const extensionUri = extensionUriOf(ext.id);
      return { id: ext.id, packageJSON: ext.manifest, isActive: !!ext.exports, exports: ext.exports, activate: () => activate(ext), extensionUri, extensionPath: extensionUri.path, extensionKind: 2 };
    },
    get all() { return [...builtinExtensions(), ...[...extensions.keys()].map((id) => vscode.extensions.getExtension(id))]; },
    onDidChange: new EventEmitter().event,
  },
  debug: { activeDebugSession: undefined, onDidStartDebugSession: new EventEmitter().event, onDidTerminateDebugSession: new EventEmitter().event, registerDebugConfigurationProvider: () => new Disposable(), registerDebugAdapterDescriptorFactory: () => new Disposable() },
  tasks: {
    registerTaskProvider(type, provider) { taskProviders.set(type, provider); return new Disposable(() => taskProviders.delete(type)); },
    fetchTasks: async (filter) => (await provideTasks()).filter((t) => !filter?.type || t.definition?.type === filter.type),
    executeTask: async (task) => { const id = rememberTask(task); notify('runTask', { id, label: task.name }); return { task, terminate() {} }; },
    get taskExecutions() { return []; },
    // Getters: the emitters are declared further down.
    get onDidStartTask() { return onDidStartTask.event; },
    get onDidEndTask() { return onDidEndTask.event; },
    onDidStartTaskProcess: new EventEmitter().event,
    get onDidEndTaskProcess() { return onDidEndTaskProcess.event; },
  },
  scm: { createSourceControl, get inputBox() { return [...sourceControls][0]?.inputBox || { value: '' }; } },
  authentication: { getSession: async () => undefined, onDidChangeSessions: new EventEmitter().event },
  // Positional ({0}) and named ({name}) arguments.
  l10n: {
    t(message, ...args) {
      const text = typeof message === 'string' ? message : message.message;
      const values = typeof message === 'object' && message.args ? message.args : args.length === 1 && args[0] && typeof args[0] === 'object' && !Array.isArray(args[0]) ? args[0] : args;
      return String(text).replace(/\{([\w-]+)\}/g, (all, key) => (values[key] === undefined ? all : String(values[key])));
    },
    bundle: undefined,
    uri: undefined,
  },
  tests: { createTestController, createTestObserver: () => ({ tests: [], onDidChangeTest: new EventEmitter().event, dispose() {} }) },
  comments: { createCommentController },
  chat: {
    createChatParticipant: (id, handler) => ({ id, requestHandler: handler, iconPath: undefined, followupProvider: undefined, onDidReceiveFeedback: new EventEmitter().event, dispose() {} }),
  },
  // No language models to lend extensions yet: selectChatModels finds none.
  lm: {
    selectChatModels: async () => [],
    onDidChangeChatModels: new EventEmitter().event,
    tools: [],
    registerTool: () => new Disposable(),
    invokeTool: async () => { throw LanguageModelError.NotFound(); },
    registerMcpServerDefinitionProvider: () => new Disposable(),
  },
  notebooks: { createNotebookController: () => ({ dispose() {} }) },
};

// Parts of the API DuoCode doesn't have yet behave as VS Code does with nothing to show: events
// never fire, registrations return a Disposable and created objects accept any call.
function inert(label) {
  const target = function () { return inert(label); };
  return new Proxy(target, {
    get(t, key) {
      if (key === 'then') return undefined;   // not a thenable
      if (key === 'dispose') return () => {};
      if (key === Symbol.toPrimitive || key === 'toString') return () => '';
      if (typeof key === 'string' && /^on[A-Z]/.test(key)) return new EventEmitter().event;
      return inert(label + '.' + String(key));
    },
    set() { return true; },
    apply() { return inert(label + '()'); },
  });
}

const stubClasses = new Map();

function lenient(namespace, name) {
  return new Proxy(namespace, {
    get(t, key) {
      if (key in t || typeof key !== 'string') return t[key];
      if (/^on(Did|Will)/.test(key)) return new EventEmitter().event;
      if (/^register/.test(key)) return () => new Disposable(() => {});
      if (/^(create|get)/.test(key)) {
        notify('log', { level: 'info', text: `vscode.${name}.${key} isn't supported in Mobile Studio yet` });
        return () => inert(`${name}.${key}`);
      }
      // A class DuoCode doesn't have: construct a plain object holding the arguments.
      if (name === 'vscode' && /^[A-Z]/.test(key)) {
        if (!stubClasses.has(key)) {
          const Stub = class { constructor(...args) { this.args = args; } };
          // Its static members (Kind.Value, or factories like Edit.insertCells) are inert too,
          // so code that calls them keeps going instead of failing with "is not a function".
          stubClasses.set(key, new Proxy(Stub, {
            get: (t, member) => (member in t || typeof member !== 'string' || member === 'then' ? t[member] : inert(key + '.' + member)),
          }));
          notify('log', { level: 'info', text: `vscode.${key} isn't supported in Mobile Studio yet` });
        }
        return stubClasses.get(key);
      }
      return undefined;
    },
  });
}

const vscode = lenient(Object.fromEntries(Object.entries(api).map(([key, value]) => [key,
  value && typeof value === 'object' && !Array.isArray(value) && /^[a-z]/.test(key) ? lenient(value, key) : value])), 'vscode');

// MARK: - Webviews

const webviews = new Map();   // id -> { panel, onMessage }
let webviewId = 0;

/** A webview panel: its HTML shows in a sandboxed frame in the editor, with messages both ways. */
function createWebviewPanel(viewType, title, options = {}) {
  const id = HOST + '-webview-' + (++webviewId);
  const onMessage = new EventEmitter();
  const onDispose = new EventEmitter();
  const onViewState = new EventEmitter();
  let html = '';
  let disposed = false;
  const show = () => notify('webview', { id, title: panel.title, html, viewType, enableScripts: !!(webview.options && webview.options.enableScripts) });
  const webview = {
    options: options || {},
    // The app serves the extension's files at duocode-res://file/<path> (ExtensionResourceSchemeHandler);
    // a test page without it inlines them as data: URLs (webviews.js). A policy built on cspSource lets both in.
    cspSource: 'duocode-res: data:',
    get html() { return html; },
    set html(value) { html = String(value); if (!disposed) show(); },
    onDidReceiveMessage: onMessage.event,
    postMessage: async (message) => { if (!disposed) notify('webviewPost', { id, message: JSON.parse(JSON.stringify(message ?? null)) }); return !disposed; },
    // Resources come from the extension's files; the page inlines them into the frame.
    asWebviewUri: (uri) => Uri.from({ scheme: 'duocode-res', authority: 'file', path: uri.path }),
  };
  let title_ = title;
  const panel = {
    _id: id,
    viewType,
    webview,
    options: options || {},
    get title() { return title_; },
    set title(value) { title_ = value; if (!disposed) notify('webviewTitle', { id, title: value }); },
    iconPath: undefined,
    viewColumn: 1,
    active: true,
    visible: true,
    onDidDispose: onDispose.event,
    onDidChangeViewState: onViewState.event,
    reveal: () => { if (!disposed) notify('webviewReveal', { id }); },
    dispose: () => {
      if (disposed) return;
      disposed = true;
      webviews.delete(id);
      notify('webviewClose', { id });
      onDispose.fire();
    },
  };
  webviews.set(id, { panel, onMessage, onDispose, closed: () => { if (!disposed) { disposed = true; webviews.delete(id); onDispose.fire(); } } });
  return panel;
}

// MARK: - Tree views, webview views and custom editors

const trees = new Map();                  // view id -> { provider, view, elements: handle -> element, commands: handle -> command, events }
const webviewViewProviders = new Map();   // view id -> { provider, options, panel }
const customEditorProviders = new Map();  // view type -> { provider, options }

/** A tree view: the page's side bar asks for its items (treeChildren) and runs what's tapped. */
function createTreeView(viewId, options = {}) {
  const provider = options.treeDataProvider;
  const events = { selection: new EventEmitter(), visibility: new EventEmitter(), expand: new EventEmitter(), collapse: new EventEmitter(), checkbox: new EventEmitter() };
  const meta = { title: undefined, description: undefined, message: undefined, badge: undefined };
  const update = () => notify('treeChanged', { viewId });
  const entry = { provider, elements: new Map(), commands: new Map(), events, meta };
  const subscription = provider && provider.onDidChangeTreeData ? provider.onDidChangeTreeData(update) : null;
  const view = {
    get title() { return meta.title; }, set title(v) { meta.title = v; update(); },
    get description() { return meta.description; }, set description(v) { meta.description = v; update(); },
    get message() { return meta.message; }, set message(v) { meta.message = v; update(); },
    get badge() { return meta.badge; }, set badge(v) { meta.badge = v; update(); },
    selection: [],
    visible: true,
    onDidChangeSelection: events.selection.event,
    onDidChangeVisibility: events.visibility.event,
    onDidExpandElement: events.expand.event,
    onDidCollapseElement: events.collapse.event,
    onDidChangeCheckboxState: events.checkbox.event,
    reveal: async () => { notify('treeReveal', { viewId }); },
    dispose() {
      if (subscription && subscription.dispose) subscription.dispose();
      if (trees.get(viewId) === entry) { trees.delete(viewId); update(); }
    },
  };
  entry.view = view;
  trees.set(viewId, entry);
  update();
  return view;
}

/** A TreeItem as the side bar shows it. Handles come from ids or labels, so they survive refreshes. */
function plainTreeItem(entry, item, element, parentHandle, seen) {
  const uri = item.resourceUri;
  const label = typeof item.label === 'string' ? item.label : item.label?.label ?? (uri ? uri.path.split('/').pop() : '');
  let handle = item.id ? 'id:' + item.id : (parentHandle || '') + '/' + label;
  while (seen.has(handle)) handle += '\'';
  seen.add(handle);
  entry.elements.set(handle, element);
  if (item.command) entry.commands.set(handle, item.command); else entry.commands.delete(handle);
  const collapsible = item.collapsibleState || 0;
  const icon = item.iconPath;
  const codicon = icon && typeof icon.id === 'string' ? icon.id : (uri && !icon ? (collapsible ? 'folder' : 'file') : null);
  let description = item.description;
  if (description === true) description = uri ? uri.path.split('/').slice(0, -1).join('/').replace(workspaceRoot, '').replace(/^\//, '') : '';
  const checkbox = item.checkboxState == null ? null : (typeof item.checkboxState === 'object' ? item.checkboxState.state : item.checkboxState);
  return {
    handle, label, collapsible, codicon,
    description: typeof description === 'string' ? description : '',
    tooltip: typeof item.tooltip === 'string' ? item.tooltip : item.tooltip?.value || '',
    contextValue: item.contextValue || '',
    hasCommand: !!item.command,
    checked: checkbox == null ? null : checkbox === 1,
  };
}

// MARK: - Tasks

const taskProviders = new Map();   // type -> provider
const knownTasks = new Map();      // id -> Task
let taskSeq = 0;
const onDidStartTask = new EventEmitter();
const onDidEndTask = new EventEmitter();
const onDidEndTaskProcess = new EventEmitter();

function rememberTask(task) {
  for (const [id, t] of knownTasks) if (t === task) return id;
  const id = HOST + '-task-' + (++taskSeq);
  knownTasks.set(id, task);
  return id;
}

async function provideTasks() {
  const types = new Set();
  for (const ext of extensions.values()) for (const d of ext.manifest.contributes?.taskDefinitions || []) if (d.type) types.add(d.type);
  for (const type of types) await activateFor('onTaskType:' + type);
  const out = [];
  for (const provider of taskProviders.values()) {
    try { out.push(...((await provider.provideTasks(noCancel)) || [])); } catch (e) { /* one provider failing doesn't stop the others */ }
  }
  return out;
}

const terminalText = (text) => String(text).replace(/\r\n?/g, '\n').replace(/\x1b\[[0-9;?]*[A-Za-z]/g, '');

/** Runs a task: custom executions here (their output goes to the Tasks channel); shell and
 * process ones are handed back to the page, which runs what it can in Node.js. */
async function runTask(id) {
  const task = knownTasks.get(id);
  if (!task) return null;
  let execution = task.execution;
  const provider = taskProviders.get(task.definition?.type);
  if (!execution && provider && provider.resolveTask) execution = (await provider.resolveTask(task, noCancel))?.execution;
  const done = (code) => {
    notify('taskEnd', { id, label: task.name, code });
    onDidEndTask.fire({ execution: { task } });
    onDidEndTaskProcess.fire({ execution: { task }, exitCode: code });
  };
  if (execution instanceof CustomExecution) {
    const pty = await execution.callback(task.definition);
    if (pty.onDidWrite) pty.onDidWrite((text) => notify('output', { channel: 'Tasks', op: 'append', text: terminalText(text) }));
    if (pty.onDidClose) pty.onDidClose((code) => done(typeof code === 'number' ? code : 0));
    onDidStartTask.fire({ execution: { task, terminate: () => pty.close && pty.close() } });
    await pty.open(undefined);
    return { custom: true };
  }
  const arg = (a) => (typeof a === 'string' ? a : a && a.value != null ? a.value : String(a));
  if (execution instanceof ShellExecution) {
    const command = execution.commandLine || [execution.command, ...(execution.args || [])].map(arg).join(' ');
    return { shell: command, cwd: execution.options?.cwd };
  }
  if (execution instanceof ProcessExecution) {
    return { shell: [execution.process, ...(execution.args || [])].map(arg).join(' '), cwd: execution.options?.cwd };
  }
  return { error: `"${task.name}" has nothing Mobile Studio can run.` };
}

/** Edits the page wrote to a file it doesn't have open: the document here follows them. */
function applyToDocument(doc, edits) {
  const sorted = edits.map((e) => ({ from: doc.offsetAt(e.range.start), to: doc.offsetAt(e.range.end), text: e.newText })).sort((a, b) => b.from - a.from);
  const oldEnd = doc.positionAt(doc._text.length);
  const oldLength = doc._text.length;
  let text = doc._text;
  for (const e of sorted) text = text.slice(0, e.from) + e.text + text.slice(e.to);
  doc._set(text);
  doc.version++;
  onDidChangeTextDocument.fire({ document: doc, contentChanges: [{ range: new Range(new Position(0, 0), oldEnd), rangeOffset: 0, rangeLength: oldLength, text }], reason: undefined });
}

/** Deactivates every extension and forgets what they registered. */
async function resetHost() {
  for (const ext of extensions.values()) {
    try {
      if (ext.context) for (const d of ext.context.subscriptions) { try { d.dispose(); } catch (e) { /* keep going */ } }
      const main = ext.nodeMain && nodeRequire ? nodeRequire.cache[nodeRequire.resolve(ext.nodeMain)]?.exports : null;
      if (main && typeof main.deactivate === 'function') await main.deactivate();
    } catch (e) { /* keep going */ }
    // Node.js caches modules; drop the extension's so a new version loads.
    if (nodeRequire && ext.path) {
      for (const key of Object.keys(nodeRequire.cache)) if (key.startsWith(ext.path)) delete nodeRequire.cache[key];
    }
  }
  extensions.clear();
  commands.clear();
  for (const kind of Object.keys(providers)) delete providers[kind];
  for (const id of [...webviews.keys()]) webviews.get(id).closed();
  trees.clear();
  webviewViewProviders.clear();
  customEditorProviders.clear();
  taskProviders.clear();
  knownTasks.clear();
  for (const name of [...outputChannels.keys()]) outputChannels.get(name).dispose();
}

/** The vscode.execute*Provider commands: [provider kind, (provider, doc, ...args) => result]. */
const PROVIDER_COMMANDS = {
  'vscode.executeHoverProvider': ['hover', (p, doc, pos) => p.provideHover(doc, pos, noCancel)],
  'vscode.executeDefinitionProvider': ['definition', (p, doc, pos) => p.provideDefinition(doc, pos, noCancel)],
  'vscode.executeTypeDefinitionProvider': ['typeDefinition', (p, doc, pos) => p.provideTypeDefinition(doc, pos, noCancel)],
  'vscode.executeImplementationProvider': ['implementation', (p, doc, pos) => p.provideImplementation(doc, pos, noCancel)],
  'vscode.executeDeclarationProvider': ['declaration', (p, doc, pos) => p.provideDeclaration(doc, pos, noCancel)],
  'vscode.executeReferenceProvider': ['references', (p, doc, pos) => p.provideReferences(doc, pos, { includeDeclaration: true }, noCancel)],
  'vscode.executeDocumentHighlights': ['highlights', (p, doc, pos) => p.provideDocumentHighlights(doc, pos, noCancel)],
  'vscode.executeDocumentSymbolProvider': ['symbols', (p, doc) => p.provideDocumentSymbols(doc, noCancel)],
  'vscode.executeFormatDocumentProvider': ['formatting', (p, doc, options) => p.provideDocumentFormattingEdits(doc, options || { tabSize: 4, insertSpaces: true }, noCancel)],
  'vscode.executeFormatRangeProvider': ['rangeFormatting', (p, doc, range, options) => p.provideDocumentRangeFormattingEdits(doc, range, options || { tabSize: 4, insertSpaces: true }, noCancel)],
  'vscode.executeCodeActionProvider': ['codeActions', (p, doc, range, kind) => p.provideCodeActions(doc, range, { diagnostics: [], only: kind ? new CodeActionKind(kind) : undefined, triggerKind: 1 }, noCancel)],
  'vscode.executeCodeLensProvider': ['codeLens', (p, doc) => p.provideCodeLenses(doc, noCancel)],
  'vscode.executeLinkProvider': ['links', (p, doc) => p.provideDocumentLinks(doc, noCancel)],
  'vscode.executeDocumentColorProvider': ['colors', (p, doc) => p.provideDocumentColors(doc, noCancel)],
  'vscode.executeFoldingRangeProvider': ['folding', (p, doc) => p.provideFoldingRanges(doc, {}, noCancel)],
  'vscode.executeSelectionRangeProvider': ['selectionRanges', (p, doc, positions) => p.provideSelectionRanges(doc, positions, noCancel)],
  'vscode.executeInlayHintProvider': ['inlayHints', (p, doc, range) => p.provideInlayHints(doc, range, noCancel)],
  'vscode.executeSignatureHelpProvider': ['signature', (p, doc, pos, trigger) => p.provideSignatureHelp(doc, pos, noCancel, { triggerKind: 1, triggerCharacter: trigger, isRetrigger: false })],
  'vscode.executeCompletionItemProvider': ['completion', (p, doc, pos, trigger) => p.provideCompletionItems(doc, pos, noCancel, { triggerKind: trigger ? 1 : 0, triggerCharacter: trigger })],
  'vscode.executeDocumentRenameProvider': ['rename', (p, doc, pos, newName) => p.provideRenameEdits(doc, pos, newName, noCancel)],
  'vscode.prepareCallHierarchy': ['callHierarchy', (p, doc, pos) => p.prepareCallHierarchy(doc, pos, noCancel)],
};
// One answer, not a list, for these.
const SINGLE_RESULT = new Set(['vscode.executeSignatureHelpProvider', 'vscode.executeDocumentRenameProvider']);

async function executeProviderCommand(name, args) {
  if (name === 'vscode.executeWorkspaceSymbolProvider') {
    const out = [];
    for (const { provider } of providers.workspaceSymbols || []) out.push(...((await provider.provideWorkspaceSymbols(args[0] || '', noCancel)) || []));
    return out;
  }
  const [kind, run] = PROVIDER_COMMANDS[name];
  const uri = typeof args[0] === 'string' ? Uri.parse(args[0]) : args[0];
  const doc = documents.get(uri.toString()) || await vscode.workspace.openTextDocument(uri);
  // Positions and ranges may come as plain objects (from JSON).
  const rest = args.slice(1).map((a) => (a && a.line !== undefined && a.character !== undefined ? toPosition(a)
    : a && a.start && a.end && a.start.line !== undefined ? new Range(toPosition(a.start), toPosition(a.end)) : a));
  const answers = [];
  for (const { provider } of providersFor(kind, doc)) {
    const r = await Promise.resolve(run(provider, doc, ...rest)).catch(() => null);
    if (r && SINGLE_RESULT.has(name)) return r;
    if (r) answers.push(r);
  }
  if (SINGLE_RESULT.has(name)) return undefined;
  if (name === 'vscode.executeCompletionItemProvider') return new CompletionList(answers.flatMap((r) => (Array.isArray(r) ? r : r.items || [])));
  return answers.flat();
}

async function executeCommand(name, args) {
  if (PROVIDER_COMMANDS[name] || name === 'vscode.executeWorkspaceSymbolProvider') return executeProviderCommand(name, args || []);
  if (!commands.has(name)) await activateFor('onCommand:' + name);
  const command = commands.get(name);
  if (command) return command.fn.apply(command.thisArg, args);
  return request('builtinCommand', { name, args: JSON.parse(JSON.stringify(args || [])) });
}

// MARK: - Calls from the page

function plainText(content) {
  if (content == null) return '';
  if (typeof content === 'string') return content;
  if (content.value !== undefined) return content.language ? '```' + content.language + '\n' + content.value + '\n```' : String(content.value);
  return '';
}

let codeActionList = [];   // the last codeActions answer's actions, by id
let completionItems = [];  // the last completion answer's items, by id
let codeLensList = [];     // code lenses' commands, by id
let linkList = [];         // document links, by id
let colorList = [];        // document colours, by id

async function resolveCompletion(entry) {
  if (!entry.resolved) {
    entry.resolved = entry.provider.resolveCompletionItem
      ? Promise.resolve(entry.provider.resolveCompletionItem(entry.item, noCancel)).then((r) => r || entry.item, () => entry.item)
      : Promise.resolve(entry.item);
  }
  return entry.resolved;
}

const callHandlers = {
  hasCommand: ({ name }) => commands.has(name)
    || [...extensions.values()].some((ext) => (ext.manifest.contributes?.commands || []).some((c) => c.command === name)),
  async completion({ uri, position, triggerCharacter }) {
    const doc = documents.get(uri);
    if (!doc) return [];
    const pos = toPosition(position);
    const out = [];
    completionItems = [];
    for (const { provider, extra } of providersFor('completion', doc)) {
      if (triggerCharacter && !(extra?.triggers || []).includes(triggerCharacter)) continue;
      try {
        const result = await provider.provideCompletionItems(doc, pos, noCancel, { triggerKind: triggerCharacter ? 1 : 0, triggerCharacter });
        const items = Array.isArray(result) ? result : result?.items || [];
        const incomplete = !Array.isArray(result) && !!result?.isIncomplete;
        for (const item of items) {
          const label = typeof item.label === 'string' ? item.label : item.label?.label;
          const insert = item.insertText instanceof SnippetString || item.insertText?.value !== undefined ? { snippet: item.insertText.value } : { text: typeof item.insertText === 'string' ? item.insertText : label };
          const range = item.range ? (item.range.start ? item.range : item.range.replacing) : undefined;
          const id = completionItems.push({ provider, item }) - 1;
          out.push({ id, label, kind: item.kind, detail: item.detail || (typeof item.label === 'object' ? item.label.description : undefined),
            documentation: plainText(item.documentation), sortText: item.sortText, filterText: item.filterText, range, incomplete,
            preselect: !!item.preselect, deprecated: (item.tags || []).includes(1), commitCharacters: item.commitCharacters,
            // Accepting it does more (or resolving it might).
            more: !!(item.additionalTextEdits?.length || item.command || provider.resolveCompletionItem), ...insert });
        }
      } catch (e) { /* one provider failing doesn't stop the others */ }
    }
    return out;
  },
  // The documentation of the highlighted completion, from resolveCompletionItem.
  async completionDetails({ id }) {
    const entry = completionItems[id];
    if (!entry) return null;
    const item = await resolveCompletion(entry);
    return { detail: item.detail, documentation: plainText(item.documentation) };
  },
  // A completion was accepted: its additional edits (imports) apply and its command runs.
  async completionAccepted({ uri, id }) {
    const entry = completionItems[id];
    if (!entry) return false;
    const item = await resolveCompletion(entry);
    if (item.additionalTextEdits?.length) {
      await request('applyEdit', { changes: [{ uri, edits: item.additionalTextEdits.map((e) => ({ range: e.range, newText: e.newText })) }] });
    }
    if (item.command) await executeCommand(item.command.command, item.command.arguments || []);
    return true;
  },
  async signatureHelp({ uri, position, triggerCharacter, retrigger }) {
    const doc = documents.get(uri);
    if (!doc) return null;
    for (const { provider } of providersFor('signature', doc)) {
      try {
        const help = await provider.provideSignatureHelp(doc, toPosition(position), noCancel, { triggerKind: triggerCharacter ? 2 : 1, triggerCharacter, isRetrigger: !!retrigger, activeSignatureHelp: undefined });
        if (!help || !help.signatures?.length) continue;
        const active = Math.min(help.activeSignature || 0, help.signatures.length - 1);
        const sig = help.signatures[active];
        const param = sig.activeParameter ?? help.activeParameter ?? 0;
        // A parameter's label is its text, or [start, end] in the signature's label.
        const p = sig.parameters?.[param];
        let span = null;
        if (p) {
          if (Array.isArray(p.label)) span = p.label;
          else { const at = sig.label.indexOf(p.label); if (at >= 0) span = [at, at + p.label.length]; }
        }
        return { label: sig.label, documentation: plainText(sig.documentation), parameter: span, parameterDocumentation: p ? plainText(p.documentation) : '',
          count: help.signatures.length, index: active };
      } catch (e) { /* ignore */ }
    }
    return null;
  },
  // What a file's providers say about all of it, at once: folding, code lenses, semantic tokens,
  // links and colours (for those it has providers for).
  async documentFeatures({ uri }) {
    const doc = documents.get(uri);
    if (!doc) return null;
    codeLensList = [];
    linkList = [];
    colorList = [];
    const out = {};
    const each = async (kind, fn) => {
      const list = providersFor(kind, doc);
      if (!list.length) return;
      out[kind] = [];
      for (const entry of list) {
        try { const r = await fn(entry); if (r) out[kind].push(...r); } catch (e) { /* ignore */ }
      }
    };
    await Promise.all([
      each('folding', async ({ provider }) => ((await provider.provideFoldingRanges(doc, {}, noCancel)) || [])
        .map((f) => ({ start: f.start, end: f.end, kind: f.kind }))),
      each('codeLens', async ({ provider }) => {
        const lenses = (await provider.provideCodeLenses(doc, noCancel)) || [];
        return Promise.all(lenses.map(async (lens) => {
          let resolved = lens;
          if (!lens.command && provider.resolveCodeLens) resolved = (await Promise.resolve(provider.resolveCodeLens(lens, noCancel)).catch(() => null)) || lens;
          if (!resolved.command) return null;
          const id = codeLensList.push(resolved.command) - 1;
          return { id, line: lens.range.start.line, title: resolved.command.title, tooltip: resolved.command.tooltip || '' };
        })).then((list) => list.filter(Boolean));
      }),
      each('semanticTokens', async ({ provider, extra }) => {
        const result = await provider.provideDocumentSemanticTokens(doc, noCancel);
        if (!result || !result.data) return [];
        const types = extra?.legend?.tokenTypes || [];
        const modifiers = extra?.legend?.tokenModifiers || [];
        const data = result.data;
        const tokens = [];
        let line = 0, char = 0;
        for (let i = 0; i + 4 < data.length; i += 5) {
          line += data[i];
          char = data[i] ? data[i + 1] : char + data[i + 1];
          const mods = [];
          for (let m = 0; m < modifiers.length; m++) if (data[i + 4] & (1 << m)) mods.push(modifiers[m]);
          tokens.push([line, char, data[i + 2], types[data[i + 3]] || '', mods.join(' ')]);
        }
        return tokens;
      }),
      each('links', async ({ provider }) => ((await provider.provideDocumentLinks(doc, noCancel)) || []).map((link) => {
        const id = linkList.push({ provider, link }) - 1;
        return { id, range: link.range, target: link.target ? link.target.toString() : null, tooltip: link.tooltip || '' };
      })),
      each('colors', async ({ provider }) => ((await provider.provideDocumentColors(doc, noCancel)) || []).map((info) => {
        const id = colorList.push({ provider, info, doc }) - 1;
        return { id, range: info.range, color: { red: info.color.red, green: info.color.green, blue: info.color.blue, alpha: info.color.alpha } };
      })),
    ]);
    return out;
  },
  async runCodeLens({ id }) {
    const command = codeLensList[id];
    if (!command) return false;
    await executeCommand(command.command, command.arguments || []);
    return true;
  },
  // A link's target (resolving it if the provider leaves that until it's followed).
  async linkTarget({ id }) {
    const entry = linkList[id];
    if (!entry) return null;
    let { link } = entry;
    if (!link.target && entry.provider.resolveDocumentLink) link = (await entry.provider.resolveDocumentLink(link, noCancel)) || link;
    return link.target ? link.target.toString() : null;
  },
  // A colour picked for a colour in the file: written as the provider presents it.
  async pickColor({ id, color }) {
    const entry = colorList[id];
    if (!entry) return false;
    const picked = new Color(color.red, color.green, color.blue, color.alpha);
    const [presentation] = (await entry.provider.provideColorPresentations(picked, { document: entry.doc, range: entry.info.range }, noCancel)) || [];
    if (!presentation) return false;
    const edit = presentation.textEdit || new TextEdit(entry.info.range, presentation.label);
    const edits = [edit, ...(presentation.additionalTextEdits || [])].map((e) => ({ range: e.range, newText: e.newText }));
    await request('applyEdit', { changes: [{ uri: entry.doc.uri.toString(), edits }] });
    return true;
  },
  async highlights({ uri, position }) {
    const doc = documents.get(uri);
    if (!doc) return [];
    for (const { provider } of providersFor('highlights', doc)) {
      try {
        const list = await provider.provideDocumentHighlights(doc, toPosition(position), noCancel);
        if (list && list.length) return list.map((h) => ({ range: h.range, kind: h.kind ?? 0 }));
      } catch (e) { /* ignore */ }
    }
    return [];
  },
  async workspaceSymbols({ query }) {
    const out = [];
    for (const { provider } of providers.workspaceSymbols || []) {
      try {
        for (const s of (await provider.provideWorkspaceSymbols(query, noCancel)) || []) {
          let symbol = s;
          if (!symbol.location?.range && provider.resolveWorkspaceSymbol) symbol = (await provider.resolveWorkspaceSymbol(s, noCancel)) || s;
          if (!symbol.location) continue;
          out.push({ name: symbol.name, kind: symbol.kind, container: symbol.containerName || '', uri: symbol.location.uri.toString(),
            range: symbol.location.range || new Range(0, 0, 0, 0) });
        }
      } catch (e) { /* ignore */ }
    }
    return out;
  },
  // Go to Type Definition, Implementation and Declaration: [{ uri, range }].
  async locations({ uri, position, kind }) {
    const doc = documents.get(uri);
    if (!doc) return [];
    const method = { typeDefinition: 'provideTypeDefinition', implementation: 'provideImplementation', declaration: 'provideDeclaration' }[kind];
    if (!method) return [];
    const out = [];
    for (const { provider } of providersFor(kind, doc)) {
      try {
        const result = await provider[method](doc, toPosition(position), noCancel);
        for (const l of [].concat(result || [])) out.push({ uri: (l.uri || l.targetUri).toString(), range: l.targetSelectionRange || l.range || l.targetRange });
      } catch (e) { /* ignore */ }
    }
    return out;
  },
  async rangeFormat({ uri, range, options }) {
    const doc = documents.get(uri);
    if (!doc) return null;
    const [entry] = providersFor('rangeFormatting', doc);
    if (!entry) return null;
    const edits = await entry.provider.provideDocumentRangeFormattingEdits(doc, toRange(range), options || { tabSize: 4, insertSpaces: true }, noCancel);
    return (edits || []).map((e) => ({ range: e.range, newText: e.newText }));
  },
  // Characters that ask for signature help or format as they're typed.
  async triggers({ uri }) {
    const doc = documents.get(uri);
    if (!doc) return { signature: [], onType: [] };
    const signature = providersFor('signature', doc).flatMap(({ extra }) => extra?.triggers || []);
    const retrigger = providersFor('signature', doc).flatMap(({ extra }) => extra?.retriggers || []);
    const onType = providersFor('onTypeFormatting', doc).flatMap(({ extra }) => extra?.triggers || []);
    return { signature, retrigger, onType };
  },
  async onTypeFormat({ uri, position, ch, options }) {
    const doc = documents.get(uri);
    if (!doc) return null;
    for (const { provider, extra } of providersFor('onTypeFormatting', doc)) {
      if (!(extra?.triggers || []).includes(ch)) continue;
      try {
        const edits = await provider.provideOnTypeFormattingEdits(doc, toPosition(position), ch, options || { tabSize: 4, insertSpaces: true }, noCancel);
        if (edits && edits.length) return edits.map((e) => ({ range: e.range, newText: e.newText }));
      } catch (e) { /* ignore */ }
    }
    return null;
  },
  async hover({ uri, position }) {
    const doc = documents.get(uri);
    if (!doc) return null;
    const parts = [];
    for (const { provider } of providersFor('hover', doc)) {
      try {
        const hover = await provider.provideHover(doc, toPosition(position), noCancel);
        if (hover) for (const c of hover.contents) parts.push(plainText(c));
      } catch (e) { /* ignore */ }
    }
    return parts.filter(Boolean).join('\n\n---\n\n') || null;
  },
  async format({ uri, options }) {
    const doc = documents.get(uri);
    if (!doc) return null;
    const [entry] = providersFor('formatting', doc);
    if (!entry) return null;
    const edits = await entry.provider.provideDocumentFormattingEdits(doc, options || { tabSize: 4, insertSpaces: true }, noCancel);
    return (edits || []).map((e) => ({ range: e.range, newText: e.newText }));
  },
  async definition({ uri, position }) {
    const doc = documents.get(uri);
    if (!doc) return null;
    for (const { provider } of providersFor('definition', doc)) {
      try {
        let result = await provider.provideDefinition(doc, toPosition(position), noCancel);
        if (Array.isArray(result)) result = result[0];
        if (result) return { uri: (result.uri || result.targetUri).toString(), range: result.range || result.targetSelectionRange || result.targetRange };
      } catch (e) { /* ignore */ }
    }
    return null;
  },
  async symbols({ uri }) {
    const doc = documents.get(uri);
    if (!doc) return [];
    for (const { provider } of providersFor('symbols', doc)) {
      try {
        const result = await provider.provideDocumentSymbols(doc, noCancel);
        if (result && result.length) {
          const flat = [];
          const walk = (list, depth) => { for (const s of list) { flat.push({ name: s.name, kind: s.kind, depth, range: s.selectionRange || s.range || s.location?.range }); if (s.children) walk(s.children, depth + 1); } };
          walk(result, 0);
          return flat;
        }
      } catch (e) { /* ignore */ }
    }
    return [];
  },
  executeCommand: ({ name, args }) => executeCommand(name, args || []),

  // Quick Fix and refactorings for a range: [{ id, title, kind, isPreferred }]; runCodeAction runs one.
  async codeActions({ uri, range, invoked }) {
    const doc = documents.get(uri);
    codeActionList = [];
    if (!doc) return [];
    const r = toRange(range);
    const diagnostics = [...diagnosticCollections].flatMap((entries) => entries.get(uri) || [])
      .filter((d) => d.range && !d.range.end.isBefore(r.start) && !r.end.isBefore(d.range.start));
    const context = { diagnostics, only: undefined, triggerKind: invoked ? 1 : 2 };
    const out = [];
    for (const { provider } of providersFor('codeActions', doc)) {
      try {
        for (const action of (await provider.provideCodeActions(doc, r, context, noCancel)) || []) {
          if (!action || action.disabled) continue;
          const id = codeActionList.push({ provider, action }) - 1;
          const isCommand = typeof action.command === 'string';
          out.push({ id, title: action.title, kind: isCommand ? '' : String(action.kind?.value ?? ''), isPreferred: !!action.isPreferred });
        }
      } catch (e) { /* ignore */ }
    }
    return out;
  },
  async runCodeAction({ id }) {
    const entry = codeActionList[id];
    if (!entry) return false;
    let { action } = entry;
    if (typeof action.command === 'string') { await executeCommand(action.command, action.arguments || []); return true; }
    if (!action.edit && entry.provider.resolveCodeAction) action = (await entry.provider.resolveCodeAction(action, noCancel)) || action;
    if (action.edit) await api.workspace.applyEdit(action.edit);
    if (action.command) await executeCommand(action.command.command, action.command.arguments || []);
    return true;
  },
  // Inlay hints in a range: [{ position, label, kind, paddingLeft, paddingRight, tooltip }].
  async inlayHints({ uri, range }) {
    const doc = documents.get(uri);
    if (!doc) return [];
    const out = [];
    for (const { provider } of providersFor('inlayHints', doc)) {
      try {
        for (const hint of (await provider.provideInlayHints(doc, toRange(range), noCancel)) || []) {
          const label = typeof hint.label === 'string' ? hint.label : (hint.label || []).map((part) => part.value).join('');
          if (!label) continue;
          out.push({ position: hint.position, label, kind: hint.kind || 0, paddingLeft: !!hint.paddingLeft, paddingRight: !!hint.paddingRight, tooltip: plainText(hint.tooltip) });
        }
      } catch (e) { /* ignore */ }
    }
    return out;
  },
  // Where the symbol at a position is used: [{ uri, range }].
  async references({ uri, position }) {
    const doc = documents.get(uri);
    if (!doc) return [];
    for (const { provider } of providersFor('references', doc)) {
      try {
        const list = await provider.provideReferences(doc, toPosition(position), { includeDeclaration: true }, noCancel);
        if (list && list.length) return list.map((l) => ({ uri: (l.uri || l.targetUri).toString(), range: l.range || l.targetRange }));
      } catch (e) { /* ignore */ }
    }
    return [];
  },
  // Renames the symbol at a position everywhere; false when no extension can.
  async rename({ uri, position, newName }) {
    const doc = documents.get(uri);
    if (!doc) return false;
    for (const { provider } of providersFor('rename', doc)) {
      try {
        const edit = await provider.provideRenameEdits(doc, toPosition(position), newName, noCancel);
        if (edit) { await api.workspace.applyEdit(edit); return true; }
      } catch (e) {
        throw new Error(e && e.message ? e.message : String(e));
      }
    }
    return false;
  },

  // Tree views: null when this host doesn't have the view.
  async treeChildren({ viewId, handle }) {
    if (!trees.has(viewId)) await activateFor('onView:' + viewId);
    const entry = trees.get(viewId);
    if (!entry) return null;
    const { meta } = entry;
    const info = { title: meta.title, description: meta.description, message: typeof meta.message === 'string' ? meta.message : meta.message?.value, badge: meta.badge?.value || 0 };
    if (!entry.provider) return { ...info, items: [] };
    const parent = handle ? entry.elements.get(handle) : undefined;
    if (handle && parent === undefined) return { ...info, items: [] };
    const children = (await entry.provider.getChildren(parent)) || [];
    const seen = new Set();
    const items = [];
    for (const element of children) {
      try {
        const item = await entry.provider.getTreeItem(element);
        if (item) items.push(plainTreeItem(entry, item, element, handle, seen));
      } catch (e) { /* skip it */ }
    }
    return { ...info, items };
  },
  async treeInvoke({ viewId, handle }) {
    const entry = trees.get(viewId);
    if (!entry) return null;
    const element = entry.elements.get(handle);
    entry.view.selection = element === undefined ? [] : [element];
    entry.events.selection.fire({ selection: entry.view.selection });
    const command = entry.commands.get(handle);
    if (command) await executeCommand(command.command, command.arguments || []);
    return true;
  },
  async treeMenu({ viewId, handle, command }) {
    const entry = trees.get(viewId);
    if (!entry) return null;
    const element = handle ? entry.elements.get(handle) : undefined;
    await executeCommand(command, element === undefined ? [] : [element, [element]]);
    return true;
  },
  treeExpand({ viewId, handle, expanded }) {
    const entry = trees.get(viewId);
    if (!entry || !entry.elements.has(handle)) return null;
    (expanded ? entry.events.expand : entry.events.collapse).fire({ element: entry.elements.get(handle) });
    return true;
  },
  treeCheck({ viewId, handle, checked }) {
    const entry = trees.get(viewId);
    if (!entry || !entry.elements.has(handle)) return null;
    entry.events.checkbox.fire({ items: [[entry.elements.get(handle), checked ? 1 : 0]] });
    return true;
  },

  /** A webview view (a side bar view drawn by the extension), shown in an editor tab. */
  async resolveWebviewView({ viewId, title }) {
    if (!webviewViewProviders.has(viewId)) await activateFor('onView:' + viewId);
    const entry = webviewViewProviders.get(viewId);
    if (!entry) return null;
    if (entry.panel) { entry.panel.reveal(); return entry.panel._id; }
    const panel = createWebviewPanel(viewId, title, entry.options.webviewOptions || {});
    const visibility = new EventEmitter();
    const view = {
      viewType: viewId,
      webview: panel.webview,
      get title() { return panel.title; }, set title(v) { panel.title = v; },
      description: undefined,
      badge: undefined,
      visible: true,
      onDidDispose: panel.onDidDispose,
      onDidChangeVisibility: visibility.event,
      show: () => panel.reveal(),
      dispose: () => panel.dispose(),
    };
    panel.onDidDispose(() => { entry.panel = null; });
    entry.panel = panel;
    await entry.provider.resolveWebviewView(view, { state: undefined }, noCancel);
    return panel._id;
  },

  /** Opens a file in an extension's custom editor (a webview in an editor tab). */
  async openCustomEditor({ viewType, uri, title }) {
    if (!customEditorProviders.has(viewType)) await activateFor('onCustomEditor:' + viewType);
    const entry = customEditorProviders.get(viewType);
    if (!entry) return null;
    const { provider, options } = entry;
    const target = Uri.parse(uri);
    const panel = createWebviewPanel(viewType, title, options.webviewOptions || {});
    if (typeof provider.resolveCustomTextEditor === 'function') {
      let doc = documents.get(uri);
      if (!doc) {
        const { text, languageId } = await request('readDocument', { uri });
        doc = new TextDocument(target, languageId, text, 1);
        documents.set(uri, doc);
        onDidOpenTextDocument.fire(doc);
      }
      await provider.resolveCustomTextEditor(doc, panel, noCancel);
    } else {
      const doc = await provider.openCustomDocument(target, { backupId: undefined, untitledDocumentData: undefined }, noCancel);
      // DuoCode saves as it goes: an edit is saved straight away.
      if (provider.onDidChangeCustomDocument) {
        provider.onDidChangeCustomDocument((e) => {
          if (e.document === doc && provider.saveCustomDocument) Promise.resolve(provider.saveCustomDocument(doc, noCancel)).catch(() => {});
        });
      }
      panel.onDidDispose(() => { if (doc && doc.dispose) doc.dispose(); });
      await provider.resolveCustomEditor(doc, panel, noCancel);
    }
    return panel._id;
  },

  async taskList() {
    return (await provideTasks()).map((t) => ({ id: rememberTask(t), label: t.name, source: t.source || t.definition?.type || '', detail: t.detail || '', group: t.group?.id || '' }));
  },
  runTask: ({ id }) => runTask(id),

  commandList() {
    const out = [];
    for (const ext of extensions.values()) {
      for (const c of ext.manifest.contributes?.commands || []) {
        out.push({ command: c.command, title: (c.category ? c.category + ': ' : '') + (typeof c.title === 'string' ? c.title : c.title?.value || c.command), extension: ext.manifest.displayName || ext.id });
      }
    }
    return out;
  },
};

// MARK: - Messages

self.onmessage = async ({ data }) => {
  const message = data;
  switch (message.type) {
    case 'init': {
      HOST = message.host || 'web';
      if (extensions.size) await resetHost();
      workspaceRoot = message.workspaceRoot;
      userConfiguration = message.configuration || {};
      self.__state = message.state || {};
      for (const ext of message.extensions) extensions.set(ext.id, { ...ext, active: null });
      themeKind = message.themeKind || enums.ColorThemeKind.Dark;
      await activateFor('*');
      await activateFor('onFileSystem:file');
      await activateForWorkspaceContents();
      await activateFor('onStartupFinished');
      postMessage({ type: 'ready' });
      break;
    }
    case 'reply': {
      const entry = pending.get(message.id);
      if (entry) { pending.delete(message.id); message.error ? entry.reject(new Error(message.error)) : entry.resolve(message.result); }
      break;
    }
    case 'docOpen': {
      const uri = Uri.parse(message.uri);
      const doc = new TextDocument(uri, message.languageId, message.text, message.version);
      documents.set(message.uri, doc);
      await activateFor('onLanguage:' + message.languageId);
      onDidOpenTextDocument.fire(doc);
      let selections = [new Selection(0, 0, 0, 0)];
      activeEditor = {
        document: doc,
        // Setting the selection moves the editor's cursor.
        get selection() { return selections[0]; },
        set selection(s) { selections = [s]; request('select', { uri: message.uri, anchor: s.anchor || s.start, active: s.active || s.end }).catch(() => {}); },
        get selections() { return selections; },
        set selections(list) { if (list && list.length) this.selection = list[0]; },
        _setSelection(s) { selections = [s]; },
        options: { tabSize: 4, insertSpaces: true },
        visibleRanges: [new Range(0, 0, doc.lineCount, 0)],
        edit: async (fn) => {
          const changes = [];
          fn({ replace: (r, t) => changes.push({ range: r instanceof Position ? new Range(r, r) : r, newText: t }), insert: (p, t) => changes.push({ range: new Range(p, p), newText: t }), delete: (r) => changes.push({ range: r, newText: '' }), setEndOfLine() {} });
          return request('applyEdit', { changes: [{ uri: message.uri, edits: changes }] });
        },
        insertSnippet: (snippet, where) => request('insertSnippet', { snippet: snippet.value, at: where?.start || where }),
        revealRange: (range) => request('reveal', { range }),
        setDecorations(type, items) {
          const ranges = (items || []).map((x) => (x instanceof Range
            ? { range: x }
            : { range: x.range, hover: plainHover(x.hoverMessage), renderOptions: x.renderOptions && plainOptions(x.renderOptions) }));
          notify('setDecorations', { uri: message.uri, key: type.key, ranges });
        },
        show() {}, hide() {},
      };
      onDidChangeActiveTextEditor.fire(activeEditor);
      onDidChangeVisibleTextEditors.fire([activeEditor]);
      updateLanguageStatus();
      onDidChangeTabs.fire({ opened: [], closed: [], changed: tabGroup().tabs });
      break;
    }
    case 'docChange': {
      const doc = documents.get(message.uri);
      if (!doc) break;
      // One change replacing the whole old text: language clients sync incrementally, so the range
      // must be the old document's.
      const oldEnd = doc.positionAt(doc._text.length);
      const oldLength = doc._text.length;
      doc._set(message.text);
      doc.version = message.version;
      doc.isDirty = true;
      onDidChangeTextDocument.fire({
        document: doc,
        contentChanges: [{ range: new Range(new Position(0, 0), oldEnd), rangeOffset: 0, rangeLength: oldLength, text: message.text }],
        reason: undefined,
      });
      break;
    }
    case 'docSave': {
      const doc = documents.get(message.uri);
      if (doc) { doc.isDirty = false; onDidSaveTextDocument.fire(doc); }
      fileEvent('change', Uri.parse(message.uri));
      break;
    }
    // Files the app created, deleted or moved (the Explorer, git, the Terminal).
    case 'fileEvent': {
      const uri = Uri.parse(message.uri);
      if (message.kind === 'rename') {
        const to = Uri.parse(message.to);
        fileEvent('delete', uri);
        fileEvent('create', to);
        onDidRenameFiles.fire({ files: [{ oldUri: uri, newUri: to }] });
      } else {
        fileEvent(message.kind, uri);
        if (message.kind === 'create') onDidCreateFiles.fire({ files: [uri] });
        if (message.kind === 'delete') onDidDeleteFiles.fire({ files: [uri] });
      }
      break;
    }
    case 'progressCancel': {
      const source = progressCancels.get(message.id);
      if (source) source.cancel();
      break;
    }
    case 'theme': {
      themeKind = message.kind;
      onDidChangeActiveColorTheme.fire({ kind: themeKind });
      break;
    }
    case 'docClose': {
      const doc = documents.get(message.uri);
      if (doc) { documents.delete(message.uri); doc.isClosed = true; onDidCloseTextDocument.fire(doc); }
      break;
    }
    case 'selection': {
      if (activeEditor && activeEditor.document.uri.toString() === message.uri) {
        const s = new Selection(toPosition(message.anchor), toPosition(message.head));
        activeEditor._setSelection(s);
        onDidChangeTextEditorSelection.fire({ textEditor: activeEditor, selections: [s], kind: 1 });
      }
      break;
    }
    case 'webviewMessage': {
      const entry = webviews.get(message.id);
      if (entry) entry.onMessage.fire(message.message);
      break;
    }
    case 'webviewClosed': {
      const entry = webviews.get(message.id);
      if (entry) entry.closed();
      break;
    }
    case 'configuration': {
      userConfiguration = message.values || {};
      onDidChangeConfiguration.fire({ affectsConfiguration: () => true });
      break;
    }
    case 'call': {
      try {
        const result = await callHandlers[message.method](message.params || {});
        postMessage({ type: 'reply', id: message.id, result: result === undefined ? null : JSON.parse(JSON.stringify(result)) });
      } catch (e) {
        postMessage({ type: 'reply', id: message.id, error: e && e.message ? e.message : String(e) });
      }
      break;
    }
    default:
      break;
  }
};
