// Merge conflicts, as VS Code shows them: the current and incoming blocks tinted, "Accept Current
// Change | Accept Incoming Change | Accept Both Changes" above each one, and a merge bar to step
// through them. "Resolve for me" asks the selected AI model for each conflict and shows its
// answers in a review sheet; nothing changes until they're accepted.
import { StateField } from '@codemirror/state';
import { EditorView, Decoration, WidgetType, ViewPlugin } from '@codemirror/view';
import { settings } from './settings.js';

const START = /^<{7}(?: (.*))?$/;
const BASE = /^\|{7}(?: (.*))?$/;
const SEP = /^={7}$/;
const END = /^>{7}(?: (.*))?$/;

/** Every complete conflict block in the document, in order. */
export function parseConflicts(doc) {
  const out = [];
  let cur = null;
  for (let n = 1; n <= doc.lines; n++) {
    const line = doc.line(n);
    const text = line.text.replace(/\r$/, '');
    let m;
    if ((m = START.exec(text))) { cur = { start: line, oursLabel: (m[1] || '').trim() }; continue; }
    if (!cur) continue;
    if (!cur.sep && !cur.base && BASE.test(text)) { cur.base = line; continue; }
    if (!cur.sep && SEP.test(text)) { cur.sep = line; continue; }
    if (cur.sep && (m = END.exec(text))) {
      const { start, base, sep } = cur;
      const end = line;
      const to = Math.min(end.to + 1, doc.length);
      const oursTo = (base || sep).from;
      out.push({
        from: start.from,
        to,
        start, base, sep, end,
        ours: doc.sliceString(Math.min(start.to + 1, oursTo), oursTo),
        base: base ? doc.sliceString(Math.min(base.to + 1, sep.from), sep.from) : null,
        theirs: doc.sliceString(Math.min(sep.to + 1, end.from), end.from),
        oursLabel: cur.oursLabel || 'HEAD',
        theirsLabel: (m[1] || '').trim() || 'incoming',
        text: doc.sliceString(start.from, to),
      });
      cur = null;
    }
  }
  return out;
}

export const conflictField = StateField.define({
  create: (state) => parseConflicts(state.doc),
  update: (value, tr) => (tr.docChanged ? parseConflicts(tr.state.doc) : value),
});

/** Replaces a conflict block with `choice`: 'current', 'incoming', 'both' or the merged text itself. */
export function resolveConflict(view, c, choice) {
  let text = choice === 'current' ? c.ours
    : choice === 'incoming' ? c.theirs
      : choice === 'both' ? c.ours + c.theirs
        : choice;
  // The last block in a file without a final newline shouldn't gain one.
  if (c.to === view.state.doc.length && !c.text.endsWith('\n') && text.endsWith('\n')) text = text.slice(0, -1);
  view.dispatch({ changes: { from: c.from, to: c.to, insert: text }, userEvent: 'input.merge', scrollIntoView: false });
}

const conflictAt = (state, pos) => state.field(conflictField).find((c) => pos >= c.from && pos <= c.to);

// The CodeLens-style actions above a conflict. Positions move as the file is edited, so the
// buttons look up their conflict from where the widget is when tapped.
class ActionsWidget extends WidgetType {
  constructor(from) { super(); this.from = from; }
  eq(other) { return other.from === this.from; }
  toDOM(view) {
    const dom = document.createElement('div');
    dom.className = 'cm-conflict-actions';
    const add = (label, choice) => {
      if (dom.childNodes.length) dom.append(Object.assign(document.createElement('span'), { className: 'cm-conflict-sep', textContent: '|' }));
      const b = document.createElement('button');
      b.textContent = label;
      b.addEventListener('mousedown', (e) => e.preventDefault());
      b.addEventListener('click', (e) => {
        e.preventDefault();
        const c = conflictAt(view.state, view.posAtDOM(dom));
        if (c) resolveConflict(view, c, choice);
      });
      dom.append(b);
    };
    add('Accept Current Change', 'current');
    add('Accept Incoming Change', 'incoming');
    add('Accept Both Changes', 'both');
    return dom;
  }
  ignoreEvent() { return true; }
}

class LabelWidget extends WidgetType {
  constructor(text) { super(); this.text = text; }
  eq(other) { return other.text === this.text; }
  toDOM() { return Object.assign(document.createElement('span'), { className: 'cm-conflict-label', textContent: this.text }); }
}

function lineClasses(ranges, doc, from, to, cls) {
  if (to <= from) return;
  for (let pos = from; pos < to;) {
    const line = doc.lineAt(pos);
    ranges.push(Decoration.line({ class: cls }).range(line.from));
    pos = line.to + 1;
  }
}

const conflictDecorations = StateField.define({
  create: (state) => build(state),
  update: (value, tr) => (tr.docChanged ? build(tr.state) : value),
  provide: (f) => EditorView.decorations.from(f),
});

function build(state) {
  const ranges = [];
  const doc = state.doc;
  for (const c of state.field(conflictField)) {
    ranges.push(Decoration.widget({ widget: new ActionsWidget(c.from), block: true, side: -1 }).range(c.from));
    ranges.push(Decoration.line({ class: 'cm-conflict-current-header' }).range(c.start.from));
    ranges.push(Decoration.widget({ widget: new LabelWidget('(Current Change)'), side: 1 }).range(c.start.to));
    lineClasses(ranges, doc, c.start.to + 1, (c.base || c.sep).from, 'cm-conflict-current');
    if (c.base) {
      ranges.push(Decoration.line({ class: 'cm-conflict-base-header' }).range(c.base.from));
      lineClasses(ranges, doc, c.base.to + 1, c.sep.from, 'cm-conflict-base');
    }
    ranges.push(Decoration.line({ class: 'cm-conflict-separator' }).range(c.sep.from));
    lineClasses(ranges, doc, c.sep.to + 1, c.end.from, 'cm-conflict-incoming');
    ranges.push(Decoration.line({ class: 'cm-conflict-incoming-header' }).range(c.end.from));
    ranges.push(Decoration.widget({ widget: new LabelWidget('(Incoming Change)'), side: 1 }).range(c.end.to));
  }
  return Decoration.set(ranges, true);
}

// MARK: - Merge bar and AI review

const el = (tag, cls, text) => {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text != null) e.textContent = text;
  return e;
};

/** Whether the open file is one of the merge's conflicted files (set by main.js when it opens). */
export const mergeInfo = { path: null, inMerge: false };

export function mergeConflicts(native, getPath, onResolvedFile) {
  const bar = el('div', 'merge-bar');
  bar.hidden = true;
  const count = el('span', 'merge-count');
  const prev = el('button', 'merge-icon', '↑');
  const next = el('button', 'merge-icon', '↓');
  prev.title = 'Previous Conflict';
  next.title = 'Next Conflict';
  const ai = el('button', 'merge-button primary', '✦ Resolve for me');
  const more = el('button', 'merge-icon', '⋯');
  more.title = 'More Actions';
  const done = el('button', 'merge-button primary', 'Mark as Resolved');
  const note = el('div', 'merge-note');
  note.hidden = true;
  bar.append(count, prev, next, el('span', 'merge-spacer'), ai, more, done);

  const menu = el('div', 'merge-menu');
  menu.hidden = true;
  const sheet = el('div', 'dc-sheet ai-merge');
  const host = document.getElementById('app');
  host.append(bar);
  document.body.append(menu, sheet, note);

  let view = null;
  let review = null;
  let noteTimer = 0;

  const flash = (text) => {
    note.textContent = text;
    note.hidden = false;
    clearTimeout(noteTimer);
    noteTimer = setTimeout(() => { note.hidden = true; }, 3200);
  };

  const keepFocusOff = (b) => b.addEventListener('mousedown', (e) => e.preventDefault());
  [prev, next, ai, more, done].forEach(keepFocusOff);

  const goTo = (c) => {
    view.dispatch({ selection: { anchor: c.from }, effects: EditorView.scrollIntoView(c.from, { y: 'start', yMargin: 40 }) });
  };
  const currentIndex = (state) => {
    const list = state.field(conflictField);
    const head = state.selection.main.head;
    const i = list.findIndex((c) => head <= c.to);
    return i < 0 ? list.length - 1 : i;
  };

  prev.onclick = () => {
    const list = view.state.field(conflictField);
    if (!list.length) return;
    const head = view.state.selection.main.head;
    const before = list.filter((c) => c.to < head || (c.from < head && head <= c.to && head !== c.from));
    goTo(before.length ? before[before.length - 1] : list[list.length - 1]);
  };
  next.onclick = () => {
    const list = view.state.field(conflictField);
    if (!list.length) return;
    const head = view.state.selection.main.head;
    goTo(list.find((c) => c.from > head) || list[0]);
  };
  ai.onclick = () => {
    if (!settings.aiMerge) {
      flash('Pick a model in Settings → AI Merge Conflicts to have conflicts resolved for you.');
      return;
    }
    startReview();
  };
  more.onclick = () => {
    if (!menu.hidden) { menu.hidden = true; return; }
    menu.replaceChildren();
    for (const [label, choice] of [['Accept All Current', 'current'], ['Accept All Incoming', 'incoming'], ['Accept All Both', 'both']]) {
      const item = el('button', 'merge-menu-item', label);
      keepFocusOff(item);
      item.onclick = () => {
        menu.hidden = true;
        // Last first, so earlier positions stay valid.
        for (const c of [...view.state.field(conflictField)].reverse()) resolveConflict(view, c, choice);
      };
      menu.append(item);
    }
    const r = more.getBoundingClientRect();
    menu.style.right = `${Math.max(8, window.innerWidth - r.right)}px`;
    menu.style.bottom = `${window.innerHeight - r.top + 4}px`;
    menu.hidden = false;
  };
  done.onclick = async () => {
    const path = getPath();
    if (!path) return;
    await onResolvedFile(path);
    mergeInfo.inMerge = false;
    update(view);
    flash(`${path} marked as resolved.`);
  };

  function update(v) {
    const list = v.state.field(conflictField);
    const show = list.length > 0 || (mergeInfo.inMerge && mergeInfo.path === getPath());
    bar.hidden = !show;
    if (!show) return;
    const resolved = list.length === 0;
    count.textContent = resolved ? 'No conflicts left'
      : `${Math.min(currentIndex(v.state) + 1, list.length)} of ${list.length} conflict${list.length === 1 ? '' : 's'}`;
    prev.hidden = next.hidden = more.hidden = ai.hidden = resolved;
    ai.classList.toggle('off', !settings.aiMerge);
    done.hidden = !(resolved && mergeInfo.inMerge && mergeInfo.path === getPath());
  }

  // MARK: Review sheet

  function startReview() {
    const list = view.state.field(conflictField);
    if (!list.length) return;
    view.contentDOM.blur();
    review = {
      items: list.map((c) => ({ key: c.text, status: 'pending', text: null, line: c.start.number })),
      index: 0,
      cancelled: false,
      path: getPath(),
    };
    sheet.classList.add('open');
    render();
    goToItem(0);
    run(review);
  }

  const find = (item) => view.state.field(conflictField).find((c) => c.text === item.key);

  async function run(r) {
    for (const item of r.items) {
      if (r.cancelled) return;
      const c = find(item);
      if (!c) { item.status = 'gone'; render(); continue; }
      item.status = 'working';
      render();
      const doc = view.state.doc;
      const beforeLine = doc.lineAt(c.from).number;
      const afterLine = doc.lineAt(c.to > 0 ? c.to - 1 : 0).number;
      const before = doc.sliceString(doc.line(Math.max(1, beforeLine - 60)).from, c.from);
      const after = doc.sliceString(c.to, doc.line(Math.min(doc.lines, afterLine + 30)).to);
      let text = null;
      try {
        text = await native({
          cmd: 'aiResolve', path: r.path, ours: c.ours, theirs: c.theirs, base: c.base,
          before, after, oursLabel: c.oursLabel, theirsLabel: c.theirsLabel,
        });
      } catch (e) {
        text = null;
      }
      if (r.cancelled) return;
      item.text = typeof text === 'string' && text.length ? text : null;
      item.status = item.text ? 'ready' : 'failed';
      render();
    }
  }

  function goToItem(i) {
    if (!review) return;
    review.index = Math.max(0, Math.min(i, review.items.length - 1));
    const c = find(review.items[review.index]);
    if (c) view.dispatch({ effects: EditorView.scrollIntoView(c.from, { y: 'start', yMargin: 24 }) });
    render();
  }

  function close() {
    if (!review) return;
    review.cancelled = true;
    native({ cmd: 'aiResolveCancel' }).catch(() => {});
    review = null;
    sheet.classList.remove('open');
  }

  function accept(item) {
    const c = find(item);
    if (!c || item.status !== 'ready') return false;
    resolveConflict(view, c, item.text);
    item.status = 'accepted';
    return true;
  }

  const open = (r) => r.items.filter((it) => it.status === 'pending' || it.status === 'working' || it.status === 'ready');

  function afterAccept() {
    const remaining = open(review);
    if (!remaining.length) {
      const failed = review.items.filter((it) => it.status === 'failed').length;
      close();
      if (failed) flash(`${failed} conflict${failed === 1 ? '' : 's'} still need${failed === 1 ? 's' : ''} resolving by hand.`);
      return;
    }
    const nextIndex = review.items.indexOf(remaining.find((it) => review.items.indexOf(it) > review.index) || remaining[0]);
    goToItem(nextIndex);
  }

  function render() {
    if (!review) return;
    const r = review;
    const item = r.items[r.index];
    sheet.replaceChildren();

    const head = el('div', 'ai-merge-head');
    const back = el('button', 'merge-icon', '‹');
    const fwd = el('button', 'merge-icon', '›');
    back.disabled = r.index === 0;
    fwd.disabled = r.index === r.items.length - 1;
    back.onclick = () => goToItem(r.index - 1);
    fwd.onclick = () => goToItem(r.index + 1);
    const title = el('span', 'ai-merge-title', `✦ Conflict ${r.index + 1} of ${r.items.length}`);
    const where = el('span', 'ai-merge-where', `line ${item.line}`);
    head.append(back, title, fwd, el('span', 'merge-spacer'), where);

    const body = el('div', 'ai-merge-body');
    const status = {
      pending: 'Waiting…',
      working: 'Resolving…',
      ready: 'Suggested merge:',
      failed: 'The AI couldn\'t merge this one. Use the buttons above the conflict instead.',
      accepted: 'Accepted.',
      gone: 'This conflict was resolved another way.',
    }[item.status];
    const statusEl = el('div', `ai-merge-status ${item.status}`, status);
    body.append(statusEl);
    if (item.text && item.status !== 'gone') body.append(el('pre', 'ai-merge-code', item.text.replace(/\n$/, '')));

    const working = r.items.some((it) => it.status === 'pending' || it.status === 'working');
    const foot = el('div', 'ai-merge-foot');
    const cancel = el('button', 'merge-button', 'Cancel');
    const acceptAll = el('button', 'merge-button', 'Accept All');
    const acceptOne = el('button', 'merge-button primary', 'Accept');
    acceptOne.disabled = item.status !== 'ready';
    acceptAll.disabled = working || !r.items.some((it) => it.status === 'ready');
    cancel.onclick = close;
    acceptOne.onclick = () => { if (accept(item)) afterAccept(); };
    acceptAll.onclick = () => {
      for (const it of r.items) accept(it);
      afterAccept();
    };
    foot.append(cancel, el('span', 'merge-spacer'), acceptAll, acceptOne);
    [back, fwd, cancel, acceptAll, acceptOne].forEach(keepFocusOff);

    sheet.append(head, body, foot);
  }

  const plugin = ViewPlugin.fromClass(class {
    constructor(v) { view = v; update(v); }
    update(u) {
      view = u.view;
      if (u.docChanged || u.selectionSet || u.startState.field(conflictField, false) !== u.state.field(conflictField, false)) update(u.view);
    }
  });

  return {
    extensions: [conflictField, conflictDecorations, plugin],
    /** Re-evaluates the bar after a file opens, a setting changes or the merge state is known. */
    refresh() { if (view) update(view); },
    closeReview: close,
  };
}
