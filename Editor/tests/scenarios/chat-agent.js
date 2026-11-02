// The Chat agent: its tools, thinking, and what it sends the model. The model is faked: each
// request gets the next of `replies`.
scenario(async () => {
  const T = '```';
  const sent = [];
  const replies = [
    // Reasoning (with a tool block that must not run), then the read tools and run_program.
    '<think>Look around first. ' + T + 'tool\n{"tool": "write_file", "path": "evil.lua", "content": "x"}\n' + T + '</think>Let me look.\n'
      + T + 'tool\n{"tool": "find_files", "pattern": "*.lua"}\n' + T + '\n'
      + T + 'tool\n{"tool": "read_files", "paths": ["main.lua", "fx.lua"]}\n' + T + '\n'
      + T + 'tool\n{"tool": "search", "query": "rectange"}\n' + T + '\n'
      + T + 'tool\n{"tool": "read_console", "lines": 5}\n' + T + '\n'
      + T + 'tool\n{"tool": "read_output"}\n' + T + '\n'
      + T + 'tool\n{"tool": "run_program", "seconds": 3}\n' + T,
    // An edit, which Auto mode makes without asking.
    T + 'tool\n{"tool": "edit_file", "path": "main.lua", "old": "rectange", "new": "rectangle"}\n' + T,
    // A template that opened <think> itself leaves only the closing tag.
    'Reasoning in the template</think>Fixed: it was a typo.',
  ];
  window.__files['lib/util.lua'] = 'return {}\n';
  mockNative((m) => {
    if (m.cmd === 'aiChatModels') return { selected: 'qwen3-4b', mode: 'auto', thinking: false, contextSize: 8192,
      models: [{ id: 'apple', name: 'Apple Intelligence', detail: '', ready: true, contexts: [{ tokens: 4096, bytes: 0, fits: true }] },
        { id: 'qwen3-4b', name: 'Qwen3 4B', detail: '', ready: true, contexts: [{ tokens: 4096, bytes: 1e9, fits: true }, { tokens: 8192, bytes: 2e9, fits: true }] }] };
    if (m.cmd === 'programConsole') return 'line a\nline b';
    if (m.cmd === 'runProgram') return { output: 'hello\n', exitCode: null, stillRunning: true };
    if (m.cmd === 'aiChat') {
      sent.push(m);
      const answer = replies[Math.min(sent.length - 1, replies.length - 1)];
      setTimeout(() => window.duocode.onEvent({ name: 'aiChatText', payload: { id: m.id, text: answer.slice(0, 20) } }), 10);
      setTimeout(() => window.duocode.onEvent({ name: 'aiChatDone', payload: { id: m.id, text: answer } }), 40);
      return true;
    }
    return undefined;
  });

  openFile('main.lua');
  await until(() => view().state.doc.toString().startsWith('-- Sample'));
  document.getElementById('chat-toggle').click();
  check('the chat opens', await until(() => !document.getElementById('chat-pane').hidden, 2000));
  await until(() => document.getElementById('chat-mode').value === 'auto', 2000);
  const think = document.getElementById('chat-think');
  check('the Think toggle starts off', think && !think.classList.contains('on'));

  const box = document.getElementById('chat-text');
  box.value = 'Fix the typo and check the game runs';
  box.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
  await until(() => sent.length >= 3 && document.getElementById('chat-send').textContent === 'Send', 8000);
  check('three model requests (tools, edit, answer)', sent.length === 3, sent.length);

  const system = sent[0].messages[0].content;
  check('the instructions list the project\'s files', /The project's files \(\d+\)/.test(system) && system.includes('lib/util.lua'));
  check('the instructions describe the new tools', ['read_files', 'find_files', 'read_console', 'read_terminal', 'read_output', 'run_program'].every((t) => system.includes(t)));
  check('Qwen3 is told not to think while Think is off', system.includes('/no_think'));
  check('the open file goes with the question', /The open file is main\.lua/.test(sent[0].messages[1].content));

  const results = (sent[1].messages.find((x) => x.content.startsWith('Tool results')) || {}).content || '';
  check('find_files matches the glob', /find_files: main\.lua\nbroken\.lua\nfx\.lua\nlib\/util\.lua/.test(results), results.slice(0, 200));
  check('read_files reads each file', results.includes('== main.lua ==') && results.includes('== fx.lua =='));
  check('search finds the line', /search: main\.lua:10: /.test(results));
  check('read_console returns the console', results.includes('line a\nline b'));
  check('read_output lists the channels', /read_output: /.test(results));
  check('run_program reports the output and that it was stopped', /run_program: It was still running after 3 s, so it was stopped\.\nConsole output:\nhello/.test(results));
  check('a tool block inside the reasoning doesn\'t run', !('evil.lua' in window.__files));
  const history = sent[1].messages.find((x) => x.role === 'assistant');
  check('the reasoning isn\'t kept in the conversation', history && !history.content.includes('<think>') && history.content.startsWith('Let me look.'));
  check('Auto mode edits without asking', window.__files['main.lua'].includes('love.graphics.rectangle(') || view().state.doc.toString().includes('love.graphics.rectangle('));
  check('reasoning shows folded', document.querySelectorAll('.chat-thinking').length >= 2);
  const answers = [...document.querySelectorAll('.chat-message.assistant .chat-body > p')];
  check('the final answer shows', (answers.pop() || {}).textContent === 'Fixed: it was a typo.');

  // Think on: saved, Qwen3 reasons by itself (no /no_think), with a bigger answer budget.
  think.click();
  await wait(100);
  check('Think turns on', think.classList.contains('on'));
  const saved = window.__native.filter((n) => n.cmd === 'aiChatSettings').pop();
  check('Think is saved', saved && saved.thinking === true, JSON.stringify(saved));
  box.value = 'again';
  box.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
  await until(() => sent.length >= 4, 4000);
  check('with Think on Qwen3 isn\'t told /no_think', !sent[3].messages[0].content.includes('/no_think'));
  check('with Think on answers can be longer', sent[3].maxTokens === 3072, sent[3].maxTokens);
  await until(() => document.getElementById('chat-send').textContent === 'Send', 4000);

  // Apple Intelligence: asked to reason, and its context is fixed.
  const model = document.getElementById('chat-model');
  model.value = 'apple';
  model.dispatchEvent(new Event('change'));
  box.value = 'third';
  box.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
  await until(() => sent.length >= 5, 4000);
  check('other models are asked to reason when Think is on', sent[4].messages[0].content.includes('Think before you answer'));
  document.getElementById('chat-settings').hidden = false;
  check('Apple Intelligence\'s context says it\'s fixed', /fixed for Apple Intelligence/.test(document.querySelector('#chat-settings select').textContent));
});
