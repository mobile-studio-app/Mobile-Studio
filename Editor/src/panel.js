// The panel under the editor, as in VS Code: Problems, Output, Debug Console and Terminal, one
// at a time in tabs, with Maximize and Close. Each tab's module draws its own body and says
// what to do when its tab is shown (onPanelTab).

const $ = (id) => document.getElementById(id);
const onShow = new Map();   // tab -> function
let current = 'problems';
let built = false;

function build() {
  if (built) return;
  built = true;
  for (const button of document.querySelectorAll('.panel-tab')) {
    button.addEventListener('click', () => showPanel(button.dataset.tab));
  }
  $('panel-close').addEventListener('click', () => hidePanel());
  $('panel-maximize').addEventListener('click', () => setMaximized(!$('panel').classList.contains('maximized')));
}

function setMaximized(on) {
  $('panel').classList.toggle('maximized', on);
  $('app').classList.toggle('panel-maximized', on);
  const button = $('panel-maximize');
  button.innerHTML = on ? '&#xEAB4;' : '&#xEAB7;';
  button.title = on ? 'Restore Panel Size' : 'Maximize Panel';
}

/** `fn` runs whenever `tab` is shown (to draw it, or focus it). */
export function onPanelTab(tab, fn) { build(); onShow.set(tab, fn); }

export function showPanel(tab) {
  build();
  if (tab) current = tab;
  $('panel').hidden = false;
  for (const button of document.querySelectorAll('.panel-tab')) button.classList.toggle('active', button.dataset.tab === current);
  for (const body of document.querySelectorAll('.panel-body')) body.classList.toggle('shown', body.dataset.body === current);
  for (const group of document.querySelectorAll('.panel-actions > [data-for]')) group.classList.toggle('shown', group.dataset.for === current);
  const fn = onShow.get(current);
  if (fn) fn();
}

export function hidePanel() {
  setMaximized(false);
  $('panel').hidden = true;
}

/** Shows `tab`, or closes the panel if `tab` (or, with no tab, any tab) is already showing. */
export function togglePanel(tab) {
  if (!$('panel').hidden && (!tab || tab === current)) hidePanel(); else showPanel(tab);
}

/** The tab showing, or null when the panel is closed. */
export const panelTab = () => (!$('panel').hidden ? current : null);

// MARK: - Debug Console: expressions evaluated in the paused program

let debugNative = null;

export function setupDebugConsole(native) {
  debugNative = native;
  const input = $('debug-input');
  const history = [];
  let index = 0;
  input.addEventListener('keydown', async (e) => {
    if (e.key === 'ArrowUp' && index > 0) { input.value = history[--index]; e.preventDefault(); return; }
    if (e.key === 'ArrowDown' && index < history.length) { input.value = history[++index] || ''; e.preventDefault(); return; }
    if (e.key !== 'Enter') return;
    const expression = input.value.trim();
    if (!expression) return;
    history.push(expression);
    index = history.length;
    input.value = '';
    debugLog(`> ${expression}`, 'debug-in');
    const result = await debugNative({ cmd: 'debugEvaluate', expression, context: 'repl' }).catch((err) => ({ error: String(err) }));
    if (result && result.error) debugLog(result.error === 'No value' ? 'Evaluating needs the program paused at a breakpoint.' : result.error, 'debug-error');
    else debugLog(result ? String(result.value) : 'undefined');
  });
  $('debug-clear').addEventListener('click', () => { $('debug-log').textContent = ''; });
  onPanelTab('debug', () => input.focus());
}

/** A line in the Debug Console. */
export function debugLog(text, className) {
  const log = $('debug-log');
  const line = document.createElement('div');
  line.textContent = text;
  if (className) line.className = className;
  log.append(line);
  log.scrollTop = log.scrollHeight;
}
