// VS Code's Markdown preview: the open .md file rendered, in place of the editor or beside it
// on a wide screen, updating as it's edited. Images load from the project; links open.
import { renderMarkdown } from './markdown.js';

let api = null;      // { native, view, current, openFile, openURL }
let mode = 'off';    // 'off', 'full' (instead of the editor) or 'side' (beside it)
let timer = 0;
const imageCache = new Map();

const MIME = { png: 'image/png', jpg: 'image/jpeg', jpeg: 'image/jpeg', gif: 'image/gif', webp: 'image/webp', svg: 'image/svg+xml', bmp: 'image/bmp' };
const $ = (id) => document.getElementById(id);

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
}

export const isMarkdown = (path) => /\.(md|markdown)$/i.test(path || '');
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

/** Re-renders now (or soon, while typing). */
export function refreshPreview(soon = false) {
  if (mode === 'off') return;
  clearTimeout(timer);
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
  if (next !== 'off' && !isMarkdown(api.current())) next = 'off';
  // Side by side needs room; on a phone the preview takes the editor's place.
  if (next === 'side' && $('editor-container').clientWidth < 640) next = 'full';
  mode = next;
  const container = $('editor-container');
  container.classList.toggle('md-full', mode === 'full');
  container.classList.toggle('md-side', mode === 'side');
  $('md-preview').hidden = mode === 'off';
  $('md-toggle').classList.toggle('on', mode !== 'off');
  if (mode === 'off') { imageCache.clear(); api.view.requestMeasure(); } else refreshPreview();
}

/** A file opened: the preview button shows for Markdown, and the preview closes for other files. */
export function fileOpened(path) {
  $('md-toggle').hidden = !isMarkdown(path);
  imageCache.clear();
  if (mode !== 'off') {
    if (isMarkdown(path)) refreshPreview(); else setPreview('off');
  }
}
