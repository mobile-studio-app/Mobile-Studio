// Read-only previews for images, audio, video, fonts and other binary files.

const MEDIA = {
  image: { png: 'image/png', jpg: 'image/jpeg', jpeg: 'image/jpeg', gif: 'image/gif', bmp: 'image/bmp', webp: 'image/webp' },
  audio: { wav: 'audio/wav', mp3: 'audio/mpeg', m4a: 'audio/mp4', aac: 'audio/aac', flac: 'audio/flac', ogg: 'audio/ogg', oga: 'audio/ogg' },
  video: { mp4: 'video/mp4', m4v: 'video/mp4', mov: 'video/quicktime', ogv: 'video/ogg' },
  font: { ttf: 'font/ttf', otf: 'font/otf' },
};
// Formats LÖVE loads that WebKit can't preview.
const NO_PREVIEW = new Set(['tga', 'dds', 'ktx', 'exr', 'hdr', 'pkm', 'astc', 'it', 'xm', 'mod', 's3m', 'love', 'zip']);
export const ICONS = { text: '📄', image: '🖼', audio: '🔊', video: '🎞', font: '🔤', binary: '📦' };

const $ = (id) => document.getElementById(id);

export function kindOf(ext) {
  for (const kind of Object.keys(MEDIA)) if (MEDIA[kind][ext]) return kind;
  return NO_PREVIEW.has(ext) ? 'binary' : 'text';
}

function formatSize(bytes) {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
}

export function hideViewer() {
  $('viewer').hidden = true;
}

function showViewer(stageClass) {
  $('viewer').hidden = false;
  const stage = $('viewer-stage');
  stage.className = stageClass || '';
  stage.replaceChildren();
  $('viewer-zoom').hidden = true;
}

function showCard(glyph, title, detail, info) {
  showViewer();
  const card = document.createElement('div');
  card.className = 'card';
  card.innerHTML = `<div class="glyph">${glyph}</div><b></b><div></div>`;
  card.querySelector('b').textContent = title;
  card.lastChild.textContent = detail;
  $('viewer-stage').append(card);
  $('viewer-info').textContent = info;
}

function setZoom(img, zoom) {
  for (const b of $('viewer-zoom').querySelectorAll('button')) b.classList.toggle('on', b.dataset.zoom === zoom);
  if (zoom === 'fit') {
    img.className = 'fit';
    img.style.width = '';
  } else {
    // Integer zoom with hard pixel edges suits pixel-art sprites.
    img.className = 'pixelated';
    img.style.width = `${img.naturalWidth * Number(zoom)}px`;
  }
}

function showImage(url, ext, size) {
  showViewer('checker');
  const img = new Image();
  img.className = 'fit';
  img.onload = () => {
    $('viewer-info').textContent = `${img.naturalWidth} × ${img.naturalHeight} px · ${ext.toUpperCase()} · ${formatSize(size)}`;
    $('viewer-zoom').hidden = false;
    // Small sprites start magnified so they're visible.
    setZoom(img, img.naturalWidth <= 64 && img.naturalHeight <= 64 ? '4' : 'fit');
  };
  img.onerror = () => showCard('🖼', 'Can’t preview this image', 'The file may be damaged or in a format iOS can’t decode.', `${ext.toUpperCase()} · ${formatSize(size)}`);
  $('viewer-zoom').onclick = (e) => { if (e.target.dataset.zoom) setZoom(img, e.target.dataset.zoom); };
  img.src = url;
  $('viewer-stage').append(img);
}

function showPlayer(kind, url, mime, ext, size) {
  const el = document.createElement(kind);
  if (!el.canPlayType(mime)) {
    showCard(ICONS[kind], `iOS can’t preview .${ext} files`, 'LÖVE can still play it in your game.', `${ext.toUpperCase()} · ${formatSize(size)}`);
    return;
  }
  showViewer();
  el.controls = true;
  el.src = url;
  el.addEventListener('loadedmetadata', () => {
    const secs = Math.round(el.duration || 0);
    const length = `${Math.floor(secs / 60)}:${String(secs % 60).padStart(2, '0')}`;
    const dims = kind === 'video' ? ` · ${el.videoWidth} × ${el.videoHeight}` : '';
    $('viewer-info').textContent = `${length}${dims} · ${ext.toUpperCase()} · ${formatSize(size)}`;
  });
  $('viewer-info').textContent = `${ext.toUpperCase()} · ${formatSize(size)}`;
  $('viewer-stage').append(el);
}

async function showFont(url, ext, size) {
  showViewer();
  try {
    const face = new FontFace('DuoCodePreview', `url(${url})`);
    await face.load();
    document.fonts.add(face);
  } catch (e) {
    showCard('🔤', 'Can’t preview this font', 'The file may be damaged or in an unsupported format.', `${ext.toUpperCase()} · ${formatSize(size)}`);
    return;
  }
  const sample = document.createElement('div');
  sample.className = 'font-sample';
  sample.style.fontFamily = 'DuoCodePreview';
  for (const px of [12, 18, 24, 36, 48]) {
    const p = document.createElement('p');
    p.style.fontSize = `${px}px`;
    p.textContent = px >= 36 ? 'The quick brown fox' : 'The quick brown fox jumps over the lazy dog 0123456789';
    sample.append(p);
  }
  const glyphs = document.createElement('p');
  glyphs.style.fontSize = '20px';
  glyphs.textContent = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ abcdefghijklmnopqrstuvwxyz !?.,:;()[]{}+-*/=<>@#$%&';
  sample.append(glyphs);
  $('viewer-stage').append(sample);
  $('viewer-info').textContent = `${ext.toUpperCase()} font · ${formatSize(size)}`;
}

/**
 * Shows a binary file. `file` is the native readBinary reply: { size, base64 } or { size, tooLarge }.
 * `isStale()` returns true once the user has opened something else.
 */
export async function showBinary(path, ext, kind, file) {
  const label = ext ? ext.toUpperCase() : 'File';
  if (file.tooLarge) {
    showCard(ICONS[kind], 'Too large to preview', 'Files over 32 MB aren’t loaded into the editor.', `${label} · ${formatSize(file.size)}`);
    return;
  }
  if (kind === 'binary') {
    const why = NO_PREVIEW.has(ext) ? `iOS can’t preview .${ext} files, but LÖVE can still load them.` : 'This file isn’t text, so it can’t be edited here.';
    showCard('📦', path.split('/').pop(), why, `${label} · ${formatSize(file.size)}`);
    return;
  }
  const mime = MEDIA[kind][ext];
  const url = `data:${mime};base64,${file.base64}`;
  if (kind === 'image') showImage(url, ext, file.size);
  else if (kind === 'font') await showFont(url, ext, file.size);
  else showPlayer(kind, url, mime, ext, file.size);
}

export function showError(message, ext) {
  showCard('⚠️', 'Can’t open this file', message, (ext || '').toUpperCase());
}
