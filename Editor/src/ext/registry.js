// What installed VS Code extensions contribute: languages, grammars, themes and snippets.
// The app hands over each enabled extension's package.json ("extList"); files are read on
// demand ("extRead").

/** JSON with comments and trailing commas, as VS Code's configuration files allow. */
export function parseJSONC(text) {
  let out = '';
  let inString = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i], next = text[i + 1];
    if (inString) {
      out += c;
      if (c === '\\') { out += next; i++; } else if (c === '"') inString = false;
      continue;
    }
    if (c === '"') { inString = true; out += c; continue; }
    if (c === '/' && next === '/') { while (i < text.length && text[i] !== '\n') i++; out += '\n'; continue; }
    if (c === '/' && next === '*') { i += 2; while (i < text.length && !(text[i] === '*' && text[i + 1] === '/')) i++; i++; continue; }
    out += c;
  }
  return JSON.parse(out.replace(/,(\s*[}\]])/g, '$1'));
}

/** Joins an extension-relative path with another relative to it ("./themes/a.json" + "./b.json"). */
export function joinPath(base, relative) {
  const parts = base.split('/').slice(0, -1);
  for (const part of relative.split('/')) {
    if (part === '..') parts.pop(); else if (part && part !== '.') parts.push(part);
  }
  return parts.join('/');
}

const clean = (path) => joinPath('x', path);   // "./a/b.json" -> "a/b.json"

export const contributions = {
  extensions: [],              // [{ id, manifest }]
  languages: new Map(),        // language id -> { id, extensions, filenames, aliases, configuration: {extId, path} }
  grammars: new Map(),         // scopeName -> { extId, path, language, embeddedLanguages, injectTo }
  grammarForLanguage: new Map(), // language id -> scopeName
  themes: new Map(),           // "ext:<id>/<path>" -> { extId, path, label, uiTheme }
  snippets: [],                // [{ language, extId, path }]
  customEditors: [],           // [{ viewType, displayName, patterns, priority, extId }]
};

let native = null;
const listeners = new Set();

export function onExtensionsChanged(fn) { listeners.add(fn); }

export function readExtensionFile(extId, path, binary = false) {
  return native({ cmd: 'extRead', id: extId, path: clean(path), binary });
}

export async function loadExtensions(nativeFn) {
  native = nativeFn;
  let list = [];
  try { list = await native({ cmd: 'extList' }); } catch (e) { list = []; }
  if (!Array.isArray(list)) list = [];
  contributions.extensions = list;
  contributions.languages.clear();
  contributions.grammars.clear();
  contributions.grammarForLanguage.clear();
  contributions.themes.clear();
  contributions.snippets = [];
  contributions.customEditors = [];

  for (const { id, manifest } of list) {
    const c = manifest.contributes || {};
    for (const lang of c.languages || []) {
      if (!lang.id) continue;
      const known = contributions.languages.get(lang.id) || { id: lang.id, extensions: [], filenames: [], aliases: [] };
      known.extensions.push(...(lang.extensions || []).map((e) => e.toLowerCase()));
      known.filenames.push(...(lang.filenames || []).map((e) => e.toLowerCase()));
      known.aliases.push(...(lang.aliases || []));
      if (lang.configuration) known.configuration = { extId: id, path: lang.configuration };
      contributions.languages.set(lang.id, known);
    }
    for (const g of c.grammars || []) {
      if (!g.scopeName || !g.path) continue;
      contributions.grammars.set(g.scopeName, { extId: id, path: g.path, language: g.language, embeddedLanguages: g.embeddedLanguages, injectTo: g.injectTo });
      if (g.language) contributions.grammarForLanguage.set(g.language, g.scopeName);
    }
    for (const theme of c.themes || []) {
      if (!theme.path) continue;
      contributions.themes.set(`ext:${id}/${theme.path}`, { extId: id, path: theme.path, label: theme.label || theme.id, uiTheme: theme.uiTheme });
    }
    for (const s of c.snippets || []) {
      if (s.path) contributions.snippets.push({ language: s.language, extId: id, path: s.path });
    }
    for (const e of c.customEditors || []) {
      if (!e.viewType) continue;
      const patterns = (e.selector || []).map((x) => x && x.filenamePattern).filter(Boolean);
      contributions.customEditors.push({ viewType: e.viewType, displayName: e.displayName || e.viewType, patterns, priority: e.priority || 'default', extId: id });
    }
  }
  for (const fn of listeners) fn();
}

/** The extension language for a file, by name then extension, or null. */
export function extensionLanguageFor(path) {
  const name = path.split('/').pop().toLowerCase();
  const dot = name.lastIndexOf('.');
  const ext = dot >= 0 ? name.slice(dot) : '';
  for (const lang of contributions.languages.values()) {
    if (lang.filenames.includes(name)) return lang;
  }
  for (const lang of contributions.languages.values()) {
    if (ext && lang.extensions.includes(ext)) return lang;
  }
  return null;
}

// A glob ("*.png", "*.{bin,dat}", with ** for any folders) as a regular expression.
function globRegExp(glob) {
  let re = '';
  for (let i = 0; i < glob.length; i++) {
    const c = glob[i];
    if (c === '*' && glob[i + 1] === '*') { re += glob[i + 2] === '/' ? '(?:.*/)?' : '.*'; i += glob[i + 2] === '/' ? 2 : 1; }
    else if (c === '*') re += '[^/]*';
    else if (c === '?') re += '[^/]';
    else if (c === '{') re += '(?:';
    else if (c === '}') re += ')';
    else if (c === ',') re += '|';
    else re += c.replace(/[.+^$()|[\]\\]/g, '\\$&');
  }
  return new RegExp('^' + re + '$', 'i');
}

/** The custom editors that can open a file (patterns without a folder match the file's name). */
export function customEditorsFor(path) {
  const name = path.split('/').pop();
  return contributions.customEditors.filter((e) => e.patterns.some((p) => globRegExp(p).test(p.includes('/') ? path : name)));
}
