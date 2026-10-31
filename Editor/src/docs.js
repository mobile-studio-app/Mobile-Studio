// Renders API docs (completion info, hover, long-press sheet) and the long-press gesture.
import { ViewPlugin } from '@codemirror/view';

const escapeHTML = (s) => String(s ?? '').replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);

function paragraphs(text) {
  return escapeHTML(text).split(/\n{2,}/).map((p) => `<p>${p.replace(/\n/g, ' ')}</p>`).join('');
}

function signatureLine(name, sig) {
  const params = sig.params.map((p) => `${escapeHTML(p.name)}${p.optional ? '?' : ''}<span class="dc-type">: ${escapeHTML(p.type)}</span>`).join(', ');
  const returns = sig.returns.length ? ` <span class="dc-type">→ ${sig.returns.map((r) => escapeHTML(r.type)).join(', ')}</span>` : '';
  return `<code class="dc-signature-line">${escapeHTML(name)}(${params})${returns}</code>`;
}

/** HTML for a resolved symbol `{ name, doc, kind }`. `compact` drops parameter tables. */
export function renderDocHTML(sym, { compact = false } = {}) {
  const { name, doc } = sym;
  const sigs = doc.signatures || [];
  let html = '';
  if (sigs.length) {
    html += sigs.slice(0, compact ? 1 : sigs.length).map((s) => signatureLine(name, s)).join('');
    if (compact && sigs.length > 1) html += `<div class="dc-muted">+${sigs.length - 1} more signature${sigs.length > 2 ? 's' : ''}</div>`;
  } else {
    html += `<code class="dc-signature-line">${escapeHTML(name)}</code>`;
  }
  html += doc.description
    ? paragraphs(compact ? doc.description.split(/\n{2,}/)[0] : doc.description)
    : `<p class="dc-muted">No documentation yet${sym.kind === 'module' ? '' : ' (this may be new in LÖVE 12)'}.</p>`;

  if (!compact && sigs.length) {
    sigs.forEach((sig, i) => {
      if (!sig.params.length && !sig.returns.length) return;
      if (sigs.length > 1) html += `<h4>Variant ${i + 1}</h4>`;
      if (sig.params.length) {
        html += '<dl>' + sig.params.map((p) =>
          `<dt>${escapeHTML(p.name)}${p.optional ? '?' : ''} <span class="dc-type">${escapeHTML(p.type)}</span></dt>` +
          (p.description ? `<dd>${escapeHTML(p.description)}</dd>` : '')).join('') + '</dl>';
      }
      if (sig.returns.length) {
        html += '<div class="dc-returns">Returns</div><dl>' + sig.returns.map((r) =>
          `<dt>${escapeHTML(r.name || 'value')} <span class="dc-type">${escapeHTML(r.type)}</span></dt>` +
          (r.description ? `<dd>${escapeHTML(r.description)}</dd>` : '')).join('') + '</dl>';
      }
    });
  }
  if (!compact && doc.url) html += `<a class="dc-link" href="${escapeHTML(doc.url)}" data-external>Open in browser ↗</a>`;
  return html;
}

// --- Bottom sheet -----------------------------------------------------------------

let sheet = null;

/** Shows docs for a symbol, or ready-made `{ title, html }` (an extension's hover). */
export function showDocsSheet(sym, openURL) {
  hideDocsSheet();
  sheet = document.createElement('div');
  sheet.className = 'dc-sheet';
  const title = sym.title || (sym.kind === 'method' ? 'Method' : sym.kind === 'module' ? 'Module' : 'Function');
  sheet.innerHTML = `<div class="dc-sheet-head"><span>${escapeHTML(title)}</span>` +
    `<button class="dc-close" aria-label="Close">✕</button></div><div class="dc-sheet-body">${sym.html ?? renderDocHTML(sym)}</div>`;
  sheet.querySelector('.dc-close').onclick = hideDocsSheet;
  sheet.addEventListener('click', (e) => {
    const link = e.target.closest('a[data-external]');
    if (link) { e.preventDefault(); openURL(link.href); }
  });
  document.body.append(sheet);
  requestAnimationFrame(() => sheet?.classList.add('open'));
}

export function hideDocsSheet() {
  if (!sheet) return;
  const old = sheet;
  sheet = null;
  old.classList.remove('open');
  setTimeout(() => old.remove(), 200);
}

/**
 * Long press (touch) on a symbol shows its docs. Fires before iOS's own text-selection
 * long press, and only when there's something to show, so ordinary selection still works
 * on plain words. `resolve` may return a promise (extension hovers).
 */
export function longPressDocs(resolve, openURL) {
  return ViewPlugin.fromClass(class {
    constructor(view) {
      this.view = view;
      this.timer = null;
      this.start = null;
      this.fired = false;
      this.onStart = (e) => {
        if (e.touches.length !== 1) return this.cancel();
        const t = e.touches[0];
        this.start = { x: t.clientX, y: t.clientY };
        this.fired = false;
        clearTimeout(this.timer);
        this.timer = setTimeout(() => this.fire(), 420);
      };
      this.onMove = (e) => {
        if (!this.start) return;
        const t = e.touches[0];
        if (Math.hypot(t.clientX - this.start.x, t.clientY - this.start.y) > 8) this.cancel();
      };
      this.onEnd = (e) => {
        clearTimeout(this.timer);
        // Swallow the end of a long press that opened docs, so no callout or selection follows.
        if (this.fired) e.preventDefault();
        this.start = null;
      };
      view.contentDOM.addEventListener('touchstart', this.onStart, { passive: true });
      view.contentDOM.addEventListener('touchmove', this.onMove, { passive: true });
      view.contentDOM.addEventListener('touchend', this.onEnd);
      view.contentDOM.addEventListener('touchcancel', this.onEnd);
    }
    async fire() {
      if (!this.start) return;
      const start = this.start;
      const pos = this.view.posAtCoords(start);
      let sym = pos != null && resolve(this.view.state, pos);
      if (sym && typeof sym.then === 'function') {
        sym = await sym.catch(() => null);
        // A slow answer still counts if the finger hasn't moved on.
        if (this.start !== start && this.start !== null) return;
      }
      if (!sym) return;
      this.fired = true;
      window.getSelection()?.removeAllRanges();
      this.view.dispatch({ selection: { anchor: pos } });
      showDocsSheet(sym, openURL);
    }
    cancel() {
      clearTimeout(this.timer);
      this.start = null;
    }
    destroy() {
      clearTimeout(this.timer);
      this.view.contentDOM.removeEventListener('touchstart', this.onStart);
      this.view.contentDOM.removeEventListener('touchmove', this.onMove);
      this.view.contentDOM.removeEventListener('touchend', this.onEnd);
      this.view.contentDOM.removeEventListener('touchcancel', this.onEnd);
    }
  });
}
