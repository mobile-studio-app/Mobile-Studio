// What the agent changed, to review and undo when it's done; and chats saved per project, to
// reopen from the history. The model is faked: each request gets the next of `replies`.
scenario(async () => {
  const call = (name, args) => `<tool_call>\n<function=${name}>\n${Object.entries(args).map(([k, v]) => `<parameter=${k}>\n${v}\n</parameter>\n`).join('')}</function>\n</tool_call>`;
  const originalMain = window.__files['main.lua'];
  const originalFx = window.__files['fx.lua'];
  const sent = [];
  const replies = [
    call('edit_file', { path: 'main.lua', old: 'rectange', new: 'rectangle' })
      + call('write_file', { path: 'src/new.lua', content: 'return 1' })
      + call('delete_file', { path: 'fx.lua' }),
    'Fixed the typo, added src/new.lua and removed fx.lua.',
    call('write_file', { path: 'conf.json', content: '{ "a": 2 }' }),
    'Changed conf.json.',
  ];
  mockNative((m) => {
    if (m.cmd === 'aiChatModels') return { selected: 'qwen3.5-4b', mode: 'turbo', thinking: false, contextSize: 8192, kvBits: 8,
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
  const opened = [];
  window.__native.length = 0;

  document.getElementById('chat-toggle').click();
  await until(() => document.getElementById('chat-mode').value === 'turbo', 3000);
  const box = document.getElementById('chat-text');
  const ask = async (text, requests) => {
    box.value = text;
    box.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
    await until(() => sent.length >= requests && document.getElementById('chat-send').textContent === 'Send', 6000);
    await wait(150);
  };
  await ask('Fix the typo and tidy up', 2);

  const card = () => [...document.querySelectorAll('.chat-changes')].pop();
  await until(() => card(), 2000);
  const rows = () => [...card().querySelectorAll('.chat-change')].map((r) => r.textContent);
  check('the agent\'s changes are listed when it\'s done', card() && /changed 3 files/.test(card().textContent)
    && rows().some((r) => r.includes('main.lua') && r.includes('+1 −1')) && rows().some((r) => r.includes('src/new.lua') && r.includes('new'))
    && rows().some((r) => r.includes('fx.lua') && r.includes('deleted')), rows().join(' | '));
  const button = (label, scope = card()) => [...scope.querySelectorAll('button')].find((b) => b.textContent === label);
  check('each change can be compared', !!button('Diff'));

  // A file changed again after the agent: undoing it asks first.
  window.__files['src/new.lua'] = 'return 2';
  button('Undo All').click();
  await until(() => !('main.lua' in window.__files) || window.__files['main.lua'] === originalMain, 2000);
  await wait(100);
  check('Undo All puts the files back', window.__files['main.lua'] === originalMain && window.__files['fx.lua'] === originalFx);
  check('a file changed since asks before it\'s undone', window.__files['src/new.lua'] === 'return 2' && !!button('Undo Anyway'));
  button('Undo Anyway').click();
  await until(() => !('src/new.lua' in window.__files), 2000);
  check('and then a new file is deleted', !('src/new.lua' in window.__files));
  check('the card says it was all undone', /changes were undone/.test(card().textContent));

  // Saved: a new chat, then the first one back from the history.
  await ask('One more change', 4);
  const saved = Object.values(window.__chats || {});
  check('the chat is saved for the project', saved.length === 1 && saved[0].title === 'Fix the typo and tidy up' && saved[0].messages.length >= 6);
  document.querySelector('.chat-icon[title="New Chat"]').click();
  await wait(100);
  check('a new chat starts empty', !!document.querySelector('.chat-empty'));
  document.querySelector('.chat-icon[title="Chat History"]').click();
  await until(() => document.querySelector('.chat-history-open'), 2000);
  check('the history lists it', /Fix the typo and tidy up/.test(document.getElementById('chat-history').textContent));
  document.querySelector('.chat-history-open').click();
  await until(() => /Changed conf\.json\./.test(document.getElementById('chat-log').textContent), 2000);
  check('reopening it brings back its messages and cards', /Fixed the typo/.test(document.getElementById('chat-log').textContent)
    && document.querySelectorAll('.chat-changes').length === 2 && /changes were undone/.test(document.getElementById('chat-log').textContent));
  check('and the history closes', document.getElementById('chat-history').hidden);
  const before = sent.length;
  replies.push('Still here.');
  await ask('Carry on', before + 1);
  check('it carries on in the same chat', Object.keys(window.__chats).length === 1 && sent[before].messages.some((x) => x.content.includes('Fix the typo and tidy up')));
});
