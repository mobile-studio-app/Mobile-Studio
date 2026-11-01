// Language features from extensions' providers, as VS Code shows them: the Quick Fix light bulb
// (and ⌘.), inlay hints (parameter names and types inline), and Peek Definition / Peek References,
// which show the code in a box under the line without leaving the file.
import { EditorView, Decoration, ViewPlugin, WidgetType, lineNumbers } from '@codemirror/view';
import { EditorState, StateEffect, StateField } from '@codemirror/state';
import { codeActionsFor, runCodeAction, inlayHintsFor, definitionAt, referencesAt } from './ext/host.js';
import { quickPick, notify } from './ext/ui.js';
import { languageFor } from './languages.js';
import { themeExtension } from './theme.js';
import { settings } from './settings.js';

let api = null;   // { native, current, openFile, reveal(path, from, to), fallbackDefinitions(view) }

export function setupLanguageFeatures(options) { api = options; }

// MARK: - Quick Fix

const KIND_ORDER = ['quickfix', 'refactor', 'source'];
const kindRank = (kind) => { const i = KIND_ORDER.findIndex((k) => kind === k || kind.startsWith(k + '.')); return i < 0 ? KIND_ORDER.length : i; };

/** The menu of code actions for the selection (or the cursor's line); runs the one picked. */
export async function quickFix(view, actions = null) {
  const { from, to } = view.state.selection.main;
  actions = actions || await codeActionsFor(view.state, from, to, true);
  if (!actions.length) { notify('info', 'No code actions available', []); return; }
  actions = actions.slice().sort((a, b) => (b.isPreferred - a.isPreferred) || (kindRank(a.kind) - kindRank(b.kind)));
  const items = [];
  let group = null;
  for (const action of actions) {
    const g = KIND_ORDER[kindRank(action.kind)] || 'more';
    if (g !== group) { items.push({ separator: true, label: { quickfix: 'Quick Fix', refactor: 'Refactor', source: 'Source Action', more: 'More Actions' }[g] }); group = g; }
    items.push({ label: action.title, description: action.isPreferred ? 'preferred' : '', action });
  }
  const picked = await quickPick({ placeholder: 'Code Actions', items });
  const item = picked == null ? null : items[picked];
  view.focus();
  if (item && item.action) {
    try { await runCodeAction(item.action); } catch (e) { notify('error', String(e && e.message ? e.message : e), []); }
  }
}

/** The light bulb: shown at the start of the cursor's line when there are code actions there. */
const lightBulb = ViewPlugin.fromClass(class {
  constructor(view) {
    this.view = view;
    this.actions = [];
    this.line = -1;
    this.timer = 0;
    this.seq = 0;
    this.dom = document.createElement('button');
    this.dom.className = 'cm-lightbulb';
    this.dom.title = 'Show Code Actions (⌘.)';
    this.dom.setAttribute('aria-label', 'Show Code Actions');
    this.dom.textContent = '';   // codicon light-bulb
    this.dom.hidden = true;
    this.dom.addEventListener('mousedown', (e) => e.preventDefault());
    this.dom.addEventListener('click', () => quickFix(this.view, this.actions));
    view.scrollDOM.appendChild(this.dom);
    this.schedule();
  }

  update(update) {
    if (update.docChanged || update.selectionSet) {
      if (update.docChanged) this.hide();
      this.schedule();
    } else if (update.geometryChanged && !this.dom.hidden) this.place();
  }

  schedule() {
    clearTimeout(this.timer);
    this.timer = setTimeout(() => this.check(), 600);
  }

  hide() { this.dom.hidden = true; this.actions = []; }

  async check() {
    const seq = ++this.seq;
    const { state } = this.view;
    const sel = state.selection.main;
    const line = state.doc.lineAt(sel.head);
    // A cursor asks about its line, as VS Code does for diagnostics' quick fixes.
    const [from, to] = sel.empty ? [line.from, line.to] : [sel.from, sel.to];
    const actions = await codeActionsFor(state, from, to, false).catch(() => []);
    if (seq !== this.seq || this.view.state !== state) return;
    this.actions = actions;
    this.line = line.from;
    if (!actions.length) { this.hide(); return; }
    this.dom.classList.toggle('fix', actions.some((a) => kindRank(a.kind) === 0));
    this.dom.hidden = false;
    this.place();
  }

  place() {
    const view = this.view;
    if (this.line > view.state.doc.length) { this.hide(); return; }
    const block = view.lineBlockAt(this.line);
    const top = block.top + view.documentPadding.top;
    this.dom.style.top = `${top + (block.height - 18) / 2}px`;
    this.dom.style.left = `${Math.max(0, view.contentDOM.offsetLeft - 20)}px`;
  }

  destroy() { clearTimeout(this.timer); this.dom.remove(); }
});

// MARK: - Inlay hints

class HintWidget extends WidgetType {
  constructor(hint) { super(); this.hint = hint; }
  eq(other) { const a = this.hint, b = other.hint; return a.label === b.label && a.paddingLeft === b.paddingLeft && a.paddingRight === b.paddingRight; }
  toDOM() {
    const span = document.createElement('span');
    span.className = 'cm-inlay-hint' + (this.hint.kind === 2 ? ' parameter' : this.hint.kind === 1 ? ' type' : '');
    span.textContent = this.hint.label;
    if (this.hint.paddingLeft) span.style.marginLeft = '0.3em';
    if (this.hint.paddingRight) span.style.marginRight = '0.3em';
    if (this.hint.tooltip) span.title = this.hint.tooltip;
    return span;
  }
  ignoreEvent() { return false; }
}

const setHints = StateEffect.define();
const hintField = StateField.define({
  create: () => Decoration.none,
  update(hints, tr) {
    hints = hints.map(tr.changes);
    for (const e of tr.effects) if (e.is(setHints)) hints = e.value;
    return hints;
  },
  provide: (f) => EditorView.decorations.from(f),
});

const hintFetcher = ViewPlugin.fromClass(class {
  constructor(view) { this.view = view; this.timer = 0; this.seq = 0; this.schedule(view, 300); }
  update(update) {
    if (update.docChanged) this.schedule(update.view, 700);
    else if (update.viewportChanged) this.schedule(update.view, 250);
  }
  schedule(view, delay) {
    clearTimeout(this.timer);
    this.timer = setTimeout(() => this.fetch(view), delay);
  }
  async fetch(view) {
    const seq = ++this.seq;
    const { state } = view;
    // The visible lines and a screen's worth either side.
    const { from, to } = view.viewport;
    const start = state.doc.lineAt(Math.max(0, from - 4000)).from;
    const end = state.doc.lineAt(Math.min(state.doc.length, to + 4000)).to;
    const list = await inlayHintsFor(state, start, end).catch(() => []);
    if (seq !== this.seq || view.state !== state) return;
    const decorations = list
      .filter((h) => h.pos >= 0 && h.pos <= state.doc.length)
      .sort((a, b) => a.pos - b.pos)
      .map((h) => Decoration.widget({ widget: new HintWidget(h), side: h.kind === 2 ? -1 : 1 }).range(h.pos));
    view.dispatch({ effects: setHints.of(Decoration.set(decorations, true)) });
  }
  destroy() { clearTimeout(this.timer); }
});

// MARK: - Peek

const openPeek = StateEffect.define();
const closePeek = StateEffect.define();

class PeekWidget extends WidgetType {
  constructor(peek) { super(); this.peek = peek; }
  eq(other) { return other.peek === this.peek; }
  get estimatedHeight() { return 260; }
  toDOM(view) {
    const { title, locations } = this.peek;
    const box = document.createElement('div');
    box.className = 'cm-peek';
    const header = document.createElement('div');
    header.className = 'cm-peek-header';
    const name = document.createElement('span');
    name.className = 'cm-peek-title';
    const open = document.createElement('button');
    open.textContent = 'Open';
    open.title = 'Open the file at this location';
    const close = document.createElement('button');
    close.textContent = '';   // codicon close
    close.className = 'codicon';
    close.title = 'Close (Escape)';
    header.append(name, open, close);
    const body = document.createElement('div');
    body.className = 'cm-peek-body';
    const list = document.createElement('div');
    list.className = 'cm-peek-list';
    const code = document.createElement('div');
    code.className = 'cm-peek-code';
    body.append(code);
    if (locations.length > 1) body.prepend(list);
    box.append(header, body);

    let inner = null;
    let selected = 0;
    const show = (index) => {
      selected = index;
      const loc = locations[index];
      const text = loc.text == null ? view.state.doc.toString() : loc.text;
      const line = EditorState.create({ doc: text }).doc.lineAt(Math.min(loc.from, text.length)).number;
      name.textContent = `${title} — ${loc.path.split('/').pop()}:${line}`;
      name.title = loc.path;
      for (const [i, el] of [...list.children].entries()) el.classList.toggle('active', i === index);
      if (inner) inner.destroy();
      inner = new EditorView({
        parent: code,
        state: EditorState.create({
          doc: text,
          selection: { anchor: loc.from, head: loc.to },
          extensions: [
            EditorState.readOnly.of(true),
            EditorView.editable.of(false),
            lineNumbers(),
            languageFor(loc.path, { suggestions: false }).extensions,
            themeExtension(settings.theme),
            EditorView.theme({ '&': { height: '100%', fontSize: 'inherit' }, '.cm-scroller': { overflow: 'auto' } }),
            EditorView.decorations.of(Decoration.set([Decoration.line({ class: 'cm-peek-target' }).range(EditorState.create({ doc: text }).doc.lineAt(Math.min(loc.from, text.length)).from)])),
          ],
        }),
      });
      inner.dispatch({ effects: EditorView.scrollIntoView(loc.from, { y: 'center' }) });
    };
    locations.forEach((loc, i) => {
      const item = document.createElement('div');
      item.className = 'cm-peek-item';
      const text = loc.text == null ? view.state.doc.toString() : loc.text;
      const doc = EditorState.create({ doc: text }).doc;
      const line = doc.lineAt(Math.min(loc.from, text.length));
      const where = document.createElement('div');
      where.className = 'cm-peek-where';
      where.textContent = `${loc.path.split('/').pop()}:${line.number}`;
      const preview = document.createElement('div');
      preview.className = 'cm-peek-preview';
      preview.textContent = line.text.trim();
      item.append(where, preview);
      item.addEventListener('click', () => show(i));
      list.append(item);
    });
    open.addEventListener('click', () => {
      const loc = locations[selected];
      view.dispatch({ effects: closePeek.of(null) });
      api.reveal(loc.path, loc.from, loc.to);
    });
    close.addEventListener('click', () => { view.dispatch({ effects: closePeek.of(null) }); view.focus(); });
    // The box is in the editor's content: keep its taps and keys to itself.
    for (const type of ['mousedown', 'touchstart', 'keydown']) box.addEventListener(type, (e) => e.stopPropagation());
    requestAnimationFrame(() => show(0));
    this.destroyInner = () => { if (inner) inner.destroy(); };
    return box;
  }
  destroy() { if (this.destroyInner) this.destroyInner(); }
  ignoreEvent() { return true; }
}

const peekField = StateField.define({
  create: () => Decoration.none,
  update(value, tr) {
    for (const e of tr.effects) {
      if (e.is(closePeek)) return Decoration.none;
      if (e.is(openPeek)) {
        const line = tr.state.doc.lineAt(e.value.pos);
        return Decoration.set([Decoration.widget({ widget: new PeekWidget(e.value), block: true, side: 1 }).range(line.to)]);
      }
    }
    // Editing closes it, as in VS Code.
    return tr.docChanged ? Decoration.none : value;
  },
  provide: (f) => EditorView.decorations.from(f),
});

function showPeek(view, title, locations) {
  view.dispatch({ effects: [openPeek.of({ title, locations, pos: view.state.selection.main.head }), EditorView.scrollIntoView(view.state.selection.main.head, { y: 'start', yMargin: 60 })] });
}

/** ⌥F12: the definition of the symbol at the cursor, in a box under the line. */
export async function peekDefinition(view) {
  const head = view.state.selection.main.head;
  let target = await definitionAt(view.state, head).catch(() => null);
  if (!target && api.fallbackDefinitions) {
    const found = await api.fallbackDefinitions(view);
    if (found && found.length) target = found[0];
  }
  if (!target) { notify('info', 'No definition found', []); return; }
  showPeek(view, 'Definition', [target]);
}

/** ⇧F12 with an extension's references: every use, in a box under the line. False without them. */
export async function peekReferences(view) {
  const list = await referencesAt(view.state, view.state.selection.main.head).catch(() => []);
  if (!list.length) return false;
  showPeek(view, `${list.length} reference${list.length === 1 ? '' : 's'}`, list);
  return true;
}

export function closePeekView(view) {
  if (view.state.field(peekField, false)?.size) { view.dispatch({ effects: closePeek.of(null) }); return true; }
  return false;
}

export const languageFeatures = () => [lightBulb, peekField];
/** Inlay hints (settings.js turns them off with editor.inlayHints.enabled). */
export const inlayHints = [hintField, hintFetcher];
