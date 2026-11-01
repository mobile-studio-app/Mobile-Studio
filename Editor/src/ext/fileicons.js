// The file icon theme's icons as PNG images for the app's lists (App/Extensions/FileIconTheme.swift),
// which can't draw SVG: icon files (SVG or PNG) drawn on a canvas, and font icons drawn with the
// theme's font.
import { readExtensionFile } from './registry.js';

const MIME = { svg: 'image/svg+xml', png: 'image/png', jpg: 'image/jpeg', jpeg: 'image/jpeg', gif: 'image/gif', webp: 'image/webp' };
const fonts = new Map();   // "<extension>/<font id>" → Promise<{ family, weight, style } | null>

/** The theme's font (fonts: the theme's "fonts" list), loaded once. */
function fontFor(extensionId, list, id) {
  const font = list.find((f) => f.id === id) || list[0];
  if (!font) return Promise.resolve(null);
  const key = `${extensionId}/${font.id}`;
  if (!fonts.has(key)) {
    fonts.set(key, (async () => {
      const src = (font.src || [])[0];
      if (!src) return null;
      const base64 = await readExtensionFile(extensionId, src.path, true);
      const family = 'file-icons-' + key.replace(/[^\w-]/g, '-');
      const face = new FontFace(family, `url(data:font/${src.format || 'woff'};base64,${base64})`);
      await face.load();
      document.fonts.add(face);
      return { family, weight: font.weight || 'normal', style: font.style || 'normal', size: font.size };
    })().catch(() => null));
  }
  return fonts.get(key);
}

/** "\\E001" (as icon themes write font characters) → the character. */
const character = (text) => text.replace(/\\([0-9a-fA-F]{1,6})/g, (_, hex) => String.fromCodePoint(parseInt(hex, 16)));

/** Draws each item ({ key, iconPath } or { key, fontCharacter, fontColor, fontId, fontSize }) at
 * `size` pixels; returns { key: base64 PNG } for the ones drawn. */
export async function renderFileIcons(extensionId, items, fontList, size) {
  const out = {};
  const canvas = document.createElement('canvas');
  canvas.width = canvas.height = size;
  const ctx = canvas.getContext('2d');
  for (const item of items || []) {
    try {
      ctx.clearRect(0, 0, size, size);
      if (item.iconPath) {
        const ext = item.iconPath.split('.').pop().toLowerCase();
        const url = ext === 'svg'
          ? 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(await readExtensionFile(extensionId, item.iconPath))
          : `data:${MIME[ext] || 'image/png'};base64,` + await readExtensionFile(extensionId, item.iconPath, true);
        const image = new Image();
        image.src = url;
        await image.decode();
        // SVGs without a width and height have no natural size: they fill the square.
        const w = image.naturalWidth || size;
        const h = image.naturalHeight || size;
        const scale = Math.min(size / w, size / h);
        ctx.drawImage(image, (size - w * scale) / 2, (size - h * scale) / 2, w * scale, h * scale);
      } else if (item.fontCharacter) {
        const font = await fontFor(extensionId, fontList || [], item.fontId);
        if (!font) continue;
        const relative = String(item.fontSize || font.size || '100%');
        const scale = relative.endsWith('%') ? parseFloat(relative) / 100 : 1;
        ctx.font = `${font.style} ${font.weight} ${Math.round(size * 0.85 * scale)}px "${font.family}"`;
        ctx.fillStyle = item.fontColor || '#c5c5c5';
        ctx.textAlign = 'center';
        ctx.textBaseline = 'middle';
        ctx.fillText(character(item.fontCharacter), size / 2, size / 2);
      } else {
        continue;
      }
      out[item.key] = canvas.toDataURL('image/png').split(',')[1];
    } catch (e) { /* this icon couldn't be drawn: the list keeps its built-in one */ }
  }
  return out;
}
