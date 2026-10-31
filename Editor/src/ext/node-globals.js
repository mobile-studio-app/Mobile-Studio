// The globals worker.js expects (a Web Worker's), set up before it loads in Node.js.
globalThis.__nodeRequire = require;
globalThis.self = globalThis;
