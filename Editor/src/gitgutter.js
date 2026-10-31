// Source control change markers in the gutter, as VS Code draws them: a green bar beside added
// lines, a blue bar beside changed lines and a red triangle where lines were deleted, against the
// file's staged (or committed) copy.
import { StateField, StateEffect, RangeSet, RangeSetBuilder, Text } from '@codemirror/state';
import { GutterMarker, ViewPlugin, gutter } from '@codemirror/view';
import { Chunk } from '@codemirror/merge';

const setOriginal = StateEffect.define();     // the original text, or null (untracked, no repository)
const refreshChanges = StateEffect.define();

const originalField = StateField.define({
  create: () => null,
  update(value, tr) {
    for (const effect of tr.effects) {
      if (effect.is(setOriginal)) value = effect.value == null ? null : Text.of(effect.value.split(/\r?\n/));
    }
    return value;
  },
});

class ChangeMarker extends GutterMarker {
  constructor(kind) { super(); this.kind = kind; }
  eq(other) { return other.kind === this.kind; }
  toDOM() {
    const el = document.createElement('div');
    el.className = 'cm-change ' + this.kind;
    return el;
  }
}
const MARKERS = { added: new ChangeMarker('added'), modified: new ChangeMarker('modified'), deleted: new ChangeMarker('deleted') };

function computeMarkers(state) {
  const original = state.field(originalField);
  if (!original) return RangeSet.empty;
  const doc = state.doc;
  const builder = new RangeSetBuilder();
  let last = -1;
  const add = (pos, marker) => {
    if (pos <= last) return;
    builder.add(pos, pos, marker);
    last = pos;
  };
  for (const chunk of Chunk.build(original, doc)) {
    if (chunk.fromB === chunk.toB) {
      add(doc.lineAt(Math.min(chunk.fromB, doc.length)).from, MARKERS.deleted);
      continue;
    }
    const marker = chunk.fromA === chunk.toA ? MARKERS.added : MARKERS.modified;
    const first = doc.lineAt(chunk.fromB).number;
    const lastLine = doc.lineAt(Math.min(Math.max(chunk.fromB, chunk.toB - 1), doc.length)).number;
    for (let n = first; n <= lastLine; n++) add(doc.line(n).from, marker);
  }
  return builder.finish();
}

const changeMarkers = ViewPlugin.fromClass(class {
  constructor(view) {
    this.markers = computeMarkers(view.state);
    this.timer = 0;
  }
  update(u) {
    const refresh = u.startState.field(originalField) !== u.state.field(originalField)
      || u.transactions.some((tr) => tr.effects.some((e) => e.is(refreshChanges)));
    if (refresh) {
      this.markers = computeMarkers(u.state);
    } else if (u.docChanged) {
      // Keep the markers in place while typing; work out the real diff once it pauses.
      this.markers = this.markers.map(u.changes);
      clearTimeout(this.timer);
      this.timer = setTimeout(() => u.view.dispatch({ effects: refreshChanges.of(null) }), 250);
    }
  }
  destroy() { clearTimeout(this.timer); }
});

export const gitGutter = [
  originalField,
  changeMarkers,
  gutter({
    class: 'cm-change-gutter',
    markers: (view) => view.plugin(changeMarkers)?.markers || RangeSet.empty,
  }),
];

/** Fetches the open file's original from the app and shows its changes. */
export function loadOriginal(view, native, path) {
  native({ cmd: 'gitOriginal', path }).then((text) => {
    view.dispatch({ effects: setOriginal.of(typeof text === 'string' ? text : null) });
  }, () => view.dispatch({ effects: setOriginal.of(null) }));
}
