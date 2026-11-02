// Opening files, diagnostics, find, and tabs.
scenario(async () => {
  openFile('main.lua');
  await until(() => view().state.doc.toString().startsWith('-- Sample'));
  check('opens main.lua', view().state.doc.toString().startsWith('-- Sample'));
  // love.graphics.rectange is a typo: LÖVE has no such function.
  const flagged = await until(() => document.querySelectorAll('.cm-lintRange-warning, .cm-lintRange-error').length > 0, 6000);
  check('flags the unknown LÖVE function', flagged);

  openFile('broken.lua');
  check('a syntax error is an error', await until(() => document.querySelectorAll('.cm-lintRange-error').length > 0, 6000));

  openFile('conf.json');
  check('JSON with a trailing comma is an error', await until(() => document.querySelectorAll('.cm-lintRange-error').length > 0, 6000));

  // Find (⌘F): counts the matches.
  openFile('main.lua');
  await until(() => view().state.doc.toString().startsWith('-- Sample'));
  view().focus();
  view().contentDOM.dispatchEvent(new KeyboardEvent('keydown', { key: 'f', code: 'KeyF', keyCode: 70, ctrlKey: true, metaKey: false, bubbles: true, cancelable: true }));
  const input = await until(() => document.querySelector('.dc-find-input'), 3000) && document.querySelector('.dc-find-input');
  check('find opens', !!input);
  if (input) {
    input.value = 'love.graphics';
    input.dispatchEvent(new Event('input', { bubbles: true }));
    await wait(400);
    const count = document.querySelector('.dc-find-count').textContent;
    check('find counts the matches', /\b4\b/.test(count), count);
    input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
  }

  // Tabs: a preview tab is replaced; an edited one stays and is saved.
  const tabs = () => [...document.querySelectorAll('.tab')].map((t) => t.querySelector('.tab-name').textContent);
  openFile('fx.lua');
  await until(() => view().state.doc.toString().startsWith('local shader'));
  view().dispatch({ changes: { from: 0, insert: '-- hi\n' } });
  await wait(100);
  openFile('README.md');
  await until(() => tabs().includes('README.md'));
  check('an edited tab stays open', tabs().includes('fx.lua'), tabs().join(', '));
  check('the edit is saved (auto save)', await until(() => window.__files['fx.lua'].startsWith('-- hi'), 4000),
    JSON.stringify(window.__native.filter((n) => n.cmd === 'write').map((n) => n.path + ':' + n.contents.slice(0, 10))));
  const before = tabs().length;
  document.querySelector('.tab.active .tab-close').click();
  await wait(300);
  check('closing a tab removes it', tabs().length === before - 1 && !tabs().includes('README.md'), tabs().join(', '));
});
