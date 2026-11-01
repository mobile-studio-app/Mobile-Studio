// The Command Palette: the editor's own commands plus those extensions contribute.
import { EditorView } from '@codemirror/view';
import {
  toggleComment, toggleBlockComment, copyLineDown, copyLineUp, moveLineUp, moveLineDown, deleteLine,
  indentMore, indentLess, selectAll, undo, redo, cursorDocStart, cursorDocEnd, selectLine, insertBlankLine,
} from '@codemirror/commands';
import { foldAll, unfoldAll, foldCode, unfoldCode } from '@codemirror/language';
import { openSearchPanel, selectNextOccurrence, selectSelectionMatches } from '@codemirror/search';
import { quickPick, inputBox, closeQuickInput } from './ext/ui.js';
import { setPreview, reloadPreview } from './mdpreview.js';
import { toggleBreakpointAtCursor } from './debug.js';
import { settings, updateSettings, settingsEffects } from './settings.js';
import { contributions } from './ext/registry.js';
import { loadExtensionTheme } from './ext/themes.js';
import { extensionCommands, runCommand, formatDocument, documentSymbols } from './ext/host.js';
import { goToDefinition, findReferences, renameSymbol } from './navigate.js';
import { quickFix, peekDefinition } from './langfeatures.js';
import { toggleOutput } from './ext/output.js';
import { togglePanel } from './panel.js';
import { showTerminal } from './terminal.js';
import { splitEditor, closeSplit, pickSideFile } from './split.js';
import { pickTask, installPackage, installDependencies } from './tasks.js';

// Commands main.js adds (they need the open file): Reopen Editor With…
const extraCommands = [];
export function addCommands(list) { extraCommands.push(...list); }

/** Replaces every selection (or the whole line when nothing is selected) with fn(text). */
function transformSelection(view, fn) {
  const changes = view.state.selection.ranges.map((r) => {
    const range = r.empty ? view.state.doc.lineAt(r.head) : r;
    return { from: range.from, to: range.to, insert: fn(view.state.sliceDoc(range.from, range.to)) };
  });
  view.dispatch({ changes, userEvent: 'input' });
  return true;
}

function sortLines(view, descending) {
  const { state } = view;
  const sel = state.selection.main;
  const first = state.doc.lineAt(sel.empty ? 0 : sel.from);
  const last = state.doc.lineAt(sel.empty ? state.doc.length : sel.to);
  const lines = state.sliceDoc(first.from, last.to).split('\n').sort((a, b) => a.localeCompare(b));
  if (descending) lines.reverse();
  view.dispatch({ changes: { from: first.from, to: last.to, insert: lines.join('\n') }, userEvent: 'input' });
  return true;
}

function trimTrailingWhitespace(view) {
  const changes = [];
  for (let i = 1; i <= view.state.doc.lines; i++) {
    const line = view.state.doc.line(i);
    const m = /\s+$/.exec(line.text);
    if (m) changes.push({ from: line.from + m.index, to: line.to });
  }
  if (changes.length) view.dispatch({ changes, userEvent: 'input' });
  return true;
}

async function goToLine(view, value = '') {
  const line = view.state.doc.lineAt(view.state.selection.main.head);
  const text = await inputBox({ prompt: `Current line: ${line.number}. Type a line number between 1 and ${view.state.doc.lines}, optionally followed by :column.`, placeholder: ':line[:column]', value, selectValue: false });
  if (!text) return;
  const [l, c] = text.replace(/^:/, '').split(/[:,]/).map((x) => parseInt(x, 10));
  if (!l) return;
  const target = view.state.doc.line(Math.max(1, Math.min(l, view.state.doc.lines)));
  const pos = Math.min(target.from + Math.max(0, (c || 1) - 1), target.to);
  view.dispatch({ selection: { anchor: pos }, effects: EditorView.scrollIntoView(pos, { y: 'center' }) });
  view.focus();
}

// MARK: - Color Theme

const BUILT_IN_THEMES = [
  { id: 'light-plus', label: 'Light+', dark: false },
  { id: 'dark-plus', label: 'Dark+ (default)', dark: true },
  { id: 'monokai', label: 'Monokai', dark: true },
  { id: 'one-dark', label: 'One Dark', dark: true },
  { id: 'solarized-dark', label: 'Solarized Dark', dark: true },
];

/** Preferences: Color Theme. Moving through the list previews each theme, as VS Code does. */
async function pickColorTheme(getView) {
  const view = getView();
  const themes = [...BUILT_IN_THEMES];
  for (const [id, t] of contributions.themes) {
    themes.push({ id, label: t.label, dark: t.uiTheme ? t.uiTheme !== 'vs' : true, description: 'extension' });
  }
  const light = themes.filter((t) => !t.dark);
  const dark = themes.filter((t) => t.dark);
  const items = [];
  if (light.length) items.push({ separator: true, label: 'light themes' });
  light.forEach((t) => items.push({ label: t.label, description: t.description, theme: t.id }));
  items.push({ separator: true, label: 'dark themes' });
  dark.forEach((t) => items.push({ label: t.label, description: t.description, theme: t.id }));
  const original = settings.theme;
  const show = async (id) => {
    if (id.startsWith('ext:') && !(await loadExtensionTheme(id))) return;
    updateSettings({ theme: id });
    view.dispatch({ effects: settingsEffects(quickOpenAPI?.current() || 'untitled.txt') });
  };
  let previewing = 0;
  const chosen = await quickPick({
    placeholder: 'Select Color Theme (Up/Down Keys to Preview)',
    items,
    activeIndex: items.findIndex((i) => i.theme === original),
    onActive: (index) => {
      const id = items[index]?.theme;
      if (!id) return;
      const seq = ++previewing;
      setTimeout(() => { if (seq === previewing) show(id); }, 60);
    },
  });
  previewing++;
  const id = chosen == null ? null : items[chosen]?.theme;
  if (!id) { await show(original); view.focus(); return; }
  await show(id);
  window.webkit?.messageHandlers?.duocode?.postMessage({ cmd: 'setTheme', id }).catch?.(() => {});
  view.focus();
}

const appCommand = (cmd) => window.webkit?.messageHandlers?.duocode?.postMessage({ cmd }).catch?.(() => {});

/** The editor's built-in commands, with VS Code's ids so extensions can run them too. */
export { pickColorTheme };

export function builtinCommands(getView) {
  const v = (fn) => () => { const view = getView(); fn(view); view.focus(); return true; };
  return [
    { command: 'editor.action.formatDocument', title: 'Format Document', keybinding: '⇧⌥F', run: () => formatDocument(getView()) },
    { command: 'editor.action.revealDefinition', title: 'Go to Definition', keybinding: 'F12', run: () => goToDefinition() },
    { command: 'editor.action.goToReferences', title: 'Find All References', keybinding: '⇧F12', run: () => findReferences() },
    { command: 'editor.action.rename', title: 'Rename Symbol', keybinding: 'F2', run: () => renameSymbol() },
    { command: 'editor.action.peekDefinition', title: 'Peek Definition', keybinding: '⌥F12', run: () => peekDefinition(getView()) },
    { command: 'editor.action.referenceSearch.trigger', title: 'Peek References', keybinding: '⇧F12', run: () => findReferences() },
    { command: 'editor.action.quickFix', title: 'Quick Fix...', keybinding: '⌘.', run: () => quickFix(getView()) },
    { command: 'workbench.action.gotoSymbol', title: 'Go to Symbol in Editor…', keybinding: '⇧⌘O', run: () => showSymbols(getView) },
    { command: 'workbench.action.gotoLine', title: 'Go to Line/Column…', keybinding: '⌃G', run: () => goToLine(getView()) },
    { command: 'workbench.action.quickOpen', title: 'Go to File…', keybinding: '⌘P', run: () => quickOpenAPI && showQuickOpen(quickOpenAPI) },
    { command: 'actions.find', title: 'Find', keybinding: '⌘F', run: v(openSearchPanel) },
    { command: 'editor.action.startFindReplaceAction', title: 'Replace', keybinding: '⌥⌘F', run: v(openSearchPanel) },
    { command: 'editor.action.commentLine', title: 'Toggle Line Comment', keybinding: '⌘/', run: v(toggleComment) },
    { command: 'editor.action.blockComment', title: 'Toggle Block Comment', keybinding: '⇧⌥A', run: v(toggleBlockComment) },
    { command: 'editor.foldAll', title: 'Fold All', run: v(foldAll) },
    { command: 'editor.unfoldAll', title: 'Unfold All', run: v(unfoldAll) },
    { command: 'editor.fold', title: 'Fold', run: v(foldCode) },
    { command: 'editor.unfold', title: 'Unfold', run: v(unfoldCode) },
    { command: 'editor.action.copyLinesDownAction', title: 'Copy Line Down', keybinding: '⇧⌥↓', run: v(copyLineDown) },
    { command: 'editor.action.copyLinesUpAction', title: 'Copy Line Up', keybinding: '⇧⌥↑', run: v(copyLineUp) },
    { command: 'editor.action.moveLinesDownAction', title: 'Move Line Down', keybinding: '⌥↓', run: v(moveLineDown) },
    { command: 'editor.action.moveLinesUpAction', title: 'Move Line Up', keybinding: '⌥↑', run: v(moveLineUp) },
    { command: 'editor.action.deleteLines', title: 'Delete Line', keybinding: '⇧⌘K', run: v(deleteLine) },
    { command: 'editor.action.insertLineAfter', title: 'Insert Line Below', keybinding: '⌘↵', run: v(insertBlankLine) },
    { command: 'editor.action.indentLines', title: 'Indent Line', keybinding: '⌘]', run: v(indentMore) },
    { command: 'editor.action.outdentLines', title: 'Outdent Line', keybinding: '⌘[', run: v(indentLess) },
    { command: 'expandLineSelection', title: 'Expand Line Selection', keybinding: '⌘L', run: v(selectLine) },
    { command: 'editor.action.addSelectionToNextFindMatch', title: 'Add Selection to Next Find Match', keybinding: '⌘D', run: v(selectNextOccurrence) },
    { command: 'editor.action.selectHighlights', title: 'Select All Occurrences of Find Match', keybinding: '⇧⌘L', run: v(selectSelectionMatches) },
    { command: 'editor.action.selectAll', title: 'Select All', keybinding: '⌘A', run: v(selectAll) },
    { command: 'cursorTop', title: 'Go to Beginning of File', run: v(cursorDocStart) },
    { command: 'cursorBottom', title: 'Go to End of File', run: v(cursorDocEnd) },
    { command: 'editor.action.transformToUppercase', title: 'Transform to Uppercase', run: v((view) => transformSelection(view, (t) => t.toUpperCase())) },
    { command: 'editor.action.transformToLowercase', title: 'Transform to Lowercase', run: v((view) => transformSelection(view, (t) => t.toLowerCase())) },
    { command: 'editor.action.transformToTitlecase', title: 'Transform to Title Case', run: v((view) => transformSelection(view, (t) => t.replace(/\b\w/g, (c) => c.toUpperCase()))) },
    { command: 'editor.action.sortLinesAscending', title: 'Sort Lines Ascending', run: v((view) => sortLines(view, false)) },
    { command: 'editor.action.sortLinesDescending', title: 'Sort Lines Descending', run: v((view) => sortLines(view, true)) },
    { command: 'editor.action.trimTrailingWhitespace', title: 'Trim Trailing Whitespace', run: v(trimTrailingWhitespace) },
    { command: 'undo', title: 'Undo', keybinding: '⌘Z', run: v(undo) },
    { command: 'redo', title: 'Redo', keybinding: '⇧⌘Z', run: v(redo) },
    { command: 'workbench.action.output.toggleOutput', title: 'View: Toggle Output', keybinding: '⇧⌘U', run: () => toggleOutput() },
    { command: 'workbench.action.togglePanel', title: 'View: Toggle Panel', keybinding: '⌘J', run: () => togglePanel() },
    { command: 'workbench.action.terminal.toggleTerminal', title: 'View: Toggle Terminal', keybinding: '⌃`', run: () => togglePanel('terminal') },
    { command: 'workbench.action.terminal.new', title: 'Terminal: Create New Terminal', keybinding: '⌃⇧`', run: () => showTerminal(true) },
    { command: 'workbench.actions.view.problems', title: 'View: Toggle Problems', keybinding: '⇧⌘M', run: () => togglePanel('problems') },
    { command: 'workbench.debug.action.toggleRepl', title: 'View: Toggle Debug Console', keybinding: '⇧⌘Y', run: () => togglePanel('debug') },
    { command: 'workbench.action.splitEditor', title: 'View: Split Editor', keybinding: '⌘\\', run: () => splitEditor() },
    { command: 'workbench.action.quickOpenToSide', title: 'View: Open File to the Side…', run: () => pickSideFile() },
    { command: 'workbench.action.closeEditorsInOtherGroups', title: 'View: Close Split Editor', run: () => closeSplit() },
    { command: 'workbench.action.tasks.runTask', title: 'Tasks: Run Task', run: () => pickTask() },
    { command: 'workbench.action.tasks.build', title: 'Tasks: Run Build Task', keybinding: '⇧⌘B', run: () => pickTask('build') },
    { command: 'workbench.action.tasks.test', title: 'Tasks: Run Test Task', run: () => pickTask('test') },
    { command: 'npm.installPackage', title: 'npm: Install Package…', run: () => installPackage() },
    { command: 'npm.installDependencies', title: 'npm: Install Dependencies', run: () => installDependencies() },
    ...extraCommands,
    { command: 'workbench.action.selectTheme', title: 'Preferences: Color Theme', keybinding: '⌘K ⌘T', run: () => pickColorTheme(getView) },
    { command: 'workbench.action.openSettings', title: 'Preferences: Open Settings', keybinding: '⌘,', run: () => appCommand('settings') },
    { command: 'workbench.view.extensions', title: 'View: Show Extensions', keybinding: '⇧⌘X', run: () => appCommand('showExtensions') },
    { command: 'workbench.view.debug', title: 'View: Show Run and Debug', run: () => appCommand('showDebug') },
    { command: 'workbench.view.scm', title: 'View: Show Source Control', keybinding: '⌃⇧G', run: () => appCommand('showSourceControl') },
    { command: 'workbench.view.search', title: 'View: Show Search', keybinding: '⇧⌘F', run: () => appCommand('showSearch') },
    { command: 'workbench.view.explorer', title: 'View: Show Explorer', keybinding: '⇧⌘E', run: () => appCommand('showExplorer') },
    { command: 'markdown.showPreview', title: 'Markdown: Open Preview', keybinding: '⇧⌘V', run: () => setPreview('full') },
    { command: 'markdown.showPreviewToSide', title: 'Markdown: Open Preview to the Side', keybinding: '⌘K V', run: () => setPreview('side') },
    { command: 'livePreview.start.preview.atFile', title: 'Live Preview: Show Preview', run: () => setPreview('side') },
    { command: 'livePreview.start.preview.atFileFull', title: 'Live Preview: Show Preview in Place of the Editor', run: () => setPreview('full') },
    { command: 'livePreview.end', title: 'Live Preview: Stop Preview', run: () => setPreview('off') },
    { command: 'livePreview.reload', title: 'Live Preview: Reload Preview', run: () => reloadPreview() },
    // The app's own commands (IDEViewController.handle(command:)).
    { command: 'editor.debug.action.toggleBreakpoint', title: 'Debug: Toggle Breakpoint', keybinding: 'F9', run: v(toggleBreakpointAtCursor) },
    { command: 'workbench.action.debug.run', title: 'Run: Run Without Debugging', run: () => appCommand('run') },
    { command: 'workbench.action.debug.start', title: 'Run: Start Debugging', keybinding: '⇧⌘D', run: () => appCommand('debug') },
    { command: 'workbench.action.debug.stop', title: 'Run: Stop', keybinding: '⌘.', run: () => appCommand('stop') },
    { command: 'mobilestudio.startRepl', title: 'Run: Start REPL', run: () => appCommand('repl') },
    { command: 'mobilestudio.toggleRunConsole', title: 'View: Toggle Run Console', run: () => appCommand('toggleConsole') },
  ];
}

const recent = [];

// MARK: - Symbols

const SYMBOL_KINDS = ['file', 'module', 'namespace', 'package', 'class', 'method', 'property', 'field', 'constructor', 'enum', 'interface', 'function', 'variable', 'constant', 'string', 'number', 'boolean', 'array', 'object', 'key', 'null', 'enum member', 'struct', 'event', 'operator', 'type parameter'];

/** Functions and classes found by pattern, for languages without a symbol provider. */
export function scanSymbols(doc, path = '') {
  const cLike = /\.(c|h|cc|cpp|hpp|m|mm|glsl|frag|vert|fs|vs|shader|cs|java)$/i.test(path);
  const patterns = [
    [/^\s*(?:local\s+)?function\s+([\w.:]+)\s*\(/, 'function'],          // Lua
    [/^\s*(?:local\s+)?([\w.]+)\s*=\s*function\s*\(/, 'function'],
    [/^(\s*)(?:async\s+)?def\s+(\w+)\s*\(/, 'function', true],                 // Python
    [/^(\s*)class\s+(\w+)/, 'class', true],
    [/^\s*(?:export\s+)?(?:async\s+)?function\*?\s+(\w+)/, 'function'],    // JavaScript
    [/^\s*(?:export\s+)?class\s+(\w+)/, 'class'],
    // C-like: a return type, then name(...) without a semicolon.
    ...(cLike ? [[/^\s*(?:(?:static|inline|extern|const|unsigned|signed)\s+)*[\w:<>]+[\s*&]+(\w+)\s*\([^;]*\)\s*\{?\s*$/, 'function']] : []),
  ];
  const out = [];
  for (let i = 1; i <= doc.lines; i++) {
    const text = doc.line(i).text;
    for (const [re, kind, indented] of patterns) {
      const m = re.exec(text);
      if (!m) continue;
      const name = indented ? m[2] : m[1];
      if (/^(if|for|while|switch|return|else)$/.test(name)) break;
      const depth = indented ? Math.floor(m[1].replace(/\t/g, '    ').length / 4) : 0;
      out.push({ name, kind: kind === 'class' ? 4 : 11, depth, line: i });
      break;
    }
  }
  return out;
}

async function showSymbols(getView, value = '') {
  const view = getView();
  let symbols = (await documentSymbols()).map((s) => ({ name: s.name, kind: s.kind, depth: s.depth, line: s.range.start.line + 1, character: s.range.start.character }));
  if (!symbols.length) symbols = scanSymbols(view.state.doc, quickOpenAPI?.current() || '');
  if (!symbols.length) {
    await quickPick({ placeholder: 'No symbols found in this file.', items: [] });
    view.focus();
    return;
  }
  let switched = null;
  const chosen = await quickPick({
    placeholder: 'Go to symbol in editor',
    prefix: '@',
    value: '@' + value,
    selectValue: false,
    items: symbols.map((s) => ({ label: '\u00a0'.repeat(s.depth * 2) + s.name, description: SYMBOL_KINDS[s.kind] || '', filterText: s.name })),
    onFilter: (v) => { if (!v.startsWith('@')) { switched = v; closeQuickInput(); } },
  });
  if (switched != null) { quickOpenAPI && showQuickOpen(quickOpenAPI, switched); return; }
  if (chosen == null) { view.focus(); return; }
  const s = symbols[chosen];
  const line = view.state.doc.line(Math.min(s.line, view.state.doc.lines));
  const from = Math.min(line.from + (s.character || 0), line.to);
  view.dispatch({ selection: { anchor: from }, effects: EditorView.scrollIntoView(from, { y: 'center' }) });
  view.focus();
}

// MARK: - Quick Open

const recentFiles = [];
let quickOpenAPI = null;

/** Remembers opened files for Quick Open's "recently opened". */
export function noteOpenedFile(path) {
  const i = recentFiles.indexOf(path);
  if (i >= 0) recentFiles.splice(i, 1);
  recentFiles.unshift(path);
  recentFiles.length = Math.min(recentFiles.length, 20);
}

/**
 * VS Code's Quick Open (⌘P): files by name, recently opened first. Typing ">" switches to the
 * Command Palette, ":" to Go to Line and "@" to Go to Symbol, as in VS Code.
 * `api` has getView, native, current and openFile.
 */
export async function showQuickOpen(api, value = '') {
  quickOpenAPI = api;
  if (value.startsWith('>')) return showCommandPalette(api.getView, [], value);
  if (value.startsWith('@')) return showSymbols(api.getView, value.slice(1));
  if (value.startsWith(':')) return goToLine(api.getView(), value.slice(1));
  const listed = await api.native({ cmd: 'list' }).catch(() => []);
  const files = (Array.isArray(listed) ? listed : []).filter((f) => !f.startsWith('.'));
  const current = api.current();
  const recent = recentFiles.filter((f) => f !== current && files.includes(f));
  const rest = files.filter((f) => !recent.includes(f) && f !== current).sort();
  const item = (f) => ({ label: f.split('/').pop(), description: f.includes('/') ? f.slice(0, f.lastIndexOf('/')) : '', filterText: f, path: f });
  const items = [];
  if (recent.length) items.push({ separator: true, label: 'recently opened' });
  recent.forEach((f) => items.push(item(f)));
  if (recent.length && rest.length) items.push({ separator: true, label: 'files' });
  rest.forEach((f) => items.push(item(f)));
  if (current && files.includes(current)) items.push(item(current));
  let switched = null;
  const chosen = await quickPick({
    placeholder: 'Search files by name (append : to go to line or @ to go to symbol)',
    items,
    value,
    selectValue: false,
    onFilter: (v) => { if (/^[>@:]/.test(v)) { switched = v; closeQuickInput(); } },
  });
  if (switched != null) return showQuickOpen(api, switched);
  if (chosen == null || !items[chosen]?.path) { api.getView().focus(); return; }
  await api.openFile(items[chosen].path);
}

/** Shows the palette: recently used first, then everything alphabetically. */
export async function showCommandPalette(getView, extra = [], value = '>') {
  const builtins = builtinCommands(getView);
  const ext = await extensionCommands();
  const all = [
    ...builtins.map((c) => ({ ...c, source: 'builtin' })),
    ...extra,
    ...ext.map((c) => ({ command: c.command, title: c.title, description: c.extension, source: 'extension' })),
  ];
  const byId = new Map(all.map((c) => [c.command, c]));
  const recents = recent.map((id) => byId.get(id)).filter(Boolean);
  const rest = all.filter((c) => !recent.includes(c.command)).sort((a, b) => a.title.localeCompare(b.title));
  const ordered = [...recents, ...rest];
  const items = [];
  if (recents.length) items.push({ separator: true, label: 'recently used' });
  recents.forEach((c) => items.push({ label: c.title, description: c.description, keybinding: c.keybinding }));
  if (recents.length) items.push({ separator: true, label: 'other commands' });
  rest.forEach((c) => items.push({ label: c.title, description: c.description, keybinding: c.keybinding }));
  // Indices in `items` skip separators; map back to commands.
  const commandAt = [];
  items.forEach((item, i) => { if (!item.separator) commandAt[i] = ordered[commandAt.filter(Boolean).length]; });
  let switched = null;
  const chosen = await quickPick({
    placeholder: 'Type the name of a command to run.',
    items,
    prefix: '>',
    value,
    selectValue: false,
    onFilter: (v) => { if (!v.startsWith('>')) { switched = v; closeQuickInput(); } },
  });
  if (switched != null && quickOpenAPI) { showQuickOpen(quickOpenAPI, switched); return; }
  const command = chosen == null ? null : commandAt[chosen];
  if (!command) { getView().focus(); return; }
  const seen = recent.indexOf(command.command);
  if (seen >= 0) recent.splice(seen, 1);
  recent.unshift(command.command);
  recent.length = Math.min(recent.length, 5);
  if (command.source === 'extension') runCommand(command.command);
  else command.run();
}
