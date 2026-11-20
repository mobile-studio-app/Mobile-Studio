// The Chat agent's long-term memory (the context cache): notes it keeps per project, and text set
// aside when it leaves the context (long tool results, compacted conversations), which it searches
// and loads back. The model is faked: each request gets the next of `replies`.
scenario(async () => {
  const call = (name, args) => `<tool_call>\n<function=${name}>\n${Object.entries(args).map(([k, v]) => `<parameter=${k}>\n${v}\n</parameter>\n`).join('')}</function>\n</tool_call>`;
  window.__memory = [{ id: 'm1', kind: 'note', title: 'Conventions', text: 'Indent with 4 spaces. Globals are capitalised.' }];
  window.__files['big.lua'] = '-- a long file\n' + 'local x = 1 -- the big file\n'.repeat(120);
  const sent = [];
  const replies = [
    call('remember', { title: 'Game structure', content: 'main.lua draws a rectangle; fx.lua has the shader.' })
      + call('recall', { query: 'spaces indent' })
      + call('read_file', { path: 'big.lua' }),
    call('load_memory', { id: 'm1' }),
    call('read_file', { path: 'main.lua', start_line: 1, end_line: 3 }),
    call('forget', { id: 'm1' }),
    'Done.',
    // The summary for /compact.
    'They looked at the game and its conventions.',
  ];
  mockNative((m) => {
    if (m.cmd === 'aiChatModels') return { selected: 'qwen3.5-4b', mode: 'edit', thinking: false, contextSize: 8192, kvBits: 8,
      models: [{ id: 'qwen3.5-4b', name: 'Standard', detail: 'Qwen3.5 4B', ready: true, agent: true, subagent: true, reasoning: 'optional', tier: 'Standard',
        contexts: [{ tokens: 8192, bytes: 1e9, fits: true }] }] };
    if (m.cmd === 'aiChat') {
      sent.push(m);
      const answer = replies[Math.min(sent.length - 1, replies.length - 1)];
      setTimeout(() => window.duocode.onEvent({ name: 'aiChatDone', payload: { id: m.id, text: answer, dropped: 0 } }), 20);
      return true;
    }
    return undefined;
  });

  document.getElementById('chat-toggle').click();
  await until(() => document.getElementById('chat-mode').value === 'edit', 3000);
  const box = document.getElementById('chat-text');
  box.value = 'Look at the game';
  box.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
  await until(() => sent.length >= 5 && document.getElementById('chat-send').textContent === 'Send', 8000);

  const system = sent[0].messages[0].content;
  check('the instructions describe long-term memory', ['remember(', 'recall(', 'load_memory(', 'forget('].every((t) => system.includes(t)));
  check('the project\'s notes are listed for the agent', system.includes('- m1: Conventions'));
  const results = (i) => (sent[i].messages.filter((x) => x.content.startsWith('Tool results')).pop() || {}).content || '';
  check('remember saves a note, without asking in Edit mode', window.__memory.some((e) => e.kind === 'note' && e.title === 'Game structure')
    && /remember: Saved a note m\d+: Game structure/.test(results(1)), results(1).slice(0, 200));
  check('recall finds the note', /recall: m1 · note · Conventions/.test(results(1)));
  const setAside = window.__memory.find((e) => e.kind === 'archive' && e.title.includes('read_file big.lua'));
  check('a long result is set aside whole', setAside && setAside.text.includes('the big file') && setAside.text.length > 1200);
  check('load_memory brings a memory back', /load_memory: m1: Conventions\nIndent with 4 spaces/.test(results(2)), results(2).slice(0, 200));
  const cut = sent[4].messages.find((x) => /cut short to save room/.test(x.content) && x.content.includes('the big file'));
  check('when it\'s cut short, the agent is told where it is', cut && cut.content.includes(`load_memory ${setAside && setAside.id} has all of it`), cut && cut.content.slice(-200));
  check('forget deletes a memory', !window.__memory.some((e) => e.id === 'm1') && /forget: Deleted m1/.test(results(4)));
  check('memory calls show what they did', [...document.querySelectorAll('.chat-chip')].some((c) => c.textContent.includes('remember "Game structure"')));

  // Compacting sets the whole conversation aside, and the summary says where.
  box.value = '/compact';
  box.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
  await until(() => window.__memory.some((e) => e.title.startsWith('Conversation of')), 4000);
  const conversation = window.__memory.find((e) => e.title.startsWith('Conversation of'));
  check('compacting sets the whole conversation aside', conversation && conversation.title.includes('Look at the game') && conversation.text.includes('User: ')
    && conversation.text.includes('Indent with 4 spaces'));
  box.value = 'and now?';
  box.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
  await until(() => sent.length >= 7, 4000);
  const summary = sent[6].messages.find((x) => x.content.startsWith('Summary of the conversation'));
  check('the summary says where the conversation is', summary && summary.content.includes(`long-term memory as ${conversation && conversation.id}`), summary && summary.content);
});
