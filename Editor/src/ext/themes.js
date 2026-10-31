// Colour themes from extensions, turned into the same palette the built-in themes use (see
// theme.js): workbench colours for the editor and its chrome, and TextMate token colours
// resolved for each kind of syntax.
import { palettes } from '../theme.js';
import { contributions, readExtensionFile, parseJSONC, joinPath } from './registry.js';

/** A theme file and the files it includes, merged (included first, as VS Code does). */
async function loadThemeFile(extId, path, depth = 0) {
  const text = await readExtensionFile(extId, path);
  let theme;
  if (/\.tmTheme$/i.test(path) || text.trimStart().startsWith('<')) {
    theme = { tokenColors: parsePlistTheme(text) };
  } else {
    theme = parseJSONC(text);
  }
  let colors = {};
  let tokenColors = [];
  if (theme.include && depth < 5) {
    const base = await loadThemeFile(extId, joinPath(path, theme.include), depth + 1);
    colors = base.colors;
    tokenColors = base.tokenColors;
  }
  if (typeof theme.tokenColors === 'string') {
    const linked = await loadThemeFile(extId, joinPath(path, theme.tokenColors), depth + 1);
    tokenColors = tokenColors.concat(linked.tokenColors);
  } else if (Array.isArray(theme.tokenColors)) {
    tokenColors = tokenColors.concat(theme.tokenColors);
  }
  return { colors: { ...colors, ...(theme.colors || {}) }, tokenColors, type: theme.type };
}

/** The settings array of a .tmTheme (plist XML). */
function parsePlistTheme(xml) {
  const doc = new DOMParser().parseFromString(xml, 'text/xml');
  const value = (node) => {
    switch (node.tagName) {
      case 'dict': {
        const out = {};
        const children = [...node.children];
        for (let i = 0; i < children.length; i += 2) out[children[i].textContent] = value(children[i + 1]);
        return out;
      }
      case 'array': return [...node.children].map(value);
      case 'true': return true;
      case 'false': return false;
      default: return node.textContent;
    }
  };
  const root = doc.querySelector('plist > dict');
  return root ? (value(root).settings || []) : [];
}

/** VS Code's rule: the most specific matching selector wins. */
function tokenColor(rules, scope) {
  let best = null;
  let bestScore = -1;
  for (const rule of rules) {
    if (!rule.settings || !rule.settings.foreground) continue;
    const selectors = Array.isArray(rule.scope) ? rule.scope : String(rule.scope || '').split(',');
    for (let selector of selectors) {
      selector = selector.trim();
      // Descendant selectors ("meta.embedded string") only apply in a context; the palette is
      // for the general case, so they're left out.
      if (!selector || /\s/.test(selector)) continue;
      if (scope === selector || scope.startsWith(selector + '.')) {
        const score = selector.split('.').length;
        if (score >= bestScore) { best = rule.settings.foreground; bestScore = score; }
      }
    }
  }
  return best;
}

function luminance(hex) {
  const m = /^#?([0-9a-f]{6})/i.exec(hex || '');
  if (!m) return 0;
  const n = parseInt(m[1], 16);
  return (0.299 * (n >> 16) + 0.587 * ((n >> 8) & 255) + 0.114 * (n & 255)) / 255;
}

const loading = new Map();

/** Loads an extension theme ("ext:<id>/<path>") into palettes. Resolves to true when it's ready. */
export function loadExtensionTheme(themeId) {
  if (palettes[themeId]) return Promise.resolve(true);
  const entry = contributions.themes.get(themeId);
  if (!entry) return Promise.resolve(false);
  if (!loading.has(themeId)) {
    loading.set(themeId, (async () => {
      const { colors, tokenColors } = await loadThemeFile(entry.extId, entry.path);
      const defaults = tokenColors.find((r) => !r.scope && r.settings) || { settings: {} };
      const dark = entry.uiTheme ? entry.uiTheme !== 'vs' : luminance(colors['editor.background']) < 0.5;
      const base = palettes[dark ? 'dark-plus' : 'light-plus'];
      const bg = colors['editor.background'] || defaults.settings.background || base.bg;
      const fg = colors['editor.foreground'] || defaults.settings.foreground || base.fg;
      const pick = (...scopes) => {
        for (const s of scopes) {
          const color = tokenColor(tokenColors, s);
          if (color) return color;
        }
        return null;
      };
      palettes[themeId] = {
        workbench: colors,
        dark,
        bg,
        fg,
        text: colors.foreground || fg,
        muted: colors.descriptionForeground || colors['editorLineNumber.foreground'] || base.muted,
        gutter: colors['editorLineNumber.foreground'] || base.gutter,
        gutterActive: colors['editorLineNumber.activeForeground'] || fg,
        activeLine: colors['editor.lineHighlightBackground'] || base.activeLine,
        selection: colors['editor.selectionBackground'] || base.selection,
        cursor: colors['editorCursor.foreground'] || fg,
        panel: colors['editorGroupHeader.tabsBackground'] || colors['sideBar.background'] || base.panel,
        border: colors['editorGroup.border'] || colors['panel.border'] || base.border,
        borderStrong: colors['editorGroupHeader.tabsBorder'] || colors['tab.border'] || base.borderStrong,
        listActive: colors['list.activeSelectionBackground'] || base.listActive,
        keyword: pick('keyword', 'storage.type') || base.keyword,
        control: pick('keyword.control', 'keyword') || base.control,
        string: pick('string') || base.string,
        number: pick('constant.numeric') || base.number,
        comment: pick('comment') || base.comment,
        func: pick('entity.name.function', 'support.function') || base.func,
        variable: pick('variable', 'variable.other') || fg,
        type: pick('entity.name.type', 'support.type', 'entity.name.class', 'storage.type') || base.type,
        constant: pick('constant.language', 'variable.other.constant', 'constant') || base.constant,
      };
      return true;
    })().catch(() => false));
  }
  return loading.get(themeId);
}

export function forgetExtensionThemes() {
  for (const id of Object.keys(palettes)) if (id.startsWith('ext:')) delete palettes[id];
  loading.clear();
}
