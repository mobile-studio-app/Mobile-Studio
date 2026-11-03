// Extensions' menus and file decorations: editor/title icons in the tab bar and the rest under "…",
// editor/context, commandPalette `when` hiding, explorer/context (for the app's Explorer), `when`
// clauses over context keys (setContext) and settings, commands given the file's Uri, file
// decorations, and configurationDefaults.
const EXTENSION = `
const vscode = require('vscode');
exports.activate = function (context) {
  const ran = [];
  const record = (name) => (uri) => { ran.push(name + ' ' + (uri instanceof vscode.Uri ? vscode.workspace.asRelativePath(uri) : typeof uri)); };
  context.subscriptions.push(
    vscode.commands.registerCommand('menus.ran', () => ran.slice()),
    vscode.commands.registerCommand('menus.preview', record('preview')),
    vscode.commands.registerCommand('menus.other', record('other')),
    vscode.commands.registerCommand('menus.context', record('context')),
    vscode.commands.registerCommand('menus.explorer', record('explorer')),
    vscode.commands.registerCommand('menus.hidden', record('hidden')),
    vscode.commands.registerCommand('menus.enable', () => vscode.commands.executeCommand('setContext', 'menus.enabled', true)),
    vscode.commands.registerCommand('menus.setting', () => vscode.workspace.getConfiguration('menus').get('greeting')),
    vscode.window.registerFileDecorationProvider({
      provideFileDecoration: (uri) => (uri.path.endsWith('.lua') ? new vscode.FileDecoration('L', 'A Lua file', new vscode.ThemeColor('charts.blue')) : undefined),
    }),
  );
};
`;

const MANIFEST = {
  name: 'menus-test', publisher: 'test', version: '1.0.0', browser: './extension.js',
  activationEvents: ['onStartupFinished'],
  contributes: {
    commands: [
      { command: 'menus.preview', title: 'Open Lua Preview', icon: '$(open-preview)' },
      { command: 'menus.other', title: 'Other Lua Thing' },
      { command: 'menus.context', title: 'Lua Context Thing' },
      { command: 'menus.explorer', title: 'Explorer Lua Thing', icon: '$(zap)' },
      { command: 'menus.hidden', title: 'Hidden From the Palette' },
      { command: 'menus.gated', title: 'Gated Thing' },
      { command: 'menus.enable', title: 'Enable Menus' },
      { command: 'menus.setting', title: 'Read Setting' },
    ],
    configuration: { properties: { 'menus.greeting': { type: 'string', default: 'hello' } } },
    configurationDefaults: { 'menus.greeting': 'hi from defaults', '[lua]': { 'editor.tabSize': 2 } },
    menus: {
      'editor/title': [
        { command: 'menus.preview', when: 'editorLangId == lua', group: 'navigation' },
        { command: 'menus.other', when: 'resourceExtname == .lua', group: '1_more' },
        { command: 'menus.gated', when: 'menus.enabled', group: 'navigation' },
      ],
      'editor/context': [{ command: 'menus.context', when: 'editorLangId == lua && !editorReadonly' }],
      'explorer/context': [
        { command: 'menus.explorer', when: 'resourceLangId == lua && !explorerResourceIsFolder', group: 'navigation' },
        { command: 'menus.other', when: 'explorerResourceIsFolder' },
      ],
      commandPalette: [{ command: 'menus.hidden', when: 'false' }, { command: 'menus.gated', when: 'menus.enabled' }],
    },
  },
};

scenario(async () => {
  mockNative((m) => {
    if (m.cmd === 'extList') return [{ id: 'test.menus-test', manifest: MANIFEST }];
    if (m.cmd === 'extRead' && m.id === 'test.menus-test') {
      if (m.path === 'extension.js') return EXTENSION;
      throw new Error('not found');
    }
    if (m.cmd === 'extHostInit') return { project: 'game', configuration: {}, state: {} };
    return undefined;
  });
  const run = (name, ...args) => window.duocode.runCommand(name, ...args);
  const titleButtons = () => [...document.querySelectorAll('#ext-title-actions button')];

  openFile('main.lua');
  await until(() => view().state.doc.toString().startsWith('-- Sample'));
  window.duocode.onEvent({ name: 'extensionsChanged', payload: {} });

  check('editor/title\'s navigation item shows as an icon in the tab bar', await until(() => titleButtons().some((b) => b.title === 'Open Lua Preview'), 8000), titleButtons().map((b) => b.title).join('|'));
  check('with a "…" for the rest', titleButtons().some((b) => b.title === 'More Actions...'));
  check('an item whose when is false doesn\'t show', !titleButtons().some((b) => b.title === 'Gated Thing'));

  titleButtons().find((b) => b.title === 'Open Lua Preview').click();
  check('its command runs with the file\'s Uri', await until(async () => ((await run('menus.ran')) || []).includes('preview main.lua')), JSON.stringify(await run('menus.ran')));

  // "…": the title bar's other items, then editor/context's.
  titleButtons().find((b) => b.title === 'More Actions...').click();
  await until(() => document.querySelectorAll('.qi-item').length >= 2);
  const labels = [...document.querySelectorAll('.qi-item')].map((e) => e.textContent);
  check('"…" lists the other title items and the context menu\'s', labels.some((l) => l.includes('Other Lua Thing')) && labels.some((l) => l.includes('Lua Context Thing')), labels.join('|'));
  [...document.querySelectorAll('.qi-item')].find((e) => e.textContent.includes('Lua Context Thing')).click();
  check('and runs the one picked', await until(async () => ((await run('menus.ran')) || []).includes('context main.lua')), JSON.stringify(await run('menus.ran')));

  // Right-click in the editor: editor/context.
  view().contentDOM.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true, clientX: 50, clientY: 50 }));
  check('right-clicking the editor shows editor/context', await until(() => [...document.querySelectorAll('.qi-item')].some((e) => e.textContent.includes('Lua Context Thing'))));
  document.querySelector('.qi-backdrop')?.dispatchEvent(new MouseEvent('mousedown', { bubbles: true }));
  document.querySelector('.qi-input')?.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
  await until(() => !document.querySelector('.qi'));

  // setContext changes what `when` allows.
  await run('menus.enable');
  check('setContext makes a gated title item show', await until(() => titleButtons().some((b) => b.title === 'Gated Thing')), titleButtons().map((b) => b.title).join('|'));

  // The Explorer's menu, for the app to show (Swift asks the page).
  const forFile = window.duocode.explorerMenu('main.lua', false).map((i) => i.title);
  const forFolder = window.duocode.explorerMenu('assets', true).map((i) => i.title);
  check('explorer/context items for a Lua file', JSON.stringify(forFile) === '["Explorer Lua Thing"]', JSON.stringify(forFile));
  check('and for a folder', JSON.stringify(forFolder) === '["Other Lua Thing"]', JSON.stringify(forFolder));
  check('with their codicon', window.duocode.explorerMenu('main.lua', false)[0]?.icon === 'zap');
  await window.duocode.runForResource('menus.explorer', 'main.lua');
  check('running one gives it the file\'s Uri', ((await run('menus.ran')) || []).includes('explorer main.lua'), JSON.stringify(await run('menus.ran')));

  // File decorations for the Explorer.
  const decorations = await window.duocode.fileDecorations(['main.lua', 'README.md']);
  check('file decorations come from the provider', decorations['main.lua']?.badge === 'L' && !decorations['README.md'], JSON.stringify(decorations));
  check('with theme colours as CSS', decorations['main.lua']?.color === '#3794ff', decorations['main.lua']?.color);

  // The Command Palette leaves out commands its menu hides.
  const palette = (await (async () => {
    window.duocode.onEvent({ name: 'commandPalette', payload: {} });
    await until(() => document.querySelectorAll('.qi-item').length > 5);
    const items = [...document.querySelectorAll('.qi-item')].map((e) => e.textContent);
    document.querySelector('.qi-input')?.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
    return items;
  })());
  check('the Command Palette hides a command its menu says to', !palette.some((l) => l.includes('Hidden From the Palette')) && palette.some((l) => l.includes('Enable Menus')), palette.filter((l) => /Hidden|Enable|Gated/.test(l)).join('|'));
  check('and shows one once its when holds', palette.some((l) => l.includes('Gated Thing')));

  check('configurationDefaults set other settings\' defaults', await run('menus.setting') === 'hi from defaults', await run('menus.setting'));

  // Status bar text with $(icon)s shows the codicons.
  check('codicons render in the title bar', titleButtons()[0].classList.contains('codicon') && titleButtons()[0].textContent.length === 1, titleButtons()[0].textContent);
});
