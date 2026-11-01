// The side-by-side diff editor, VS Code's default on a wide screen: the original on the left
// (read-only) and the file on the right, lined up, with the changes marked and arrows to revert a
// change. The right side's edits go to the main editor (hidden meanwhile), which saves them, so
// autosave, format on save and the dirty dot work as they do for any file.
import { MergeView } from '@codemirror/merge';
import { EditorView, keymap, lineNumbers, highlightActiveLine, drawSelection } from '@codemirror/view';
import { EditorState } from '@codemirror/state';
import { history, historyKeymap, defaultKeymap, indentWithTab } from '@codemirror/commands';
import { settingsExtensions } from './settings.js';

const $ = (id) => document.getElementById(id);
let merge = null;
let mainView = null;

/** Side by side unless turned off (Toggle Inline View), and only where there's room. */
export function wantsSideBySide() {
  let saved = null;
  try { saved = localStorage.getItem('diff.renderSideBySide'); } catch (e) { /* no storage */ }
  return saved !== 'false' && $('editor-container').clientWidth >= 700;
}

export function setSideBySidePreference(on) {
  try { localStorage.setItem('diff.renderSideBySide', on ? 'true' : 'false'); } catch (e) { /* no storage */ }
}

export const isSideBySide = () => merge !== null;

/** Shows `view`'s document (path) beside `original`. `readOnly`: a snapshot (staged, a commit). */
export function openSideBySide({ view, path, original, readOnly, save }) {
  closeSideBySide();
  mainView = view;
  const host = $('diff-side');
  const common = (editable) => [
    lineNumbers(),
    drawSelection(),
    highlightActiveLine(),
    history(),
    keymap.of([
      { key: 'Mod-s', run: () => { save(); return true; } },
      { key: 'Alt-F5', run: () => goToChunk(1) },
      { key: 'Shift-Alt-F5', run: () => goToChunk(-1) },
      indentWithTab, ...defaultKeymap, ...historyKeymap,
    ]),
    settingsExtensions(path),
    editable ? [] : [EditorState.readOnly.of(true), EditorView.editable.of(false)],
  ];
  let syncing = false;
  merge = new MergeView({
    a: { doc: original, extensions: common(false) },
    b: {
      doc: view.state.doc,
      extensions: [
        common(!readOnly),
        // Edits (typing, reverting a change) go to the main editor.
        EditorView.updateListener.of((u) => {
          if (!u.docChanged || syncing || !mainView) return;
          syncing = true;
          try { mainView.dispatch({ changes: u.changes, userEvent: 'input' }); } finally { syncing = false; }
        }),
      ],
    },
    parent: host,
    highlightChanges: true,
    gutter: true,
    revertControls: readOnly ? undefined : 'a-to-b',
  });
  host.hidden = false;
  view.dom.hidden = true;
  // Start at the first change, as VS Code does.
  requestAnimationFrame(() => {
    if (!merge || !merge.chunks.length) return;
    const first = merge.chunks[0];
    merge.b.dispatch({ selection: { anchor: Math.min(first.fromB, merge.b.state.doc.length) }, effects: EditorView.scrollIntoView(Math.min(first.fromB, merge.b.state.doc.length), { y: 'center' }) });
  });
  return merge;
}

/** Back to the single editor (another file opened, the tab closed, or Toggle Inline View). */
export function closeSideBySide() {
  if (!merge) return;
  merge.destroy();
  merge = null;
  const host = $('diff-side');
  host.hidden = true;
  host.replaceChildren();
  if (mainView) mainView.dom.hidden = false;
  mainView = null;
}

/** The next or previous change in the side-by-side diff (Alt+F5 / Shift+Alt+F5). */
export function goToChunk(direction) {
  if (!merge || !merge.chunks.length) return false;
  const head = merge.b.state.selection.main.head;
  const chunks = merge.chunks;
  const next = direction > 0
    ? chunks.find((c) => c.fromB > head) || chunks[0]
    : [...chunks].reverse().find((c) => c.fromB < head) || chunks[chunks.length - 1];
  const at = Math.min(next.fromB, merge.b.state.doc.length);
  merge.b.dispatch({ selection: { anchor: at }, effects: EditorView.scrollIntoView(at, { y: 'center' }) });
  merge.b.focus();
  return true;
}
