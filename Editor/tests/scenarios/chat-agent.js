// The Chat agent: its tools, thinking, and what it sends the model. The model is faked: each
// request gets the next of `replies`.
scenario(async () => {
  const T = '```';
  const sent = [];
  const replies = [
    // Reasoning (with a tool block that must not run), then the read tools and run_program.
    '<think>Look around first. ' + T + 'tool\n{"tool": "write_file", "path": "evil.lua", "content": "x"}\n' + T + '</think>Let me look.\n'
      + T + 'tool\n{"tool": "find_files", "pattern": "*.lua"}\n' + T + '\n'
      + T + 'tool\n{"tool": "read_files", "paths": ["main.lua", "fx.lua", "big.lua"]}\n' + T + '\n'
      + T + 'tool\n{"tool": "search", "query": "rectange"}\n' + T + '\n'
      + T + 'tool\n{"tool": "read_console", "lines": 5}\n' + T + '\n'
      + T + 'tool\n{"tool": "read_output"}\n' + T + '\n'
      + T + 'tool\n{"tool": "run_program", "seconds": 3}\n' + T,
    // The same search again: caught as a repeat.
    '<think>Search again.</think>' + T + 'tool\n{"tool": "search", "query": "rectange"}\n' + T,
    // An edit, which Auto mode makes without asking.
    T + 'tool\n{"tool": "edit_file", "path": "main.lua", "old": "rectange", "new": "rectangle"}\n' + T,
    // A template that opened <think> itself leaves only the closing tag.
    'Reasoning in the template</think>Fixed: it was a typo.',
  ];
  window.__files['lib/util.lua'] = 'return {}\n';
  window.__files['big.lua'] = '-- a long file\n' + 'local x = 1\n'.repeat(300);
  const models = [
    { id: 'apple', name: 'Apple Intelligence', detail: '', ready: true, agent: false, reasoning: 'none', contexts: [{ tokens: 4096, bytes: 0, fits: true }] },
    { id: 'qwen3.5-4b', name: 'Qwen3.5 4B', detail: '', ready: true, agent: true, reasoning: 'optional',
      contexts: [{ tokens: 4096, bytes: 1e9, fits: true }, { tokens: 8192, bytes: 2e9, fits: true }] },
    { id: 'cloud:anthropic', name: 'claude-sonnet-5-5 (Anthropic)', detail: '', ready: true, cloud: true, agent: true, reasoning: 'optional',
      contexts: [{ tokens: 200000, bytes: 0, fits: true }] },
  ];
  mockNative((m) => {
    if (m.cmd === 'aiChatModels') return { selected: 'qwen3.5-4b', mode: 'auto', thinking: false, contextSize: 8192, kvBits: 8, models };
    if (m.cmd === 'programConsole') return 'line a\nline b';
    if (m.cmd === 'runProgram') return { output: 'hello\n', exitCode: null, stillRunning: true };
    if (m.cmd === 'aiChat') {
      sent.push(m);
      const answer = replies[Math.min(sent.length - 1, replies.length - 1)];
      setTimeout(() => window.duocode.onEvent({ name: 'aiChatText', payload: { id: m.id, text: answer.slice(0, 20) } }), 10);
      setTimeout(() => window.duocode.onEvent({ name: 'aiChatDone', payload: { id: m.id, text: answer,
        promptTokens: Math.round(m.messages.reduce((n, x) => n + x.content.length, 0) / 3.5), dropped: 0 } }), 40);
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
  check('the Think toggle starts off, and can be turned on for Qwen3', think && !think.classList.contains('on') && !think.disabled);

  const box = document.getElementById('chat-text');
  box.value = 'Fix the typo and check the game runs';
  box.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
  await until(() => sent.length >= 4 && document.getElementById('chat-send').textContent === 'Send', 8000);
  check('four model requests (tools, repeat, edit, answer)', sent.length === 4, sent.length);

  const system = sent[0].messages[0].content;
  check('the instructions list the project\'s files', /The project's files \(\d+\)/.test(system) && system.includes('lib/util.lua'));
  check('the instructions describe the new tools', ['read_files', 'find_files', 'read_console', 'read_terminal', 'read_output', 'run_program'].every((t) => system.includes(t)));
  check('a model that reasons by itself isn\'t told how to think while Think is off', !system.includes('<think>') && !system.includes('/no_think'));
  check('the open file goes with the question', /The open file is main\.lua/.test(sent[0].messages[1].content));
  check('the question is marked to keep when room runs out', sent[2].messages[1].keep === true && sent[2].messages.slice(2).every((m) => !m.keep));

  const results = (sent[1].messages.find((x) => x.content.startsWith('Tool results')) || {}).content || '';
  check('find_files matches the glob', /find_files: main\.lua\nbroken\.lua\nfx\.lua\nlib\/util\.lua\nbig\.lua/.test(results), results.slice(0, 200));
  check('read_files reads each file', results.includes('== main.lua ==') && results.includes('== fx.lua =='));
  check('search finds the line', /search: main\.lua:10: /.test(results));
  check('read_console returns the console', results.includes('line a\nline b'));
  check('read_output lists the channels', /read_output: /.test(results));
  check('run_program reports the output and that it was stopped', /run_program: It was still running after 3 s, so it was stopped\.\nConsole output:\nhello/.test(results));
  check('a tool block inside the reasoning doesn\'t run', !('evil.lua' in window.__files));
  const repeat = sent[2].messages.filter((x) => x.content.startsWith('Tool results')).pop();
  check('a repeated call is caught, not run again', repeat && /You already made this exact call/.test(repeat.content), repeat && repeat.content);
  const history = sent[1].messages.find((x) => x.role === 'assistant');
  check('this question\'s reasoning goes back between its steps', history && history.content.startsWith('<think>') && history.content.includes('Look around first.'));
  check('Auto mode edits without asking', window.__files['main.lua'].includes('love.graphics.rectangle(') || view().state.doc.toString().includes('love.graphics.rectangle('));
  check('reasoning shows folded', document.querySelectorAll('.chat-thinking').length >= 2);
  const answers = [...document.querySelectorAll('.chat-message.assistant .chat-body > p')];
  check('the final answer shows', (answers.pop() || {}).textContent === 'Fixed: it was a typo.');

  // Think on: saved, Qwen3.5 reasons by itself (the app opens its thinking), with a bigger answer budget.
  think.click();
  await wait(100);
  check('Think turns on', think.classList.contains('on'));
  const saved = window.__native.filter((n) => n.cmd === 'aiChatSettings').pop();
  check('Think is saved', saved && saved.thinking === true, JSON.stringify(saved));
  box.value = 'again';
  box.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
  await until(() => sent.length >= 5, 4000);
  const next = sent[4];
  check('with Think on, a model that reasons by itself isn\'t told how', !next.messages[0].content.includes('/no_think') && !next.messages[0].content.includes('inside <think>'));
  check('with Think on answers can be longer, and the app is told', next.maxTokens === 3072 && next.thinking === true, next.maxTokens);
  check('an earlier question\'s reasoning is left out', next.messages.filter((x) => x.role === 'assistant').every((x) => !x.content.includes('<think>')));
  check('older tool results are cut short', next.messages.some((x) => /cut short to save room/.test(x.content)) || sent[3].messages.some((x) => /cut short to save room/.test(x.content)));
  await until(() => document.getElementById('chat-send').textContent === 'Send', 4000);

  // A cloud model is asked to reason in <think> tags.
  const model = document.getElementById('chat-model');
  model.value = 'cloud:anthropic';
  model.dispatchEvent(new Event('change'));
  box.value = 'third';
  box.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
  await until(() => sent.length >= 6, 4000);
  check('other models are asked to reason when Think is on', sent[5].messages[0].content.includes('Think before you answer'));
  await until(() => document.getElementById('chat-send').textContent === 'Send', 4000);

  // Apple Intelligence: chat only, no Think, and its context is fixed.
  model.value = 'apple';
  model.dispatchEvent(new Event('change'));
  await wait(100);
  check('Apple Intelligence is chat only', document.getElementById('chat-mode').disabled && document.getElementById('chat-mode').value === 'chat');
  check('and can\'t think', think.disabled && !think.classList.contains('on'));
  document.getElementById('chat-settings').hidden = false;
  check('Apple Intelligence\'s context says it\'s fixed', /fixed for Apple Intelligence/.test(document.querySelector('#chat-settings select').textContent));
  check('subagent settings are hidden for a chat-only model', !/Subagent model/.test(document.getElementById('chat-settings').textContent));
});
