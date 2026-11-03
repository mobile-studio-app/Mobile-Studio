// When the context runs out, the agent compacts before the model loses its task: the question
// stays word for word after the summary.
scenario(async () => {
  const T = '```';
  const sent = [];
  window.__files['big.lua'] = '-- a long file\n' + 'local x = 1\n'.repeat(300);
  mockNative((m) => {
    if (m.cmd === 'aiChatModels') return { selected: 'qwen3.5-4b', mode: 'auto', thinking: false, contextSize: 4096, kvBits: 8,
      models: [{ id: 'qwen3.5-4b', name: 'Qwen3.5 4B', detail: '', ready: true, agent: true, reasoning: 'optional', contexts: [{ tokens: 4096, bytes: 1e9, fits: true }] }] };
    if (m.cmd === 'aiChat') {
      sent.push(m);
      const summarising = /You summarise conversations/.test(m.messages[0].content);
      const step = sent.filter((x) => !/You summarise conversations/.test(x.messages[0].content)).length;
      const answer = summarising ? 'The user wants the typo fixed. big.lua was read.'
        : step === 1 ? T + 'tool\n{"tool": "read_file", "path": "big.lua"}\n' + T
          : 'Done.';
      // The first answer's prompt didn't fit: the app left a turn out.
      setTimeout(() => window.duocode.onEvent({ name: 'aiChatDone', payload: { id: m.id, text: answer, dropped: step === 1 && !summarising ? 1 : 0 } }), 30);
      return true;
    }
    return undefined;
  });
  document.getElementById('chat-toggle').click();
  await until(() => document.getElementById('chat-mode').value === 'auto', 3000);
  const box = document.getElementById('chat-text');
  box.value = 'Fix the typo in main.lua';
  box.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
  await until(() => sent.length >= 3 && document.getElementById('chat-send').textContent === 'Send', 6000);
  check('it compacts after the app had to leave turns out', sent.length >= 2 && /You summarise conversations/.test(sent[1].messages[0].content), sent.length);
  const after = sent[2] && sent[2].messages;
  check('the summary comes first, kept', after && /Summary of the conversation/.test(after[1].content) && after[1].keep === true);
  check('then the question, word for word and kept', after && after[2].keep === true && after[2].content.includes('Fix the typo in main.lua'));
  check('the answer shows', /Done\./.test(document.getElementById('chat-log').textContent));
});
