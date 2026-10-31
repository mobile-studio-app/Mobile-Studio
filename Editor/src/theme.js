// Editor colour themes. Each palette drives the CodeMirror theme, the syntax colours and
// (through CSS variables) the tab bar, docs sheet and file viewer in editor.html.
import { EditorView } from '@codemirror/view';
import { HighlightStyle, syntaxHighlighting } from '@codemirror/language';
import { tags as t } from '@lezer/highlight';

export const palettes = {
  'dark-plus': {
    dark: true, bg: '#1e1e1e', fg: '#d4d4d4', text: '#cccccc', muted: '#999999',
    gutter: '#858585', gutterActive: '#c6c6c6', activeLine: '#2a2d2e80', selection: '#264f78', cursor: '#aeafad',
    panel: '#252526', border: '#454545', borderStrong: '#1a1a1a', listActive: '#04395e',
    keyword: '#569cd6', control: '#c586c0', string: '#ce9178', number: '#b5cea8', comment: '#6a9955',
    func: '#dcdcaa', variable: '#9cdcfe', type: '#4ec9b0', constant: '#4fc1ff',
  },
  'light-plus': {
    dark: false, bg: '#ffffff', fg: '#000000', text: '#333333', muted: '#6e6e6e',
    gutter: '#237893', gutterActive: '#0b216f', activeLine: '#0000000a', selection: '#add6ff', cursor: '#000000',
    panel: '#f3f3f3', border: '#d4d4d4', borderStrong: '#e5e5e5', listActive: '#cce6ff',
    keyword: '#0000ff', control: '#af00db', string: '#a31515', number: '#098658', comment: '#008000',
    func: '#795e26', variable: '#001080', type: '#267f99', constant: '#0070c1',
  },
  'monokai': {
    dark: true, bg: '#272822', fg: '#f8f8f2', text: '#e6e6e0', muted: '#90908a',
    gutter: '#90908a', gutterActive: '#c2c2bf', activeLine: '#3e3d3280', selection: '#49483e', cursor: '#f8f8f0',
    panel: '#1e1f1c', border: '#414339', borderStrong: '#151612', listActive: '#414339',
    keyword: '#f92672', control: '#f92672', string: '#e6db74', number: '#ae81ff', comment: '#75715e',
    func: '#a6e22e', variable: '#f8f8f2', type: '#66d9ef', constant: '#ae81ff',
  },
  'one-dark': {
    dark: true, bg: '#282c34', fg: '#abb2bf', text: '#c8ccd4', muted: '#7f848e',
    gutter: '#495162', gutterActive: '#abb2bf', activeLine: '#2c313c', selection: '#3e4451', cursor: '#528bff',
    panel: '#21252b', border: '#3b4048', borderStrong: '#181a1f', listActive: '#2c313a',
    keyword: '#c678dd', control: '#c678dd', string: '#98c379', number: '#d19a66', comment: '#5c6370',
    func: '#61afef', variable: '#e06c75', type: '#e5c07b', constant: '#56b6c2',
  },
  'solarized-dark': {
    dark: true, bg: '#002b36', fg: '#93a1a1', text: '#93a1a1', muted: '#657b83',
    gutter: '#586e75', gutterActive: '#93a1a1', activeLine: '#073642', selection: '#274642', cursor: '#d30102',
    panel: '#00212b', border: '#2b4c55', borderStrong: '#001a22', listActive: '#005a6f',
    keyword: '#859900', control: '#859900', string: '#2aa198', number: '#d33682', comment: '#586e75',
    func: '#268bd2', variable: '#839496', type: '#b58900', constant: '#cb4b16',
  },
};

export function paletteFor(name) {
  return palettes[name] || palettes['dark-plus'];
}

/** CodeMirror theme + syntax highlighting for a palette name. */
export function themeExtension(name) {
  const c = paletteFor(name);
  const theme = EditorView.theme({
    '&': { color: c.fg, backgroundColor: c.bg, height: '100%' },
    '.cm-scroller': { fontFamily: 'ui-monospace, Menlo, Consolas, monospace', lineHeight: '1.5' },
    '.cm-content': { caretColor: c.cursor, padding: '6px 0 40vh' },
    '.cm-cursor, .cm-dropCursor': { borderLeftColor: c.cursor, borderLeftWidth: '2px' },
    '&.cm-focused .cm-selectionBackground, .cm-selectionBackground, .cm-content ::selection': { backgroundColor: c.selection },
    '.cm-activeLine': { backgroundColor: c.activeLine },
    '.cm-gutters': { backgroundColor: c.bg, color: c.gutter, border: 'none' },
    '.cm-activeLineGutter': { backgroundColor: 'transparent', color: c.gutterActive },
    '.cm-lineNumbers .cm-gutterElement': { padding: '0 10px 0 8px', minWidth: '28px' },
    '.cm-foldPlaceholder': { backgroundColor: c.selection, border: 'none', color: c.fg },
    '.cm-matchingBracket': { backgroundColor: '#0064001a', outline: `1px solid ${c.gutter}` },
    '.cm-searchMatch': { backgroundColor: c.dark ? '#623315' : '#ffe08a', outline: '1px solid #9e6a03' },
    '.cm-searchMatch.cm-searchMatch-selected': { backgroundColor: c.dark ? '#515c6a' : '#f8c95b' },
    '.cm-panels': { backgroundColor: c.panel, color: c.fg },
    '.cm-panels.cm-panels-top': { borderBottom: `1px solid ${c.border}` },
    '.cm-panel input, .cm-panel button': { fontSize: '13px' },
    '.cm-tooltip': { backgroundColor: c.panel, border: `1px solid ${c.border}`, color: c.fg, borderRadius: '4px' },
    '.cm-tooltip-autocomplete > ul': { fontFamily: 'ui-monospace, Menlo, Consolas, monospace', maxHeight: '14em' },
    '.cm-tooltip-autocomplete > ul > li': { padding: '3px 8px !important', lineHeight: '1.4' },
    '.cm-tooltip-autocomplete > ul > li[aria-selected]': { backgroundColor: c.listActive, color: c.fg },
    '.cm-completionDetail': { color: c.muted, fontStyle: 'normal', marginLeft: '8px' },
    '.cm-completionMatchedText': { color: c.dark ? '#18a3ff' : '#0066bf', textDecoration: 'none', fontWeight: '600' },
    '.cm-completionInfo': { padding: '6px 10px', maxWidth: '320px', whiteSpace: 'normal' },
    '.cm-diagnostic-error': { borderLeft: '3px solid #f14c4c' },
    '.cm-diagnostic-warning': { borderLeft: '3px solid #cca700' },
    '.cm-diagnostic-info': { borderLeft: '3px solid #3794ff' },
    '.cm-lintRange-error': { backgroundImage: 'none', textDecoration: 'underline wavy #f14c4c', textUnderlineOffset: '3px' },
    '.cm-lintRange-warning': { backgroundImage: 'none', textDecoration: 'underline wavy #cca700', textUnderlineOffset: '3px' },
    '.cm-lintRange-info': { backgroundImage: 'none', textDecoration: 'underline wavy #3794ff', textUnderlineOffset: '3px' },
    // AI inline suggestion
    '.cm-ghost': { color: c.gutter, opacity: '0.85', whiteSpace: 'pre', cursor: 'pointer' },
    '.cm-ghost-accept': {
      display: 'inline-block', marginLeft: '8px', padding: '0 6px', borderRadius: '4px', fontSize: '11px',
      lineHeight: '16px', verticalAlign: 'middle', fontFamily: '-apple-system, sans-serif',
      color: c.fg, backgroundColor: c.selection, cursor: 'pointer',
    },
  }, { dark: c.dark });

  const highlight = syntaxHighlighting(HighlightStyle.define([
    { tag: [t.keyword, t.modifier, t.operatorKeyword], color: c.keyword },
    { tag: [t.controlKeyword, t.moduleKeyword], color: c.control },
    { tag: [t.string, t.special(t.string), t.regexp], color: c.string },
    { tag: [t.number, t.integer, t.float], color: c.number },
    { tag: [t.bool, t.null, t.atom], color: c.keyword },
    { tag: [t.comment, t.lineComment, t.blockComment, t.docComment], color: c.comment, fontStyle: 'italic' },
    { tag: [t.function(t.variableName), t.function(t.propertyName), t.macroName], color: c.func },
    { tag: [t.variableName, t.propertyName, t.attributeName], color: c.variable },
    { tag: [t.typeName, t.className, t.namespace, t.standard(t.typeName)], color: c.type },
    { tag: [t.constant(t.variableName), t.standard(t.variableName)], color: c.constant },
    { tag: [t.definition(t.variableName)], color: c.variable },
    { tag: [t.processingInstruction, t.meta], color: c.control },
    { tag: [t.heading], color: c.keyword, fontWeight: 'bold' },
    { tag: [t.link, t.url], color: c.string, textDecoration: 'underline' },
    { tag: [t.emphasis], fontStyle: 'italic' },
    { tag: [t.strong], fontWeight: 'bold' },
    { tag: [t.invalid], color: '#f44747' },
  ]));
  return [theme, highlight];
}

/** Colours the page around the editor (tab bar, docs sheet, viewer) to match. */
// VS Code's workbench colours for the built-in light theme (the dark ones derive from their palettes).
const LIGHT_WORKBENCH = {
  'activityBar.background': '#2c2c2c', 'activityBar.foreground': '#ffffff', 'activityBar.inactiveForeground': '#ffffff66',
  'sideBar.background': '#f3f3f3', 'sideBar.foreground': '#616161', 'sideBarTitle.foreground': '#6f6f6f',
  'descriptionForeground': '#717171', 'icon.foreground': '#424242', 'input.background': '#ffffff', 'input.placeholderForeground': '#767676',
  'list.hoverBackground': '#e8e8e8', 'list.inactiveSelectionBackground': '#e4e6f1', 'list.activeSelectionBackground': '#cce6ff',
  'sideBarSectionHeader.border': '#61616130', 'panel.border': '#80808059', 'badge.background': '#c4c4c4',
};

/**
 * The colours the app's own chrome (side bar, activity bar, lists, inputs) uses for a theme, from
 * the theme's workbench colours where it has them. Sent to the app (see ThemeColors.swift).
 */
export function chromeColors(name) {
  const c = paletteFor(name);
  const w = { ...(name === 'light-plus' ? LIGHT_WORKBENCH : {}), ...(c.workbench || {}) };
  const pick = (...values) => values.find((v) => typeof v === 'string' && v);
  return Object.fromEntries(Object.entries({
    editorBackground: pick(w['editor.background'], c.bg),
    sideBar: pick(w['sideBar.background'], c.panel),
    activityBar: pick(w['activityBar.background'], c.dark ? c.borderStrong : '#2c2c2c'),
    activityBarForeground: pick(w['activityBar.foreground']),
    activityBarInactive: pick(w['activityBar.inactiveForeground']),
    activityBarBadge: pick(w['activityBarBadge.background']),
    foreground: pick(w['sideBar.foreground'], w.foreground, c.text),
    titleForeground: pick(w['sideBarTitle.foreground'], w['sideBar.foreground'], w.foreground, c.text),
    description: pick(w.descriptionForeground, c.muted),
    icon: pick(w['icon.foreground'], w.foreground, c.text),
    border: pick(w['panel.border'], w['sideBar.border'], c.border),
    sectionBorder: pick(w['sideBarSectionHeader.border'], w['sideBar.border'], c.border),
    inputBackground: pick(w['input.background'], c.dark ? c.activeLine : '#ffffff'),
    placeholder: pick(w['input.placeholderForeground'], c.muted),
    focusBorder: pick(w.focusBorder),
    buttonBackground: pick(w['button.background']),
    buttonHover: pick(w['button.hoverBackground']),
    badgeBackground: pick(w['badge.background']),
    listHover: pick(w['list.hoverBackground']),
    listSelection: pick(w['list.inactiveSelectionBackground']),
    listActiveSelection: pick(w['list.activeSelectionBackground'], c.listActive),
    link: pick(w['textLink.foreground']),
    statusBar: pick(w['statusBar.background']),
  }).filter(([, v]) => v));
}

export function applyChrome(name) {
  const c = paletteFor(name);
  const root = document.documentElement.style;
  root.colorScheme = c.dark ? 'dark' : 'light';
  const vars = {
    bg: c.bg, chrome: c.panel, fg: c.fg, text: c.text, muted: c.muted, border: c.border,
    'border-strong': c.borderStrong, 'c-func': c.func, 'c-variable': c.variable, 'c-type': c.type, 'c-constant': c.constant,
  };
  for (const [k, v] of Object.entries(vars)) root.setProperty(`--${k}`, v);
}
