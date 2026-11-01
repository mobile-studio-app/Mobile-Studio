// VS Code's minimap (the whole file in miniature beside the editor, with the visible part
// marked; drag it to scroll) and sticky scroll (the lines that open the blocks the top of the
// screen is inside stay pinned at the top: the function, the class, the loop).
import { ViewPlugin, EditorView } from '@codemirror/view';
import { syntaxTree, highlightingFor } from '@codemirror/language';
import { highlightTree } from '@lezer/highlight';

// The CSS class the theme gives a syntax tag (a token's class names), resolved through the state.
const themeHighlighter = (state) => ({ style: (tags) => highlightingFor(state, tags) });

/** Calls `fn(from, to, className)` for each highlighted token in [from, to). */
function eachToken(state, from, to, fn) {
  const tree = syntaxTree(state);
  if (!tree.length) return;
  highlightTree(tree, themeHighlighter(state), (a, b, cls) => fn(a, b, cls), from, to);
}

/** A line's indentation in columns, or -1 for a blank line. */
function indentOf(text, tabSize) {
  let col = 0;
  for (const ch of text) {
    if (ch === ' ') col++;
    else if (ch === '\t') col += tabSize - (col % tabSize);
    else return col;
  }
  return -1;
}

// MARK: - Sticky scroll

const MAX_STICKY = 5;

/** The lines opening the blocks around line `n` (1-based), outermost first. By indentation, as
 * VS Code does for languages without a folding model: works for braces, Python, Lua and the rest. */
function scopesAround(doc, n, tabSize) {
  let line = n;
  let indent = -1;
  while (line <= doc.lines && (indent = indentOf(doc.line(line).text, tabSize)) < 0) line++;
  if (indent <= 0) return [];
  const headers = [];
  for (let i = Math.min(line, doc.lines) - 1; i >= 1 && indent > 0; i--) {
    const text = doc.line(i).text;
    const at = indentOf(text, tabSize);
    if (at < 0 || at >= indent) continue;
    // A line that only closes something ("}", "end", ")") isn't a header; keep looking.
    if (/^\s*[)\]}]/.test(text)) continue;
    headers.push(i);
    indent = at;
  }
  return headers.reverse();
}

class StickyScroll {
  constructor(view) {
    this.view = view;
    this.lines = [];
    this.dom = document.createElement('div');
    this.dom.className = 'cm-sticky';
    this.dom.hidden = true;
    this.dom.addEventListener('mousedown', (e) => e.preventDefault());
    this.dom.addEventListener('click', (e) => {
      const row = e.target.closest('[data-line]');
      if (row) this.jump(Number(row.dataset.line));
    });
    view.dom.appendChild(this.dom);
    this.onScroll = () => this.schedule();
    view.scrollDOM.addEventListener('scroll', this.onScroll, { passive: true });
    this.frame = 0;
    this.schedule();
  }

  update(update) {
    if (update.docChanged || update.viewportChanged || update.geometryChanged) this.schedule();
  }

  schedule() {
    if (this.frame) return;
    this.frame = requestAnimationFrame(() => { this.frame = 0; this.measure(); });
  }

  measure() {
    const view = this.view;
    const { state } = view;
    const tabSize = state.tabSize;
    const lineHeight = view.defaultLineHeight;
    const top = view.scrollDOM.scrollTop - view.documentPadding.top;
    if (top <= 0 || view.scrollDOM.clientHeight < lineHeight * 12) { this.render([]); return; }
    // The line under the pinned rows decides them, so settle on a count that agrees with itself.
    let headers = [];
    for (let pass = 0; pass < 3; pass++) {
      const block = view.lineBlockAtHeight(top + headers.length * lineHeight);
      const n = state.doc.lineAt(block.from).number;
      const next = scopesAround(state.doc, n, tabSize).filter((h) => h < n).slice(0, MAX_STICKY);
      if (next.length === headers.length && next.every((h, i) => h === headers[i])) break;
      headers = next;
    }
    this.render(headers);
  }

  render(headers) {
    const view = this.view;
    if (headers.length === this.lines.length && headers.every((h, i) => h === this.lines[i]) && !this.stale) return;
    this.lines = headers;
    this.stale = false;
    if (!headers.length) { this.dom.hidden = true; this.dom.replaceChildren(); return; }
    const gutters = view.dom.querySelector('.cm-gutters');
    const gutterWidth = gutters ? gutters.getBoundingClientRect().width : 0;
    // Numbers end where the line number gutter does; the fold gutter after it is space.
    const numbers = view.dom.querySelector('.cm-lineNumbers');
    const numbersWidth = numbers && gutters ? numbers.getBoundingClientRect().right - gutters.getBoundingClientRect().left : gutterWidth;
    const linePadding = parseFloat(getComputedStyle(view.contentDOM.querySelector('.cm-line') || view.contentDOM).paddingLeft) || 0;
    this.dom.style.left = '0px';
    this.dom.style.right = `${view.dom.clientWidth - view.scrollDOM.offsetLeft - view.scrollDOM.clientWidth}px`;
    // The editor's font (the content's, which the theme and font size setting set).
    const font = getComputedStyle(view.contentDOM);
    this.dom.style.fontFamily = font.fontFamily;
    this.dom.style.fontSize = font.fontSize;
    this.dom.style.lineHeight = font.lineHeight;
    const rows = headers.map((n) => {
      const line = view.state.doc.line(n);
      const row = document.createElement('div');
      row.className = 'cm-sticky-line';
      row.dataset.line = String(n);
      row.style.height = `${view.defaultLineHeight}px`;
      const number = document.createElement('span');
      number.className = 'cm-sticky-number';
      number.style.width = `${numbersWidth}px`;
      number.textContent = String(n);
      const text = document.createElement('span');
      text.className = 'cm-sticky-text';
      text.style.paddingLeft = `${gutterWidth - numbersWidth + linePadding}px`;
      let at = line.from;
      eachToken(view.state, line.from, line.to, (from, to, cls) => {
        if (from > at) text.append(view.state.sliceDoc(at, from));
        const span = document.createElement('span');
        span.className = cls;
        span.textContent = view.state.sliceDoc(from, to);
        text.append(span);
        at = to;
      });
      if (at < line.to) text.append(view.state.sliceDoc(at, line.to));
      row.append(number, text);
      return row;
    });
    this.dom.replaceChildren(...rows);
    this.dom.hidden = false;
  }

  /** Shows the line under the pinned rows above it, with the cursor at its start. */
  jump(n) {
    const view = this.view;
    const line = view.state.doc.line(n);
    const index = this.lines.indexOf(n);
    const block = view.lineBlockAt(line.from);
    view.scrollDOM.scrollTop = block.top + view.documentPadding.top - Math.max(0, index) * view.defaultLineHeight;
    view.dispatch({ selection: { anchor: line.from + Math.max(0, indentOf(line.text, view.state.tabSize)) } });
    view.focus();
  }

  destroy() {
    cancelAnimationFrame(this.frame);
    this.view.scrollDOM.removeEventListener('scroll', this.onScroll);
    this.dom.remove();
  }
}

export const stickyScroll = ViewPlugin.fromClass(StickyScroll);

// MARK: - Minimap

const MINIMAP_WIDTH = 72;
const ROW = 2;          // pixels per line
const MIN_EDITOR = 640; // narrower editors (phones) don't get one

class Minimap {
  constructor(view) {
    this.view = view;
    this.canvas = document.createElement('canvas');
    this.canvas.className = 'cm-minimap';
    this.colors = new Map();
    this.frame = 0;
    this.dragging = null;
    view.dom.appendChild(this.canvas);
    this.onScroll = () => this.schedule();
    view.scrollDOM.addEventListener('scroll', this.onScroll, { passive: true });
    this.canvas.addEventListener('pointerdown', (e) => this.pointerDown(e));
    this.canvas.addEventListener('pointermove', (e) => this.pointerMove(e));
    this.canvas.addEventListener('pointerup', (e) => this.pointerUp(e));
    this.canvas.addEventListener('pointercancel', (e) => this.pointerUp(e));
    this.schedule();
  }

  update(update) {
    if (update.docChanged || update.viewportChanged || update.geometryChanged || update.selectionSet) this.schedule();
    // A theme change: colours are looked up again.
    if (update.startState.facet(EditorView.darkTheme) !== update.state.facet(EditorView.darkTheme)) this.colors.clear();
  }

  schedule() {
    if (this.frame) return;
    this.frame = requestAnimationFrame(() => { this.frame = 0; this.draw(); });
  }

  get enabled() { return this.view.dom.clientWidth >= MIN_EDITOR; }

  colorFor(cls) {
    if (!this.colors.has(cls)) {
      const probe = document.createElement('span');
      probe.className = cls;
      probe.style.display = 'none';
      this.view.contentDOM.appendChild(probe);
      this.colors.set(cls, getComputedStyle(probe).color);
      probe.remove();
    }
    return this.colors.get(cls);
  }

  /** The first line drawn and the minimap's vertical offset: when the file is taller than the
   * minimap, it scrolls along with the editor, as VS Code's does. */
  layout() {
    const view = this.view;
    const height = this.canvas.clientHeight;
    const total = view.state.doc.lines * ROW;
    const scroller = view.scrollDOM;
    const range = Math.max(1, scroller.scrollHeight - scroller.clientHeight);
    const offset = total > height ? (scroller.scrollTop / range) * (total - height) : 0;
    return { height, total, offset };
  }

  draw() {
    const view = this.view;
    const on = this.enabled;
    view.dom.classList.toggle('cm-minimap-on', on);
    this.canvas.hidden = !on;
    if (!on) return;
    const dpr = window.devicePixelRatio || 1;
    const width = MINIMAP_WIDTH;
    const { height, offset } = this.layout();
    if (this.canvas.width !== width * dpr || this.canvas.height !== Math.round(height * dpr)) {
      this.canvas.width = width * dpr;
      this.canvas.height = Math.round(height * dpr);
    }
    const ctx = this.canvas.getContext('2d');
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, width, height);
    const { doc } = view.state;
    const first = Math.max(1, Math.floor(offset / ROW) + 1);
    const last = Math.min(doc.lines, first + Math.ceil(height / ROW) + 1);
    const base = getComputedStyle(view.contentDOM).color;
    const tabSize = view.state.tabSize;
    const charWidth = 1;
    // Each token as a bar per run of non-space characters, in the token's colour.
    const drawRun = (lineNo, text, startCol, color) => {
      const y = (lineNo - 1) * ROW - offset;
      ctx.fillStyle = color;
      let col = startCol;
      let runStart = -1;
      for (let i = 0; i <= text.length; i++) {
        const ch = text[i];
        const blank = ch === undefined || ch === ' ' || ch === '\t';
        if (!blank && runStart < 0) runStart = col;
        if (blank && runStart >= 0) {
          ctx.fillRect(4 + runStart * charWidth, y, Math.max(1, (col - runStart) * charWidth), ROW - 0.6);
          runStart = -1;
        }
        if (ch === '\t') col += tabSize - (col % tabSize); else col++;
      }
      return col;
    };
    ctx.globalAlpha = 0.7;
    const from = doc.line(first).from;
    const to = doc.line(last).to;
    // Columns where each token starts, per line: text before a token is drawn in the base colour.
    let line = doc.line(first);
    let col = 0;
    let at = line.from;
    const advanceTo = (pos) => {
      while (pos > line.to && line.number < last) {
        if (at < line.to) drawRun(line.number, doc.sliceString(at, line.to), col, base);
        line = doc.line(line.number + 1);
        col = 0;
        at = line.from;
      }
    };
    const fill = (start, end, color) => {
      advanceTo(start);
      if (start > at) { col = drawRun(line.number, doc.sliceString(at, start), col, base); at = start; }
      // A token can span lines (comments, strings).
      while (end > line.to && line.number < last) {
        col = drawRun(line.number, doc.sliceString(at, line.to), col, color);
        line = doc.line(line.number + 1);
        col = 0;
        at = line.from;
      }
      col = drawRun(line.number, doc.sliceString(at, Math.min(end, line.to)), col, color);
      at = Math.min(end, line.to);
    };
    eachToken(view.state, from, to, (a, b, cls) => fill(a, b, this.colorFor(cls)));
    advanceTo(to + 1);
    if (at < line.to) drawRun(line.number, doc.sliceString(at, line.to), col, base);
    ctx.globalAlpha = 1;

    // The visible part.
    const scroller = view.scrollDOM;
    const lineHeight = view.defaultLineHeight || 16;
    const sliderTop = (scroller.scrollTop / lineHeight) * ROW - offset;
    const sliderHeight = Math.max(8, (scroller.clientHeight / lineHeight) * ROW);
    this.slider = { top: sliderTop, height: sliderHeight };
    ctx.fillStyle = this.dragging ? 'rgba(191, 191, 191, 0.2)' : 'rgba(121, 121, 121, 0.2)';
    ctx.fillRect(0, sliderTop, width, sliderHeight);
    // The cursor's line.
    const cursorLine = doc.lineAt(view.state.selection.main.head).number;
    ctx.fillStyle = 'rgba(160, 160, 160, 0.5)';
    ctx.fillRect(0, (cursorLine - 1) * ROW - offset, width, ROW);
  }

  /** Scrolls so the slider's top is at minimap y. */
  scrollToSlider(y) {
    const view = this.view;
    const { offset } = this.layout();
    const lineHeight = view.defaultLineHeight || 16;
    view.scrollDOM.scrollTop = ((y + offset) / ROW) * lineHeight;
  }

  pointerDown(e) {
    e.preventDefault();
    const y = e.offsetY;
    const slider = this.slider || { top: 0, height: 0 };
    // On the slider: drag it. Elsewhere: centre it there, then drag.
    const grab = y >= slider.top && y <= slider.top + slider.height ? y - slider.top : slider.height / 2;
    this.dragging = { grab };
    this.canvas.setPointerCapture(e.pointerId);
    this.scrollToSlider(y - grab);
    this.schedule();
  }

  pointerMove(e) {
    if (!this.dragging) return;
    this.scrollToSlider(e.offsetY - this.dragging.grab);
  }

  pointerUp(e) {
    if (!this.dragging) return;
    this.dragging = null;
    try { this.canvas.releasePointerCapture(e.pointerId); } catch (err) { /* already released */ }
    this.schedule();
  }

  destroy() {
    cancelAnimationFrame(this.frame);
    this.view.scrollDOM.removeEventListener('scroll', this.onScroll);
    this.view.dom.classList.remove('cm-minimap-on');
    this.canvas.remove();
  }
}

export const minimap = ViewPlugin.fromClass(Minimap);
