// AI inline suggestions ("ghost text"). After a pause in typing, the native side asks the
// selected model (Settings → AI) to continue the code at the cursor. The suggestion is shown
// greyed out; Tab or a tap accepts it, Esc or moving the cursor drops it.
import { StateField, StateEffect, Prec } from '@codemirror/state';
import { EditorView, Decoration, WidgetType, ViewPlugin, keymap } from '@codemirror/view';
import { completionStatus } from '@codemirror/autocomplete';
import { settings } from './settings.js';

const DELAY = 450;          // ms of no typing before asking
const PREFIX_CHARS = 3000;  // code before the cursor sent as context
const SUFFIX_CHARS = 600;   // code after the cursor
const touch = typeof matchMedia === 'function' && matchMedia('(pointer: coarse)').matches;

const setGhost = StateEffect.define();

class GhostWidget extends WidgetType {
  constructor(text) {
    super();
    this.text = text;
  }

  eq(other) {
    return other.text === this.text;
  }

  toDOM(view) {
    const span = document.createElement('span');
    span.className = 'cm-ghost';
    span.textContent = this.text;
    if (touch) {
      const chip = document.createElement('span');
      chip.className = 'cm-ghost-accept';
      chip.textContent = 'Accept';
      span.appendChild(chip);
    }
    const accept = (e) => {
      e.preventDefault();
      e.stopPropagation();
      acceptGhost(view);
    };
    span.addEventListener('mousedown', accept);
    span.addEventListener('touchend', accept);
    return span;
  }

  ignoreEvent() {
    return true;
  }
}

const ghostField = StateField.define({
  create: () => null,
  update(ghost, tr) {
    for (const e of tr.effects) if (e.is(setGhost)) return e.value;
    if (!ghost) return null;
    if (tr.docChanged) {
      // Typing the suggestion's own next characters keeps the rest of it on screen.
      let kept = null;
      let changes = 0;
      tr.changes.iterChanges((fromA, toA, fromB, toB, inserted) => {
        changes++;
        const typed = inserted.toString();
        if (fromA === ghost.pos && toA === fromA && typed && ghost.text.length > typed.length && ghost.text.startsWith(typed)) {
          kept = { pos: toB, text: ghost.text.slice(typed.length) };
        }
      });
      return changes === 1 ? kept : null;
    }
    if (tr.selection && tr.state.selection.main.head !== ghost.pos) return null;
    return ghost;
  },
  provide: (field) => EditorView.decorations.from(field, (ghost) => (ghost
    ? Decoration.set([Decoration.widget({ widget: new GhostWidget(ghost.text), side: 1 }).range(ghost.pos)])
    : Decoration.none)),
});

function acceptGhost(view) {
  const ghost = view.state.field(ghostField, false);
  if (!ghost) return false;
  view.dispatch({
    changes: { from: ghost.pos, insert: ghost.text },
    selection: { anchor: ghost.pos + ghost.text.length },
    effects: setGhost.of(null),
    userEvent: 'input.complete',
    scrollIntoView: true,
  });
  return true;
}

function dismissGhost(view) {
  if (!view.state.field(ghostField, false)) return false;
  view.dispatch({ effects: setGhost.of(null) });
  return true;
}

/** Start of the context window: snapped to a line that stays put while you type, so the
 *  model can reuse its work from the previous request. */
function contextStart(doc, pos) {
  if (pos <= PREFIX_CHARS) return 0;
  let start = pos - PREFIX_CHARS;
  start -= start % 1024;
  const line = doc.lineAt(start);
  return line.number < doc.lines ? doc.line(line.number + 1).from : line.from;
}

/**
 * native(msg) posts to the app; setBusy(bool) shows the tab bar indicator;
 * getPath() is the open file.
 */
export function aiCompletion(native, setBusy, getPath) {
  const requester = ViewPlugin.fromClass(class {
    constructor(view) {
      this.view = view;
      this.timer = 0;
      this.seq = 0;
      this.pending = false;
    }

    update(u) {
      if (!u.docChanged && !u.selectionSet) return;
      clearTimeout(this.timer);
      this.cancel();
      if (!settings.ai) {
        if (u.state.field(ghostField, false)) queueMicrotask(() => dismissGhost(this.view));
        return;
      }
      const typed = u.transactions.some((tr) => (tr.isUserEvent('input') && !tr.isUserEvent('input.complete')) || tr.isUserEvent('delete'));
      if (!typed || u.state.field(ghostField, false)) return;
      this.timer = setTimeout(() => this.request(), DELAY);
    }

    cancel() {
      this.seq++;
      if (this.pending) {
        this.pending = false;
        setBusy(false);
        native({ cmd: 'aiCancel' }).catch(() => {});
      }
    }

    async request() {
      const view = this.view;
      const state = view.state;
      const sel = state.selection.main;
      if (!settings.ai || !sel.empty || completionStatus(state) === 'active') return;
      const pos = sel.head;
      const line = state.doc.lineAt(pos);
      // Only suggest at the end of a line (closing brackets and quotes may follow).
      if (!/^[\s)\]}'",;]*$/.test(line.text.slice(pos - line.from))) return;

      const seq = ++this.seq;
      const prefix = state.doc.sliceString(contextStart(state.doc, pos), pos);
      const suffix = state.doc.sliceString(pos, Math.min(state.doc.length, pos + SUFFIX_CHARS));
      this.pending = true;
      setBusy(true);
      let text = null;
      try {
        text = await native({ cmd: 'aiComplete', prefix, suffix, path: getPath() || '' });
      } catch (e) {
        text = null;
      }
      if (seq !== this.seq) return;
      this.pending = false;
      setBusy(false);
      if (!text || view.state.doc !== state.doc || view.state.selection.main.head !== pos) return;
      view.dispatch({ effects: setGhost.of({ pos, text }) });
    }

    destroy() {
      clearTimeout(this.timer);
      this.cancel();
    }
  });

  return [
    ghostField,
    requester,
    Prec.highest(keymap.of([
      { key: 'Tab', run: acceptGhost },
      { key: 'Escape', run: dismissGhost },
    ])),
  ];
}
