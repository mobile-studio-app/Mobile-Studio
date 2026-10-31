// VS Code's breadcrumbs under the tabs: the file's folders, the file, then the function the
// cursor is in. Tapping the file opens Quick Open; tapping a symbol lists the file's symbols.
import { scanSymbols } from './palette.js';

let bar = null;
let onOpen = () => {};
let lastKey = '';

export function setupBreadcrumbs(element, open) {
  bar = element;
  onOpen = open;
}

/** The functions around `line` (outermost first), judged by indentation as the scan has no ends. */
function enclosingSymbols(doc, path, line) {
  const symbols = scanSymbols(doc, path);
  const indent = (n) => /^\s*/.exec(doc.line(n).text)[0].replace(/\t/g, '    ').length;
  // A blank line belongs to whatever the next non-blank line belongs to.
  let at = line;
  while (at < doc.lines && !doc.line(at).text.trim()) at++;
  const lineIndent = indent(at);
  const chain = [];
  for (const s of symbols) {
    if (s.line > line) break;
    const own = indent(s.line);
    if (s.line !== line && lineIndent <= own) continue;
    while (chain.length && indent(chain[chain.length - 1].line) >= own) chain.pop();
    chain.push(s);
  }
  return chain;
}

function segment(text, icon, action) {
  const el = document.createElement('span');
  el.className = 'crumb';
  if (icon) {
    const i = document.createElement('span');
    i.className = 'crumb-icon ' + icon.className;
    i.textContent = icon.text;
    el.append(i);
  }
  el.append(document.createTextNode(text));
  if (action) el.addEventListener('click', action);
  return el;
}

/** Updates the bar for the open file and cursor (path null hides it). */
export function updateBreadcrumbs(state, path) {
  if (!bar) return;
  if (!path) {
    bar.hidden = true;
    lastKey = '';
    return;
  }
  bar.hidden = false;
  const line = state.doc.lineAt(state.selection.main.head).number;
  const chain = state.doc.length < 500000 ? enclosingSymbols(state.doc, path, line) : [];
  const key = path + '|' + chain.map((s) => s.name + s.line).join(',');
  if (key === lastKey) return;
  lastKey = key;
  bar.textContent = '';
  const parts = path.split('/');
  const items = [];
  parts.slice(0, -1).forEach((folder) => items.push(segment(folder, null, () => onOpen(''))));
  items.push(segment(parts[parts.length - 1], { className: 'file', text: '' }, () => onOpen('')));
  for (const s of chain) {
    items.push(segment(s.name, { className: s.kind === 4 ? 'class' : 'function', text: s.kind === 4 ? '' : '' }, () => onOpen('@')));
  }
  items.forEach((item, i) => {
    if (i) {
      const sep = document.createElement('span');
      sep.className = 'crumb-sep';
      sep.textContent = '';
      bar.append(sep);
    }
    bar.append(item);
  });
  bar.scrollLeft = bar.scrollWidth;
}
