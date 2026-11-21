// @-mentions in the chat: typing @ suggests the project's files, and each one mentioned goes with
// the question. The model is faked.
scenario(async () => {
  window.__files['lib/util.lua'] = 'local util = {}\nfunction util.clamp(x, a, b) return math.max(a, math.min(b, x)) end\nreturn util\n';
  const sent = [];
  mockNative((m) => {
    if (m.cmd === 'aiChatModels') return { selected: 'qwen3.5-4b', mode: 'edit', contextSize: 8192, kvBits: 8,
      models: [{ id: 'qwen3.5-4b', name: 'Standard', detail: 'Qwen3.5 4B', ready: true, agent: true, reasoning: 'optional', contexts: [{ tokens: 8192, bytes: 1e9, fits: true }] }] };
    if (m.cmd === 'aiChat') {
      sent.push(m);
      setTimeout(() => window.duocode.onEvent({ name: 'aiChatDone', payload: { id: m.id, text: 'It clamps.' } }), 20);
      return true;
    }
    return undefined;
  });
  document.getElementById('chat-toggle').click();
  await until(() => document.getElementById('chat-mode').value === 'edit', 3000);
  const box = document.getElementById('chat-text');
  const type = (value) => {
    box.value = value;
    box.setSelectionRange(value.length, value.length);
    box.dispatchEvent(new Event('input', { bubbles: true }));
  };
  const rows = () => [...document.querySelectorAll('.chat-mention')].map((r) => r.querySelector('.chat-mention-path').textContent);

  type('What does @uti');
  check('@ suggests files matching what follows it', await until(() => rows().includes('lib/util.lua'), 1000), rows().join(', '));
  type('What does @');
  check('a bare @ suggests every file', await until(() => rows().length >= 4, 1000), rows().join(', '));
  type('What does @ut');
  await until(() => rows()[0] === 'lib/util.lua', 1000);
  box.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true, cancelable: true }));
  check('Enter picks the suggestion instead of sending', box.value === 'What does @lib/util.lua ' && sent.length === 0 && !document.querySelector('.chat-mentions'), box.value);
  type(box.value + 'do?');
  check('the suggestions close once the word is done', !document.querySelector('.chat-mentions'));
  type('What does @nope');
  check('nothing to suggest, nothing shown', await until(() => !document.querySelector('.chat-mentions'), 500));

  type('What does @lib/util.lua do? And @missing.lua?');
  box.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true, cancelable: true }));
  await until(() => sent.length >= 1, 3000);
  const question = sent[0].messages.find((x) => x.role === 'user').content;
  check('a mentioned file goes with the question', question.includes('(Mentioned: lib/util.lua.)') && question.includes('function util.clamp'), question.slice(0, 300));
  check('a mention of no file is left as it is', !question.includes('Mentioned: missing.lua') && question.includes('@missing.lua?'));
  await until(() => /It clamps\./.test(document.getElementById('chat-log').textContent), 2000);
  check('the chat shows the message as typed', [...document.querySelectorAll('.chat-message.user .chat-body')].pop().textContent === 'What does @lib/util.lua do? And @missing.lua?');
});
