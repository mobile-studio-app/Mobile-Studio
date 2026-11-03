// A web extension using more of the vscode API: activation by the project's files, quick picks
// made with createQuickPick, workspace edits that create and rename files (and the file watchers
// that hear them), text editor commands, secrets, virtual documents, progress, the selection, the
// execute*Provider commands and the namespaces that only need to exist (tests, comments, lm).
const EXTENSION = `
const vscode = require('vscode');
const events = [];
exports.activate = function (context) {
  const item = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 10);
  item.text = 'API test';
  item.command = { command: 'test.echo', arguments: ['from the status bar'] };
  item.show();

  const watcher = vscode.workspace.createFileSystemWatcher('**/*.txt');
  watcher.onDidCreate((u) => events.push('create ' + vscode.workspace.asRelativePath(u)));
  watcher.onDidDelete((u) => events.push('delete ' + vscode.workspace.asRelativePath(u)));
  vscode.workspace.onDidRenameFiles((e) => events.push('rename ' + e.files.map((f) => vscode.workspace.asRelativePath(f.newUri)).join()));

  context.subscriptions.push(
    vscode.commands.registerCommand('test.echo', (x) => { events.push('echo ' + x); return x; }),
    vscode.commands.registerCommand('test.events', () => events.slice()),
    vscode.commands.registerCommand('test.quickPick', () => new Promise((resolve) => {
      const pick = vscode.window.createQuickPick();
      pick.placeholder = 'Pick a fruit';
      pick.busy = true;
      pick.onDidAccept(() => { resolve(pick.selectedItems.map((i) => i.label)); pick.dispose(); });
      pick.onDidHide(() => resolve(null));
      pick.show();
      // Items arriving after show(), as extensions often do.
      setTimeout(() => { pick.items = [{ label: 'apple' }, { label: 'fruits', kind: vscode.QuickPickItemKind.Separator }, { label: 'banana' }]; pick.busy = false; }, 300);
    })),
    vscode.commands.registerCommand('test.files', async () => {
      const root = vscode.workspace.workspaceFolders[0].uri;
      const edit = new vscode.WorkspaceEdit();
      edit.createFile(vscode.Uri.joinPath(root, 'made.txt'), { contents: new TextEncoder().encode('made by an extension') });
      edit.renameFile(vscode.Uri.joinPath(root, 'made.txt'), vscode.Uri.joinPath(root, 'moved.txt'));
      return vscode.workspace.applyEdit(edit);
    }),
    vscode.commands.registerTextEditorCommand('test.header', (editor, edit) => {
      edit.insert(new vscode.Position(0, 0), '-- header\\n');
    }),
    vscode.commands.registerCommand('test.secrets', async () => {
      await context.secrets.store('token', 's3cret');
      const got = await context.secrets.get('token');
      await context.secrets.delete('token');
      return [got, await context.secrets.get('token')];
    }),
    vscode.commands.registerCommand('test.select', () => {
      const editor = vscode.window.activeTextEditor;
      editor.selection = new vscode.Selection(4, 0, 4, 8);
      return true;
    }),
    vscode.workspace.registerTextDocumentContentProvider('test-virtual', {
      provideTextDocumentContent: (uri) => 'virtual content for ' + uri.path,
    }),
    vscode.commands.registerCommand('test.virtual', async () => {
      const doc = await vscode.workspace.openTextDocument(vscode.Uri.parse('test-virtual:/notes.md'));
      await vscode.window.showTextDocument(doc);
      return doc.getText();
    }),
    vscode.commands.registerCommand('test.progress', () => vscode.window.withProgress(
      { location: vscode.ProgressLocation.Notification, title: 'Indexing', cancellable: true },
      (progress, token) => new Promise((resolve) => {
        progress.report({ message: 'files', increment: 50 });
        token.onCancellationRequested(() => resolve('cancelled'));
        setTimeout(() => resolve('finished'), 4000);
      }),
    )),
    vscode.languages.registerHoverProvider('lua', { provideHover: () => new vscode.Hover('a hover') }),
    vscode.commands.registerCommand('test.providers', async () => {
      const uri = vscode.window.activeTextEditor.document.uri;
      const hovers = await vscode.commands.executeCommand('vscode.executeHoverProvider', uri, new vscode.Position(0, 1));
      return hovers.map((h) => h.contents.map((c) => c.value ?? c).join());
    }),
    vscode.commands.registerCommand('test.misc', async () => {
      const controller = vscode.tests.createTestController('t', 'Tests');
      controller.items.add(controller.createTestItem('a', 'A'));
      const scm = vscode.scm.createSourceControl('s', 'S');
      scm.inputBox.value = 'message';
      return {
        l10n: vscode.l10n.t('Hello {name}, {0}', { name: 'you', 0: 'zero' }),
        tests: controller.items.size,
        scm: scm.inputBox.value,
        cancel: new vscode.CancellationError() instanceof Error,
        models: (await vscode.lm.selectChatModels()).length,
        commands: (await vscode.commands.getCommands(true)).includes('test.echo'),
        terminals: Array.isArray(vscode.window.terminals),
        theme: vscode.window.activeColorTheme.kind,
      };
    }),
  );
};
`;

const MANIFEST = {
  name: 'api-test', publisher: 'test', version: '1.0.0', browser: './extension.js',
  activationEvents: ['workspaceContains:**/*.lua'],
  contributes: { commands: [{ command: 'test.echo', title: 'Echo' }] },
};

scenario(async () => {
  const files = window.__files;
  const secrets = new Map();
  mockNative((m) => {
    if (m.cmd === 'extList') return [{ id: 'test.api-test', manifest: MANIFEST }];
    if (m.cmd === 'extRead' && m.id === 'test.api-test') {
      if (m.path === 'extension.js') return EXTENSION;
      throw new Error('not found');
    }
    if (m.cmd === 'extHostInit') return { project: 'game', configuration: {}, state: {} };
    if (m.cmd === 'extSecret') {
      if (m.op === 'store') { secrets.set(m.key, m.value); return true; }
      if (m.op === 'get') return secrets.has(m.key) ? secrets.get(m.key) : null;
      if (m.op === 'delete') { secrets.delete(m.key); return true; }
      return [...secrets.keys()];
    }
    if (m.cmd === 'fs') {
      if (m.op === 'stat') { if (m.path in files) return { type: 1, size: files[m.path].length, mtime: 0, ctime: 0 }; throw new Error('not found'); }
      if (m.op === 'write') { files[m.path] = atob(m.base64); return true; }
      if (m.op === 'read') { if (m.path in files) return btoa(files[m.path]); throw new Error('not found'); }
      if (m.op === 'delete') { delete files[m.path]; return true; }
      if (m.op === 'rename') { files[m.to] = files[m.path]; delete files[m.path]; return true; }
    }
    return undefined;
  });
  const run = (name, ...args) => window.duocode.runCommand(name, ...args);

  openFile('main.lua');
  await until(() => view().state.doc.toString().startsWith('-- Sample'));
  window.duocode.onEvent({ name: 'extensionsChanged', payload: {} });

  // workspaceContains: activates it without any command being run.
  const status = () => document.getElementById('ext-status')?.textContent || '';
  check('workspaceContains: activates the extension', await until(() => status().includes('API test'), 8000), status());

  document.querySelector('.ext-status-item').click();
  await until(async () => false, 300);
  check('a status bar item\'s command runs with its arguments', (await run('test.events')).includes('echo from the status bar'), JSON.stringify(await run('test.events')));

  // createQuickPick: shown once its items arrive; separators aren't choices.
  const picked = run('test.quickPick');
  check('a quick pick made with createQuickPick shows', await until(() => document.querySelectorAll('.qi-item').length === 2), document.querySelectorAll('.qi-item').length);
  const labels = [...document.querySelectorAll('.qi-item')].map((e) => e.textContent);
  check('with its items (not the separator)', labels.some((l) => l.includes('apple')) && labels.some((l) => l.includes('banana')), labels.join('|'));
  [...document.querySelectorAll('.qi-item')].find((e) => e.textContent.includes('banana')).click();
  check('and onDidAccept has the selected item', JSON.stringify(await picked) === '["banana"]', JSON.stringify(await picked));

  // WorkspaceEdit file operations, heard by the file watcher and onDidRenameFiles.
  check('a workspace edit creates and renames a file', await run('test.files') === true);
  check('the file is there, renamed', files['moved.txt'] === 'made by an extension' && !('made.txt' in files), JSON.stringify(Object.keys(files)));
  const events = await run('test.events');
  check('file watchers hear the create, delete and rename', ['create made.txt', 'delete made.txt', 'rename moved.txt'].every((e) => events.includes(e)), JSON.stringify(events));

  // registerTextEditorCommand: the edit builder's edits are applied.
  await run('test.header');
  check('a text editor command\'s edits apply', await until(() => view().state.doc.toString().startsWith('-- header\n-- Sample')), view().state.doc.toString().slice(0, 30));

  check('secrets are stored, read and deleted', JSON.stringify(await run('test.secrets')) === '["s3cret",null]', JSON.stringify(await run('test.secrets')));

  // Setting the selection moves the editor's.
  await run('test.select');
  const line = () => view().state.doc.lineAt(view().state.selection.main.head).number;
  check('setting TextEditor.selection selects in the editor', await until(() => line() === 5 && !view().state.selection.main.empty), `${line()} ${view().state.selection.main.from}-${view().state.selection.main.to}`);

  // vscode.execute*Provider commands.
  const hovers = await run('test.providers');
  check('vscode.executeHoverProvider answers from the providers', JSON.stringify(hovers) === '["a hover"]', JSON.stringify(hovers));

  const misc = (await run('test.misc')) || {};
  check('l10n.t fills named and numbered arguments', misc.l10n === 'Hello you, zero', misc.l10n);
  check('the tests namespace keeps test items', misc.tests === 1, misc.tests);
  check('source controls have an input box', misc.scm === 'message', misc.scm);
  check('CancellationError is an Error', misc.cancel === true);
  check('lm finds no models (rather than throwing)', misc.models === 0, misc.models);
  check('getCommands lists the extension\'s commands', misc.commands === true);
  check('window.terminals is a list', misc.terminals === true);
  check('activeColorTheme is dark with the dark theme', misc.theme === 2, misc.theme);

  // withProgress: in the status bar, and cancellable from there.
  const progress = run('test.progress');
  check('withProgress shows in the status bar', await until(() => status().includes('Indexing files 50%')), status());
  [...document.querySelectorAll('.ext-status-item')].find((e) => e.textContent.includes('Indexing')).click();
  check('tapping it cancels the task', await progress === 'cancelled');
  check('and it goes once the task ends', await until(() => !status().includes('Indexing')), status());

  // A content provider's virtual document: read-only, in its own tab.
  const text = await run('test.virtual');
  check('a virtual document has its provider\'s text', text === 'virtual content for /notes.md', text);
  check('and shows read-only in the editor', await until(() => view().state.doc.toString() === 'virtual content for /notes.md' && view().state.readOnly), view().state.doc.toString().slice(0, 40));
  check('in a tab of its own', [...document.querySelectorAll('#tabs .tab, #tabs [class*="tab"]')].some((t) => t.textContent.includes('notes.md')));
});
