// DuoCode editor: CodeMirror 6 inside the app's WKWebView.
// The native side talks to it through `window.duocode` and the `duocode` message handler.
import { EditorState, Compartment } from '@codemirror/state';
import {
  EditorView, keymap, lineNumbers, highlightActiveLine, highlightActiveLineGutter, highlightSpecialChars,
  drawSelection, dropCursor,
} from '@codemirror/view';
import { defaultKeymap, history, historyKeymap, indentWithTab, undo, redo } from '@codemirror/commands';
import { indentOnInput, bracketMatching, foldGutter, foldKeymap } from '@codemirror/language';
import { closeBrackets, closeBracketsKeymap } from '@codemirror/autocomplete';
import { searchKeymap, highlightSelectionMatches } from '@codemirror/search';
import { lintKeymap } from '@codemirror/lint';
import { unifiedMergeView, goToNextChunk, goToPreviousChunk } from '@codemirror/merge';
import { languageFor } from './languages.js';
import { settings, settingsExtensions, settingsEffects, updateSettings } from './settings.js';
import { aiCompletion } from './ai-complete.js';
import { symbolAt } from './lua-intel.js';
import { longPressDocs, hideDocsSheet } from './docs.js';
import { kindOf, ICONS, showBinary, showError, hideViewer } from './viewer.js';
import { mergeConflicts, mergeInfo } from './conflicts.js';
import { loadExtensions } from './ext/registry.js';
import { lockScrollDirection } from './scroll-lock.js';
import { resetGrammars } from './ext/textmate.js';
import { loadExtensionTheme, forgetExtensionThemes } from './ext/themes.js';
import { setSnippetContext, resetSnippets } from './ext/snippets.js';
import { prepareLanguage, forgetExtensionLanguages, languageIdFor } from './languages.js';
import { applyChrome, chromeColors } from './theme.js';
import { startHost, setConfiguration, hoverAt, outputLog, formatDocument, hostExtensions, didOpen, didChange, didSave, didSelect } from './ext/host.js';
import { showCommandPalette, showQuickOpen, noteOpenedFile, builtinCommands, pickColorTheme } from './palette.js';
import { closeQuickInput, notify as showNotification } from './ext/ui.js';
import { gitGutter, loadOriginal } from './gitgutter.js';
import { findWidget } from './findwidget.js';
import { setupWebviews, reveal as revealWebview, closeWebview } from './ext/webviews.js';
import { postToHost, extensionFileAt } from './ext/host.js';
import { setupNavigation, goToDefinition, findReferences, renameSymbol, fallbackDefinitions } from './navigate.js';
import { setupLanguageFeatures, languageFeatures, quickFix, peekDefinition, closePeekView } from './langfeatures.js';
import { setupMarkdownPreview, setPreview, refreshPreview, fileOpened, previewMode, previewSaved } from './mdpreview.js';
import { extensionKeys, buildExtensionKeymap, currentExtensionKeymap } from './ext/keybindings.js';
import { runCommand } from './ext/host.js';
import { setupBreadcrumbs, updateBreadcrumbs } from './breadcrumbs.js';
import { setupTabs, showTab, setTabIcon, setActiveDirty, removeTab, clearTabs, activeTab, renameTabs } from './tabs.js';
import { setupSplit, mainChanged, sideText, openToSide, refreshSplit, flushSplit } from './split.js';
import { setupTasks } from './tasks.js';
import { setupDebugConsole, showPanel, togglePanel } from './panel.js';
import { setupProblems, problemsChanged } from './problems.js';
import { setupTerminal, showTerminal } from './terminal.js';
import { setupOutput } from './ext/output.js';
import { nodeAddress } from './ext/host.js';
import { addCommands } from './palette.js';
import { customEditorsFor } from './ext/registry.js';
import { quickPick } from './ext/ui.js';
import { openCustomEditor, openWebviewView, viewChildren, viewInvoke, viewMenu, viewExpand, viewCheck } from './ext/host.js';
import { breakpointGutterHandlers, toggleBreakpointAtCursor, debugExtensions, showBreakpoints, showPausedLine, showInlineValues, debugValueAt } from './debug.js';

const native = (msg) => window.webkit.messageHandlers.duocode.postMessage(msg);
const openURL = (url) => native({ cmd: 'openURL', url });

const $ = (id) => document.getElementById(id);
const posLabel = $('pos');

let current = null;      // path of the open file
let dirty = false;
let readOnly = false;    // binary previews are never saved
let languageName = '';
let openSeq = 0;         // guards against a slow load landing after another file was opened
const states = new Map(); // path → EditorState, so undo history survives switching files
let debugLocation = null; // { path, line } where the debugged program is paused
let debugPaused = false;
const debugApi = { native, path: () => (readOnly ? null : current), isPaused: () => debugPaused };

function setDirty(value) {
  dirty = value;
  setActiveDirty(value);
}

function updatePos(state) {
  const head = state.selection.main.head;
  const line = state.doc.lineAt(head);
  posLabel.textContent = `${languageName} · Ln ${line.number}, Col ${head - line.from + 1}`;
}

const aiBusy = $('ai-busy');
const setAIBusy = (busy) => { aiBusy.hidden = !busy; };
let autoSaveTimer = 0;
let autoSaving = false;
let crumbTimer = 0;

// Merge conflicts: VS Code's inline conflict actions, the merge bar and AI "Resolve for me".
const merge = mergeConflicts(native, () => current, async (path) => {
  await save();
  await native({ cmd: 'markResolved', path });
});

// Asks the app whether the open file is one of the merge's unresolved files.
function checkMergeState(path) {
  mergeInfo.path = path;
  mergeInfo.inMerge = false;
  merge.refresh();
  native({ cmd: 'conflictInfo', path }).then((info) => {
    if (current !== path) return;
    mergeInfo.inMerge = !!(info && info.inMerge);
    merge.refresh();
  }, () => {});
}

// Source Control diffs: an inline (unified) diff against the original, like VS Code's inline diff editor.
const diffSlot = new Compartment();
const diffExtension = (original) => [
  unifiedMergeView({ original, mergeControls: false, highlightChanges: true, gutter: true, syntaxHighlightDeletions: true }),
  keymap.of([{ key: 'Alt-F5', run: goToNextChunk }, { key: 'Shift-Alt-F5', run: goToPreviousChunk }]),
];

function baseExtensions(path) {
  languageName = languageFor(path).name;
  const isLua = languageName === 'Lua';
  return [
    lineNumbers({ domEventHandlers: breakpointGutterHandlers }),
    highlightActiveLineGutter(),
    highlightSpecialChars(),
    history(),
    foldGutter(),
    drawSelection(),
    dropCursor(),
    EditorState.allowMultipleSelections.of(true),
    indentOnInput(),
    bracketMatching(),
    closeBrackets(),
    highlightActiveLine(),
    highlightSelectionMatches(),
    findWidget,
    settingsExtensions(path),
    diffSlot.of([]),
    merge.extensions,
    aiCompletion(native, setAIBusy, () => current),
    longPressDocs((state, pos) => {
      if (debugPaused) return debugValueAt(debugApi, state, pos);
      return isLua ? symbolAt(state, pos) || hoverAt(state, pos) : hoverAt(state, pos);
    }, openURL),
    debugExtensions(debugApi),
    gitGutter,
    hostExtensions(),
    languageFeatures(),
    extensionKeys.of(currentExtensionKeymap()),
    keymap.of([
      { key: 'Mod-s', run: () => { save(); return true; } },
      { key: 'Mod-Shift-p', run: () => { commandPalette(); return true; } },
      { key: 'Ctrl-`', run: () => { togglePanel('terminal'); return true; } },
      { key: 'Ctrl-Shift-`', run: () => { showTerminal(true); return true; } },
      { key: 'Mod-j', run: () => { togglePanel(); return true; } },
      { key: 'Mod-Shift-m', run: () => { togglePanel('problems'); return true; } },
      { key: 'Mod-Shift-y', run: () => { togglePanel('debug'); return true; } },
      { key: 'Mod-p', run: () => { quickOpen(); return true; } },
      { key: 'F12', run: () => { goToDefinition(); return true; } },
      { key: 'F9', run: () => toggleBreakpointAtCursor(view) },
      { key: 'Shift-F12', run: () => { findReferences(); return true; } },
      { key: 'F2', run: () => { renameSymbol(); return true; } },
      { key: 'Mod-.', run: (v) => { quickFix(v); return true; } },
      { key: 'Alt-F12', run: (v) => { peekDefinition(v); return true; } },
      { key: 'Escape', run: (v) => closePeekView(v) },
      { key: 'Mod-Shift-v', run: () => { setPreview('toggle'); return true; } },
      { key: 'Mod-k Mod-t', run: () => { pickColorTheme(() => view); return true; } },
      { key: 'Mod-k v', run: () => { setPreview('side'); return true; } },
      { key: 'Mod-Shift-o', run: () => { quickOpen('@'); return true; } },
      { key: 'Ctrl-g', run: () => { quickOpen(':'); return true; } },
      { key: 'F1', run: () => { commandPalette(); return true; } },
      ...closeBracketsKeymap, ...defaultKeymap, ...searchKeymap, ...historyKeymap, ...foldKeymap, ...lintKeymap,
      indentWithTab,
    ]),
    EditorView.contentAttributes.of({ autocorrect: 'off', autocapitalize: 'off', spellcheck: 'false', translate: 'no' }),
    EditorView.updateListener.of((u) => {
      if (u.docChanged && previewMode() !== 'off') refreshPreview(true);
      if (u.docChanged && !readOnly) {
        setDirty(true);
        clearTimeout(autoSaveTimer);
        if (settings.autoSave) autoSaveTimer = setTimeout(() => { autoSaving = true; save().finally(() => { autoSaving = false; }); }, 1000);
      }
      if (u.docChanged || u.selectionSet) {
        updatePos(u.state);
        clearTimeout(crumbTimer);
        crumbTimer = setTimeout(() => updateBreadcrumbs(view.state, readOnly ? null : current), 120);
      }
      // Linting reports through effects: the Problems panel counts again.
      if (u.docChanged || u.transactions.some((t) => t.effects.length)) problemsChanged();
      if (current && !readOnly) {
        if (u.docChanged) mainChanged(current, u.transactions);
        if (u.docChanged) didChange(current, () => u.view.state.doc.toString());
        if (u.selectionSet) didSelect(current, u.state);
      }
    }),
  ];
}

const view = new EditorView({
  parent: $('editor-container'),
  state: EditorState.create({ doc: '', extensions: baseExtensions('untitled.txt') }),
});
lockScrollDirection(view.scrollDOM);

// Installed VS Code extensions: their grammars, themes and snippets (see ext/).
async function refreshExtensions() {
  await loadExtensions(native);
  resetGrammars();
  resetSnippets();
  forgetExtensionLanguages();
  forgetExtensionThemes();
  await ensureTheme();
  // Extensions' browser code runs in the extension host.
  await startHost(hostAPI).catch(() => {});
  rebuildKeymap();
}

// Keyboard shortcuts: keybindings.json's, then extensions'. A command is the Command Palette's,
// or else an extension's.
let userKeybindings = [];

function runAnyCommand(command, args = []) {
  const builtin = builtinCommands(() => view).find((c) => c.command === command);
  if (builtin) return builtin.run(...args);
  return runCommand(command, ...args);
}

function rebuildKeymap() {
  const keys = buildExtensionKeymap(runAnyCommand, () => ({
    languageId: current ? languageIdFor(current) : '',
    extname: current && current.includes('.') ? '.' + current.split('.').pop() : '',
  }), userKeybindings);
  view.dispatch({ effects: extensionKeys.reconfigure(keys) });
}

/** Reads @user/keybindings.json (JSON with comments) and applies it. */
async function loadUserKeybindings() {
  const text = await native({ cmd: 'read', path: '@user/keybindings.json' }).catch(() => '[]');
  try {
    const list = JSON.parse(stripJSONComments(String(text)) || '[]');
    userKeybindings = Array.isArray(list) ? list.filter((k) => k && typeof k.key === 'string' && typeof k.command === 'string') : [];
  } catch (e) {
    showNotification('warning', `keybindings.json isn't valid JSON: ${e.message}`, []);
    userKeybindings = [];
  }
  rebuildKeymap();
}

/** JSON with comments and trailing commas (VS Code's settings files) as plain JSON. */
function stripJSONComments(text) {
  let out = '';
  let inString = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (inString) {
      out += c;
      if (c === '\\') { out += text[++i] ?? ''; continue; }
      if (c === '"') inString = false;
      continue;
    }
    if (c === '"') { inString = true; out += c; continue; }
    if (c === '/' && text[i + 1] === '/') { while (i < text.length && text[i] !== '\n') i++; out += '\n'; continue; }
    if (c === '/' && text[i + 1] === '*') { i += 2; while (i < text.length && !(text[i] === '*' && text[i + 1] === '/')) i++; i++; continue; }
    out += c;
  }
  return out.replace(/,(\s*[\]}])/g, '$1');
}

const hostAPI = {
  native,
  view,
  current: () => (readOnly ? null : current),
  openFile: (path) => openFile(path),
  save: () => save(),
  languageIdFor,
  builtinCommands: () => builtinCommands(() => view),
};

const quickOpenAPI = { getView: () => view, native, current: () => current, openFile: (path) => openFromUser(path) };

/** A file opened from the Explorer or Quick Open: in an extension's custom editor if one is the
 * default for it, otherwise as text. */
async function openFromUser(path) {
  const editor = customEditorsFor(path).find((e) => e.priority !== 'option');
  if (editor && await openCustomEditor(editor.viewType, path, path.split('/').pop())) {
    if (dirty) await save();
    return;
  }
  return openFile(path);
}

/** View: Reopen Editor With…: the text editor or an extension's custom editor. */
async function reopenWith() {
  const tab = activeTab();
  const path = tab && (tab.path || null);
  if (!path) return;
  const editors = customEditorsFor(path);
  const items = [{ label: 'Text Editor', description: 'built-in' }, ...editors.map((e) => ({ label: e.displayName, description: e.extId }))];
  const chosen = await quickPick({ placeholder: `Select editor for '${path.split('/').pop()}'`, items });
  if (chosen == null) return;
  if (chosen === 0) { await openFile(path); return; }
  await openCustomEditor(editors[chosen - 1].viewType, path, path.split('/').pop());
}
addCommands([{ command: 'workbench.action.reopenWithEditor', title: 'View: Reopen Editor With…', run: () => reopenWith() }]);
// VS Code's settings files (App/Settings/UserSettingsFiles.swift).
addCommands([
  { command: 'workbench.action.openSettingsJson', title: 'Preferences: Open User Settings (JSON)', run: () => openFile('@user/settings.json') },
  { command: 'workbench.action.openGlobalKeybindingsFile', title: 'Preferences: Open Keyboard Shortcuts (JSON)', run: () => openFile('@user/keybindings.json') },
  {
    command: 'workbench.action.openWorkspaceSettingsFile', title: 'Preferences: Open Workspace Settings (JSON)',
    run: async () => {
      const exists = await native({ cmd: 'stat', path: '.vscode/settings.json' }).then(() => true, () => false);
      if (!exists) {
        await native({ cmd: 'write', path: '.vscode/settings.json', contents: '// Settings for this project, over your own (Preferences: Open User Settings).\n{\n}\n' });
        await native({ cmd: 'filesChanged' }).catch(() => {});
      }
      openFile('.vscode/settings.json');
    },
  },
]);
loadUserKeybindings();

function commandPalette() {
  showQuickOpen(quickOpenAPI, '>');
}

function quickOpen(value = '') {
  showQuickOpen(quickOpenAPI, value);
}
$('palette').addEventListener('click', () => commandPalette());

/** An extension theme loads once; until then the editor shows the default theme. */
async function ensureTheme() {
  if (!settings.theme.startsWith('ext:')) return;
  if (await loadExtensionTheme(settings.theme)) {
    applyChrome(settings.theme);
    pushChrome();
    view.dispatch({ effects: settingsEffects(current || 'untitled.txt') });
  }
}

function showText(path, text) {
  noteOpenedFile(path);
  $('empty-editor').hidden = true;
  setSnippetContext(languageIdFor(path), path);
  hideViewer();
  view.dom.hidden = false;
  readOnly = false;
  // Reuse the cached state (and its undo history) if the file hasn't changed on disk.
  const cached = states.get(path);
  const state = cached && cached.doc.toString() === text
    ? cached
    : EditorState.create({ doc: text, extensions: baseExtensions(path) });
  if (state === cached) languageName = languageFor(path).name;
  view.setState(state);
  // A cached state may predate a settings change.
  // and may still be showing a diff.
  if (state === cached) view.dispatch({ effects: [...settingsEffects(path), diffSlot.reconfigure([])] });
  posLabel.style.visibility = 'visible';
  updatePos(state);
  checkMergeState(path);
  updateBreadcrumbs(view.state, path);
  fileOpened(path);
  didOpen(path, view.state.doc.toString());
  showPausedLine(view, debugLocation && debugLocation.path === path ? debugLocation.line : null);
  native({ cmd: 'getBreakpoints', path }).then((list) => { if (current === path) showBreakpoints(view, list); }, () => {});
  loadOriginal(view, native, path);
}

async function openFile(path) {
  revealWebview(null);
  merge.closeReview();
  if (dirty) await save();
  hideDocsSheet();
  if (current) states.set(current, view.state);
  const seq = ++openSeq;
  current = path;
  const ext = path.includes('.') ? path.split('.').pop().toLowerCase() : '';
  let kind = kindOf(ext);
  showTab({ key: path, path, icon: ICONS[kind] });
  setDirty(false);
  $('empty-editor').hidden = true;

  if (kind === 'text') {
    try {
      // The side editor's copy when it has the file open (it may not be saved yet).
      const text = sideText(path) ?? await native({ cmd: 'read', path });
      await prepareLanguage(path);
      if (seq === openSeq) showText(path, text);
      return;
    } catch (e) {
      // A missing file opens empty so it can be created; an existing unreadable one is binary.
      const exists = await native({ cmd: 'stat', path }).then(() => true, () => false);
      if (seq !== openSeq) return;
      if (!exists) { showText(path, ''); return; }
      kind = 'binary';
      setTabIcon(path, ICONS.binary);
    }
  }

  readOnly = true;
  view.dom.hidden = true;
  posLabel.style.visibility = 'hidden';
  updateBreadcrumbs(view.state, null);
  fileOpened(path);
  let file;
  try {
    file = await native({ cmd: 'readBinary', path });
  } catch (e) {
    if (seq === openSeq) showError(String(e), ext);
    return;
  }
  if (seq === openSeq) await showBinary(path, ext, kind, file);
}

/** A file or folder was renamed (to) or deleted (to null): tabs, cached states and the open file follow. */
function pathMoved(from, to) {
  const inside = (p) => p === from || p.startsWith(from + '/');
  for (const key of [...states.keys()]) {
    if (!inside(key)) continue;
    const state = states.get(key);
    states.delete(key);
    if (to) states.set(to + key.slice(from.length), state);
  }
  const wasOpen = current && inside(current);
  const openPath = wasOpen && to ? to + current.slice(from.length) : null;
  renameTabs(from, to);
  if (!wasOpen) return;
  if (openPath) {
    states.set(openPath, view.state);
    current = null;   // reopen at the new path (language and title follow the new name)
    openFile(openPath);
  } else {
    current = null;
    setDirty(false);
    const next = activeTab();
    if (next) openFile(next.path); else showEmpty();
  }
}

/** No file open (the last tab closed). */
function showEmpty() {
  current = null;
  readOnly = true;
  setDirty(false);
  hideDocsSheet();
  hideViewer();
  view.dom.hidden = true;
  posLabel.style.visibility = 'hidden';
  updateBreadcrumbs(view.state, null);
  $('empty-editor').hidden = false;
}

async function closeTab(tab) {
  const active = activeTab();
  if (active && active.key === tab.key && dirty) await save();
  if (current && active && active.key === tab.key) states.set(current, view.state);
  const next = removeTab(tab.key);
  // Closing discards the file's editing state (undo history), as in VS Code.
  if (!tab.key.startsWith('diff:')) states.delete(tab.path);
  if (active && active.key === tab.key) {
    if (next) openFile(next.path); else showEmpty();
  }
}

setupBreadcrumbs($('breadcrumbs'), (value) => quickOpen(value));
setupSplit({ native, mainView: view, mainPath: () => (readOnly ? null : current) });
setupTasks({ native, flush: () => save() });
setupOutput();
setupDebugConsole(native);
setupProblems({ view, current: () => (readOnly ? null : current), reveal: (path, line, column) => reveal(path, line, column, 0) });
setupTerminal({
  native,
  nodeAddress: () => nodeAddress(hostAPI),
  projectPath: async () => ((await native({ cmd: 'extHostInit' }).catch(() => null)) || {}).projectPath,
  // `open file` in the terminal: files in the project open in the editor.
  openPath: async (absolute) => {
    const root = ((await native({ cmd: 'extHostInit' }).catch(() => null)) || {}).projectPath || '';
    if (root && absolute.startsWith(root + '/')) await openFile(absolute.slice(root.length + 1));
  },
});
setupWebviews({
  post: postToHost,
  showTab: (id, title) => showTab({ key: 'webview:' + id, path: '', title, icon: '◫', preview: false }),
  closeTab: (id) => { const next = removeTab('webview:' + id); if (next && !activeTab()?.key.startsWith('webview:')) openFile(next.path); },
  extensionOf: extensionFileAt,
});
setupNavigation({ native, view, current: () => (readOnly ? null : current), openFile: (path) => openFile(path) });
setupLanguageFeatures({
  fallbackDefinitions: () => fallbackDefinitions(),
  // Peek's Open: the file, with the location selected.
  reveal: async (path, from, to) => {
    if (path !== current) await openFile(path);
    if (current !== path || readOnly) return;
    const end = view.state.doc.length;
    view.dispatch({ selection: { anchor: Math.min(from, end), head: Math.min(to, end) }, effects: EditorView.scrollIntoView(Math.min(from, end), { y: 'center' }) });
    view.focus();
  },
});
setupMarkdownPreview({
  native, view, current: () => current, openFile: (path) => openFile(path), openURL,
  nodeAddress: () => nodeAddress(hostAPI),
  projectPath: async () => ((await native({ cmd: 'extHostInit' }).catch(() => null)) || {}).projectPath,
});
$('md-toggle').addEventListener('click', () => setPreview($('editor-container').clientWidth >= 640 && previewMode() === 'off' ? 'side' : 'toggle'));
setupTabs($('tabs'), {
  select: (tab) => {
    if (tab.key.startsWith('webview:')) { showTab(tab); revealWebview(tab.key.slice(8)); return; }
    revealWebview(null);
    openFile(tab.path);
  },
  close: (tab) => {
    if (tab.key.startsWith('webview:')) {
      closeWebview(tab.key.slice(8), false);
      const next = removeTab(tab.key);
      if (next && !next.key.startsWith('webview:')) openFile(next.path);
      else if (next) revealWebview(next.key.slice(8));
      else showEmpty();
      return;
    }
    closeTab(tab);
  },
});

let formatting = false;

async function save() {
  if (!current || readOnly || !dirty) return;
  // Format on Save; not for auto-saves while typing, which would move text under the cursor.
  if (settings.formatOnSave && !formatting && !autoSaving) {
    formatting = true;
    try { await formatDocument(view); } catch (e) { /* save anyway */ }
    formatting = false;
  }
  const path = current;
  const contents = view.state.doc.toString();
  try {
    await native({ cmd: 'write', path, contents });
  } catch (e) {
    // settings.json and keybindings.json are saved even when they can't be applied: say why.
    if (!path.startsWith('@user/')) throw e;
    showNotification('warning', String(e && e.message ? e.message : e), []);
  }
  if (path === current && view.state.doc.toString() === contents) setDirty(false);
  if (path === '@user/keybindings.json') loadUserKeybindings();
  didSave(path);
  previewSaved(path);
  states.set(path, view.state);
}

// Re-reads the open file after something else (pull, discard) changed it on disk.
// Unsaved edits are dropped rather than written over the new contents.
async function reload() {
  if (!current) return;
  const path = current;
  current = null;
  setDirty(false);
  await openFile(path);
}

async function jumpToLine(path, lineNumber) {
  await openFile(path);
  if (readOnly) return;
  const line = view.state.doc.line(Math.max(1, Math.min(lineNumber, view.state.doc.lines)));
  view.dispatch({
    selection: { anchor: line.from, head: line.to },
    effects: EditorView.scrollIntoView(line.from, { y: 'center' }),
  });
  view.focus();
}

// Opens a search result with the match selected. Column and length are in UTF-16 units.
async function reveal(path, lineNumber, column, length) {
  await openFile(path);
  if (readOnly || current !== path) return;
  const doc = view.state.doc;
  const line = doc.line(Math.max(1, Math.min(lineNumber, doc.lines)));
  const from = Math.min(line.from + column, line.to);
  const to = Math.min(from + length, doc.length);
  view.dispatch({ selection: { anchor: from, head: to }, effects: EditorView.scrollIntoView(from, { y: 'center' }) });
}

// A diff from Source Control. Without `modified` the working file opens editable, diffed against
// `original`; otherwise it's a read-only snapshot (the staged copy, a deleted file, a commit).
async function openDiff({ path, original, modified, title }) {
  if (modified == null) {
    await openFile(path);
    if (readOnly || current !== path) return;
  } else {
    if (dirty) await save();
    hideDocsSheet();
    if (current) states.set(current, view.state);
    ++openSeq;
    current = null;
    setDirty(false);
    hideViewer();
    view.dom.hidden = false;
    readOnly = true;
    view.setState(EditorState.create({
      doc: modified,
      extensions: [baseExtensions(path), EditorState.readOnly.of(true), EditorView.editable.of(false)],
    }));
    posLabel.style.visibility = 'visible';
    updatePos(view.state);
  }
  view.dispatch({ effects: diffSlot.reconfigure(diffExtension(original)) });
  showTab({ key: 'diff:' + path, path, title: title || path, icon: '⇄' });
  // Start at the first change, as VS Code does.
  requestAnimationFrame(() => {
    view.dispatch({ selection: { anchor: 0 } });
    goToNextChunk(view);
    view.dispatch({ effects: EditorView.scrollIntoView(view.state.selection.main.head, { y: 'center' }) });
  });
}

// Keys from the bar above the on-screen keyboard (EditorKeyBar). Real keys go through CodeMirror's
// own key handling, so Tab still accepts an AI suggestion and indents a selection.
const KEY_CODES = { Tab: 9, ArrowLeft: 37, ArrowUp: 38, ArrowRight: 39, ArrowDown: 40 };
function barKey(name) {
  if (name === 'palette') { commandPalette(); return; }
  if (readOnly) return;
  if (name === 'undo') { undo(view); return; }
  if (name === 'redo') { redo(view); return; }
  if (name === 'dismiss') { view.contentDOM.blur(); return; }
  if (name.startsWith('insert:')) {
    const text = name.slice(7);
    view.dispatch({ ...view.state.replaceSelection(text), userEvent: 'input.type', scrollIntoView: true });
    return;
  }
  const shift = name.startsWith('Shift-');
  const key = shift ? name.slice(6) : name;
  view.contentDOM.dispatchEvent(new KeyboardEvent('keydown', {
    key, code: key, keyCode: KEY_CODES[key] || 0, shiftKey: shift, bubbles: true, cancelable: true,
  }));
}

window.duocode = {
  // The CodeMirror view, for debugging in Safari's Web Inspector and for the editor test harness.
  view,
  // The extension host's log, for debugging.
  extensionOutput: () => outputLog(),
  // Awaited by the host (EditorWebView.flushSaves) before it runs the game or switches projects.
  async flush() {
    await save();
    await flushSplit();
  },
  // The side bar's extension views (App/Sidebar/ExtensionViewsPanelView.swift).
  viewChildren: (viewId, handle) => viewChildren(viewId, handle),
  viewInvoke: (viewId, handle) => viewInvoke(viewId, handle),
  viewMenu: (viewId, handle, command) => (handle ? viewMenu(viewId, handle, command) : runCommand(command)),
  viewExpand: (viewId, handle, expanded) => viewExpand(viewId, handle, expanded),
  viewCheck: (viewId, handle, checked) => viewCheck(viewId, handle, checked),
  openWebviewView: (viewId, title) => openWebviewView(viewId, title),
  // The panel under the editor (panel.js): 'problems', 'output', 'debug' or 'terminal'.
  showPanel: (tab) => showPanel(tab),
  // A Command Palette command, or an extension's, by id (for the app: Settings' buttons).
  runCommand: (name, ...args) => runAnyCommand(name, args),
  togglePanel: (tab) => togglePanel(tab),
  onEvent({ name, payload }) {
    if (name === 'openFile' && payload?.path) openFromUser(payload.path);
    if (name === 'openFileToSide' && payload?.path) openToSide(payload.path);
    if (name === 'pathMoved' && payload?.from) pathMoved(payload.from, payload.to || null);
    if (name === 'projectChanged') { clearTabs(); states.clear(); current = null; setDirty(false); }
    if (name === 'jumpToLine' && payload?.file) jumpToLine(payload.file, payload.line || 1);
    if (name === 'reveal' && payload?.file) reveal(payload.file, payload.line || 1, payload.column || 0, payload.length || 0);
    if (name === 'openDiff' && payload?.path) openDiff(payload);
    if (name === 'key' && payload?.name) barKey(payload.name);
    if (name === 'saveAll') save();
    if (name === 'reload') reload();
    if (name === 'settings') applySettings(payload);
    if (name === 'commandPalette') commandPalette();
    if (name === 'gitChanged' && current && !readOnly) loadOriginal(view, native, current);
    if (name === 'quickOpen') quickOpen(payload?.value || '');
    if (name === 'debugLocation') showDebugLocation(payload && payload.path ? payload : null);
    if (name === 'debugState') debugPaused = !!(payload && payload.paused);
    if (name === 'breakpoints' && current && !readOnly) {
      const path = current;
      native({ cmd: 'getBreakpoints', path }).then((list) => { if (current === path) showBreakpoints(view, list); }, () => {});
    }
    if (name === 'extensionConfiguration') setConfiguration(payload);
    if (name === 'escape') closeQuickInput();
    if (name === 'extensionsChanged') refreshExtensions().then(() => reload());
  },
};

/** Shows where the debugged program is paused (opening the file), or clears it. */
async function showDebugLocation(location) {
  debugLocation = location;
  if (!location) {
    if (!readOnly) showPausedLine(view, null);
    return;
  }
  if (current !== location.path) await openFile(location.path);
  if (current === location.path && !readOnly) {
    showPausedLine(view, location.line);
    showInlineValues(view, debugApi, location.line);
  }
}

/** Tells the app the theme's colours for its own side bar and activity bar. */
let lastChrome = '';
function pushChrome() {
  const colors = chromeColors(settings.theme);
  const key = settings.theme + JSON.stringify(colors);
  if (key === lastChrome) return;
  lastChrome = key;
  native({ cmd: 'themeColors', theme: settings.theme, dark: document.documentElement.style.colorScheme !== 'light', colors }).catch(() => {});
}

function applySettings(values) {
  if (!updateSettings(values)) return;
  pushChrome();
  ensureTheme();
  refreshSplit();
  if (!current || readOnly) return;
  view.dispatch({ effects: settingsEffects(current) });
  merge.refresh();
  if (!settings.autoSave) clearTimeout(autoSaveTimer);
}

native({ cmd: 'getSettings' })
  .then((values) => updateSettings(values), () => updateSettings({}))
  .then(() => pushChrome())
  .then(() => refreshExtensions().catch((e) => console.error('Extensions failed to load:', e)))
  .finally(() => openFile('main.lua'));
