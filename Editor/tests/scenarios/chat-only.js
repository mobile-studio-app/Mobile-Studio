// A model too small to be the agent only chats: no tools, no Think, the open file with the question.
scenario(async () => {
  const T = '```';
  const sent = [];
  mockNative((m) => {
    if (m.cmd === 'aiChatModels') return { selected: 'llama3.2-1b', mode: 'turbo', thinking: true, contextSize: 8192, kvBits: 8,
      models: [{ id: 'llama3.2-1b', name: 'Llama 3.2 1B', detail: '', ready: true, agent: false, reasoning: 'none',
        contexts: [{ tokens: 8192, bytes: 1e9, fits: true }] }] };
    if (m.cmd === 'aiChat') {
      sent.push(m);
      // Small models still try tools now and then: they mustn't run.
      const answer = 'Use rectangle.\n' + T + 'tool\n{"tool": "write_file", "path": "oops.lua", "content": "x"}\n' + T;
      setTimeout(() => window.duocode.onEvent({ name: 'aiChatDone', payload: { id: m.id, text: answer } }), 30);
      return true;
    }
    return undefined;
  });
  openFile('main.lua');
  await until(() => view().state.doc.toString().startsWith('-- Sample'));
  document.getElementById('chat-toggle').click();
  const mode = document.getElementById('chat-mode');
  await until(() => mode.value === 'chat', 3000);
  check('the mode says Chat only and can\'t be changed', mode.value === 'chat' && mode.disabled);
  const think = document.getElementById('chat-think');
  check('Think is off and can\'t be turned on', think.disabled && !think.classList.contains('on'));
  check('the empty chat says to pick a bigger model for the agent', /pick a bigger model/.test(document.getElementById('chat-log').textContent));

  const box = document.getElementById('chat-text');
  box.value = 'What is wrong with love.draw?';
  box.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
  await until(() => sent.length >= 1 && document.getElementById('chat-send').textContent === 'Send', 4000);
  await wait(200);
  check('one request, no tool steps', sent.length === 1, sent.length);
  check('no tools in the instructions', !/Tools:/.test(sent[0].messages[0].content));
  check('no thinking asked for', !/Think before you answer/.test(sent[0].messages[0].content) && sent[0].maxTokens === 1536 && !sent[0].thinking);
  check('the open file itself goes with the question', sent[0].messages[1].content.includes('love.graphics.rectange("fill"'));
  check('a tool block in the answer doesn\'t run', !('oops.lua' in window.__files));
});
