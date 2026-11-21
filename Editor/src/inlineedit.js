// Edit with AI (⌘I, or the editor's context menu): describe a change to the selected lines (or,
// with nothing selected, code to write at the cursor's line), and the Chat model rewrites them in
// place (chat.js's editWithAI, no tools). The result shows as a diff in the editor: the new lines
// highlighted, the old ones struck through above them, with Accept (⌘↩), Reject (Esc) and Try Again.
import { StateField, StateEffect } from '@codemirror/state';
import { EditorView, Decoration, WidgetType, keymap } from '@codemirror/view';
import { Prec } from '@codemirror/state';

// { edit({ instruction, code, path, before, after }) → { code } | { error }, stop(), current() → path }
let api = null;
export function setupInlineEdit(o) { api = o; }

// The edit going on: { phase: 'prompt' | 'working' | 'error' | 'review', from, to, original, instruction, message }.
const setEdit = StateEffect.define();

const editField = StateField.define({
  create: () => null,
  update(value, tr) {
    for (const e of tr.effects) if (e.is(setEdit)) return e.value;
    if (value && tr.docChanged) return { ...value, from: tr.changes.mapPos(value.from, -1), to: tr.changes.mapPos(value.to, 1) };
    return value;
  },
  provide: (field) => EditorView.decorations.compute([field], (state) => decorations(state, state.field(field))),
});

function decorations(state, e) {
  if (!e) return Decoration.none;
  const ranges = [];
  const first = state.doc.lineAt(e.from);
  ranges.push(Decoration.widget({ widget: e.phase === 'review' ? new ReviewWidget(e) : new PromptWidget(e), block: true, side: -1 }).range(first.from));
  // The lines being changed, or the new ones.
  if (e.to > e.from) {
    const last = state.doc.lineAt(Math.max(e.from, e.to - 1));
    const cls = e.phase === 'review' ? 'cm-ai-added' : 'cm-ai-target';
    for (let n = first.number; n <= last.number; n++) ranges.push(Decoration.line({ class: cls }).range(state.doc.line(n).from));
  }
  return Decoration.set(ranges, true);
}

const button = (label, title, run) => {
  const b = document.createElement('button');
  b.className = 'cm-ai-button';
  b.textContent = label;
  if (title) b.title = title;
  b.addEventListener('mousedown', (ev) => ev.preventDefault());
  b.addEventListener('click', (ev) => { ev.preventDefault(); run(); });
  return b;
};

class PromptWidget extends WidgetType {
  constructor(e) { super(); this.e = e; }
  eq(other) { return other.e.phase === this.e.phase && other.e.message === this.e.message; }
  toDOM(view) {
    const box = document.createElement('div');
    box.className = 'cm-ai-edit';
    const input = document.createElement('input');
    input.className = 'cm-ai-input';
    input.placeholder = this.e.from === this.e.to ? 'Write code here with AI: describe it' : 'Edit with AI: describe the change';
    input.value = this.e.instruction || '';
    input.setAttribute('aria-label', 'Edit with AI');
    input.setAttribute('autocapitalize', 'sentences');
    const working = this.e.phase === 'working';
    input.disabled = working;
    input.addEventListener('keydown', (ev) => {
      ev.stopPropagation();
      if (ev.key === 'Enter' && !ev.isComposing && input.value.trim()) { ev.preventDefault(); run(view, input.value.trim()); }
      if (ev.key === 'Escape') { ev.preventDefault(); cancel(view); }
    });
    box.append(input);
    const row = document.createElement('div');
    row.className = 'cm-ai-row';
    if (working) {
      row.append(Object.assign(document.createElement('span'), { className: 'cm-ai-status', textContent: 'Editing with AI…' }), button('Stop', 'Stop (Esc)', () => cancel(view)));
    } else {
      if (this.e.message) row.append(Object.assign(document.createElement('span'), { className: 'cm-ai-status cm-ai-error', textContent: this.e.message }));
      row.append(button('Edit', 'Edit (↩)', () => input.value.trim() && run(view, input.value.trim())), button('Cancel', 'Cancel (Esc)', () => cancel(view)));
      setTimeout(() => input.focus(), 0);
    }
    box.append(row);
    return box;
  }
  ignoreEvent() { return true; }
}

class ReviewWidget extends WidgetType {
  constructor(e) { super(); this.e = e; }
  eq(other) { return other.e.original === this.e.original && other.e.phase === this.e.phase; }
  toDOM(view) {
    const box = document.createElement('div');
    box.className = 'cm-ai-edit cm-ai-review';
    if (this.e.original) {
      const old = document.createElement('pre');
      old.className = 'cm-ai-removed';
      old.textContent = this.e.original.replace(/\n$/, '');
      box.append(old);
    }
    const row = document.createElement('div');
    row.className = 'cm-ai-row';
    row.append(
      Object.assign(document.createElement('span'), { className: 'cm-ai-status', textContent: `“${this.e.instruction}”` }),
      button('Accept', 'Accept (⌘↩)', () => accept(view)),
      button('Reject', 'Reject (Esc)', () => reject(view)),
      button('Try Again', 'Ask again, changing the instruction', () => retry(view)),
    );
    box.append(row);
    return box;
  }
  ignoreEvent() { return true; }
}

/** ⌘I: the selected lines (whole), or the cursor's line to write code at. */
export function startInlineEdit(view) {
  const current = view.state.field(editField, false);
  if (current && current.phase === 'review') accept(view);
  const sel = view.state.selection.main;
  const doc = view.state.doc;
  let from, to;
  if (sel.empty) {
    from = to = doc.lineAt(sel.head).from;
  } else {
    from = doc.lineAt(sel.from).from;
    // A selection ending at the start of a line doesn't take that line.
    const end = doc.lineAt(sel.to > sel.from && doc.lineAt(sel.to).from === sel.to ? sel.to - 1 : sel.to);
    to = end.to < doc.length ? end.to + 1 : end.to;
  }
  view.dispatch({ effects: setEdit.of({ phase: 'prompt', from, to, original: doc.sliceString(from, to), instruction: '' }), scrollIntoView: true });
  return true;
}

async function run(view, instruction) {
  const e = view.state.field(editField);
  if (!e) return;
  view.dispatch({ effects: setEdit.of({ ...e, phase: 'working', instruction, message: '' }) });
  const state = view.state;
  const result = await api.edit({ instruction, code: state.sliceDoc(e.from, e.to), path: api.current(), before: state.sliceDoc(0, e.from), after: state.sliceDoc(e.to) });
  const now = view.state.field(editField);
  if (!now || now.phase !== 'working') return;   // cancelled
  if (result.error) {
    view.dispatch({ effects: setEdit.of({ ...now, phase: 'error', message: result.error }) });
    return;
  }
  const original = view.state.sliceDoc(now.from, now.to);
  view.dispatch({
    changes: { from: now.from, to: now.to, insert: result.code },
    effects: setEdit.of({ phase: 'review', from: now.from, to: now.from + result.code.length, original, instruction }),
    userEvent: 'input.ai',
  });
}

function cancel(view) {
  const e = view.state.field(editField);
  if (e && e.phase === 'working') api.stop();
  view.dispatch({ effects: setEdit.of(null) });
  view.focus();
}

function accept(view) {
  view.dispatch({ effects: setEdit.of(null) });
  view.focus();
  return true;
}

function reject(view) {
  const e = view.state.field(editField);
  if (!e || e.phase !== 'review') return false;
  view.dispatch({ changes: { from: e.from, to: e.to, insert: e.original }, effects: setEdit.of(null), userEvent: 'input.ai' });
  view.focus();
  return true;
}

function retry(view) {
  const e = view.state.field(editField);
  if (!e) return;
  view.dispatch({
    changes: { from: e.from, to: e.to, insert: e.original },
    effects: setEdit.of({ phase: 'prompt', from: e.from, to: e.from + e.original.length, original: e.original, instruction: e.instruction }),
    userEvent: 'input.ai',
  });
}

/** The editor extension: the edit's state and its keys. */
export function inlineEditExtension() {
  return [
    editField,
    Prec.highest(keymap.of([
      { key: 'Mod-i', run: startInlineEdit },
      { key: 'Mod-Enter', run: (view) => { const e = view.state.field(editField); return !!(e && e.phase === 'review') && accept(view); } },
      { key: 'Escape', run: (view) => {
        const e = view.state.field(editField);
        if (!e) return false;
        if (e.phase === 'review') return reject(view);
        cancel(view);
        return true;
      } },
    ])),
  ];
}
