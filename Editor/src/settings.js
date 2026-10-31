// Editor preferences from the app's Settings screen. Each one lives in a compartment so a
// change applies to the open file immediately (and to cached files when they're reopened).
import { Compartment, EditorState } from '@codemirror/state';
import { EditorView } from '@codemirror/view';
import { indentUnit } from '@codemirror/language';
import { themeExtension, applyChrome } from './theme.js';
import { languageFor } from './languages.js';

export const settings = {
  theme: 'dark-plus',
  fontSize: 13,
  tabSize: 4,
  wordWrap: false,
  autoSave: true,
  formatOnSave: false,
  suggestions: true,
  ai: false,          // an AI model is selected and ready to be asked for completions
  aiMerge: false,     // the model picked for merge conflicts is ready ("Resolve for me")
};

const themeSlot = new Compartment();
const fontSlot = new Compartment();
const indentSlot = new Compartment();
const wrapSlot = new Compartment();
const languageSlot = new Compartment();

const fontExt = () => EditorView.theme({ '&': { fontSize: `${settings.fontSize}px` } });
const indentExt = () => [EditorState.tabSize.of(settings.tabSize), indentUnit.of(' '.repeat(settings.tabSize))];
const wrapExt = () => (settings.wordWrap ? EditorView.lineWrapping : []);
const languageExt = (path) => languageFor(path, { suggestions: settings.suggestions }).extensions;

/** The settings-driven extensions for a new editor state. */
export function settingsExtensions(path) {
  return [
    themeSlot.of(themeExtension(settings.theme)),
    fontSlot.of(fontExt()),
    indentSlot.of(indentExt()),
    wrapSlot.of(wrapExt()),
    languageSlot.of(languageExt(path)),
  ];
}

/** Effects that bring an existing state in line with the current settings. */
export function settingsEffects(path) {
  return [
    themeSlot.reconfigure(themeExtension(settings.theme)),
    fontSlot.reconfigure(fontExt()),
    indentSlot.reconfigure(indentExt()),
    wrapSlot.reconfigure(wrapExt()),
    languageSlot.reconfigure(languageExt(path)),
  ];
}

/** Merges new values in; returns true if anything changed. */
export function updateSettings(values) {
  let changed = false;
  for (const key of Object.keys(settings)) {
    if (values && key in values && values[key] !== settings[key]) {
      settings[key] = values[key];
      changed = true;
    }
  }
  applyChrome(settings.theme);
  return changed;
}
