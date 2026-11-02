// The chat opens after extensions change and over an extension's webview tab (it once couldn't
// be opened after using the Extensions panel).
scenario(async () => {
  const pane = () => document.getElementById('chat-pane');
  const shown = () => {
    const p = pane();
    if (!p || p.hidden) return 'hidden';
    const r = p.getBoundingClientRect();
    if (r.width < 10 || r.height < 10) return 'no size';
    const hit = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
    return p.contains(hit) ? 'shown' : 'covered by ' + (hit && (hit.id || hit.className || hit.tagName));
  };
  const toggle = async () => { document.getElementById('chat-toggle').click(); await wait(250); };

  openFile('main.lua');
  await until(() => view().state.doc.toString().startsWith('-- Sample'));
  await toggle();
  check('the chat opens', shown() === 'shown', shown());
  await toggle();
  check('and closes', shown() === 'hidden', shown());

  window.duocode.onEvent({ name: 'extensionsChanged', payload: {} });
  await wait(1500);
  await toggle();
  check('it opens after extensions change', shown() === 'shown', shown());
  await toggle();

  // An extension's webview tab, as webviews.js shows one: an iframe over the editor.
  const webviews = document.getElementById('webviews');
  const frame = document.createElement('iframe');
  frame.className = 'webview';
  frame.srcdoc = '<body style="background:#123">extension</body>';
  webviews.append(frame);
  webviews.hidden = false;
  await wait(300);
  await toggle();
  check('it opens over an extension\'s webview', shown() === 'shown', shown());
  await toggle();
  check('and closes again', shown() === 'hidden', shown());

  // Left open where it has no room: the toggle opens it again rather than closing it.
  await toggle();
  const container = document.getElementById('editor-container');
  container.style.display = 'none';
  await toggle();
  container.style.display = '';
  await wait(100);
  check('a chat left open with no size opens again on the toggle', shown() === 'shown', shown());
});
