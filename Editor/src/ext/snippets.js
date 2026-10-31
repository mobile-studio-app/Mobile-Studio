// Snippets from extensions (contributes.snippets), offered as completions for their language.
import { snippetCompletion } from '@codemirror/autocomplete';
import { contributions, readExtensionFile, parseJSONC } from './registry.js';

let activeLanguage = 'plaintext';
let currentPath = '';
const cache = new Map();   // language id -> Promise<Completion[]>

export function setSnippetContext(languageId, path) {
  activeLanguage = languageId;
  currentPath = path;
}

export function resetSnippets() { cache.clear(); }

/** VS Code snippet syntax -> CodeMirror's: $1 -> ${1}, ${1|a,b|} -> ${1:a}, variables resolved. */
export function convertSnippet(body, path = currentPath) {
  const file = path.split('/').pop() || '';
  const now = new Date();
  const pad = (n) => String(n).padStart(2, '0');
  const variables = {
    TM_FILENAME: file,
    TM_FILENAME_BASE: file.replace(/\.[^.]*$/, ''),
    TM_DIRECTORY: path.split('/').slice(0, -1).join('/'),
    TM_FILEPATH: path,
    RELATIVE_FILEPATH: path,
    TM_SELECTED_TEXT: '', TM_CURRENT_LINE: '', TM_CURRENT_WORD: '', CLIPBOARD: '',
    CURRENT_YEAR: String(now.getFullYear()), CURRENT_YEAR_SHORT: String(now.getFullYear()).slice(2),
    CURRENT_MONTH: pad(now.getMonth() + 1), CURRENT_DATE: pad(now.getDate()),
    CURRENT_HOUR: pad(now.getHours()), CURRENT_MINUTE: pad(now.getMinutes()), CURRENT_SECOND: pad(now.getSeconds()),
    LINE_COMMENT: '--', BLOCK_COMMENT_START: '--[[', BLOCK_COMMENT_END: ']]',
    UUID: (crypto.randomUUID && crypto.randomUUID()) || '',
  };
  let text = Array.isArray(body) ? body.join('\n') : String(body);
  text = text.replace(/\$\{(\d+)\|([^|},]*)(?:,[^|}]*)*\|\}/g, (_, n, first) => `\${${n}:${first}}`);
  text = text.replace(/\$\{([A-Z_]+)(?::([^}]*))?\}/g, (m, name, fallback) => (name in variables ? (variables[name] || fallback || '') : m));
  text = text.replace(/\$([A-Z_]+)\b/g, (m, name) => (name in variables ? variables[name] : m));
  text = text.replace(/\$(\d+)/g, (_, n) => `\${${n}}`);
  return text.replace(/\\\$/g, '$').replace(/\\\}/g, '}');
}

function snippetsFor(language) {
  if (!cache.has(language)) {
    cache.set(language, (async () => {
      const options = [];
      for (const entry of contributions.snippets) {
        if (entry.language && entry.language !== language) continue;
        try {
          const json = parseJSONC(await readExtensionFile(entry.extId, entry.path));
          for (const [name, snippet] of Object.entries(json)) {
            if (!snippet || snippet.body == null) continue;
            if (!entry.language && snippet.scope && !snippet.scope.split(',').map((s) => s.trim()).includes(language)) continue;
            const prefixes = Array.isArray(snippet.prefix) ? snippet.prefix : [snippet.prefix || name];
            for (const prefix of prefixes) {
              options.push({ prefix, name, body: snippet.body, description: snippet.description });
            }
          }
        } catch (e) { /* a broken snippet file is skipped */ }
      }
      return options;
    })());
  }
  return cache.get(language);
}

/** Completion source for the open file's language. */
export async function snippetSource(context) {
  const word = context.matchBefore(/[\w.$@#:-]+/);
  if (!word || (word.from === word.to && !context.explicit)) return null;
  const all = await snippetsFor(activeLanguage);
  if (!all.length) return null;
  return {
    from: word.from,
    options: all.map((s) => snippetCompletion(convertSnippet(s.body), {
      label: s.prefix,
      detail: s.name !== s.prefix ? s.name : 'snippet',
      info: s.description,
      type: 'text',
      boost: -1,
    })),
    validFor: /^[\w.$@#:-]*$/,
  };
}
