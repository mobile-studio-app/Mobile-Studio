import { hidePanel, onPanelTab, panelTab, showPanel, togglePanel } from '../panel.js';

// VS Code's Output panel (a tab of the panel, panel.js): one channel at a time, picked from a list. Extensions
// write to their output channels; tasks and npm write to "Tasks" and "npm", and the extension
// host's own messages go to "Extensions".

const channels = new Map();   // name -> text
const MAX = 256 * 1024;       // characters kept per channel
let selected = null;
let panel = null;
let pending = 0;

const $ = (id) => document.getElementById(id);

function build() {
  if (panel) return panel;
  panel = $('panel');
  $('output-clear').addEventListener('click', () => { if (selected) { channels.set(selected, ''); render(); } });
  $('output-channel').addEventListener('change', (e) => { selected = e.target.value; render(); });
  onPanelTab('output', () => { renderChannels(); render(); });
  return panel;
}

function renderChannels() {
  const select = $('output-channel');
  if (!select) return;
  select.textContent = '';
  for (const name of [...channels.keys()].sort((a, b) => a.localeCompare(b))) {
    const option = document.createElement('option');
    option.value = name;
    option.textContent = name;
    option.selected = name === selected;
    select.append(option);
  }
}

function render() {
  if (!panel || panelTab() !== 'output') return;
  const text = $('output-text');
  const atEnd = text.scrollTop + text.clientHeight >= text.scrollHeight - 8;
  text.textContent = channels.get(selected) || '';
  if (atEnd) text.scrollTop = text.scrollHeight;
}

/** Output from an extension's channel (op: append, replace, clear, show, dispose). */
export function channelOutput(name, op, text = '') {
  const isNew = !channels.has(name);
  if (op === 'dispose') {
    channels.delete(name);
    if (selected === name) selected = channels.keys().next().value || null;
    renderChannels();
    render();
    return;
  }
  let value = channels.get(name) || '';
  if (op === 'append') value += text;
  else if (op === 'replace') value = text;
  else if (op === 'clear') value = '';
  if (value.length > MAX) value = value.slice(value.length - MAX);
  channels.set(name, value);
  if (!selected) selected = name;
  if (isNew) renderChannels();
  if (op === 'show') { showOutput(name); return; }
  if (name !== selected) return;
  // Output can come quickly; draw once a frame.
  if (!pending) pending = requestAnimationFrame(() => { pending = 0; render(); });
}

export function showOutput(name) {
  build();
  if (name) {
    if (!channels.has(name)) channels.set(name, '');
    selected = name;
  }
  showPanel('output');
}

export function hideOutput() {
  if (panelTab() === 'output') hidePanel();
}

export const toggleOutput = () => { build(); togglePanel('output'); };
export const outputChannels = () => [...channels.keys()];

/** Makes the Output tab ready before anything is written to it. */
export function setupOutput() { build(); }

/** An Output channel's text, for the Chat agent's read_output. */
export const channelText = (name) => channels.get(name) ?? null;
