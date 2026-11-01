// The globals worker.js expects (a Web Worker's), set up before it loads in Node.js.
globalThis.__nodeRequire = require;
globalThis.self = globalThis;

// Node.js 18's V8 predates RegExp's v flag (unicodeSets), which newer extensions (Codex) pass to
// new RegExp. Retried with u, which reads the same patterns apart from v's set operations and
// properties of strings: those still throw, as they would have.
try {
  new RegExp('', 'v');
} catch (e) {
  const Native = RegExp;
  const withU = (flags) => (typeof flags === 'string' && flags.includes('v') ? flags.replace('v', flags.includes('u') ? '' : 'u') : flags);
  const make = (args, newTarget) => {
    try { return Reflect.construct(Native, args, newTarget); } catch (err) {
      if (!(err instanceof SyntaxError) || typeof args[1] !== 'string' || !args[1].includes('v')) throw err;
      return Reflect.construct(Native, [args[0], withU(args[1])], newTarget);
    }
  };
  globalThis.RegExp = new Proxy(Native, {
    construct: (target, args, newTarget) => make(args, newTarget === globalThis.RegExp ? Native : newTarget),
    apply: (target, self, args) => make(args, Native),
  });
}
