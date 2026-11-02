// The merge editor with git's information: diff3 markers (the common ancestor), each side named,
// what's being done, and the whole file from either side.
scenario(async () => {
  window.__files['game.lua'] = [
    'local speed = 1',
    '<<<<<<< HEAD',
    'local jump = 200',
    '||||||| merged common ancestor',
    'local jump = 100',
    '=======',
    'local jump = 150',
    '>>>>>>> feature',
    'return speed',
    '',
  ].join('\n');
  mockNative((m) => {
    if (m.cmd === 'conflictInfo') return { inMerge: true, operation: 'merge', oursLabel: 'main', theirsLabel: 'feature' };
    if (m.cmd === 'conflictVersions') return { base: 'local jump = 100\n', ours: 'local speed = 1\nlocal jump = 200\nreturn speed\n', theirs: 'local speed = 2\nlocal jump = 150\nreturn speed\n' };
    return undefined;
  });
  openFile('game.lua');
  check('the conflict shows its actions', await until(() => document.querySelector('.cm-conflict-actions'), 4000),
    JSON.stringify(view().state.doc.toString().slice(0, 80)));
  const labels = () => [...document.querySelectorAll('.cm-conflict-label')].map((e) => e.textContent);
  check('the sides are named once the app says', await until(() => labels().includes('(Current Change: main)'), 3000), labels().join(' | '));
  check('the incoming side too', labels().includes('(Incoming Change: feature)'), labels().join(' | '));
  check('the common ancestor is shown', labels().includes('(Common Ancestor)') && document.querySelector('.cm-conflict-base'), labels().join(' | '));
  const bar = document.querySelector('.merge-bar');
  check('the bar says what is being done', /^Merge: 1 of 1 conflict/.test(bar.querySelector('.merge-count').textContent), bar.querySelector('.merge-count').textContent);

  // Accept Current keeps ours, without the ancestor's lines.
  const before = view().state.doc.toString();
  [...document.querySelectorAll('.cm-conflict-actions button')].find((b) => b.textContent === 'Accept Current Change').click();
  await wait(100);
  check('Accept Current keeps the current side only', view().state.doc.toString() === 'local speed = 1\nlocal jump = 200\nreturn speed\n', JSON.stringify(view().state.doc.toString()));
  view().dispatch({ changes: { from: 0, to: view().state.doc.length, insert: before } });
  await wait(100);

  // The whole incoming file, from git's own copy.
  bar.querySelector('.merge-icon[title="More Actions"]').click();
  await wait(100);
  const items = [...document.querySelectorAll('.merge-menu-item')].map((b) => b.textContent);
  check('whole-file choices are offered', ['Compare Current and Incoming', 'Take Current File', 'Take Incoming File'].every((t) => items.includes(t)), items.join(', '));
  [...document.querySelectorAll('.merge-menu-item')].find((b) => b.textContent === 'Take Incoming File').click();
  await until(() => view().state.doc.toString().startsWith('local speed = 2'), 2000);
  check('Take Incoming File puts in their whole file', view().state.doc.toString() === 'local speed = 2\nlocal jump = 150\nreturn speed\n');
  check('and the bar offers Mark as Resolved', await until(() => !bar.querySelector('.merge-button.primary:last-child').hidden, 2000));
});
