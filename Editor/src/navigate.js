// Go to Definition, Find All References and Rename Symbol for files no extension understands:
// definitions are found by pattern (Lua, Python, JavaScript, C-like), references by whole word,
// in the open file first and then across the project's files of the same kind.
import { EditorView } from '@codemirror/view';
import { goToDefinition as providerDefinition } from './ext/host.js';
import { quickPick, inputBox, notify } from './ext/ui.js';

let api = null;   // { native, view, current, openFile }

export function setupNavigation(options) { api = options; }

const escapeRegExp = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const extOf = (path) => (path.includes('.') ? path.split('.').pop().toLowerCase() : '');

const FAMILIES = [
  ['lua'], ['py', 'pyw'], ['js', 'mjs', 'cjs', 'jsx', 'ts', 'tsx'], ['c', 'h', 'cc', 'cpp', 'hpp', 'm', 'mm'],
  ['glsl', 'frag', 'vert', 'fs', 'vs', 'shader'],
];
const family = (path) => FAMILIES.find((f) => f.includes(extOf(path))) || [extOf(path)];

/** Patterns that define `name`, strongest first. */
function definitionPatterns(path, name) {
  const n = escapeRegExp(name);
  switch (family(path)[0]) {
    case 'lua': return [
      new RegExp(`^\\s*local\\s+function\\s+${n}\\s*\\(`),
      new RegExp(`^\\s*function\\s+(?:[\\w.]+[.:])?${n}\\s*\\(`),
      new RegExp(`^\\s*local\\s+(?:[\\w\\s,]*,\\s*)?${n}\\b(?!\\s*[.(:[])`),
      new RegExp(`^\\s*for\\s+(?:[\\w\\s,]*,\\s*)?${n}\\b[^=]*(?:=|\\bin\\b)`),
      new RegExp(`(?:^|[\\s.])${n}\\s*=\\s*function\\b`),
      new RegExp(`^\\s*(?:[\\w.]+\\.)?${n}\\s*=(?!=)`),
    ];
    case 'py': return [
      new RegExp(`^\\s*(?:async\\s+)?def\\s+${n}\\s*\\(`),
      new RegExp(`^\\s*class\\s+${n}\\b`),
      new RegExp(`^\\s*(?:self\\.)?${n}\\s*(?::[^=]*)?=(?!=)`),
      new RegExp(`^\\s*(?:from\\s+\\S+\\s+)?import\\s+.*\\b${n}\\b`),
    ];
    case 'js': return [
      new RegExp(`\\bfunction\\*?\\s+${n}\\s*\\(`),
      new RegExp(`\\bclass\\s+${n}\\b`),
      new RegExp(`\\b(?:const|let|var)\\s+${n}\\b`),
      new RegExp(`^\\s*(?:async\\s+)?${n}\\s*\\([^)]*\\)\\s*\\{`),
      new RegExp(`\\b${n}\\s*[:=]\\s*(?:async\\s*)?(?:function|\\()`),
    ];
    default: return [
      new RegExp(`^\\s*(?:#define\\s+${n}\\b|(?:struct|class|enum|union)\\s+${n}\\b)`),
      new RegExp(`^\\s*(?:(?:static|inline|extern|const|unsigned|signed|uniform|varying|in|out)\\s+)*[\\w:<>]+[\\s*&]+${n}\\s*\\(`),
      new RegExp(`^\\s*(?:(?:static|const|uniform|extern)\\s+)*[\\w:<>]+[\\s*&]+${n}\\s*(?:=|;|\\[)`),
    ];
  }
}

/** The identifier at the cursor, and the object it's a field of ("player" in player.move). */
function wordAtCursor(state) {
  const { head } = state.selection.main;
  const line = state.doc.lineAt(head);
  const at = head - line.from;
  const word = /[\w$]/;
  let start = at, end = at;
  while (start > 0 && word.test(line.text[start - 1])) start--;
  while (end < line.text.length && word.test(line.text[end])) end++;
  if (start === end) return null;
  return { name: line.text.slice(start, end), from: line.from + start, to: line.from + end, line: line.number };
}

/** The project's files of the same kind as `path`, with the open file's unsaved text. */
async function projectFiles(path) {
  const listed = await api.native({ cmd: 'list' }).catch(() => []);
  const exts = family(path);
  const files = (Array.isArray(listed) ? listed : []).filter((f) => exts.includes(extOf(f)) && f !== path).slice(0, 300);
  const out = [{ path, text: api.view.state.doc.toString() }];
  for (const f of files) {
    const text = await api.native({ cmd: 'read', path: f }).catch(() => null);
    if (typeof text === 'string' && text.length < 2000000) out.push({ path: f, text });
  }
  return out;
}

function definitionsIn(file, patterns) {
  const found = [];
  file.text.split('\n').forEach((text, i) => {
    const rank = patterns.findIndex((re) => re.test(text));
    if (rank >= 0) found.push({ path: file.path, line: i + 1, text, rank });
  });
  return found;
}

async function reveal(path, line, name) {
  if (path !== api.current()) await api.openFile(path);
  const { view } = api;
  const doc = view.state.doc;
  const l = doc.line(Math.min(line, doc.lines));
  const col = name ? new RegExp(`\\b${escapeRegExp(name)}\\b`).exec(l.text) : null;
  const from = l.from + (col ? col.index : 0);
  view.dispatch({ selection: { anchor: from, head: from + (col ? name.length : 0) }, effects: EditorView.scrollIntoView(from, { y: 'center' }) });
  view.focus();
}

function pickLocation(placeholder, matches, name) {
  return quickPick({
    placeholder,
    items: matches.map((m) => ({ label: m.text.trim().slice(0, 140), description: `${m.path}:${m.line}`, filterText: m.path + ' ' + m.text })),
  }).then((i) => (i == null ? null : matches[i])).then((m) => m && reveal(m.path, m.line, name));
}

/** F12: an extension's definition provider, else the definition found by pattern. */
export async function goToDefinition() {
  if (await providerDefinition()) return;
  const path = api.current();
  const word = path && wordAtCursor(api.view.state);
  if (!word) return;
  const patterns = definitionPatterns(path, word.name);
  // In the open file: the nearest definition above the cursor (a local), else the first.
  const here = definitionsIn({ path, text: api.view.state.doc.toString() }, patterns).filter((d) => d.line !== word.line || d.rank === 0);
  const above = here.filter((d) => d.line <= word.line);
  const local = above.length ? above.reduce((a, b) => (b.rank < a.rank || (b.rank === a.rank && b.line > a.line) ? b : a)) : here[0];
  if (local && local.rank <= 2) { reveal(path, local.line, word.name); return; }
  const all = [];
  for (const file of await projectFiles(path)) all.push(...definitionsIn(file, patterns));
  const best = all.length ? Math.min(...all.map((d) => d.rank)) : -1;
  const matches = all.filter((d) => d.rank === best && !(d.path === path && d.line === word.line));
  if (!matches.length) { notify('info', `No definition found for '${word.name}'.`, []); return; }
  if (matches.length === 1) { reveal(matches[0].path, matches[0].line, word.name); return; }
  pickLocation(`Definitions of ${word.name}`, matches, word.name);
}

/** Shift-F12: every whole-word use of the name, across the project's files of this kind. */
export async function findReferences() {
  const path = api.current();
  const word = path && wordAtCursor(api.view.state);
  if (!word) return;
  const re = new RegExp(`(^|[^\\w$])${escapeRegExp(word.name)}(?![\\w$])`);
  const matches = [];
  for (const file of await projectFiles(path)) {
    file.text.split('\n').forEach((text, i) => { if (re.test(text)) matches.push({ path: file.path, line: i + 1, text }); });
  }
  if (!matches.length) { notify('info', `No references to '${word.name}'.`, []); return; }
  pickLocation(`${matches.length} reference${matches.length === 1 ? '' : 's'} to ${word.name}`, matches, word.name);
}

const KEYWORDS = new Set(('and break do else elseif end false for function goto if in local nil not or repeat return then true until while '
  + 'def class import from as with try except finally raise lambda pass yield None True False is global nonlocal assert del async await '
  + 'var let const new this typeof instanceof switch case default continue throw catch void delete static struct enum').split(' '));

/** F2: renames every whole-word use in the open file (one undo step). */
export async function renameSymbol() {
  const { view } = api;
  const word = wordAtCursor(view.state);
  if (!word) return;
  if (KEYWORDS.has(word.name)) { notify('info', `'${word.name}' is a keyword; it can't be renamed.`, []); return; }
  const name = await inputBox({ prompt: `Rename '${word.name}' in this file. Press Enter to rename, Escape to cancel.`, value: word.name });
  if (!name || name === word.name || !/^[A-Za-z_$][\w$]*$/.test(name)) { view.focus(); return; }
  const text = view.state.doc.toString();
  const re = new RegExp(`(^|[^\\w$])(${escapeRegExp(word.name)})(?![\\w$])`, 'g');
  const changes = [];
  for (let m = re.exec(text); m; m = re.exec(text)) {
    const from = m.index + m[1].length;
    // Fields of other objects (other.name) keep their names, unless it's the one under the cursor.
    if (text[from - 1] === '.' && from !== word.from) continue;
    changes.push({ from, to: from + word.name.length, insert: name });
  }
  view.dispatch({ changes, userEvent: 'input.rename' });
  view.focus();
}
