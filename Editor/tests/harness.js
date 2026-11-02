// Loaded before the editor: helpers for the scenarios, and their results for run.mjs.
window.__results = [];
window.__done = false;

const wait = (ms) => new Promise((r) => setTimeout(r, ms));

/** Waits until `test()` is true (or `ms` pass); resolves with whether it became true. */
async function until(test, ms = 5000) {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    try { if (test()) return true; } catch (e) { /* not yet */ }
    await wait(50);
  }
  return false;
}

/** One expectation: `ok`, with `detail` shown when it fails. */
function check(name, ok, detail) {
  window.__results.push({ name, ok: !!ok, detail: detail === undefined ? '' : String(detail) });
}

/** The scenario: runs once the editor has started. Throwing fails it. */
function scenario(body) {
  (async () => {
    try {
      await until(() => window.duocode && window.duocode.view, 10000);
      await body();
    } catch (e) {
      check('scenario finished', false, e && e.stack ? e.stack : e);
    }
    window.__done = true;
  })();
}

window.addEventListener('error', (e) => check('no page errors', false, e.message));
window.addEventListener('unhandledrejection', (e) => check('no unhandled rejections', false, e.reason && e.reason.message ? e.reason.message : e.reason));

const openFile = (path) => window.duocode.onEvent({ name: 'openFile', payload: { path } });
const view = () => window.duocode.view;
