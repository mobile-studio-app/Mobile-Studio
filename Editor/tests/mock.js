// The app's side of the editor (EditorWebView.swift), faked: a project in memory, and every
// message to the app recorded in window.__native. Scenarios add handlers with mockNative().
window.__files = {
  'main.lua': [
    '-- Sample',
    'local img',
    '',
    'function love.load()',
    '    img = love.graphics.newImage("sprite.png")',
    '    font = love.graphics.newFont(14)',
    'end',
    '',
    'function love.draw()',
    '    love.graphics.rectange("fill", 10, 10, 50, 50)',
    '    love.graphics.draw(img, 100, 100)',
    'end',
    '',
    'function love.update(dt)',
    '    if dt > 1 then',
    '        print("slow")',
    '    end',
    'end',
  ].join('\n'),
  'broken.lua': 'function love.draw()\n    love.graphics.print("hi", 1, 1\nend',
  'fx.lua': 'local shader = love.graphics.newShader([[\n    vec4 effect(vec4 c, Image t, vec2 tc, vec2 sc) { return c; }\n]])',
  'conf.json': '{ "a": 1, }',
  'README.md': '# My Game\n\nA **LÖVE** game.\n\n## Controls\n\n- [x] Movement\n- [ ] Enemies\n\n```lua\nfunction love.draw()\n  love.graphics.print("hi", 10, 10)\nend\n```\n',
};
window.__settings = { theme: 'dark-plus', fontSize: 13, tabSize: 4, wordWrap: false, autoSave: true, suggestions: true, ai: false };
window.__native = [];

const handlers = [];
/** Answers messages to the app: `handler(message)` returns an answer, or undefined to pass it on. */
function mockNative(handler) { handlers.unshift(handler); }

window.webkit = { messageHandlers: { duocode: { postMessage: async (m) => {
  window.__native.push(m);
  for (const handler of handlers) {
    const answer = await handler(m);
    if (answer !== undefined) return answer;
  }
  const f = window.__files;
  if (m.cmd === 'getSettings') return window.__settings;
  if (m.cmd === 'read') { if (m.path in f) return f[m.path]; throw new Error('not found'); }
  if (m.cmd === 'stat') { if (m.path in f) return { size: f[m.path].length }; throw new Error('not found'); }
  if (m.cmd === 'write') { f[m.path] = m.contents; return true; }
  if (m.cmd === 'list') return Object.keys(f);
  if (m.cmd === 'extList') return [];
  return true;
} } } };
