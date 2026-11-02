// A cloud model set up with the user's own key: listed apart, labelled as sending code away, with
// its provider's context.
scenario(async () => {
  mockNative((m) => {
    if (m.cmd === 'aiChatModels') return { selected: 'cloud:anthropic', mode: 'edit', contextSize: 4096,
      models: [{ id: 'apple', name: 'Apple Intelligence', detail: '', ready: true, contexts: [{ tokens: 4096, bytes: 0, fits: true }] },
        { id: 'cloud:anthropic', name: 'claude-sonnet-5-5 (Anthropic)', detail: 'Cloud · sends your code to Anthropic', ready: true, cloud: true,
          contexts: [{ tokens: 200000, bytes: 0, fits: true }] }] };
    return undefined;
  });
  document.getElementById('chat-toggle').click();
  const select = document.getElementById('chat-model');
  await until(() => select.querySelector('optgroup'), 3000);
  const group = select.querySelector('optgroup');
  check('cloud models are grouped and labelled', group && /sends your code/.test(group.label), group && group.label);
  check('the cloud model is chosen', select.value === 'cloud:anthropic');
  check('the empty chat says the code leaves the device', /sent to its provider/.test(document.getElementById('chat-log').textContent));
  check('the meter uses the provider\'s context, not the local setting', /\/ 200k tokens/.test(document.querySelector('.chat-meter-text').textContent),
    document.querySelector('.chat-meter-text').textContent);
  document.getElementById('chat-settings').hidden = false;
  check('the context row says it\'s the cloud model\'s', /200K, the cloud model's/.test(document.querySelector('#chat-settings select').textContent));
  select.value = 'apple';
  select.dispatchEvent(new Event('change'));
  await wait(100);
  check('switching to a local model says it stays on the device', /Everything runs on this device/.test(document.getElementById('chat-log').textContent));
});
