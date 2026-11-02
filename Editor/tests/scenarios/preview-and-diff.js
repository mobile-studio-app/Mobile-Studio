// Markdown preview, and the inline diff editor.
scenario(async () => {
  openFile('README.md');
  const button = document.getElementById('md-toggle');
  check('Markdown files get the preview button', await until(() => !button.hidden, 3000));
  button.click();
  const preview = document.getElementById('md-preview');
  check('the preview shows the heading', await until(() => (preview.querySelector('h1') || {}).textContent === 'My Game', 3000));
  check('task lists render as checkboxes', preview.querySelectorAll('input[type=checkbox]').length === 2);
  button.click();

  const original = window.__files['main.lua'];
  window.__files['main.lua'] = original.replace('function love.draw()\n', 'function love.draw()\n    love.graphics.setColor(1, 0, 0)\n');
  window.duocode.onEvent({ name: 'openDiff', payload: { path: 'main.lua', original, title: 'main.lua (Working Tree)' } });
  check('the diff marks the added line', await until(() => document.querySelectorAll('.cm-changedLine').length > 0, 3000));
  openFile('main.lua');
  check('opening the file normally drops the diff', await until(() => document.querySelectorAll('.cm-changedLine').length === 0, 3000));
});
