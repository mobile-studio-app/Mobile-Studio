// fetch() for DuoCode's Node.js. V8 runs without JIT on iOS, which leaves out WebAssembly, and
// Node 18's fetch (undici) parses HTTP with a WebAssembly build of llhttp, so every fetch()
// failed with "WebAssembly is not defined". This one sends requests with Node's http and https
// modules and answers with Node's own Response (Headers, Request, Response, FormData and web
// streams all work without WebAssembly), so code using fetch can't tell the difference.
//
// installFetch is self-contained (it only uses require), so worker threads get it too: they
// run `(${installFetch})()` before their script.

/** True for the error undici leaves behind when it loads: harmless, since its fetch isn't used. */
export function isUndiciWasmError(e) {
  return !!e && e.name === 'ReferenceError' && /WebAssembly is not defined/.test(e.message) && /undici/.test(e.stack || '');
}

/** `ownRejections`: also ignore undici's failed WebAssembly load (where nothing else handles
 * unhandled rejections, Node 18 would end the program over it). */
export function installFetch(ownRejections = false) {
  // Using Headers, Request or Response loads undici, which then fails to compile its
  // WebAssembly parser in the background: an unhandled rejection that means nothing here.
  if (ownRejections) {
    process.on('unhandledRejection', (e) => {
      if (e && e.name === 'ReferenceError' && /WebAssembly is not defined/.test(e.message) && /undici/.test(e.stack || '')) return;
      throw e;   // as Node does without a listener
    });
  }
  const http = require('http');
  const https = require('https');
  const zlib = require('zlib');
  const { Readable } = require('stream');

  const nullBodyStatus = new Set([101, 103, 204, 205, 304]);
  const redirectStatus = new Set([301, 302, 303, 307, 308]);

  function abortError(signal) {
    const reason = signal && signal.reason;
    if (reason instanceof Error) return reason;
    return new DOMException('This operation was aborted', 'AbortError');
  }

  /** One HTTP request; resolves with the Node response (not following redirects). */
  function send(url, method, headers, body, signal) {
    return new Promise((resolve, reject) => {
      const transport = url.protocol === 'http:' ? http : https;
      const request = transport.request(url, { method, headers }, resolve);
      const onAbort = () => { request.destroy(abortError(signal)); reject(abortError(signal)); };
      if (signal) {
        if (signal.aborted) return onAbort();
        signal.addEventListener('abort', onAbort, { once: true });
        request.on('close', () => signal.removeEventListener('abort', onAbort));
      }
      request.on('error', (e) => reject(Object.assign(new TypeError('fetch failed'), { cause: e })));
      if (body) request.end(body); else request.end();
    });
  }

  async function fetch(input, init) {
    const request = new Request(input, init);
    let url = new URL(request.url);
    if (url.protocol === 'data:') return nodeFetchData(url);
    if (url.protocol !== 'http:' && url.protocol !== 'https:') throw new TypeError(`fetch failed: ${url.protocol} URLs aren't supported`);
    let method = request.method;
    let body = request.body ? Buffer.from(await request.arrayBuffer()) : null;
    const headers = {};
    request.headers.forEach((value, key) => { headers[key] = value; });
    if (!headers['accept']) headers['accept'] = '*/*';
    if (!headers['accept-encoding']) headers['accept-encoding'] = 'gzip, deflate, br';
    if (!headers['user-agent']) headers['user-agent'] = 'node';
    let redirected = false;

    for (let hops = 0; ; hops++) {
      if (body) headers['content-length'] = String(body.length); else delete headers['content-length'];
      const response = await send(url, method, headers, body, request.signal);
      const status = response.statusCode;
      const location = response.headers.location;
      if (redirectStatus.has(status) && location && request.redirect !== 'manual') {
        response.resume();
        if (request.redirect === 'error') throw new TypeError('fetch failed: redirected');
        if (hops >= 20) throw new TypeError('fetch failed: too many redirects');
        const next = new URL(location, url);
        if (status === 303 || ((status === 301 || status === 302) && method === 'POST')) {
          method = 'GET';
          body = null;
          for (const key of Object.keys(headers)) if (/^content-/.test(key)) delete headers[key];
        }
        if (next.origin !== url.origin) { delete headers['authorization']; delete headers['cookie']; }
        url = next;
        redirected = true;
        continue;
      }
      return toResponse(response, url, method, redirected, request.signal);
    }
  }

  function toResponse(response, url, method, redirected, signal) {
    const headers = new Headers();
    for (let i = 0; i < response.rawHeaders.length; i += 2) headers.append(response.rawHeaders[i], response.rawHeaders[i + 1]);
    let stream = response;
    // Like fetch, hand back the content decoded.
    const encoding = (response.headers['content-encoding'] || '').trim().toLowerCase();
    const decoder = encoding === 'gzip' || encoding === 'x-gzip' ? zlib.createGunzip({ flush: zlib.constants.Z_SYNC_FLUSH, finishFlush: zlib.constants.Z_SYNC_FLUSH })
      : encoding === 'deflate' ? zlib.createInflate()
      : encoding === 'br' ? zlib.createBrotliDecompress()
      : null;
    if (decoder) {
      response.on('error', (e) => decoder.destroy(e));
      stream = response.pipe(decoder);
    }
    if (signal) signal.addEventListener('abort', () => stream.destroy(abortError(signal)), { once: true });
    const noBody = method === 'HEAD' || nullBodyStatus.has(response.statusCode);
    if (noBody) response.resume();
    const result = new Response(noBody ? null : Readable.toWeb(stream), {
      status: response.statusCode, statusText: response.statusMessage || '', headers,
    });
    Object.defineProperty(result, 'url', { value: url.href });
    Object.defineProperty(result, 'redirected', { value: redirected });
    return result;
  }

  function nodeFetchData(url) {
    const match = /^([^,]*?)(;base64)?,(.*)$/s.exec(decodeURIComponent(url.href.slice(5)));
    if (!match) throw new TypeError('fetch failed: bad data URL');
    const body = match[2] ? Buffer.from(match[3], 'base64') : Buffer.from(match[3]);
    return new Response(body, { status: 200, headers: { 'content-type': match[1] || 'text/plain;charset=US-ASCII' } });
  }

  globalThis.fetch = fetch;
}

let preloadArgv = null;

/** execArgv for worker threads that gives them this fetch: --require of a file holding it. Empty
 * if this Node.js won't take --require in a worker (so workers still start). */
export function fetchPreloadArgv() {
  if (preloadArgv) return preloadArgv;
  preloadArgv = [];
  try {
    const fs = require('fs');
    const path = require('path');
    const os = require('os');
    const { Worker } = require('worker_threads');
    const file = path.join(os.tmpdir(), 'mobile-studio-fetch.js');
    fs.writeFileSync(file, `(${installFetch})(true);\n`);
    new Worker('', { eval: true, execArgv: ['--require', file] }).terminate();
    preloadArgv = ['--require', file];
  } catch (e) { /* workers keep Node's own fetch */ }
  return preloadArgv;
}
