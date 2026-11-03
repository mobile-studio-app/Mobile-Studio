// Language features from an extension's providers: completions that resolve, replace a range and
// add an edit elsewhere; signature help; folding ranges; code lenses; semantic tokens; document
// links; colours; document highlights; Go to Implementation; workspace symbols; Format Selection.
const EXTENSION = `
const vscode = require('vscode');
exports.activate = function (context) {
  const lua = { language: 'lua' };
  const ran = [];
  const legend = new vscode.SemanticTokensLegend(['function', 'variable'], ['readonly']);
  context.subscriptions.push(
    vscode.commands.registerCommand('test.ran', () => ran.slice()),
    vscode.commands.registerCommand('test.lens', (x) => { ran.push('lens ' + x); }),
    vscode.commands.registerCommand('test.accepted', () => { ran.push('accepted'); }),
    vscode.languages.registerCompletionItemProvider(lua, {
      provideCompletionItems(doc, pos) {
        const item = new vscode.CompletionItem('zebraFunction', vscode.CompletionItemKind.Function);
        item.additionalTextEdits = [vscode.TextEdit.insert(new vscode.Position(0, 0), '-- imported\\n')];
        item.command = { command: 'test.accepted', title: '' };
        return [item];
      },
      resolveCompletionItem(item) { item.documentation = new vscode.MarkdownString('Resolved **docs**'); return item; },
    }),
    vscode.languages.registerSignatureHelpProvider(lua, {
      provideSignatureHelp(doc, pos) {
        const text = doc.lineAt(pos.line).text.slice(0, pos.character);
        if (!/newFont\\([^)]*$/.test(text)) return null;
        const help = new vscode.SignatureHelp();
        const sig = new vscode.SignatureInformation('newFont(size, hinting)', 'Makes a font.');
        sig.parameters = [new vscode.ParameterInformation('size'), new vscode.ParameterInformation('hinting')];
        help.signatures = [sig];
        help.activeParameter = (text.split('newFont(')[1].match(/,/g) || []).length;
        return help;
      },
    }, '(', ','),
    vscode.languages.registerFoldingRangeProvider(lua, { provideFoldingRanges: () => [new vscode.FoldingRange(1, 3)] }),
    vscode.languages.registerCodeLensProvider(lua, {
      provideCodeLenses: () => [new vscode.CodeLens(new vscode.Range(3, 0, 3, 0))],
      resolveCodeLens: (lens) => { lens.command = { title: '2 references', command: 'test.lens', arguments: ['load'] }; return lens; },
    }),
    vscode.languages.registerDocumentSemanticTokensProvider(lua, {
      provideDocumentSemanticTokens() {
        const b = new vscode.SemanticTokensBuilder(legend);
        b.push(1, 6, 3, 1, 0);   // "img" in "local img"
        return b.build();
      },
    }, legend),
    vscode.languages.registerDocumentLinkProvider(lua, {
      provideDocumentLinks: () => [new vscode.DocumentLink(new vscode.Range(4, 34, 4, 44), vscode.Uri.parse('https://example.com/sprite'))],
    }),
    vscode.languages.registerColorProvider(lua, {
      provideDocumentColors: () => [new vscode.ColorInformation(new vscode.Range(0, 0, 0, 2), new vscode.Color(1, 0, 0, 1))],
      provideColorPresentations: (color) => [new vscode.ColorPresentation('#' + [color.red, color.green, color.blue].map((v) => Math.round(v * 255).toString(16).padStart(2, '0')).join(''))],
    }),
    vscode.languages.registerDocumentHighlightProvider(lua, {
      provideDocumentHighlights: (doc, pos) => [new vscode.DocumentHighlight(new vscode.Range(1, 6, 1, 9)), new vscode.DocumentHighlight(new vscode.Range(4, 4, 4, 7), vscode.DocumentHighlightKind.Write)],
    }),
    vscode.languages.registerImplementationProvider(lua, {
      provideImplementation: (doc) => [new vscode.Location(doc.uri, new vscode.Range(13, 9, 13, 20))],
    }),
    vscode.languages.registerWorkspaceSymbolProvider({
      provideWorkspaceSymbols: (q) => [new vscode.SymbolInformation('love.draw', vscode.SymbolKind.Function, '', new vscode.Location(vscode.Uri.joinPath(vscode.workspace.workspaceFolders[0].uri, 'main.lua'), new vscode.Range(8, 9, 8, 18)))].filter((s) => s.name.includes(q)),
    }),
    vscode.languages.registerDocumentRangeFormattingEditProvider(lua, {
      provideDocumentRangeFormattingEdits: (doc, range) => [vscode.TextEdit.replace(new vscode.Range(range.start.line, 0, range.start.line, 0), '  ')],
    }),
  );
};
`;

const MANIFEST = {
  name: 'lang-test', publisher: 'test', version: '1.0.0', browser: './extension.js',
  activationEvents: ['onLanguage:lua'],
  contributes: { commands: [{ command: 'test.ran', title: 'Ran' }] },
};

scenario(async () => {
  mockNative((m) => {
    if (m.cmd === 'extList') return [{ id: 'test.lang-test', manifest: MANIFEST }];
    if (m.cmd === 'extRead' && m.id === 'test.lang-test') {
      if (m.path === 'extension.js') return EXTENSION;
      throw new Error('not found');
    }
    if (m.cmd === 'extHostInit') return { project: 'game', configuration: {}, state: {} };
    return undefined;
  });
  const run = (name, ...args) => window.duocode.runCommand(name, ...args);
  const text = () => view().state.doc.toString();
  const CODES = { Escape: 27, Enter: 13, ArrowDown: 40 };
  const key = (k) => view().contentDOM.dispatchEvent(new KeyboardEvent('keydown', { key: k, code: k, keyCode: CODES[k], bubbles: true, cancelable: true }));

  openFile('main.lua');
  await until(() => text().startsWith('-- Sample'));
  window.duocode.onEvent({ name: 'extensionsChanged', payload: {} });

  // Code lenses, semantic tokens, links, colours: asked for once the file is still.
  check('a code lens shows above its line', await until(() => document.querySelector('.cm-codelens')?.textContent === '2 references', 8000), document.querySelector('.cm-codelens')?.textContent);
  check('semantic tokens colour the code', await until(() => document.querySelector('.cm-sem-variable')?.textContent === 'img'), document.querySelector('.cm-sem-variable')?.textContent);
  check('document links are underlined', document.querySelector('.cm-ext-link')?.textContent === 'sprite.png', document.querySelector('.cm-ext-link')?.textContent);
  check('colours get a swatch', !!document.querySelector('.cm-color-swatch'));

  document.querySelector('.cm-codelens-item').dispatchEvent(new MouseEvent('mousedown', { bubbles: true }));
  check('tapping a code lens runs its command', await until(async () => false, 300) || JSON.stringify(await run('test.ran')).includes('lens load'), JSON.stringify(await run('test.ran')));

  // ⌘-click follows a link.
  const linkEl = document.querySelector('.cm-ext-link');
  const r = linkEl.getBoundingClientRect();
  linkEl.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true, metaKey: true, clientX: r.left + 3, clientY: r.top + r.height / 2 }));
  check('⌘-clicking a link opens it', await until(() => window.__native.some((m) => m.cmd === 'openExternal' && m.uri === 'https://example.com/sprite')));

  // Folding by the provider's range (lines 2-4).
  check('the fold gutter shows the provider\'s ranges', await until(() => document.querySelectorAll('.cm-foldGutter .cm-gutterElement span').length > 0), document.querySelectorAll('.cm-foldGutter .cm-gutterElement').length);

  // Document highlights as the cursor rests on a symbol.
  view().dispatch({ selection: { anchor: view().state.doc.line(2).from + 7 } });
  check('document highlights mark the symbol\'s uses', await until(() => document.querySelectorAll('.cm-ext-highlight').length === 1 && document.querySelectorAll('.cm-ext-highlight-write').length === 1),
    `${document.querySelectorAll('.cm-ext-highlight').length} ${document.querySelectorAll('.cm-ext-highlight-write').length}`);

  // Signature help: typing "(" after newFont, then "," moves to the next parameter.
  const line6 = view().state.doc.line(6);
  const at = line6.from + line6.text.indexOf('(14)');
  view().dispatch({ changes: { from: at, to: at + 4, insert: '' }, selection: { anchor: at } });
  view().dispatch({ changes: { from: at, insert: '(' }, selection: { anchor: at + 1 }, userEvent: 'input.type' });
  const sig = () => document.querySelector('.ext-signature');
  check('typing "(" shows the signature', await until(() => sig()?.textContent.includes('newFont(size, hinting)')), sig()?.textContent);
  check('with the parameter being typed in bold', sig()?.querySelector('b')?.textContent === 'size', sig()?.querySelector('b')?.textContent);
  view().dispatch({ changes: { from: at + 1, insert: '14,' }, selection: { anchor: at + 4 }, userEvent: 'input.type' });
  check('"," moves on to the next parameter', await until(() => sig()?.querySelector('b')?.textContent === 'hinting'), sig()?.querySelector('b')?.textContent);
  // (The first Escape closes the completion list typing opened, as in VS Code.)
  key('Escape');
  if (sig()) { await wait(50); key('Escape'); }
  check('Escape closes it', await until(() => !sig()));
  view().dispatch({ changes: { from: at, to: at + 4, insert: '(14)' } });

  // A completion that resolves its documentation, adds an edit at the top and runs a command.
  const end = view().state.doc.line(16).to;
  view().dispatch({ changes: { from: end, insert: '\n    zebra' }, selection: { anchor: end + 10 }, userEvent: 'input.type' });
  const option = () => [...document.querySelectorAll('.cm-tooltip-autocomplete li')].find((li) => li.textContent.includes('zebraFunction'));
  check('the extension\'s completion is offered', await until(() => !!option(), 5000), document.querySelector('.cm-tooltip-autocomplete')?.textContent);
  check('its documentation comes from resolveCompletionItem', await until(() => document.querySelector('.cm-completionInfo')?.textContent.includes('Resolved docs')), document.querySelector('.cm-completionInfo')?.textContent);
  [...document.querySelectorAll('.cm-tooltip-autocomplete li')].forEach((li, i) => { if (li === option()) for (let k = 0; k < i; k++) key('ArrowDown'); });
  // Past the list's last update (Enter right after one is ignored, so it doesn't accept the wrong item).
  await wait(500);
  key('Enter');
  check('accepting inserts it', await until(() => text().includes('    zebraFunction')), text().slice(-40));
  check('and applies its additional edit', await until(() => text().startsWith('-- imported\n-- Sample')), text().slice(0, 30));
  check('and runs its command', await until(async () => false, 400) || (await run('test.ran')).includes('accepted'), JSON.stringify(await run('test.ran')));

  // Go to Implementation.
  view().dispatch({ selection: { anchor: 0 } });
  await window.duocode.runCommand('editor.action.goToImplementation');
  const head = () => view().state.doc.lineAt(view().state.selection.main.head).number;
  check('Go to Implementations goes to the provider\'s location', await until(() => head() === 14), head());

  // Go to Symbol in Workspace: the query, then the list.
  const symbolSearch = window.duocode.runCommand('workbench.action.showAllSymbols');
  await until(() => document.querySelector('.qi-input'));
  const input = document.querySelector('.qi-input');
  input.value = 'draw';
  input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
  check('workspace symbols are listed', await until(() => [...document.querySelectorAll('.qi-item')].some((e) => e.textContent.includes('love.draw'))), document.querySelector('.qi')?.textContent);
  [...document.querySelectorAll('.qi-item')].find((e) => e.textContent.includes('love.draw')).click();
  await symbolSearch;
  check('and picking one goes there', await until(() => head() === 9), head());

  // Format Selection: the range formatter's edits.
  const line3 = view().state.doc.line(3);
  view().dispatch({ selection: { anchor: line3.from, head: line3.to } });
  await window.duocode.runCommand('editor.action.formatSelection');
  check('Format Selection applies the range formatter', await until(() => view().state.doc.line(3).text.startsWith('  local img')), view().state.doc.line(3).text);
});
