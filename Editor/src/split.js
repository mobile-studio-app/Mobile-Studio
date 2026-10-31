// View: Split Editor. A second editor beside the main one (below it on a narrow screen), with
// its own file. When both show the same file they share its text: an edit in one appears in the
// other. The side editor saves as you type, as the main one does with Auto Save.
import { lockScrollDirection } from './scroll-lock.js';
import { EditorState, Annotation } from '@codemirror/state';
import {
  EditorView, keymap, lineNumbers, highlightActiveLine, highlightActiveLineGutter, highlightSpecialChars, drawSelection,
} from '@codemirror/view';
import { defaultKeymap, history, historyKeymap, indentWithTab } from '@codemirror/commands';
import { indentOnInput, bracketMatching, foldGutter, foldKeymap } from '@codemirror/language';
import { closeBrackets, closeBracketsKeymap } from '@codemirror/autocomplete';
import { searchKeymap, highlightSelectionMatches } from '@codemirror/search';
import { settingsExtensions, settingsEffects } from './settings.js';
import { prepareLanguage } from './languages.js';
import { kindOf } from './viewer.js';
import { quickPick, notify } from './ext/ui.js';

const synced = Annotation.define();
let host = null;   // { native, mainView, mainPath(), onClosed() }
let view = null;
let path = null;
let saveTimer = 0;
let dirty = false;

const $ = (id) => document.getElementById(id);

export function setupSplit(callbacks) {
  host = callbacks;
  $('side-close').addEventListener('click', () => closeSplit());
  $('side-title').addEventListener('click', () => pickSideFile());
}

export const splitPath = () => (view && !$('side-editor').hidden ? path : null);
export const sideView = () => view;

/** The side editor's text for a file, when it has that file open (so both start the same). */
export const sideText = (file) => (splitPath() === file ? view.state.doc.toString() : null);

async function save() {
  clearTimeout(saveTimer);
  if (!view || !path || !dirty) return;
  const contents = view.state.doc.toString();
  await host.native({ cmd: 'write', path, contents });
  if (view.state.doc.toString() === contents) dirty = false;
  renderTitle();
}

function renderTitle() {
  $('side-title').textContent = (path ? path.split('/').pop() : '') + (dirty ? ' ●' : '');
  $('side-title').title = path || '';
}

function extensions(file) {
  return [
    lineNumbers(), highlightActiveLineGutter(), highlightSpecialChars(), history(), foldGutter(), drawSelection(),
    EditorState.allowMultipleSelections.of(true), indentOnInput(), bracketMatching(), closeBrackets(), highlightActiveLine(),
    highlightSelectionMatches(),
    settingsExtensions(file),
    keymap.of([
      { key: 'Mod-s', run: () => { save(); return true; } },
      ...closeBracketsKeymap, ...defaultKeymap, ...searchKeymap, ...historyKeymap, ...foldKeymap, indentWithTab,
    ]),
    EditorView.contentAttributes.of({ autocorrect: 'off', autocapitalize: 'off', spellcheck: 'false', translate: 'no' }),
    EditorView.updateListener.of((u) => {
      if (!u.docChanged) return;
      // Edits made here go to the main editor when it shows the same file.
      if (host.mainPath() === path) {
        for (const tr of u.transactions) {
          if (tr.docChanged && !tr.annotation(synced)) forward(tr, host.mainView);
        }
      }
      if (u.transactions.some((tr) => tr.docChanged && !tr.annotation(synced))) {
        dirty = true;
        renderTitle();
        clearTimeout(saveTimer);
        saveTimer = setTimeout(save, 1000);
      }
    }),
  ];
}

/** Applies a transaction's changes to the other editor, or copies the whole text if they differ. */
function forward(tr, target) {
  if (target.state.doc.length === tr.startState.doc.length) {
    target.dispatch({ changes: tr.changes, annotations: synced.of(true) });
  } else {
    target.dispatch({ changes: { from: 0, to: target.state.doc.length, insert: tr.state.doc.toString() }, annotations: synced.of(true) });
  }
}

/** The main editor changed the file the side editor shows. */
export function mainChanged(file, transactions) {
  if (splitPath() !== file) return;
  for (const tr of transactions) if (tr.docChanged && !tr.annotation(synced)) forward(tr, view);
}

export const isSynced = (tr) => !!tr.annotation(synced);

/** Opens a file in the side editor (showing it if it's closed). */
export async function openToSide(file) {
  if (kindOf(file.includes('.') ? file.split('.').pop().toLowerCase() : '') !== 'text') {
    notify('info', `${file.split('/').pop()} can't open in the side editor.`, []);
    return;
  }
  await save();
  let text = null;
  if (host.mainPath() === file) text = host.mainView.state.doc.toString();
  if (text == null) text = await host.native({ cmd: 'read', path: file }).catch(() => '');
  await prepareLanguage(file);
  path = file;
  dirty = false;
  const state = EditorState.create({ doc: text, extensions: extensions(file) });
  if (!view) {
    view = new EditorView({ parent: $('side-container'), state });
    lockScrollDirection(view.scrollDOM);
  }
  else view.setState(state);
  $('side-editor').hidden = false;
  document.getElementById('editor-row').classList.add('split');
  renderTitle();
  host.mainView.requestMeasure();
}

/** View: Split Editor: the main editor's file, beside it. */
export function splitEditor() {
  const file = host.mainPath();
  if (file) openToSide(file); else pickSideFile();
}

export async function closeSplit() {
  await save();
  $('side-editor').hidden = true;
  document.getElementById('editor-row').classList.remove('split');
  path = null;
  host.mainView.requestMeasure();
}

async function pickSideFile() {
  const files = ((await host.native({ cmd: 'list' }).catch(() => [])) || []).filter((f) => kindOf(f.includes('.') ? f.split('.').pop().toLowerCase() : '') === 'text');
  const chosen = await quickPick({ placeholder: 'Open to the side', items: files.map((f) => ({ label: f.split('/').pop(), description: f.includes('/') ? f.split('/').slice(0, -1).join('/') : '' })) });
  if (chosen != null) openToSide(files[chosen]);
}
export { pickSideFile };

/** Settings changed: the side editor follows. */
export function refreshSplit() {
  if (view && path) view.dispatch({ effects: settingsEffects(path) });
}

export const flushSplit = () => save();
