// VS Code's find widget: floats at the editor's top right, counts matches ("3 of 12"), has Match
// Case, Match Whole Word and Regular Expression toggles, and a replace row behind the twistie.
import { search, SearchQuery, setSearchQuery, getSearchQuery, findNext, findPrevious, replaceNext, replaceAll, closeSearchPanel, selectMatches } from '@codemirror/search';

// Codicons (codicon.ttf, loaded by editor.html).
const ICON = {
  chevronRight: '\ueab6', chevronDown: '\ueab4', up: '\ueaa1', down: '\uea9a', close: '\uea76', selection: '\ueb85',
};

function button(className, label, text, onClick) {
  const b = document.createElement('button');
  b.className = className;
  b.type = 'button';
  b.title = label;
  b.setAttribute('aria-label', label);
  b.textContent = text;
  b.addEventListener('mousedown', (e) => e.preventDefault());   // keep focus in the input
  b.addEventListener('click', onClick);
  return b;
}

class FindPanel {
  constructor(view) {
    this.view = view;
    const query = getSearchQuery(view.state);
    this.dom = document.createElement('div');
    this.dom.className = 'dc-find';
    this.dom.addEventListener('keydown', (e) => this.keydown(e));

    this.toggle = button('dc-find-toggle', 'Toggle Replace', ICON.chevronRight, () => this.setReplaceVisible(!this.replaceVisible));

    this.findInput = this.input('Find', query.search, 'search');
    this.caseButton = this.option('Aa', 'Match Case', query.caseSensitive, 'caseSensitive');
    this.wordButton = this.option('ab', 'Match Whole Word', query.wholeWord, 'wholeWord');
    this.wordButton.classList.add('word');
    this.regexButton = this.option('.*', 'Use Regular Expression', query.regexp, 'regexp');
    const findField = this.field(this.findInput, [this.caseButton, this.wordButton, this.regexButton]);

    this.count = document.createElement('span');
    this.count.className = 'dc-find-count';
    const prev = button('dc-find-action', 'Previous Match (⇧Enter)', ICON.up, () => findPrevious(this.view));
    const next = button('dc-find-action', 'Next Match (Enter)', ICON.down, () => findNext(this.view));
    const all = button('dc-find-action', 'Select All Matches', ICON.selection, () => selectMatches(this.view));
    const close = button('dc-find-action', 'Close (Escape)', ICON.close, () => closeSearchPanel(this.view));

    const findRow = document.createElement('div');
    findRow.className = 'dc-find-row';
    findRow.append(findField, this.count, prev, next, all, close);

    this.replaceInput = this.input('Replace', query.replace, 'replace');
    const replaceField = this.field(this.replaceInput, []);
    const replaceOne = button('dc-find-action text', 'Replace (Enter)', 'Replace', () => replaceNext(this.view));
    const replaceEvery = button('dc-find-action text', 'Replace All', 'All', () => replaceAll(this.view));
    this.replaceRow = document.createElement('div');
    this.replaceRow.className = 'dc-find-row replace';
    this.replaceRow.append(replaceField, replaceOne, replaceEvery);

    const rows = document.createElement('div');
    rows.className = 'dc-find-rows';
    rows.append(findRow, this.replaceRow);
    this.dom.append(this.toggle, rows);
    this.setReplaceVisible(!!query.replace);
    this.updateCount();
  }

  input(placeholder, value, name) {
    const input = document.createElement('input');
    input.className = 'dc-find-input';
    input.placeholder = placeholder;
    input.value = value || '';
    input.name = name;
    input.setAttribute('main-field', name === 'search' ? 'true' : 'false');
    input.setAttribute('autocapitalize', 'off');
    input.setAttribute('autocorrect', 'off');
    input.spellcheck = false;
    input.addEventListener('input', () => this.commit());
    return input;
  }

  field(input, options) {
    const field = document.createElement('div');
    field.className = 'dc-find-field';
    field.append(input, ...options);
    return field;
  }

  option(text, label, on, key) {
    const b = button('dc-find-option' + (on ? ' on' : ''), label, text, () => {
      b.classList.toggle('on');
      this.commit();
    });
    b.dataset.key = key;
    return b;
  }

  setReplaceVisible(visible) {
    this.replaceVisible = visible;
    this.replaceRow.hidden = !visible;
    this.toggle.textContent = visible ? ICON.chevronDown : ICON.chevronRight;
    this.toggle.classList.toggle('open', visible);
  }

  commit() {
    const query = new SearchQuery({
      search: this.findInput.value,
      replace: this.replaceInput.value,
      caseSensitive: this.caseButton.classList.contains('on'),
      wholeWord: this.wordButton.classList.contains('on'),
      regexp: this.regexButton.classList.contains('on'),
    });
    if (!query.eq(getSearchQuery(this.view.state))) this.view.dispatch({ effects: setSearchQuery.of(query) });
  }

  keydown(e) {
    if (e.key === 'Escape') { e.preventDefault(); closeSearchPanel(this.view); this.view.focus(); return; }
    if (e.key === 'Enter' && e.target === this.findInput) { e.preventDefault(); (e.shiftKey ? findPrevious : findNext)(this.view); return; }
    if (e.key === 'Enter' && e.target === this.replaceInput) { e.preventDefault(); (e.metaKey || e.ctrlKey ? replaceAll : replaceNext)(this.view); }
  }

  /** "No results", or "3 of 12" with the selection on the third match. */
  updateCount() {
    const query = getSearchQuery(this.view.state);
    this.dom.classList.toggle('no-results', false);
    if (!query.search || !query.valid) { this.count.textContent = query.search && !query.valid ? 'Invalid' : 'No results'; return; }
    const { from, to } = this.view.state.selection.main;
    const cursor = query.getCursor(this.view.state);
    let total = 0, current = 0;
    for (let next = cursor.next(); !next.done; next = cursor.next()) {
      total++;
      if (next.value.from === from && next.value.to === to) current = total;
      if (total >= 9999) break;
    }
    this.count.textContent = total ? `${current || '?'} of ${total >= 9999 ? '9999+' : total}` : 'No results';
    this.dom.classList.toggle('no-results', total === 0);
  }

  mount() {
    this.findInput.focus();
    this.findInput.select();
  }

  update(update) {
    for (const tr of update.transactions) {
      for (const effect of tr.effects) {
        if (effect.is(setSearchQuery) && !effect.value.eq(this.currentQuery())) this.sync(effect.value);
      }
    }
    if (update.docChanged || update.selectionSet || update.transactions.some((tr) => tr.effects.some((e) => e.is(setSearchQuery)))) {
      this.updateCount();
    }
  }

  currentQuery() {
    return new SearchQuery({
      search: this.findInput.value, replace: this.replaceInput.value,
      caseSensitive: this.caseButton.classList.contains('on'), wholeWord: this.wordButton.classList.contains('on'),
      regexp: this.regexButton.classList.contains('on'),
    });
  }

  sync(query) {
    this.findInput.value = query.search;
    this.replaceInput.value = query.replace;
    this.caseButton.classList.toggle('on', query.caseSensitive);
    this.wordButton.classList.toggle('on', query.wholeWord);
    this.regexButton.classList.toggle('on', query.regexp);
  }

  get top() { return true; }
}

export const findWidget = search({ top: true, createPanel: (view) => new FindPanel(view) });
