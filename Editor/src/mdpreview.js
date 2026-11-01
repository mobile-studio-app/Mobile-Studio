// VS Code's Markdown preview: the open .md file rendered, in place of the editor or beside it
// on a wide screen, updating as it's edited. Images load from the project; links open.
// HTML pages get a Live Preview the same way (as VS Code's Live Preview extension): the page from
// the Node.js host's server (ext/node-preview.js), with unsaved edits to it and to its stylesheets
// and scripts showing as they're typed, and its console output in the Output panel.
import { renderMarkdown } from './markdown.js';
import { channelOutput } from './ext/output.js';

let api = null;      // { native, view, current, openFile, openURL, nodeAddress, projectPath }
let mode = 'off';    // 'off', 'full' (instead of the editor) or 'side' (beside it)
let timer = 0;
const imageCache = new Map();
let page = null;     // the HTML page being previewed (project-relative)
let base = null;     // the Node.js host's address
const sent = new Map();   // path → the unsaved text the server has

const MIME = { png: 'image/png', jpg: 'image/jpeg', jpeg: 'image/jpeg', gif: 'image/gif', webp: 'image/webp', svg: 'image/svg+xml', bmp: 'image/bmp' };
const $ = (id) => document.getElementById(id);
const LOG = 'Live Preview';

export function setupMarkdownPreview(options) {
  api = options;
  $('md-preview').addEventListener('click', (e) => {
    const link = e.target.closest('a[href]');
    if (!link) return;
    e.preventDefault();
    const href = link.getAttribute('href');
    if (/^(https?:|mailto:)/.test(href)) { api.openURL(href); return; }
    if (href.startsWith('#')) { document.getElementById(href.slice(1))?.scrollIntoView({ block: 'start' }); return; }
    api.openFile(resolve(href.split('#')[0]));
  });
  // The previewed page's console (see node-preview.js).
  window.addEventListener('message', (e) => {
    const data = e.data;
    if (!data || data.mobileStudioPreview !== 'console' || !page) return;
    const prefix = data.level === 'log' ? '' : `[${data.level}] `;
    channelOutput(LOG, 'append', prefix + data.text + '\n');
  });
}

export const isMarkdown = (path) => /\.(md|markdown)$/i.test(path || '');
export const isHTML = (path) => /\.(html?|xhtml)$/i.test(path || '');
/** Files a page's preview keeps showing beside (its stylesheets, scripts and so on). */
const isWebFile = (path) => /\.(html?|xhtml|css|m?js|json|svg|glsl|txt)$/i.test(path || '');
export const previewMode = () => mode;

/** Paths in the document are relative to its folder. */
function resolve(relative) {
  const parts = (api.current() || '').split('/').slice(0, -1);
  for (const p of decodeURI(relative).split('/')) {
    if (p === '..') parts.pop(); else if (p && p !== '.') parts.push(p);
  }
  return parts.join('/');
}

async function loadImages(container) {
  for (const img of container.querySelectorAll('img[data-src]')) {
    const src = img.getAttribute('data-src');
    if (/^(https?:|data:)/.test(src)) { img.src = src; continue; }
    const path = resolve(src);
    if (!imageCache.has(path)) {
      imageCache.set(path, api.native({ cmd: 'readBinary', path }).then((file) => {
        const mime = MIME[path.split('.').pop().toLowerCase()] || 'image/png';
        return file && file.base64 ? `data:${mime};base64,${file.base64}` : null;
      }, () => null));
    }
    const url = await imageCache.get(path);
    if (url) img.src = url; else img.classList.add('missing');
  }
}

const post = (action, body) => fetch(`${base}/preview/${action}`, { method: 'POST', body: JSON.stringify(body) });

/** The open file's text, for the page's preview (it serves it in place of the saved file). */
function sendBuffer() {
  const path = api.current();
  if (!base || !path || path.startsWith('@')) return;
  const text = api.view.state.doc.toString();
  if (sent.get(path) === text) return;
  sent.set(path, text);
  post('buffer', { path, text }).catch(() => {});
}

/** The open file was saved: the server can serve it from disk again. */
export function previewSaved(path) {
  if (!base || !sent.has(path)) return;
  sent.delete(path);
  post('buffer', { path, text: null }).catch(() => {});
}

/** Shows the HTML page `path` from the Node.js host's server. */
async function showPage(path) {
  page = path;
  const container = $('md-preview');
  container.classList.add('web');
  base = await api.nodeAddress().catch(() => null);
  if (page !== path) return;
  if (!base) {
    container.innerHTML = '<div class="md-body"><p>Live Preview needs the Node.js runtime, which hasn\'t started.</p></div>';
    return;
  }
  sent.clear();
  try {
    await post('root', { dir: await api.projectPath() });
    sendBuffer();
  } catch (e) { /* the page shows the error */ }
  if (page !== path) return;
  const frame = document.createElement('iframe');
  frame.className = 'web-preview';
  frame.title = 'Preview ' + path.split('/').pop();
  frame.src = `${base}/preview/files/${path.split('/').map(encodeURIComponent).join('/')}`;
  container.replaceChildren(frame);
}

/** Reloads the page's preview. */
export function reloadPreview() {
  const frame = $('md-preview').querySelector('iframe');
  if (frame) frame.src = frame.src;
}

/** Re-renders now (or soon, while typing). */
export function refreshPreview(soon = false) {
  if (mode === 'off') return;
  clearTimeout(timer);
  if (page) {
    if (soon) timer = setTimeout(sendBuffer, 300); else sendBuffer();
    return;
  }
  const render = () => {
    const container = $('md-preview');
    const top = container.scrollTop;
    container.innerHTML = '<div class="md-body">' + renderMarkdown(api.view.state.doc.toString()) + '</div>';
    container.scrollTop = top;
    loadImages(container);
  };
  if (soon) timer = setTimeout(render, 250); else render();
}

/** 'full', 'side' or 'off'; 'toggle' switches between the editor and the preview. */
export function setPreview(next) {
  if (next === 'toggle') next = mode === 'off' ? 'full' : 'off';
  const path = api.current();
  // A page's preview stays open beside its stylesheets and scripts.
  const keepPage = page && mode === 'side' && isWebFile(path);
  if (next !== 'off' && !isMarkdown(path) && !isHTML(path) && !keepPage) next = 'off';
  // Side by side needs room; on a phone the preview takes the editor's place.
  if (next === 'side' && $('editor-container').clientWidth < 640) next = 'full';
  const was = mode;
  mode = next;
  const container = $('editor-container');
  container.classList.toggle('md-full', mode === 'full');
  container.classList.toggle('md-side', mode === 'side');
  $('md-preview').hidden = mode === 'off';
  $('md-toggle').classList.toggle('on', mode !== 'off');
  if (mode === 'off') {
    imageCache.clear();
    closePage();
    api.view.requestMeasure();
    return;
  }
  if (isHTML(path) && (page !== path || was === 'off')) showPage(path);
  else if (isMarkdown(path)) { closePage(); refreshPreview(); }
  else refreshPreview();
}

function closePage() {
  if (!page) return;
  page = null;
  clearTimeout(timer);
  const container = $('md-preview');
  container.classList.remove('web');
  container.replaceChildren();
}

/** A file opened: the preview button shows for Markdown and HTML, and the preview closes for other files. */
export function fileOpened(path) {
  $('md-toggle').hidden = !isMarkdown(path) && !isHTML(path) && !(page && mode === 'side' && isWebFile(path));
  imageCache.clear();
  if (mode === 'off') return;
  if (isMarkdown(path)) { closePage(); refreshPreview(); return; }
  if (isHTML(path)) { if (page !== path) showPage(path); return; }
  if (!(page && mode === 'side' && isWebFile(path))) setPreview('off');
}
