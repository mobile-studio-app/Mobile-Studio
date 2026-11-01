// The globals worker.js expects (a Web Worker's), set up before it loads in Node.js.
globalThis.__nodeRequire = require;
globalThis.self = globalThis;

// nodejs-mobile says the platform is "ios". Extensions only know darwin, linux and win32, and it's
// their macOS programs that run here (App/NativeTools), so they're told it's macOS: Codex looks for
// bin/aarch64-apple-darwin/codex, not bin/undefined-aarch64/codex.
if (process.platform === 'ios') {
  Object.defineProperty(process, 'platform', { value: 'darwin', enumerable: true });
  require('os').platform = () => 'darwin';
}

// Node.js 18's V8 predates RegExp's v flag (unicodeSets), which newer extensions (Codex) pass to
// new RegExp. Retried with u, which reads the same patterns apart from v's set operations and
// properties of strings: those still throw, as they would have.
try {
  new RegExp('', 'v');
} catch (e) {
  const Native = RegExp;
  const withU = (flags) => (typeof flags === 'string' && flags.includes('v') ? flags.replace('v', flags.includes('u') ? '' : 'u') : flags);
  // v's emoji properties of strings, as u can match them: flags, keycaps, and pictographs with
  // their variation selectors, skin tones and zero-width-joined sequences.
  const EMOJI = '(?:\\p{Regional_Indicator}\\p{Regional_Indicator}|[#*0-9]\\uFE0F?\\u20E3'
    + '|\\p{Extended_Pictographic}(?:\\uFE0F|\\p{Emoji_Modifier})?(?:\\u200D\\p{Extended_Pictographic}(?:\\uFE0F|\\p{Emoji_Modifier})?)*)';
  const forU = (source) => (typeof source === 'string'
    ? source.replace(/\\p\{(?:RGI_Emoji|Basic_Emoji|Emoji_Keycap_Sequence|RGI_Emoji_\w+)\}/g, EMOJI)
    : source);
  const make = (args, newTarget) => {
    try { return Reflect.construct(Native, args, newTarget); } catch (err) {
      if (!(err instanceof SyntaxError) || typeof args[1] !== 'string' || !args[1].includes('v')) throw err;
      return Reflect.construct(Native, [forU(args[0]), withU(args[1])], newTarget);
    }
  };
  globalThis.RegExp = new Proxy(Native, {
    construct: (target, args, newTarget) => make(args, newTarget === globalThis.RegExp ? Native : newTarget),
    apply: (target, self, args) => make(args, Native),
  });
}
