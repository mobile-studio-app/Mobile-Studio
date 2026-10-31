// Picks the language support for a file from its extension.
import { StreamLanguage } from '@codemirror/language';
import { lua } from '@codemirror/legacy-modes/mode/lua';
import { shader } from '@codemirror/legacy-modes/mode/clike';
import { json, jsonParseLinter } from '@codemirror/lang-json';
import { cpp } from '@codemirror/lang-cpp';
import { markdown } from '@codemirror/lang-markdown';
import { python } from '@codemirror/lang-python';
import { css } from '@codemirror/lang-css';
import { html } from '@codemirror/lang-html';
import { javascript } from '@codemirror/lang-javascript';
import { linter } from '@codemirror/lint';
import { autocompletion } from '@codemirror/autocomplete';
import { luaSupport } from './lua-intel.js';
import { uniformInitialiserDiagnostics } from './glsl-intel.js';
import { EditorState } from '@codemirror/state';
import { extensionLanguageFor } from './ext/registry.js';
import { loadTextMateLanguage } from './ext/textmate.js';
import { snippetSource } from './ext/snippets.js';
import { extensionCompletions } from './ext/host.js';

// Extension languages whose grammar has loaded (language id -> CodeMirror language).
const extensionLanguages = new Map();
// Extension snippets and completion providers join every language's completions.
const snippetCompletions = EditorState.languageData.of(() => [{ autocomplete: snippetSource }, { autocomplete: extensionCompletions }]);

/** Built-in support for an extension, or null when only an extension knows the file type. */
function builtInExtension(ext) {
  return ['lua', 'json', 'c', 'h', 'cpp', 'hpp', 'cc', 'm', 'mm', 'glsl', 'frag', 'vert', 'fs', 'vs', 'shader', 'md', 'markdown', 'py', 'pyw',
    'css', 'scss', 'less', 'html', 'htm', 'js', 'mjs', 'cjs', 'jsx', 'ts', 'mts', 'cts', 'tsx'].includes(ext);
}

/** Loads the grammar an extension contributes for this file, if the file needs one. */
export async function prepareLanguage(path) {
  const ext = path.includes('.') ? path.split('.').pop().toLowerCase() : '';
  if (builtInExtension(ext)) return;
  const lang = extensionLanguageFor(path);
  if (!lang || extensionLanguages.has(lang.id)) return;
  const language = await loadTextMateLanguage(lang);
  if (language) extensionLanguages.set(lang.id, { language, name: lang.aliases[0] || lang.id });
}

export function forgetExtensionLanguages() { extensionLanguages.clear(); }

/** The VS Code language id for a file, for snippets and extensions. */
export function languageIdFor(path) {
  const ext = path.includes('.') ? path.split('.').pop().toLowerCase() : '';
  const ids = { lua: 'lua', json: 'json', c: 'c', h: 'c', cpp: 'cpp', hpp: 'cpp', cc: 'cpp', m: 'objective-c', mm: 'objective-cpp',
    glsl: 'glsl', frag: 'glsl', vert: 'glsl', fs: 'glsl', vs: 'glsl', shader: 'glsl', md: 'markdown', markdown: 'markdown', py: 'python', pyw: 'python' };
  if (ids[ext]) return ids[ext];
  const known = extensionLanguageFor(path)?.id;
  if (known) return known;
  // VS Code's ids for common files, so extensions' providers find them even without a grammar.
  const common = { js: 'javascript', mjs: 'javascript', cjs: 'javascript', jsx: 'javascriptreact', ts: 'typescript', tsx: 'typescriptreact',
    css: 'css', scss: 'scss', less: 'less', html: 'html', htm: 'html', xml: 'xml', yaml: 'yaml', yml: 'yaml', toml: 'toml',
    sh: 'shellscript', rs: 'rust', go: 'go', java: 'java', cs: 'csharp', rb: 'ruby', php: 'php', swift: 'swift', kt: 'kotlin',
    csv: 'csv', tsv: 'tsv', ini: 'ini', sql: 'sql', vue: 'vue', svelte: 'svelte', graphql: 'graphql', txt: 'plaintext' };
  return common[ext] || 'plaintext';
}

const glsl = StreamLanguage.define(shader);
const luaLanguage = StreamLanguage.define(lua);

/** Returns { name, extensions } for a file path. With suggestions off, no completion popup. */
export function languageFor(path, { suggestions = true } = {}) {
  const lang = baseLanguageFor(path, suggestions);
  // Lua brings its own completion sources; other languages (plain text too, for extensions'
  // completion providers and snippets) use the language's and extensions' sources.
  if (suggestions && lang.name !== 'Lua') {
    return { name: lang.name, extensions: [lang.extensions, autocompletion(), snippetCompletions] };
  }
  return lang;
}

function baseLanguageFor(path, suggestions) {
  const ext = path.includes('.') ? path.split('.').pop().toLowerCase() : '';
  switch (ext) {
    case 'lua':
      return { name: 'Lua', extensions: luaSupport(luaLanguage, suggestions) };
    case 'json':
      return { name: 'JSON', extensions: [json(), linter(jsonParseLinter())] };
    case 'c': case 'h': case 'cpp': case 'hpp': case 'cc': case 'm': case 'mm':
      return { name: ext === 'c' || ext === 'h' ? 'C' : 'C++', extensions: [cpp()] };
    case 'glsl': case 'frag': case 'vert': case 'fs': case 'vs': case 'shader':
      return { name: 'GLSL', extensions: [glsl, linter((view) => uniformInitialiserDiagnostics(view.state.doc.toString()))] };
    case 'py': case 'pyw':
      // python() completes keywords, builtins and the file's own names.
      return { name: 'Python', extensions: [python()] };
    case 'md': case 'markdown':
      return { name: 'Markdown', extensions: [markdown()] };
    case 'css': case 'scss': case 'less':
      return { name: ext === 'css' ? 'CSS' : ext.toUpperCase(), extensions: [css()] };
    case 'html': case 'htm':
      return { name: 'HTML', extensions: [html()] };
    case 'js': case 'mjs': case 'cjs':
      return { name: 'JavaScript', extensions: [javascript()] };
    case 'jsx':
      return { name: 'JavaScript JSX', extensions: [javascript({ jsx: true })] };
    case 'ts': case 'mts': case 'cts':
      return { name: 'TypeScript', extensions: [javascript({ typescript: true })] };
    case 'tsx':
      return { name: 'TypeScript JSX', extensions: [javascript({ typescript: true, jsx: true })] };
    default: {
      const lang = extensionLanguageFor(path);
      const loaded = lang && extensionLanguages.get(lang.id);
      if (loaded) return { name: loaded.name, extensions: [loaded.language] };
      return { name: 'Plain Text', extensions: [] };
    }
  }
}
