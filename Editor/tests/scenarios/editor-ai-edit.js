// The editor's context menu (a right click, or a finger held still) and Edit with AI (⌘I): a change
// written by the Chat model, shown as a diff to accept or reject. The model is faked.
scenario(async () => {
  const sent = [];
  let answer = '```lua\n    love.graphics.rectangle("fill", 10, 10, 50, 50)\n```';
  mockNative((m) => {
    if (m.cmd === 'aiChatModels') return { selected: 'qwen3.5-4b', mode: 'edit', contextSize: 8192, kvBits: 8,
      models: [{ id: 'qwen3.5-4b', name: 'Standard', detail: 'Qwen3.5 4B', ready: true, agent: true, reasoning: 'optional', contexts: [{ tokens: 8192, bytes: 1e9, fits: true }] }] };
    if (m.cmd === 'aiChat') {
      sent.push(m);
      setTimeout(() => window.duocode.onEvent({ name: 'aiChatDone', payload: { id: m.id, text: answer } }), 30);
      return true;
    }
    return undefined;
  });
  openFile('main.lua');
  await until(() => view().state.doc.toString().startsWith('-- Sample'));
  const v = view();
  const coordsOf = (text) => { const at = v.state.doc.toString().indexOf(text); return v.coordsAtPos(at + 2); };
  const items = () => [...document.querySelectorAll('.ctx-menu .ctx-item')];
  const item = (label) => items().find((e) => e.querySelector('.ctx-label').textContent === label);

  // Right click.
  const at = coordsOf('love.graphics.draw');
  v.contentDOM.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true, clientX: at.left, clientY: at.top + 2 }));
  check('a right click opens the context menu', await until(() => items().length > 5, 1000));
  const labels = items().map((e) => e.querySelector('.ctx-label').textContent);
  check('with VS Code\'s editor items', ['Go to Definition', 'Rename Symbol', 'Format Document', 'Edit with AI…', 'Copy', 'Paste', 'Command Palette…'].every((l) => labels.includes(l)), labels.join(' | '));
  check('Cut and Copy are off without a selection', item('Copy').getAttribute('aria-disabled') === 'true');
  check('a symbol with docs gets Show Docs first', await until(() => labels.length && items()[0].textContent === 'Show Docs', 1000), items().map((e) => e.textContent).slice(0, 2).join(' | '));
  items()[0].click();
  check('which opens them', await until(() => document.querySelector('.dc-sheet'), 1000));
  document.querySelector('.dc-close')?.click();
  check('the menu closes after picking', !document.querySelector('.ctx-menu'));

  // A finger held still (where touch events can be made).
  let touched = false;
  try {
    const p = coordsOf('love.graphics.print');
    const touch = new Touch({ identifier: 1, target: v.contentDOM, clientX: p.left, clientY: p.top + 2 });
    v.contentDOM.dispatchEvent(new TouchEvent('touchstart', { bubbles: true, cancelable: true, touches: [touch], targetTouches: [touch], changedTouches: [touch] }));
    touched = true;
    await wait(600);
    check('holding a finger still opens the menu', items().length > 5);
    const end = new TouchEvent('touchend', { bubbles: true, cancelable: true, touches: [], changedTouches: [touch] });
    v.contentDOM.dispatchEvent(end);
    check('and the press\'s end is swallowed, so iOS shows nothing of its own', end.defaultPrevented);
    document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
    check('Escape closes it', !document.querySelector('.ctx-menu'));
  } catch (e) {
    if (touched) throw e;
  }

  // Edit with AI, from the menu, on a selected line.
  const line = v.state.doc.line(10);
  v.dispatch({ selection: { anchor: line.from + 4, head: line.to } });
  v.contentDOM.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true, clientX: at.left, clientY: v.coordsAtPos(line.from + 6).top + 2 }));
  await until(() => item('Edit with AI…'), 1000);
  check('with a selection, Copy is on', item('Copy').getAttribute('aria-disabled') !== 'true');
  item('Edit with AI…').click();
  const input = () => document.querySelector('.cm-ai-input');
  check('Edit with AI asks what to change', await until(() => input(), 1000) && input().placeholder.includes('describe the change'));
  input().value = 'fix the typo';
  input().dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
  await until(() => document.querySelector('.cm-ai-review'), 3000);
  const prompt = sent[0] && sent[0].messages.map((x) => x.content).join('\n');
  check('the model gets the line marked, the file around it and the instruction', prompt && prompt.includes('<<<CHANGE>>>\n    love.graphics.rectange("fill"') && prompt.includes('function love.update') && prompt.includes('Instruction: fix the typo'));
  check('the change shows as a diff', v.state.doc.line(10).text === '    love.graphics.rectangle("fill", 10, 10, 50, 50)'
    && document.querySelectorAll('.cm-ai-added').length === 1 && document.querySelector('.cm-ai-removed').textContent.includes('rectange'));
  [...document.querySelectorAll('.cm-ai-button')].find((b) => b.textContent === 'Reject').click();
  await wait(50);
  check('Reject puts it back', v.state.doc.line(10).text.includes('rectange') && !document.querySelector('.cm-ai-edit'));

  // Again, with Try Again then Accept.
  v.dispatch({ selection: { anchor: line.from, head: line.to } });
  v.focus();
  v.contentDOM.dispatchEvent(new KeyboardEvent('keydown', { key: 'i', ...(/Mac|iPhone|iPad/.test(navigator.platform) ? { metaKey: true } : { ctrlKey: true }), bubbles: true, cancelable: true }));
  check('⌘I starts an edit', await until(() => input(), 1000));
  input().value = 'fix it';
  input().dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
  await until(() => document.querySelector('.cm-ai-review'), 3000);
  [...document.querySelectorAll('.cm-ai-button')].find((b) => b.textContent === 'Try Again').click();
  await until(() => input(), 1000);
  check('Try Again goes back to the instruction, with the original', input().value === 'fix it' && v.state.doc.line(10).text.includes('rectange'));
  input().dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
  await until(() => document.querySelector('.cm-ai-review'), 3000);
  [...document.querySelectorAll('.cm-ai-button')].find((b) => b.textContent === 'Accept').click();
  await wait(50);
  check('Accept keeps it', v.state.doc.line(10).text.includes('rectangle(') && !document.querySelector('.cm-ai-edit') && !document.querySelector('.cm-ai-added'));

  // With nothing selected: code written at the cursor's line.
  answer = '```lua\n-- a comment\n```';
  v.dispatch({ selection: { anchor: v.state.doc.line(13).from } });
  v.contentDOM.dispatchEvent(new KeyboardEvent('keydown', { key: 'i', ...(/Mac|iPhone|iPad/.test(navigator.platform) ? { metaKey: true } : { ctrlKey: true }), bubbles: true, cancelable: true }));
  await until(() => input(), 1000);
  check('with nothing selected it writes new code', input().placeholder.includes('Write code here'));
  input().value = 'add a comment';
  input().dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
  await until(() => document.querySelector('.cm-ai-review'), 3000);
  check('inserted at that line, without replacing it', v.state.doc.line(13).text === '-- a comment' && v.state.doc.line(14).text === '' && !document.querySelector('.cm-ai-removed'));
  v.contentDOM.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true, cancelable: true }));
  await wait(50);
  check('Escape rejects it', v.state.doc.line(13).text === '' && !document.querySelector('.cm-ai-edit'));
});
