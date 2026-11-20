// When the context fills, the oldest messages move to the context cache word for word instead of
// being summarised: they stay in the chat, the model gets a list of what they were and the memory
// to load them from, and the current question and latest steps stay. The model is faked.
scenario(async () => {
  const call = (name, args) => `<tool_call>\n<function=${name}>\n${Object.entries(args).map(([k, v]) => `<parameter=${k}>\n${v}\n</parameter>\n`).join('')}</function>\n</tool_call>`;
  for (let n = 1; n <= 6; n++) window.__files[`big${n}.lua`] = `-- long file ${n}\n` + `local value${n} = ${n} -- part of big${n}\n`.repeat(110);
  const sent = [];
  mockNative((m) => {
    if (m.cmd === 'aiChatModels') return { selected: 'qwen3.5-4b', mode: 'auto', thinking: false, contextSize: 6144, kvBits: 8,
      models: [{ id: 'qwen3.5-4b', name: 'Standard', detail: 'Qwen3.5 4B', ready: true, agent: true, subagent: true, reasoning: 'optional', tier: 'Standard',
        contexts: [{ tokens: 8192, bytes: 1e9, fits: true }] }] };
    if (m.cmd === 'aiChat') {
      sent.push(m);
      const step = sent.filter((x) => !/You summarise conversations/.test(x.messages[0].content)).length;
      const answer = /You summarise conversations/.test(m.messages[0].content) ? 'A summary.'
        : step <= 6 ? `Reading file ${step}.\n` + call('read_file', { path: `big${step}.lua` }) : 'Done: read them all.';
      setTimeout(() => window.duocode.onEvent({ name: 'aiChatDone', payload: { id: m.id, text: answer, dropped: 0 } }), 20);
      return true;
    }
    return undefined;
  });

  document.getElementById('chat-toggle').click();
  await until(() => document.getElementById('chat-mode').value === 'auto', 3000);
  const box = document.getElementById('chat-text');
  box.value = 'Read all the big files';
  box.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
  await until(() => sent.length >= 7 && document.getElementById('chat-send').textContent === 'Send', 10000);

  check('nothing was summarised', !sent.some((m) => /You summarise conversations/.test(m.messages[0].content)));
  const pagedAt = sent.findIndex((m) => m.messages.some((x) => /earlier messages of this chat were moved to long-term memory/.test(x.content)));
  check('older messages moved out when the context filled', pagedAt > 0,
    `${sent.length} requests; prompt characters: ${sent.map((m) => m.messages.reduce((n, x) => n + x.content.length, 0)).join(', ')}; system ${sent[0].messages[0].content.length}`);
  const prompt = sent[sent.length - 1].messages;
  const stub = prompt.find((x) => /were moved to long-term memory as (m\d+)/.test(x.content));
  const id = stub && /as (m\d+)/.exec(stub.content)[1];
  check('in their place, what they were and where to load them', stub && stub.keep === true && stub.content.includes('[read_file big1.lua]')
    && stub.content.includes(`load_memory ${id} brings them back`), stub && stub.content.slice(0, 400));
  const kept = (window.__memory || []).find((e) => e.id === id);
  check('they\'re in memory word for word', kept && kept.text.includes('Reading file 1.') && kept.text.includes('part of big1'));
  check('the question stays, word for word and kept', prompt[1].content.includes('Read all the big files') && prompt[1].keep === true);
  check('the latest steps stay', prompt.some((x) => x.content.includes('part of big6')) && prompt.some((x) => x.content.includes('Reading file 6.')));
  check('moved messages aren\'t sent too', !prompt.some((x) => x.role === 'assistant' && x.content.includes('Reading file 1.')));
  check('they stay in the chat', /Reading file 1\./.test(document.getElementById('chat-log').textContent)
    && /older messages moved to the context cache/.test(document.getElementById('chat-log').textContent));
  check('the answer shows', /Done: read them all\./.test(document.getElementById('chat-log').textContent));
});
