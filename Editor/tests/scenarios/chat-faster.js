// Faster answers (speculative decoding) in the chat's settings: offered for models with a draft
// model, saved, and its state said (downloading, won't fit). The app is faked.
scenario(async () => {
  let state = 'off';
  mockNative((m) => {
    if (m.cmd === 'aiChatSettings' && 'fasterAnswers' in m) state = m.fasterAnswers ? 'download' : 'off';
    if (m.cmd === 'aiChatModels') return { selected: 'qwen3.5-9b', mode: 'edit', contextSize: 8192, kvBits: 8,
      models: [
        { id: 'lfm3-1.7b', name: 'Light', detail: 'LFM3 1.7B', ready: true, agent: true, reasoning: 'optional', fasterAnswers: 'unavailable', contexts: [{ tokens: 8192, bytes: 1e9, fits: true }] },
        { id: 'qwen3.5-9b', name: 'Smart', detail: 'Qwen3.5 9B', ready: true, agent: true, reasoning: 'optional', fasterAnswers: state, contexts: [{ tokens: 8192, bytes: 1e9, fits: true }] },
      ] };
    return undefined;
  });
  document.getElementById('chat-toggle').click();
  await until(() => document.getElementById('chat-model').value === 'qwen3.5-9b', 3000);
  const panel = document.getElementById('chat-settings');
  const fasterRow = () => [...panel.querySelectorAll('.chat-setting')].find((r) => /Faster answers/.test(r.textContent));
  check('Faster answers is offered for a model with a draft model', !!fasterRow());
  check('and starts off', fasterRow().querySelector('select').value === 'off');
  const select = fasterRow().querySelector('select');
  select.value = 'on';
  select.dispatchEvent(new Event('change'));
  check('turning it on is saved', await until(() => window.__native.some((n) => n.cmd === 'aiChatSettings' && n.fasterAnswers === true), 1000));
  check('and says the draft model downloads', await until(() => /0\.5 GB draft model: it downloads/.test(panel.textContent), 1000), panel.textContent.slice(0, 300));
  const model = document.getElementById('chat-model');
  model.value = 'lfm3-1.7b';
  model.dispatchEvent(new Event('change'));
  await wait(100);
  check('a model without one doesn\'t offer it', !fasterRow());
});
