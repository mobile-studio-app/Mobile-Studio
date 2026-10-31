// The debugger in the editor: the breakpoint gutter (tap left of the line numbers to add or
// remove one), the line the program is paused on, and values of expressions while paused.
import { StateField, StateEffect, RangeSet, RangeSetBuilder } from '@codemirror/state';
import { EditorView, Decoration, GutterMarker, WidgetType, gutter, hoverTooltip } from '@codemirror/view';
import { quickPick, inputBox } from './ext/ui.js';

const setBreakpoints = StateEffect.define();   // [{ line, condition, logMessage, enabled }]
const toggleBreakpoint = StateEffect.define(); // a position on the line
const editBreakpoint = StateEffect.define();   // { pos, bp }: replaces the line's breakpoint
const setPausedLine = StateEffect.define();    // a line number, or null
const setInlineValues = StateEffect.define();  // Decoration set of values at line ends, or null

class BreakpointMarker extends GutterMarker {
  constructor(bp) { super(); this.bp = bp; }
  eq(other) {
    return other.bp.condition === this.bp.condition && other.bp.logMessage === this.bp.logMessage && other.bp.enabled === this.bp.enabled;
  }
  toDOM() {
    const el = document.createElement('div');
    let kind = 'cm-breakpoint';
    if (this.bp.logMessage) kind += ' log';
    else if (this.bp.condition) kind += ' conditional';
    if (this.bp.enabled === false) kind += ' disabled';
    el.className = kind;
    if (this.bp.condition) el.title = 'Condition: ' + this.bp.condition;
    if (this.bp.logMessage) el.title = 'Log: ' + this.bp.logMessage;
    return el;
  }
}

class PausedMarker extends GutterMarker {
  toDOM() {
    const el = document.createElement('div');
    el.className = 'cm-paused-arrow';
    return el;
  }
}
const pausedMarker = new PausedMarker();

function buildBreakpoints(doc, list) {
  const builder = new RangeSetBuilder();
  const seen = new Set();
  for (const bp of [...list].sort((a, b) => a.line - b.line)) {
    if (bp.line < 1 || bp.line > doc.lines || seen.has(bp.line)) continue;
    seen.add(bp.line);
    const from = doc.line(bp.line).from;
    builder.add(from, from, new BreakpointMarker(bp));
  }
  return builder.finish();
}

export const breakpointField = StateField.define({
  create: () => RangeSet.empty,
  update(set, tr) {
    set = set.map(tr.changes);
    for (const effect of tr.effects) {
      if (effect.is(setBreakpoints)) set = buildBreakpoints(tr.newDoc, effect.value);
      if (effect.is(editBreakpoint)) {
        const from = tr.newDoc.lineAt(effect.value.pos).from;
        set = set.update({ filter: (f) => f !== from, add: [new BreakpointMarker(effect.value.bp).range(from)] });
      }
      if (effect.is(toggleBreakpoint)) {
        const from = tr.newDoc.lineAt(effect.value).from;
        let exists = false;
        set.between(from, from, () => { exists = true; });
        set = exists
          ? set.update({ filter: (f) => f !== from })
          : set.update({ add: [new BreakpointMarker({ line: 0, enabled: true }).range(from)] });
      }
    }
    return set;
  },
});

/** The breakpoints as the app stores them, with their current line numbers. */
function breakpointList(state) {
  const out = [];
  const seen = new Set();
  const iter = state.field(breakpointField).iter();
  for (; iter.value; iter.next()) {
    const line = state.doc.lineAt(iter.from).number;
    if (seen.has(line)) continue;
    seen.add(line);
    const { condition, logMessage, enabled } = iter.value.bp;
    out.push({ line, condition, logMessage, enabled: enabled !== false });
  }
  return out;
}

const pausedLineField = StateField.define({
  create: () => null,
  update(line, tr) {
    for (const effect of tr.effects) if (effect.is(setPausedLine)) line = effect.value;
    if (line != null && tr.docChanged) {
      const pos = tr.changes.mapPos(tr.startState.doc.line(Math.min(line, tr.startState.doc.lines)).from);
      line = tr.newDoc.lineAt(pos).number;
    }
    return line;
  },
  provide: (field) => EditorView.decorations.from(field, (line) => (view) => {
    const doc = view.state.doc;
    if (line == null || line > doc.lines) return Decoration.none;
    return Decoration.set([Decoration.line({ class: 'cm-paused-line' }).range(doc.line(line).from)]);
  }),
});

// VS Code's inline values: while paused, each line above the stop shows the values of the
// variables it mentions ("x = 4, name = "duo"").
class InlineValuesWidget extends WidgetType {
  constructor(text) { super(); this.text = text; }
  eq(other) { return other.text === this.text; }
  toDOM() {
    const el = document.createElement('span');
    el.className = 'cm-inline-values';
    el.textContent = this.text;
    return el;
  }
  ignoreEvent() { return true; }
}

const inlineValuesField = StateField.define({
  create: () => Decoration.none,
  update(set, tr) {
    for (const effect of tr.effects) {
      if (effect.is(setInlineValues)) set = effect.value || Decoration.none;
      if (effect.is(setPausedLine) && effect.value == null) set = Decoration.none;
    }
    return tr.docChanged ? set.map(tr.changes) : set;
  },
  provide: (field) => EditorView.decorations.from(field),
});

/** Where a line comment starts, by file type (Lua's # is the length operator, not a comment). */
function lineComment(path) {
  if (/\.(py|pyw|sh|rb|ya?ml|toml)$/i.test(path)) return /#.*$/;
  if (/\.lua$/i.test(path)) return /--.*$/;
  return /\/\/.*$/;
}

function inlineValueDecorations(doc, pausedLine, values, path) {
  const comment = lineComment(path || '');
  const byName = new Map();
  for (const v of values) if (/^[A-Za-z_]\w*$/.test(v.name) && !byName.has(v.name)) byName.set(v.name, v.value);
  if (!byName.size) return Decoration.none;
  const decorations = [];
  const first = Math.max(1, pausedLine - 40);
  for (let n = first; n <= Math.min(pausedLine, doc.lines); n++) {
    const line = doc.line(n);
    // Skip comments; strings can mention names too, which is fine.
    const code = line.text.replace(comment, '');
    const seen = [];
    for (const m of code.matchAll(/[A-Za-z_]\w*/g)) {
      const name = m[0];
      if (byName.has(name) && !seen.includes(name) && code[m.index - 1] !== '.' && code[m.index - 1] !== ':') seen.push(name);
    }
    if (!seen.length) continue;
    let text = seen.map((name) => name + ' = ' + byName.get(name)).join(', ');
    if (text.length > 120) text = text.slice(0, 119) + '…';
    decorations.push(Decoration.widget({ widget: new InlineValuesWidget(text), side: 1 }).range(line.to));
  }
  return Decoration.set(decorations, true);
}

/** Shows the paused frame's variable values at the ends of the lines that use them. */
export async function showInlineValues(view, api, pausedLine) {
  const values = await api.native({ cmd: 'debugInlineValues' }).catch(() => null);
  if (!Array.isArray(values) || !api.isPaused()) return;
  view.dispatch({ effects: setInlineValues.of(inlineValueDecorations(view.state.doc, pausedLine, values, api.path())) });
}

// Expressions under the pointer (or long press) while paused: identifiers with their field
// accesses, e.g. player.pos.x or self.items[1].
function expressionAt(state, pos) {
  const line = state.doc.lineAt(pos);
  const text = line.text;
  const at = pos - line.from;
  const word = /[\w$]/;
  if (!word.test(text[at] || '') && !word.test(text[at - 1] || '')) return null;
  let end = at;
  while (end < text.length && word.test(text[end])) end++;
  let start = at;
  while (start > 0 && /[\w$.:\]\[]/.test(text[start - 1])) start--;
  const expression = text.slice(start, end).replace(/^[.:]+/, '').replace(/:/g, '.');
  if (!expression || /^\d/.test(expression)) return null;
  return { expression, from: line.from + start, to: line.from + end };
}

const escapeHTML = (s) => String(s ?? '').replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);

/**
 * The debugger's editor extensions. `api` has native (the bridge), path() (the open file) and
 * isPaused().
 */
export function debugExtensions(api) {
  let reportTimer = 0;
  const report = (view) => {
    clearTimeout(reportTimer);
    reportTimer = setTimeout(() => {
      const path = api.path();
      if (path) api.native({ cmd: 'setBreakpoints', path, breakpoints: breakpointList(view.state) }).catch(() => {});
    }, 400);
  };

  const evaluateHover = hoverTooltip(async (view, pos) => {
    if (!api.isPaused()) return null;
    const found = expressionAt(view.state, pos);
    if (!found) return null;
    const result = await api.native({ cmd: 'debugEvaluate', expression: found.expression }).catch(() => null);
    if (!result || result.error) return null;
    return {
      pos: found.from,
      end: found.to,
      above: true,
      create() {
        const dom = document.createElement('div');
        dom.className = 'dc-hover';
        dom.innerHTML = `<code class="dc-signature-line">${escapeHTML(result.value)}</code><span class="dc-muted">${escapeHTML(result.type)}</span>`;
        return { dom };
      },
    };
  }, { hoverTime: 300 });

  return [
    breakpointField,
    pausedLineField,
    inlineValuesField,
    gutter({
      class: 'cm-breakpoint-gutter',
      markers: (view) => view.state.field(breakpointField),
      lineMarker: (view, line) => {
        const paused = view.state.field(pausedLineField);
        return paused != null && paused <= view.state.doc.lines && view.state.doc.line(paused).from === line.from ? pausedMarker : null;
      },
      lineMarkerChange: (update) => update.startState.field(pausedLineField) !== update.state.field(pausedLineField),
      initialSpacer: () => new BreakpointMarker({ enabled: true }),
      domEventHandlers: breakpointGutterHandlers,
    }),
    evaluateHover,
    EditorView.updateListener.of((u) => {
      const toggled = u.transactions.some((tr) => tr.effects.some((e) => e.is(toggleBreakpoint) || e.is(editBreakpoint)));
      const fromApp = u.transactions.some((tr) => tr.effects.some((e) => e.is(setBreakpoints)));
      if (fromApp) return;
      if (toggled) { report(u.view); return; }
      // Edits move breakpoints with their lines; tell the app the new line numbers.
      if (u.docChanged && u.startState.field(breakpointField).size) {
        const before = breakpointList(u.startState).map((b) => b.line).join();
        const after = breakpointList(u.state).map((b) => b.line).join();
        if (before !== after || u.state.doc.lines !== u.startState.doc.lines) report(u.view);
      }
    }),
  ];
}

/**
 * Tap toggles the line's breakpoint; long press (or right click) opens its menu. Used by the
 * breakpoint strip and the line numbers, so the whole margin is a target (as in Xcode).
 */
export const breakpointGutterHandlers = {
  mousedown(view, line) {
    // The mousedown that follows a long press doesn't toggle too.
    if (Date.now() - longPressedAt < 800) return true;
    view.dispatch({ effects: toggleBreakpoint.of(line.from) });
    return true;
  },
  // Long press (or right click) on a breakpoint: edit it, as VS Code's gutter menu does.
  touchstart(view, line, event) {
    clearTimeout(pressTimer);
    const touch = event.touches[0];
    pressStart = touch && { x: touch.clientX, y: touch.clientY };
    pressTimer = setTimeout(() => { longPressedAt = Date.now(); breakpointMenu(view, line.from); }, 500);
    return false;
  },
  touchmove(view, line, event) {
    const touch = event.touches[0];
    if (pressStart && touch && Math.hypot(touch.clientX - pressStart.x, touch.clientY - pressStart.y) > 8) clearTimeout(pressTimer);
    return false;
  },
  touchend() { clearTimeout(pressTimer); return false; },
  contextmenu(view, line, event) {
    event.preventDefault();
    breakpointMenu(view, line.from);
    return true;
  },
};

/** Debug: Toggle Breakpoint (F9) on the cursor's line. */
export function toggleBreakpointAtCursor(view) {
  view.dispatch({ effects: toggleBreakpoint.of(view.state.selection.main.head) });
  return true;
}

let pressTimer = 0;
let pressStart = null;
let longPressedAt = 0;

/** The line's breakpoint marker, if it has one. */
function breakpointAt(state, pos) {
  const from = state.doc.lineAt(pos).from;
  let found = null;
  state.field(breakpointField).between(from, from, (f, t, marker) => { if (f === from) found = marker.bp; });
  return found;
}

async function breakpointMenu(view, pos) {
  const bp = breakpointAt(view.state, pos);
  const line = view.state.doc.lineAt(pos).number;
  const items = bp
    ? [
      { label: 'Edit Condition…', description: bp.condition || '' },
      { label: 'Edit Log Message…', description: bp.logMessage || '' },
      { label: bp.enabled === false ? 'Enable Breakpoint' : 'Disable Breakpoint' },
      { label: 'Remove Breakpoint' },
    ]
    : [{ label: 'Add Breakpoint' }, { label: 'Add Conditional Breakpoint…' }, { label: 'Add Logpoint…' }];
  const chosen = await quickPick({ placeholder: `Line ${line}`, items });
  if (chosen == null) return;
  const label = items[chosen].label;
  const current = bp || { enabled: true };
  const set = (next) => view.dispatch({ effects: editBreakpoint.of({ pos, bp: next }) });
  if (label === 'Remove Breakpoint') { view.dispatch({ effects: toggleBreakpoint.of(pos) }); return; }
  if (label === 'Add Breakpoint') { view.dispatch({ effects: toggleBreakpoint.of(pos) }); return; }
  if (label.endsWith('Breakpoint')) { set({ ...current, enabled: current.enabled === false }); return; }
  const log = label.includes('Log');
  const value = await inputBox({
    prompt: log ? 'Message to log when the line runs; {expression} shows a value. The program keeps running.' : 'Stop only when this expression is true.',
    placeholder: log ? 'x is {x}' : 'x > 10',
    value: (log ? current.logMessage : current.condition) || '',
  });
  if (value == null) return;
  set(log ? { ...current, logMessage: value || undefined } : { ...current, condition: value || undefined });
}

/** Shows the app's breakpoints for the open file. */
export function showBreakpoints(view, list) {
  view.dispatch({ effects: setBreakpoints.of(Array.isArray(list) ? list : []) });
}

/** Marks the line the program is paused on (null clears it) and scrolls to it. */
export function showPausedLine(view, line) {
  const effects = [setPausedLine.of(line)];
  if (line != null && line >= 1 && line <= view.state.doc.lines) {
    effects.push(EditorView.scrollIntoView(view.state.doc.line(line).from, { y: 'center' }));
  }
  view.dispatch({ effects });
}

/** The long-press sheet's value of the expression at `pos`, while paused. */
export async function debugValueAt(api, state, pos) {
  if (!api.isPaused()) return null;
  const found = expressionAt(state, pos);
  if (!found) return null;
  const result = await api.native({ cmd: 'debugEvaluate', expression: found.expression }).catch(() => null);
  if (!result || result.error) return null;
  return {
    title: found.expression,
    html: `<code class="dc-signature-line">${escapeHTML(result.value)}</code><p class="dc-muted">${escapeHTML(result.type)}</p>`,
  };
}
