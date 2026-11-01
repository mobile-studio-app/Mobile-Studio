// Git blame on the cursor's line, as VS Code shows it (git.blame.editorDecoration.enabled): who
// last changed the line, when, and the commit's message, faded at the end of the line. Tapping it
// shows the whole commit message.
import { ViewPlugin, Decoration, WidgetType, EditorView } from '@codemirror/view';
import { StateEffect, StateField } from '@codemirror/state';
import { notify, quickPick } from './ext/ui.js';

let api = null;   // { native, current }

export function setupBlame(options) { api = options; }

function ago(ms) {
  const s = Math.max(0, (Date.now() - ms) / 1000);
  const units = [[31536000, 'year'], [2592000, 'month'], [604800, 'week'], [86400, 'day'], [3600, 'hour'], [60, 'minute']];
  for (const [size, name] of units) {
    const n = Math.floor(s / size);
    if (n >= 1) return `${n} ${name}${n === 1 ? '' : 's'} ago`;
  }
  return 'just now';
}

class BlameWidget extends WidgetType {
  constructor(commit) { super(); this.commit = commit; }
  eq(other) { return other.commit === this.commit; }
  toDOM() {
    const span = document.createElement('span');
    span.className = 'cm-blame';
    const c = this.commit;
    if (!c) {
      span.textContent = 'You, now • Uncommitted changes';
    } else {
      const summary = c.message.split('\n')[0];
      span.textContent = `${c.author}, ${ago(c.date)} • ${summary}`;
      span.title = `${c.author}, ${new Date(c.date).toLocaleString()}\n${c.id.slice(0, 8)}\n\n${c.message}`;
      span.addEventListener('click', () => notify('info', `${c.id.slice(0, 7)} ${c.author}, ${new Date(c.date).toLocaleString()}: ${c.message}`, []));
    }
    return span;
  }
  ignoreEvent() { return false; }
}

const setBlame = StateEffect.define();
const blameField = StateField.define({
  create: () => Decoration.none,
  update(value, tr) {
    for (const e of tr.effects) if (e.is(setBlame)) return e.value;
    return tr.docChanged || tr.selection ? Decoration.none : value;
  },
  provide: (f) => EditorView.decorations.from(f),
});

const blamePlugin = ViewPlugin.fromClass(class {
  constructor(view) {
    this.view = view;
    this.data = null;      // { commits, lines } for `forDoc`
    this.forDoc = null;
    this.loading = null;
    this.timer = 0;
    this.schedule(800);
  }

  update(update) {
    if (update.docChanged || update.selectionSet) this.schedule(update.docChanged ? 1500 : 350);
  }

  schedule(delay) {
    clearTimeout(this.timer);
    this.timer = setTimeout(() => this.show(), delay);
  }

  async show() {
    const view = this.view;
    const path = api && api.current();
    // Not for settings files, or read-only copies (a diff's original side, a commit's snapshot).
    if (!path || path.startsWith('@') || view.state.readOnly) return;
    const { state } = view;
    if (this.forDoc !== state.doc) {
      const doc = state.doc;
      const data = await api.native({ cmd: 'gitBlame', path, text: doc.toString() }).catch(() => null);
      if (view.state.doc !== doc || api.current() !== path) return;
      this.data = data && Array.isArray(data.lines) ? data : null;
      this.forDoc = doc;
    }
    if (!this.data) return;
    // One annotation, on the cursor's line, while the selection is a cursor.
    const sel = view.state.selection.main;
    if (!sel.empty || view.state.selection.ranges.length > 1) { view.dispatch({ effects: setBlame.of(Decoration.none) }); return; }
    const line = view.state.doc.lineAt(sel.head);
    const index = this.data.lines[line.number - 1];
    if (index === undefined) return;
    const commit = index >= 0 ? this.data.commits[index] : null;
    // Untouched new files have nothing to say.
    if (!commit && this.data.commits.length === 0) return;
    const deco = Decoration.widget({ widget: new BlameWidget(commit), side: 1 }).range(line.to);
    view.dispatch({ effects: setBlame.of(Decoration.set([deco])) });
  }

  destroy() { clearTimeout(this.timer); }
});

export const blame = [blameField, blamePlugin];

/** Git: View File History: the commits that changed the open file; the one picked opens as a diff. */
export async function fileHistory(openDiff) {
  const path = api && api.current();
  if (!path) { notify('info', 'Open a file to see its history.', []); return; }
  const list = await api.native({ cmd: 'gitFileHistory', path }).catch(() => []);
  if (!Array.isArray(list) || !list.length) { notify('info', `No commits have changed ${path.split('/').pop()}.`, []); return; }
  const picked = await quickPick({
    placeholder: `History of ${path.split('/').pop()}`,
    items: list.map((c) => ({ label: c.message.split('\n')[0], description: `${c.author}, ${ago(c.date)}`, detail: c.id.slice(0, 7) })),
  });
  if (picked == null) return;
  const commit = list[picked];
  const texts = await api.native({ cmd: 'gitFileHistory', path, commit: commit.id }).catch(() => null);
  if (!texts) return;
  const name = path.split('/').pop();
  const short = commit.id.slice(0, 7);
  openDiff({ path, original: texts.original, modified: texts.modified, title: `${name} (${short}^ ↔ ${short})` });
}
