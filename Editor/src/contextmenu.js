// The editor's context menu, as VS Code has it: Go to Definition, Rename, Format, Edit with AI,
// extensions' editor/context commands, Cut/Copy/Paste and the Command Palette. It opens with a
// right click (a mouse or trackpad), or by holding a finger still on one spot, before iOS's own
// long press (text selection) would start; moving while holding moves the cursor as usual. A symbol
// with docs gets Show Docs first (long press used to open them directly).
import { EditorView } from '@codemirror/view';

// { runCommand(name), extensionItems() → [{ label, run }], native, docsAt(state, pos) → sym | Promise, showDocs(sym) }
let options = null;
let menu = null;
let opened = 0;

const HOLD_MS = 420;
const HOLD_SLOP = 8;   // px a finger may move and still be holding still

export function setupContextMenu(o) { options = o; }

function close() {
  if (!menu) return;
  menu.remove();
  menu = null;
  document.removeEventListener('pointerdown', outside, true);
  document.removeEventListener('keydown', key, true);
}

function outside(e) { if (menu && !menu.contains(e.target)) close(); }

function key(e) {
  if (!menu) return;
  const items = [...menu.querySelectorAll('.ctx-item:not([aria-disabled="true"])')];
  const at = items.indexOf(document.activeElement);
  if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); close(); }
  else if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
    e.preventDefault();
    e.stopPropagation();
    const next = items[(at + (e.key === 'ArrowDown' ? 1 : items.length - 1) + (at < 0 && e.key === 'ArrowUp' ? 1 : 0)) % items.length];
    if (next) next.focus();
  }
}

/** The menu's items for the editor as it is: [{ label, keys?, run, disabled? } | 'separator']. */
function itemsFor(view) {
  const selected = !view.state.selection.main.empty;
  const run = (name) => () => options.runCommand(name);
  const extension = (options.extensionItems && options.extensionItems()) || [];
  return [
    { label: 'Go to Definition', keys: 'F12', run: run('editor.action.revealDefinition') },
    { label: 'Go to References', keys: '⇧F12', run: run('editor.action.goToReferences') },
    { label: 'Peek Definition', keys: '⌥F12', run: run('editor.action.peekDefinition') },
    { label: 'Peek References', run: run('editor.action.referenceSearch.trigger') },
    'separator',
    { label: 'Rename Symbol', keys: 'F2', run: run('editor.action.rename') },
    { label: 'Change All Occurrences', keys: '⌘F2', run: run('editor.action.selectHighlights') },
    { label: 'Format Document', keys: '⇧⌥F', run: run('editor.action.formatDocument') },
    ...(selected ? [{ label: 'Format Selection', keys: '⌘K ⌘F', run: run('editor.action.formatSelection') }] : []),
    { label: 'Quick Fix…', keys: '⌘.', run: run('editor.action.quickFix') },
    'separator',
    { label: 'Edit with AI…', keys: '⌘I', run: run('mobilestudio.chat.inlineEdit') },
    { label: 'Explain with Chat', run: run('mobilestudio.chat.explain') },
    { label: 'Fix with Chat', run: run('mobilestudio.chat.fix') },
    ...(extension.length ? ['separator', ...extension] : []),
    'separator',
    { label: 'Cut', keys: '⌘X', disabled: !selected, run: () => cut(view) },
    { label: 'Copy', keys: '⌘C', disabled: !selected, run: () => copy(view) },
    { label: 'Paste', keys: '⌘V', run: () => paste(view) },
    'separator',
    { label: 'Command Palette…', keys: '⇧⌘P', run: run('workbench.action.showCommands') },
  ];
}

function copy(view) {
  const text = view.state.sliceDoc(view.state.selection.main.from, view.state.selection.main.to);
  navigator.clipboard?.writeText(text).catch(() => {});
  options.native?.({ cmd: 'clipboardWrite', text }).catch(() => {});
}

function cut(view) {
  copy(view);
  view.dispatch(view.state.replaceSelection(''), { userEvent: 'delete.cut' });
}

async function paste(view) {
  const text = await (options.native ? options.native({ cmd: 'clipboardRead' }) : navigator.clipboard.readText()).catch(() => '');
  if (text) view.dispatch({ ...view.state.replaceSelection(String(text)), userEvent: 'input.paste', scrollIntoView: true });
  view.focus();
}

/** Opens the menu at (x, y) for the editor. The cursor moves there first, unless it's inside the
 * selection (which the menu then acts on). */
export function openContextMenu(view, x, y) {
  // A long press can also fire contextmenu: one menu.
  if (menu && Date.now() - opened < 400) return;
  close();
  opened = Date.now();
  const pos = view.posAtCoords({ x, y });
  const sel = view.state.selection.main;
  if (pos != null && (pos < sel.from || pos > sel.to)) view.dispatch({ selection: { anchor: pos } });
  menu = document.createElement('div');
  menu.className = 'ctx-menu';
  menu.setAttribute('role', 'menu');
  for (const item of itemsFor(view)) {
    if (item === 'separator') {
      if (menu.lastChild && !menu.lastChild.classList.contains('ctx-separator')) menu.append(Object.assign(document.createElement('div'), { className: 'ctx-separator' }));
      continue;
    }
    const row = document.createElement('button');
    row.className = 'ctx-item';
    row.setAttribute('role', 'menuitem');
    row.append(Object.assign(document.createElement('span'), { className: 'ctx-label', textContent: item.label }));
    if (item.keys) row.append(Object.assign(document.createElement('span'), { className: 'ctx-keys', textContent: item.keys }));
    if (item.disabled) row.setAttribute('aria-disabled', 'true');
    row.addEventListener('click', (e) => {
      e.preventDefault();
      if (item.disabled) return;
      close();
      view.focus();
      item.run();
    });
    menu.append(row);
  }
  if (menu.lastChild && menu.lastChild.classList.contains('ctx-separator')) menu.lastChild.remove();
  document.body.append(menu);
  const place = () => {
    // On screen: beside the point, flipped to fit.
    const r = menu.getBoundingClientRect();
    menu.style.left = Math.max(4, Math.min(x, window.innerWidth - r.width - 4)) + 'px';
    menu.style.top = (y + r.height + 4 > window.innerHeight ? Math.max(4, y - r.height) : y) + 'px';
  };
  place();
  document.addEventListener('pointerdown', outside, true);
  document.addEventListener('keydown', key, true);
  // The symbol's docs, when it has any (an extension's hover may take a moment).
  const shown = menu;
  if (pos != null && options.docsAt) {
    Promise.resolve(options.docsAt(view.state, pos)).catch(() => null).then((sym) => {
      if (!sym || menu !== shown) return;
      const row = document.createElement('button');
      row.className = 'ctx-item';
      row.setAttribute('role', 'menuitem');
      row.append(Object.assign(document.createElement('span'), { className: 'ctx-label', textContent: 'Show Docs' }));
      row.addEventListener('click', (e) => { e.preventDefault(); close(); options.showDocs(sym); });
      menu.prepend(row, Object.assign(document.createElement('div'), { className: 'ctx-separator' }));
      place();
    });
  }
}

/** The editor extension: right click, and holding a finger still. */
export function contextMenuExtension() {
  let hold = null;   // { x, y, timer, fired }
  const cancel = () => { if (hold) clearTimeout(hold.timer); hold = null; };
  return EditorView.domEventHandlers({
    contextmenu(e, view) {
      e.preventDefault();
      openContextMenu(view, e.clientX, e.clientY);
      return true;
    },
    touchstart(e, view) {
      cancel();
      if (e.touches.length !== 1) return false;
      const t = e.touches[0];
      hold = { x: t.clientX, y: t.clientY, fired: false };
      // Held still: the menu, before iOS starts its own text selection.
      hold.timer = setTimeout(() => {
        if (!hold) return;
        hold.fired = true;
        window.getSelection()?.removeAllRanges();
        openContextMenu(view, hold.x, hold.y);
      }, HOLD_MS);
      return false;
    },
    touchmove(e) {
      const t = e.touches[0];
      if (hold && !hold.fired && t && Math.hypot(t.clientX - hold.x, t.clientY - hold.y) > HOLD_SLOP) cancel();
      return false;
    },
    touchend(e) {
      if (!hold) return false;
      const { fired } = hold;
      cancel();
      // Swallow the end of the press that opened the menu, so no callout or selection follows.
      if (fired) e.preventDefault();
      return fired;
    },
    touchcancel() { cancel(); return false; },
    scroll() { close(); return false; },
  });
}
