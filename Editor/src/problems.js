// The Problems panel: errors and warnings in the project, by file, as in VS Code. The open
// file's come from the editor's lint state (the built-in checks and extensions' together);
// other files' from what extensions reported for them. Tapping one opens it there.
import { forEachDiagnostic } from '@codemirror/lint';
import { hostDiagnostics, onDiagnosticsChanged } from './ext/host.js';
import { onPanelTab, panelTab } from './panel.js';

const $ = (id) => document.getElementById(id);
const ICONS = { error: ['', '#f14c4c'], warning: ['', '#cca700'], info: ['', '#3794ff'], hint: ['', '#999'] };
const SEVERITIES = ['error', 'warning', 'info', 'hint'];
const RANK = { error: 0, warning: 1, info: 2, hint: 3 };

let api = null;   // { view, current(), reveal(path, line, column) }
let timer = 0;

export function setupProblems(appAPI) {
  api = appAPI;
  onPanelTab('problems', render);
  onDiagnosticsChanged(problemsChanged);
  problemsChanged();
}

/** Something that can change the problems happened: count them again soon. */
export function problemsChanged() {
  clearTimeout(timer);
  timer = setTimeout(() => { updateBadge(); if (panelTab() === 'problems') render(); }, 300);
}

function collect() {
  const files = new Map();   // path -> [{ severity, message, source, line, column }]
  const current = api.current();
  if (current) {
    const doc = api.view.state.doc;
    const list = [];
    forEachDiagnostic(api.view.state, (d, from) => {
      const line = doc.lineAt(Math.min(from, doc.length));
      list.push({ severity: d.severity, message: d.message, source: d.source, line: line.number, column: from - line.from + 1 });
    });
    if (list.length) files.set(current, list);
  }
  for (const { path, items } of hostDiagnostics()) {
    if (path === current) continue;
    files.set(path, items.map((d) => ({
      severity: SEVERITIES[d.severity] || 'error', message: d.message, source: d.source,
      line: d.range.start.line + 1, column: d.range.start.character + 1,
    })));
  }
  for (const list of files.values()) list.sort((a, b) => RANK[a.severity] - RANK[b.severity] || a.line - b.line);
  return [...files].sort(([a], [b]) => a.localeCompare(b));
}

function updateBadge() {
  if (!api) return;
  let count = 0;
  for (const [, list] of collect()) count += list.filter((p) => p.severity === 'error' || p.severity === 'warning').length;
  const badge = $('problems-count');
  badge.hidden = count === 0;
  badge.textContent = count > 999 ? '999+' : String(count);
}

function render() {
  const host = $('problems-list');
  host.textContent = '';
  const files = collect();
  if (!files.length) {
    const empty = document.createElement('div');
    empty.className = 'problems-empty';
    empty.textContent = 'No problems have been detected in the workspace.';
    host.append(empty);
    return;
  }
  for (const [path, list] of files) {
    const header = document.createElement('div');
    header.className = 'problem-file';
    const name = document.createElement('span');
    name.textContent = path;
    const count = document.createElement('span');
    count.className = 'panel-badge count';
    count.textContent = String(list.length);
    header.append(name, count);
    host.append(header);
    for (const p of list) {
      const row = document.createElement('div');
      row.className = 'problem';
      const [glyph, color] = ICONS[p.severity] || ICONS.error;
      const icon = document.createElement('span');
      icon.className = 'codicon';
      icon.textContent = glyph;
      icon.style.color = color;
      const message = document.createElement('span');
      message.className = 'message';
      message.textContent = p.message;
      const where = document.createElement('span');
      where.className = 'where';
      where.textContent = `${p.source ? p.source + ' ' : ''}[Ln ${p.line}, Col ${p.column}]`;
      row.append(icon, message, where);
      row.addEventListener('click', () => api.reveal(path, p.line, p.column - 1));
      host.append(row);
    }
  }
}
