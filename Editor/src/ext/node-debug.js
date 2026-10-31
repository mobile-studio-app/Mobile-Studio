// The JavaScript debugger: DuoCode's debug protocol (Runtimes/common/DebugChannel.h) on top of
// Node.js's inspector. The program runs in a worker thread; this, on the main thread, attaches
// to it through the inspector's NodeWorker domain, so pausing the program leaves Node.js (and
// the extension host) running.
//   commands: setBreakpoints, continue, next, stepIn, stepOut, pause, scopes, variables, evaluate
//   events:   stopped { reason, text, frames }, continued, and replies { response, body | error }
let session = null;
function mainSession() {
  if (!session) {
    // Loaded when first needed: a Node.js built without the inspector throws on loading it.
    const inspector = require('inspector');
    session = new inspector.Session();
    session.connect();
  }
  return session;
}

/** Whether this Node.js has the inspector (a build without it throws on connecting). */
export function debuggingAvailable() {
  try { mainSession(); return true; } catch (e) { return false; }
}
const post = (method, params = {}) => new Promise((resolve, reject) => {
  mainSession().post(method, params, (error, result) => (error ? reject(error) : resolve(result)));
});

const SCOPE_NAMES = { local: 'Locals', closure: 'Closure', block: 'Block', catch: 'Catch', script: 'Script', with: 'With', module: 'Module', global: 'Globals', eval: 'Eval' };

/** "abc" for strings, 42, [Function: f], Array(3)… as the debugger shows them. */
function describe(object) {
  if (!object) return 'undefined';
  switch (object.type) {
    case 'undefined': return 'undefined';
    case 'string': return JSON.stringify(object.value);
    case 'number': case 'boolean': return object.description ?? String(object.value);
    case 'bigint': return object.description || String(object.unserializableValue);
    case 'symbol': return object.description || 'Symbol()';
    case 'function': return 'ƒ ' + String(object.description || '').split(/\r?\n/)[0].replace(/^(async\s+)?function\s*/, '$1').slice(0, 80);
    default: return object.subtype === 'null' ? 'null' : object.description || object.className || 'Object';
  }
}

/** A debugging session for one run. `send` reports events and replies (JSON text). */
export class ProgramDebugger {
  constructor(config, dir, send) {
    this.config = typeof config === 'string' ? JSON.parse(config || '{}') : config || {};
    this.dir = dir.replace(/\\/g, '/');
    this.send = (message) => send(JSON.stringify(message));
    this.workerSession = null;   // the program's inspector session id
    this.programThread = null;
    this.waiting = new Map();    // NodeWorker session id -> worker id, until we know which is the program
    this.nextId = 1;
    this.pending = new Map();    // inspector message id -> { resolve, reject }
    this.scripts = new Map();    // script id -> url
    this.callFrames = [];
    this.refs = new Map();       // ref -> object id
    this.nextRef = 1;
    this.breakpointIds = [];
    this.onNotification = (message) => this.notification(message);
  }

  /** Before the program's worker is created: new workers wait for us. */
  async start() {
    mainSession().on('inspectorNotification', this.onNotification);
    await post('NodeWorker.enable', { waitForDebuggerOnStart: true });
  }

  /** The program's worker exists: its thread id identifies it. */
  setProgramThread(threadId) {
    this.programThread = String(threadId);
    for (const [sessionId, workerId] of this.waiting) this.attached(sessionId, workerId);
    this.waiting.clear();
  }

  async stop() {
    mainSession().removeListener('inspectorNotification', this.onNotification);
    for (const { reject } of this.pending.values()) reject(new Error('The program ended.'));
    this.pending.clear();
    await post('NodeWorker.disable').catch(() => {});
  }

  notification({ method, params }) {
    if (method === 'NodeWorker.attachedToWorker') {
      const { sessionId, workerInfo } = params;
      if (this.programThread === null) this.waiting.set(sessionId, workerInfo.workerId);
      else this.attached(sessionId, workerInfo.workerId);
    } else if (method === 'NodeWorker.receivedMessageFromWorker' && params.sessionId === this.workerSession) {
      this.fromProgram(JSON.parse(params.message));
    } else if (method === 'NodeWorker.detachedFromWorker' && params.sessionId === this.workerSession) {
      this.workerSession = null;
    }
  }

  attached(sessionId, workerId) {
    if (workerId !== this.programThread || this.workerSession) {
      // Another worker (an extension's, or one the program started): let it run undebugged.
      post('NodeWorker.sendMessageToWorker', { sessionId, message: JSON.stringify({ id: 0, method: 'Runtime.runIfWaitingForDebugger' }) })
        .then(() => post('NodeWorker.detach', { sessionId })).catch(() => {});
      return;
    }
    this.workerSession = sessionId;
    this.begin().catch((e) => this.send({ event: 'output', text: `The debugger couldn't start: ${e.message}\n` }));
  }

  /** A request to the program's inspector. */
  request(method, params = {}) {
    if (!this.workerSession) return Promise.reject(new Error('The program isn\'t running.'));
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      post('NodeWorker.sendMessageToWorker', { sessionId: this.workerSession, message: JSON.stringify({ id, method, params }) })
        .catch((e) => { this.pending.delete(id); reject(e); });
    });
  }

  async begin() {
    await this.request('Runtime.enable');
    await this.request('Debugger.enable');
    await this.setBreakpoints(this.config.breakpoints || {}, this.config.stopOnErrors !== false);
    await this.request('Runtime.runIfWaitingForDebugger');
  }

  fromProgram(message) {
    if (message.id !== undefined) {
      const entry = this.pending.get(message.id);
      if (!entry) return;
      this.pending.delete(message.id);
      if (message.error) entry.reject(new Error(message.error.message)); else entry.resolve(message.result);
      return;
    }
    const { method, params } = message;
    if (method === 'Debugger.scriptParsed') {
      this.scripts.set(params.scriptId, params.url);
      // Only the project's own code is stepped through: Node.js's and packages' code is skipped.
      if (!this.projectFile(params.url) && params.url) {
        this.request('Debugger.setBlackboxedRanges', { scriptId: params.scriptId, positions: [{ lineNumber: 0, columnNumber: 0 }] }).catch(() => {});
      }
    } else if (method === 'Debugger.paused') {
      this.paused(params);
    } else if (method === 'Debugger.resumed') {
      this.callFrames = [];
      this.refs.clear();
      this.send({ event: 'continued' });
    }
  }

  /** The project-relative path of a script's URL, or null for code outside the project (and its packages). */
  projectFile(url) {
    if (!url) return null;
    let file = url;
    if (file.startsWith('file://')) { try { file = decodeURIComponent(new URL(file).pathname); } catch (e) { return null; } }
    file = file.replace(/\\/g, '/').replace(/^\/([A-Za-z]:\/)/, '$1');
    if (!file.startsWith(this.dir + '/')) return null;
    const relative = file.slice(this.dir.length + 1);
    return relative.startsWith('node_modules/') || relative.includes('/node_modules/') ? null : relative;
  }

  paused(params) {
    this.callFrames = params.callFrames || [];
    this.refs.clear();
    const frames = [];
    this.callFrames.forEach((frame, index) => {
      const file = this.projectFile(frame.url || this.scripts.get(frame.location.scriptId));
      if (file) frames.push({ id: index + 1, name: frame.functionName || '(anonymous)', file, line: frame.location.lineNumber + 1 });
    });
    let reason = 'pause';
    let text;
    if (params.reason === 'exception' || params.reason === 'promiseRejection') {
      reason = 'exception';
      text = params.data ? describe(params.data).split('\n')[0] : 'Exception';
    } else if (params.hitBreakpoints && params.hitBreakpoints.length) reason = 'breakpoint';
    else if (params.reason === 'other' && this.stepping) reason = 'step';
    this.stepping = false;
    // A worker waiting for the debugger stops before its first line, and stepping can leave the
    // project: with nothing of the project's to show, carry on.
    if (params.reason === 'Break on start' || !frames.length) { this.request('Debugger.resume').catch(() => {}); return; }
    this.send({ event: 'stopped', reason, text, frames });
  }

  ref(objectId) {
    const ref = this.nextRef++;
    this.refs.set(ref, objectId);
    return ref;
  }

  variable(name, object) {
    const out = { name, value: describe(object), type: object ? object.subtype || object.type : 'undefined' };
    if (object && object.objectId && (object.type === 'object' || object.type === 'function') && object.subtype !== 'null') out.ref = this.ref(object.objectId);
    return out;
  }

  async setBreakpoints(byFile, stopOnErrors) {
    for (const id of this.breakpointIds.splice(0)) await this.request('Debugger.removeBreakpoint', { breakpointId: id }).catch(() => {});
    for (const [file, list] of Object.entries(byFile || {})) {
      const absolute = (this.dir + '/' + file).replace(/^\/+/, '');
      const urlRegex = '^(file://)?/*' + absolute.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '$';
      for (const bp of list) {
        let condition = bp.condition || '';
        if (bp.logMessage) {
          // A logpoint: print the message ({expressions} filled in) and carry on.
          const template = bp.logMessage.replace(/[`\\]/g, '\\$&').replace(/\$\{/g, '\\${').replace(/\{([^{}]+)\}/g, '${$1}');
          const log = `(console.log(\`${template}\`), false)`;
          condition = condition ? `(${condition}) && ${log}` : log;
        }
        try {
          const result = await this.request('Debugger.setBreakpointByUrl', { urlRegex, lineNumber: bp.line - 1, columnNumber: 0, condition });
          this.breakpointIds.push(result.breakpointId);
        } catch (e) { /* a line that can't take one */ }
      }
    }
    await this.request('Debugger.setPauseOnExceptions', { state: stopOnErrors ? 'uncaught' : 'none' }).catch(() => {});
  }

  /** A command from the IDE (JSON text). */
  async command(json) {
    let message;
    try { message = JSON.parse(json); } catch (e) { return; }
    const reply = (body) => { if (message.id !== undefined) this.send({ response: message.id, body }); };
    const fail = (error) => { if (message.id !== undefined) this.send({ response: message.id, error }); };
    const frame = () => this.callFrames[(message.frame || 1) - 1];
    try {
      switch (message.command) {
        case 'setBreakpoints': await this.setBreakpoints(message.breakpoints, message.stopOnErrors !== false); break;
        case 'continue': await this.request('Debugger.resume'); break;
        case 'next': this.stepping = true; await this.request('Debugger.stepOver'); break;
        case 'stepIn': this.stepping = true; await this.request('Debugger.stepInto'); break;
        case 'stepOut': this.stepping = true; await this.request('Debugger.stepOut'); break;
        case 'pause': await this.request('Debugger.pause'); break;
        case 'scopes': {
          const f = frame();
          if (!f) { fail('No such frame.'); break; }
          reply(f.scopeChain.map((s) => ({ name: SCOPE_NAMES[s.type] || s.type, ref: this.ref(s.object.objectId) })));
          break;
        }
        case 'variables': {
          const objectId = this.refs.get(message.ref);
          if (!objectId) { reply([]); break; }
          const { result } = await this.request('Runtime.getProperties', { objectId, ownProperties: true, generatePreview: false });
          reply(result.filter((p) => p.value || p.get).map((p) => this.variable(p.name, p.value || { type: 'undefined', description: '(getter)' })));
          break;
        }
        case 'evaluate': {
          const f = frame();
          if (!f) { fail('The program isn\'t paused.'); break; }
          const result = await this.request('Debugger.evaluateOnCallFrame', {
            callFrameId: f.callFrameId, expression: message.expression, silent: true, throwOnSideEffect: message.context === 'hover',
          });
          if (result.exceptionDetails) fail(result.exceptionDetails.exception ? describe(result.exceptionDetails.exception).split('\n')[0] : result.exceptionDetails.text);
          else reply(this.variable(message.expression, result.result));
          break;
        }
        default:
          break;
      }
    } catch (e) {
      fail(e.message || String(e));
    }
  }
}
