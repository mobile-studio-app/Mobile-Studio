// The Chat agent's file tools, the tool call formats models write, what happens to calls that
// can't be read, and subagents on Apple Intelligence. The model is faked: each request gets the
// next of `replies` (subagents' requests, which name their model, get `subagentReply`).
scenario(async () => {
  const T = '```';
  const call = (name, args) => `<tool_call>\n<function=${name}>\n${Object.entries(args).map(([k, v]) => `<parameter=${k}>\n${v}\n</parameter>\n`).join('')}</function>\n</tool_call>`;
  const sent = [];
  const subagentSent = [];
  const replies = [
    // Qwen's own format, with code that would need escaping in JSON; then the line tools.
    'Making the game.\n'
      + call('write_file', { path: 'src/game.lua', content: 'local Game = {}\n\nfunction Game.title()\n  return "It\'s \\"on\\""\nend\n\nreturn Game' })
      + call('insert_lines', { path: 'src/game.lua', line: 2, content: '-- the game' })
      + call('replace_lines', { path: 'src/game.lua', start_line: 4, end_line: 6, content: 'function Game.title()\n  return "Game"\nend' })
      + call('append_file', { path: 'src/game.lua', content: '-- end' })
      + call('delete_lines', { path: 'src/game.lua', start_line: 9, end_line: 9 }),
    // Hermes JSON with a raw newline in it, an edit whose indentation is off, and a bare JSON call.
    '<tool_call>\n{"name": "copy_file", "arguments": {"from": "src/game.lua", "to": "src/copy.lua"}}\n</tool_call>\n'
      + T + 'tool\n{"tool": "edit_file", "path": "main.lua", "old": "\tlove.graphics.draw(img, 100, 100)\nend", "new": "\tlove.graphics.draw(img, 200, 200)\nend"}\n' + T + '\n'
      + 'and {"tool": "create_folder", "path": "assets"}',
    // A move, then a delete, which Auto mode asks about.
    call('move_file', { from: 'src/copy.lua', to: 'lib/copy.lua' }) + call('delete_file', { path: 'lib/copy.lua' }),
    // A call that can't be read: it goes back to the model rather than ending the turn.
    T + 'tool\n{"tool": "read_file", "path": "main.lua", start_line: }\n' + T,
    // The model invents the result after its call: cut off.
    call('read_file', { path: 'main.lua', start_line: 9, end_line: 10 }) + '\n<tool_response>\nmade up\n</tool_response>\nAll done!',
    // A call cut off by the answer's length.
    '<tool_call>\n<function=write_file>\n<parameter=path>\nbig.lua\n</parameter>\n<parameter=content>\nlocal x = 1\nlocal y',
    // Research for the subagents.
    call('delegate', { tasks: '["Where is love.draw?", "What does fx.lua do?"]' }),
    'Done: the game is in src/game.lua.',
  ];
  const subagentReply = (m) => (m.messages.length === 2 ? call('search', { query: 'love.draw' }) : 'love.draw is in main.lua:9.');
  const models = [
    { id: 'apple', name: 'Apple Intelligence', detail: '', ready: true, agent: false, subagent: true, reasoning: 'none', contexts: [{ tokens: 4096, bytes: 0, fits: true }] },
    { id: 'qwen3.5-9b', name: 'Qwen3.5 9B', detail: '', ready: true, agent: true, subagent: true, reasoning: 'optional', contexts: [{ tokens: 16384, bytes: 1e9, fits: true }] },
  ];
  mockNative((m) => {
    if (m.cmd === 'aiChatModels') return { selected: 'qwen3.5-9b', mode: 'auto', thinking: false, contextSize: 16384, kvBits: 8, subagentModel: 'apple', subagentParallel: 2, subagentContextSize: 4096, models };
    if (m.cmd === 'aiChat') {
      const forSubagent = m.model === 'apple';
      (forSubagent ? subagentSent : sent).push(m);
      const answer = forSubagent ? subagentReply(m) : replies[Math.min(sent.length - 1, replies.length - 1)];
      setTimeout(() => window.duocode.onEvent({ name: 'aiChatDone', payload: { id: m.id, text: answer, dropped: 0 } }), 20);
      return true;
    }
    return undefined;
  });

  openFile('fx.lua');
  await until(() => view().state.doc.toString().includes('newShader'));
  document.getElementById('chat-toggle').click();
  await until(() => document.getElementById('chat-mode').value === 'auto', 3000);
  const box = document.getElementById('chat-text');
  box.value = 'Make a game module';
  box.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));

  // The delete waits for approval.
  const deleteCard = () => [...document.querySelectorAll('.chat-approval')].find((c) => /Delete lib\/copy\.lua\?/.test(c.textContent));
  await until(deleteCard, 8000);
  const approve = deleteCard();
  check('deleting asks first in Auto mode', !!approve, `${sent.length} requests; ${JSON.stringify((sent[sent.length - 1]?.messages || []).slice(-1)).slice(0, 400)}`);
  check('the move ran before it', 'lib/copy.lua' in window.__files && !('src/copy.lua' in window.__files));
  if (approve) [...approve.querySelectorAll('button')].find((b) => b.textContent === 'Allow').click();
  await until(() => sent.length >= replies.length && document.getElementById('chat-send').textContent === 'Send', 10000);

  const system = sent[0].messages[0].content;
  check('the instructions show Qwen\'s own call format', system.includes('<function=edit_file>') && system.includes('<parameter=path>'));
  check('the instructions list the file tools', ['insert_lines', 'replace_lines', 'delete_lines', 'append_file', 'move_file', 'copy_file', 'delete_file', 'create_folder'].every((t) => system.includes(t)));

  const results = (i) => (sent[i].messages.filter((x) => x.content.startsWith('Tool results')).pop() || {}).content || '';
  check('the file was written, edited by line, appended to and trimmed', window.__files['src/game.lua']
    === 'local Game = {}\n-- the game\n\nfunction Game.title()\n  return "Game"\nend\n\nreturn Game\n', JSON.stringify(window.__files['src/game.lua']));
  check('each change shows the lines as they now are', /Lines \d+-\d+ now read:\n\d+\t/.test(results(1)) && /src\/game\.lua has \d+ lines/.test(results(1)));
  check('Hermes\' JSON format runs', results(2).includes('copy_file: Copied src/game.lua to src/copy.lua.'), results(2).slice(0, 300));
  check('an edit copied with the wrong indentation still applies, indented as the file is',
    window.__files['main.lua'].includes('\n    love.graphics.draw(img, 200, 200)\nend\n'), results(2).slice(0, 400));
  check('a bare JSON call runs too', /create_folder: Created the folder assets/.test(results(2)), results(2));
  check('the file was deleted once allowed', !('lib/copy.lua' in window.__files));

  check('a call that can\'t be read goes back to the model', /couldn't be run: its JSON couldn't be read/.test(results(4)) && results(4).includes('<function=edit_file>'), results(4).slice(0, 300));
  const invented = sent[5].messages.filter((x) => x.role === 'assistant').pop();
  check('what the model invents after a call is cut', invented && !invented.content.includes('made up') && !invented.content.includes('All done'));
  check('and the real result comes back', /read_file: main\.lua \(lines 9-10 of \d+\):\n9\tfunction love\.draw\(\)/.test(results(5)), results(5).slice(0, 200));
  check('a call cut off by the answer\'s length isn\'t run, and the model is told to write in parts', !('big.lua' in window.__files && window.__files['big.lua'].includes('local y'))
    && /cut off in the middle of a tool call/.test(results(6)) && results(6).includes('append_file'), results(6).slice(0, 300));

  check('subagents use Apple Intelligence', subagentSent.length >= 4 && subagentSent.every((m) => m.model === 'apple' && m.contextSize === 4096));
  check('subagents only get the read tools', !subagentSent[0].messages[0].content.includes('write_file') && subagentSent[0].messages[0].content.includes('search('));
  check('their answers reach the agent', /Answer: love\.draw is in main\.lua:9\./.test(results(7)), results(7).slice(0, 300));
  const shown = [...document.querySelectorAll('.chat-message.assistant .chat-body')].map((b) => b.textContent).join('\n');
  check('calls show as chips, not as text', !/<function=|<parameter=|"tool":/.test(shown) && document.querySelectorAll('.chat-chip').length >= 8, shown.slice(0, 300));
  check('the final answer shows', shown.includes('Done: the game is in src/game.lua.'));
});
