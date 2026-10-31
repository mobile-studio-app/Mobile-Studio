// Extensions' keyboard shortcuts (contributes.keybindings), as CodeMirror key bindings that run
// the extension's command. "when" clauses are checked for the language and file extension; other
// conditions are assumed to hold.
import { keymap } from '@codemirror/view';
import { Compartment } from '@codemirror/state';
import { contributions } from './registry.js';

const KEY_NAMES = {
  enter: 'Enter', escape: 'Escape', tab: 'Tab', space: 'Space', backspace: 'Backspace', delete: 'Delete',
  up: 'ArrowUp', down: 'ArrowDown', left: 'ArrowLeft', right: 'ArrowRight', home: 'Home', end: 'End',
  pageup: 'PageUp', pagedown: 'PageDown', insert: 'Insert',
};

/** "ctrl+shift+k cmd+i" (VS Code) -> "Ctrl-Shift-k Mod-i" (CodeMirror). */
export function convertKey(key) {
  return key.trim().split(/\s+/).map((stroke) => stroke.split('+').map((part) => {
    const p = part.toLowerCase();
    if (p === 'cmd' || p === 'meta' || p === 'win') return 'Mod';
    if (p === 'ctrl') return 'Ctrl';
    if (p === 'alt' || p === 'option') return 'Alt';
    if (p === 'shift') return 'Shift';
    if (KEY_NAMES[p]) return KEY_NAMES[p];
    if (/^f\d+$/.test(p)) return p.toUpperCase();
    return p.length === 1 ? p : part;
  }).join('-')).join(' ');
}

/** Enough of VS Code's "when" for shortcuts that belong to a language or file type. */
export function whenHolds(when, context) {
  if (!when) return true;
  return when.split('||').some((any) => any.split('&&').every((term) => {
    const t = term.trim();
    let m = /^!?\s*(editorLangId|resourceLangId)\s*(==|!=)\s*'?([\w.-]+)'?$/.exec(t);
    if (m) return (context.languageId === m[3]) === (m[2] === '==');
    m = /^(resourceExtname)\s*(==|!=)\s*'?([\w.-]+)'?$/.exec(t);
    if (m) return (context.extname === m[3]) === (m[2] === '==');
    m = /^(editorLangId|resourceLangId)\s+in\s+/.exec(t);
    if (m) return true;
    return true;
  }));
}

export const extensionKeys = new Compartment();
let bindings = [];

/** The keymap for the installed extensions' shortcuts. `run(command, args)` runs one;
 * `context()` gives { languageId, extname } for "when". */
export function buildExtensionKeymap(run, context) {
  const byKey = new Map();
  for (const ext of contributions.extensions) {
    const list = ext.manifest.contributes?.keybindings;
    for (const kb of Array.isArray(list) ? list : list ? [list] : []) {
      const key = kb.mac || kb.key;
      if (!key || !kb.command || kb.command.startsWith('-')) continue;
      const cmKey = convertKey(key);
      if (!byKey.has(cmKey)) byKey.set(cmKey, []);
      byKey.get(cmKey).push(kb);
    }
  }
  bindings = [...byKey].map(([key, list]) => ({
    key,
    run: () => {
      const ctx = context();
      const kb = list.find((k) => whenHolds(k.when, ctx));
      if (!kb) return false;
      run(kb.command, kb.args === undefined ? [] : [kb.args]);
      return true;
    },
  }));
  return keymap.of(bindings);
}

/** The current extension keymap, for new editor states. */
export const currentExtensionKeymap = () => keymap.of(bindings);
