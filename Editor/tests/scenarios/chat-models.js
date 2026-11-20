// The Chat panel's model menu: the four tiers, in order, with ones not downloaded yet opening
// Settings → AI and ones this device can't run greyed out.
scenario(async () => {
  mockNative((m) => {
    if (m.cmd === 'aiChatModels') return { selected: 'apple', mode: 'edit', contextSize: 4096,
      models: [{ id: 'apple', name: 'Nano', detail: 'Apple Intelligence · built into iOS', ready: true, tier: 'Nano', contexts: [{ tokens: 4096, bytes: 0, fits: true }] },
        { id: 'lfm3-1.7b', name: 'Light', detail: 'LFM3 1.7B · 1.1 GB download', ready: false, suggested: true, tier: 'Light', contexts: [] },
        { id: 'qwen3.5-4b', name: 'Standard', detail: 'Qwen3.5 4B · 2.7 GB download', ready: false, suggested: true, tier: 'Standard', contexts: [] },
        { id: 'qwen3.5-9b', name: 'Smart', detail: 'Qwen3.5 9B · Needs a device with 12 GB of memory.', ready: false, tier: 'Smart', contexts: [] }] };
    return undefined;
  });
  document.getElementById('chat-toggle').click();
  const select = document.getElementById('chat-model');
  await until(() => select.options.length >= 5, 3000);
  const texts = [...select.options].map((o) => o.textContent);
  check('the tiers are listed in order', /^Nano$/.test(texts[0]) && /^Light \(/.test(texts[1]) && /^Standard \(/.test(texts[2]) && /^Smart \(/.test(texts[3]), texts.join(' | '));
  check('a tier not downloaded says how big it is', texts[1].includes('1.1 GB download'));
  check('a tier this device can\'t run is greyed out', select.options[3].disabled && !select.options[1].disabled);
  check('there are no other local models or groups', !select.querySelector('optgroup') && select.options.length === 5);
  check('the chosen tier stays shown', select.selectedOptions[0].textContent === 'Nano');
  const unlabelled = [...document.querySelectorAll('#chat-pane button, #chat-pane select, #chat-pane textarea')]
    .filter((el) => !el.getAttribute('aria-label') && !el.closest('label') && !el.textContent.trim().match(/^[\w ]+$/))
    .map((el) => el.className || el.tagName);
  check('VoiceOver has a name for every chat control', unlabelled.length === 0, unlabelled.join(', '));
  select.selectedIndex = 1;
  select.dispatchEvent(new Event('change'));
  await wait(300);
  check('picking a tier to download opens Settings → AI', window.__native.some((n) => n.cmd === 'aiSettings'));
  check('and the menu goes back to the chosen tier', select.selectedOptions[0].textContent === 'Nano');
});
