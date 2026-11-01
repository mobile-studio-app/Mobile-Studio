// Extensions' webview panels: each one's HTML in a sandboxed frame over the editor, in its own
// tab. acquireVsCodeApi() inside the frame posts to the extension and receives its messages.
// Files the HTML loads from the extension (asWebviewUri) are inlined before it's shown.
import { readExtensionFile } from './registry.js';

const panels = new Map();   // id -> { frame, title, extId }
let host = null;            // { post(message), showTab(id, title), closeTab(id), extensionOf(path) }
let visible = null;

export function setupWebviews(callbacks) {
  host = callbacks;
  window.addEventListener('message', (e) => {
    const data = e.data;
    if (!data || typeof data !== 'object' || !data.__duocodeWebview) return;
    const panel = panels.get(data.__duocodeWebview);
    if (!panel || e.source !== panel.frame.contentWindow) return;
    host.post({ type: 'webviewMessage', id: data.__duocodeWebview, message: data.message });
  });
}

const BRIDGE = (id, state) => `<script>
(() => {
  let state = ${JSON.stringify(state ?? null)};
  const api = {
    postMessage: (message) => parent.postMessage({ __duocodeWebview: ${JSON.stringify(id)}, message }, '*'),
    setState: (value) => { state = value; parent.postMessage({ __duocodeWebviewState: ${JSON.stringify(id)}, state: value }, '*'); return value; },
    getState: () => state,
  };
  let acquired = false;
  window.acquireVsCodeApi = () => {
    if (acquired) throw new Error('An instance of the VS Code API has already been acquired');
    acquired = true;
    return api;
  };
})();
<\/script>`;

// VS Code's webview theme variables, so extensions' styles look right.
const THEME_STYLE = `<style>
:root {
  --vscode-font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; --vscode-font-size: 13px; --vscode-font-weight: normal;
  --vscode-editor-font-family: ui-monospace, Menlo, Consolas, monospace; --vscode-editor-font-size: 13px;
  --vscode-foreground: #cccccc; --vscode-editor-background: #1e1e1e; --vscode-editor-foreground: #d4d4d4;
  --vscode-button-background: #0e639c; --vscode-button-foreground: #ffffff; --vscode-button-hoverBackground: #1177bb;
  --vscode-input-background: #3c3c3c; --vscode-input-foreground: #cccccc; --vscode-input-border: transparent;
  --vscode-focusBorder: #007fd4; --vscode-textLink-foreground: #3794ff; --vscode-sideBar-background: #252526;
  --vscode-panel-border: #80808059; --vscode-descriptionForeground: #ccccccb3; --vscode-errorForeground: #f48771;
  --vscode-list-hoverBackground: #2a2d2e; --vscode-list-activeSelectionBackground: #04395e;
  --vscode-textCodeBlock-background: #0a0a0a66; --vscode-widget-shadow: #0000005c; --vscode-badge-background: #4d4d4d;
}
body { background: var(--vscode-editor-background); color: var(--vscode-foreground); font-family: var(--vscode-font-family);
  font-size: var(--vscode-font-size); margin: 0; padding: 0 20px; }
a { color: var(--vscode-textLink-foreground); }
</style>`;

const MIME = { png: 'image/png', jpg: 'image/jpeg', jpeg: 'image/jpeg', gif: 'image/gif', svg: 'image/svg+xml', webp: 'image/webp',
  woff: 'font/woff', woff2: 'font/woff2', ttf: 'font/ttf', css: 'text/css', js: 'text/javascript', json: 'application/json' };

/** Replaces duocode-res:// references with the files' contents (scripts and styles inline, others as data URLs). */
async function inlineResources(html, extensionOf) {
  const refs = new Set();
  html.replace(/duocode-res:\/\/([^"'\s)>]+)/g, (_, path) => refs.add(path));
  const urls = new Map();
  for (const ref of refs) {
    // duocode-res://file/<path>; or the older duocode-res://<encoded path>/.
    const bare = ref.split(/[?#]/)[0];
    const path = bare.startsWith('file/') ? decodeURI(bare.slice(4)) : decodeURIComponent(bare).replace(/\/+$/, '');
    const located = extensionOf(path);
    if (!located) continue;
    const ext = path.split('.').pop().toLowerCase();
    try {
      if (ext === 'js' || ext === 'css' || ext === 'json' || ext === 'svg') {
        const text = await readExtensionFile(located.id, located.path);
        urls.set(ref, 'data:' + (MIME[ext] || 'text/plain') + ';charset=utf-8,' + encodeURIComponent(text));
      } else {
        const base64 = await readExtensionFile(located.id, located.path, true);
        urls.set(ref, 'data:' + (MIME[ext] || 'application/octet-stream') + ';base64,' + base64);
      }
    } catch (e) { /* missing: left as is */ }
  }
  return html.replace(/duocode-res:\/\/([^"'\s)>]+)/g, (all, ref) => urls.get(ref) || all);
}

function container() { return document.getElementById('webviews'); }

/** Shows (or updates) a panel's HTML. */
export async function showWebview({ id, title, html, enableScripts }) {
  let panel = panels.get(id);
  if (!panel) {
    const frame = document.createElement('iframe');
    frame.className = 'webview';
    // Scripts only if the extension enabled them; never the page's origin (no access to the app).
    frame.setAttribute('sandbox', enableScripts ? 'allow-scripts allow-forms allow-popups' : '');
    container().append(frame);
    panel = { frame, title, state: null };
    panels.set(id, panel);
  }
  panel.title = title;
  // The app serves duocode-res:// itself (scripts can then import their other files); a test page
  // without it gets the files inlined.
  const body = window.__duocodeResources ? html : await inlineResources(html, host.extensionOf);
  // The bridge and theme go first in <head> (or at the top when there's no head).
  const prefix = BRIDGE(id, panel.state) + THEME_STYLE;
  panel.frame.srcdoc = /<head[^>]*>/i.test(body) ? body.replace(/<head[^>]*>/i, (m) => m + prefix) : prefix + body;
  host.showTab(id, title);
  reveal(id);
}

export function postToWebview({ id, message }) {
  const panel = panels.get(id);
  if (panel && panel.frame.contentWindow) panel.frame.contentWindow.postMessage(message, '*');
}

export function retitleWebview({ id, title }) {
  const panel = panels.get(id);
  if (panel) { panel.title = title; host.showTab(id, title); }
}

/** Shows one panel over the editor (null hides them all). */
export function reveal(id) {
  visible = id;
  for (const [key, panel] of panels) panel.frame.hidden = key !== id;
  container().hidden = !id || !panels.has(id);
  // A webview has no file, so no breadcrumbs (opening a file brings them back).
  if (id && panels.has(id)) document.getElementById('breadcrumbs').hidden = true;
}

export const visibleWebview = () => visible;

/** The panel's tab closed, or the extension disposed it. */
export function closeWebview(id, fromExtension) {
  const panel = panels.get(id);
  if (!panel) return;
  panel.frame.remove();
  panels.delete(id);
  if (visible === id) reveal(null);
  if (fromExtension) host.closeTab(id); else host.post({ type: 'webviewClosed', id });
}

window.addEventListener('message', (e) => {
  const data = e.data;
  if (data && data.__duocodeWebviewState) {
    const panel = panels.get(data.__duocodeWebviewState);
    if (panel && e.source === panel.frame.contentWindow) panel.state = data.state;
  }
});
