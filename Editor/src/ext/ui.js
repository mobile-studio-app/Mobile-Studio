// VS Code's quick input (the box at the top used by the Command Palette, quick picks and input
// boxes) and its notification toasts.

let active = null;   // the open quick input's close function

function element(tag, className, text) {
  const el = document.createElement(tag);
  if (className) el.className = className;
  if (text != null) el.textContent = text;
  return el;
}

/** Fuzzy match: every query character appears in order. Returns matched indices or null. */
export function fuzzyMatch(query, text) {
  if (!query) return [];
  const q = query.toLowerCase();
  const t = text.toLowerCase();
  // A contiguous match reads best, so prefer it.
  const at = t.indexOf(q);
  if (at >= 0) return [...q].map((_, i) => at + i);
  const out = [];
  let j = 0;
  for (let i = 0; i < t.length && j < q.length; i++) if (t[i] === q[j]) { out.push(i); j++; }
  return j === q.length ? out : null;
}

/** Higher is better: a match at the start, then at a word start, then anywhere, then scattered. */
export function matchScore(indices, text) {
  if (!indices.length) return 0;
  const contiguous = indices[indices.length - 1] - indices[0] === indices.length - 1;
  const first = indices[0];
  const wordStart = first === 0 || /[\s.:_\-/(]/.test(text[first - 1]);
  return (contiguous ? 100 : 0) + (first === 0 ? 50 : wordStart ? 25 : 0) - first / 100;
}

function highlighted(text, indices) {
  const span = element('span', 'qi-label');
  const set = new Set(indices);
  let run = '';
  let inMatch = false;
  const flush = () => {
    if (!run) return;
    span.append(inMatch ? element('b', null, run) : document.createTextNode(run));
    run = '';
  };
  [...text].forEach((c, i) => {
    if (set.has(i) !== inMatch) { flush(); inMatch = set.has(i); }
    run += c;
  });
  flush();
  return span;
}

/**
 * Shows the quick input. `items` are { label, description, detail, separator }; resolves to the chosen
 * index (or indices with canPickMany), or null when dismissed. With `items` omitted it's an input box
 * and resolves to the text.
 */
function open({ items, placeholder = '', prompt = '', value = '', password = false, canPickMany = false, onFilter, prefix = '', selectValue = true, onActive, activeIndex }) {
  if (active) active(null);
  return new Promise((resolve) => {
    const backdrop = element('div', 'qi-backdrop');
    const box = element('div', 'qi');
    const input = element('input', 'qi-input');
    input.type = password ? 'password' : 'text';
    input.placeholder = placeholder;
    input.value = value;
    input.setAttribute('autocapitalize', 'off');
    input.setAttribute('autocorrect', 'off');
    input.spellcheck = false;
    const row = element('div', 'qi-row');
    row.append(input);
    let okButton = null;
    if (canPickMany) {
      okButton = element('button', 'qi-ok', 'OK');
      row.append(okButton);
    }
    box.append(row);
    if (prompt) box.append(element('div', 'qi-prompt', prompt));
    const list = element('div', 'qi-list');
    box.append(list);
    backdrop.append(box);
    document.body.append(backdrop);

    let shown = [];      // [{ index, el }]
    let selected = 0;
    const picked = new Set();

    const close = (result) => {
      active = null;
      backdrop.remove();
      resolve(result);
    };
    active = close;

    const select = (i) => {
      if (!shown.length) return;
      selected = (i + shown.length) % shown.length;
      shown.forEach((s, k) => s.el.classList.toggle('selected', k === selected));
      shown[selected].el.scrollIntoView({ block: 'nearest' });
      if (onActive) onActive(shown[selected].index);
    };

    const accept = () => {
      if (!items) { close(input.value); return; }
      if (canPickMany) { close([...picked].sort((a, b) => a - b)); return; }
      if (shown[selected]) close(shown[selected].index);
    };

    const render = () => {
      if (!items) return;
      // A mode prefix (">" in the Command Palette) isn't part of the search.
      const query = (prefix && input.value.startsWith(prefix) ? input.value.slice(prefix.length) : input.value).trim();
      list.textContent = '';
      shown = [];
      let pendingSeparator = null;
      let entries = items.map((item, index) => {
        if (item.separator) return { item, index };
        const label = item.label || '';
        const match = fuzzyMatch(query, label)
          ?? (query && item.filterText && fuzzyMatch(query, item.filterText) ? [] : null)
          ?? (query && item.description ? (fuzzyMatch(query, item.description) && []) : null);
        return { item, index, match, score: match ? matchScore(match, label) : -1 };
      });
      // While filtering, best matches first (and no separators), as VS Code does.
      if (query) entries = entries.filter((e) => !e.item.separator && e.match).sort((a, b) => b.score - a.score);
      entries.forEach(({ item, index, match }) => {
        if (item.separator) { pendingSeparator = item.label; return; }
        const label = item.label || '';
        if (pendingSeparator != null && !query) {
          list.append(element('div', 'qi-separator', pendingSeparator));
          pendingSeparator = null;
        }
        const el = element('div', 'qi-item');
        if (canPickMany) {
          const check = element('span', 'qi-check', picked.has(index) ? '☑' : '☐');
          el.append(check);
        }
        const text = element('div', 'qi-text');
        const line = element('div', 'qi-line');
        line.append(highlighted(label, match || []));
        if (item.description) line.append(element('span', 'qi-description', item.description));
        text.append(line);
        if (item.detail) text.append(element('div', 'qi-detail', item.detail));
        el.append(text);
        if (item.keybinding) el.append(element('span', 'qi-key', item.keybinding));
        el.addEventListener('click', () => {
          if (canPickMany) {
            if (picked.has(index)) picked.delete(index); else picked.add(index);
            render();
            return;
          }
          close(index);
        });
        list.append(el);
        shown.push({ index, el });
      });
      if (!shown.length) list.append(element('div', 'qi-empty', query ? 'No matching results' : 'No items'));
      const start = !query && activeIndex != null ? shown.findIndex((s) => s.index === activeIndex) : -1;
      select(Math.max(0, start));
    };

    input.addEventListener('input', () => { render(); if (onFilter) onFilter(input.value); });
    input.addEventListener('keydown', (e) => {
      if (e.key === 'Escape') { e.preventDefault(); close(null); }
      else if (e.key === 'Enter') { e.preventDefault(); accept(); }
      else if (e.key === 'ArrowDown') { e.preventDefault(); select(selected + 1); }
      else if (e.key === 'ArrowUp') { e.preventDefault(); select(selected - 1); }
    });
    backdrop.addEventListener('pointerdown', (e) => { if (e.target === backdrop) close(null); });
    if (okButton) okButton.addEventListener('click', accept);
    render();
    input.focus();
    if (value && selectValue) input.select();
  });
}

export const quickPick = (params) => open(params);
export const inputBox = (params) => open({ ...params, items: undefined });
export const closeQuickInput = () => { if (active) active(null); };

// MARK: - Notifications

const ICONS = { info: 'ⓘ', warning: '⚠', error: '⊗' };

/** A notification toast. Resolves to the chosen button's index, or null when closed. */
export function notify(severity, text, items = []) {
  let stack = document.getElementById('notifications');
  if (!stack) {
    stack = element('div', 'notifications');
    stack.id = 'notifications';
    document.body.append(stack);
  }
  return new Promise((resolve) => {
    const toast = element('div', `toast ${severity}`);
    const head = element('div', 'toast-head');
    head.append(element('span', `toast-icon ${severity}`, ICONS[severity] || ICONS.info));
    head.append(element('span', 'toast-text', text));
    const close = element('button', 'toast-close', '✕');
    head.append(close);
    toast.append(head);
    let timer = 0;
    const done = (result) => {
      clearTimeout(timer);
      toast.remove();
      resolve(result);
    };
    close.addEventListener('click', () => done(null));
    if (items.length) {
      const buttons = element('div', 'toast-buttons');
      items.forEach((label, i) => {
        const b = element('button', i === 0 ? 'toast-button primary' : 'toast-button', label);
        b.addEventListener('click', () => done(i));
        buttons.append(b);
      });
      toast.append(buttons);
    } else {
      timer = setTimeout(() => done(null), severity === 'error' ? 12000 : 7000);
    }
    stack.append(toast);
    while (stack.children.length > 4) stack.firstChild.remove();
  });
}
