// The Chat panel's model menu: suggested models that aren't downloaded yet.
scenario(async () => {
  mockNative((m) => {
    if (m.cmd === 'aiChatModels') return { selected: 'apple', mode: 'edit', contextSize: 4096,
      models: [{ id: 'apple', name: 'Apple Intelligence', detail: '', ready: true, contexts: [{ tokens: 4096, bytes: 0, fits: true }] },
        { id: 'qwen2.5-coder-3b-instruct', name: 'Qwen2.5-Coder 3B Instruct', detail: 'Best for coding on most devices · 1.9 GB', ready: false, suggested: true, contexts: [] },
        { id: 'qwen3-4b', name: 'Qwen3 4B', detail: 'Thinks before it answers · 2.5 GB', ready: false, suggested: true, contexts: [] }] };
    return undefined;
  });
  document.getElementById('chat-toggle').click();
  const select = document.getElementById('chat-model');
  await until(() => select.querySelector('optgroup'), 3000);
  const group = select.querySelector('optgroup');
  check('suggested models are grouped', group && group.label === 'Suggested (download)');
  check('each suggestion says why', group && group.children.length === 2 && group.children[1].textContent.includes('Thinks before it answers'));
  check('the chosen model stays shown', select.selectedOptions[0].textContent === 'Apple Intelligence');
  const unlabelled = [...document.querySelectorAll('#chat-pane button, #chat-pane select, #chat-pane textarea')]
    .filter((el) => !el.getAttribute('aria-label') && !el.closest('label') && !el.textContent.trim().match(/^[\w ]+$/))
    .map((el) => el.className || el.tagName);
  check('VoiceOver has a name for every chat control', unlabelled.length === 0, unlabelled.join(', '));
  select.value = '__get__';
  select.dispatchEvent(new Event('change'));
  await wait(300);
  check('picking a suggestion opens Settings → AI', window.__native.some((n) => n.cmd === 'aiSettings'));
  check('and the menu goes back to the chosen model', select.selectedOptions[0].textContent === 'Apple Intelligence');
});
