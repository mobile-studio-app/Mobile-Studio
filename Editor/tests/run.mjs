// The editor's browser tests: each scenario in scenarios/ runs in the real editor page
// (App/Resources/Editor/editor.html and the built bundle) in headless Chrome or Edge, with the
// app faked by mock.js. `npm test` (after `npm run build`); `npm test -- chat` runs the scenarios
// whose names contain "chat". The browser is CHROME_PATH, or the usual Chrome or Edge.
import { existsSync, mkdtempSync, readdirSync, readFileSync, writeFileSync, cpSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import puppeteer from 'puppeteer-core';

const here = dirname(fileURLToPath(import.meta.url));
const resources = join(here, '../../App/Resources/Editor');
const TIMEOUT = 60_000;

function browserPath() {
  const candidates = [
    process.env.CHROME_PATH,
    '/usr/bin/google-chrome', '/usr/bin/google-chrome-stable', '/usr/bin/chromium', '/usr/bin/chromium-browser',
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    '/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge',
    'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe',
    'C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe',
    'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
  ];
  const found = candidates.find((p) => p && existsSync(p));
  if (!found) throw new Error('No Chrome or Edge found; set CHROME_PATH.');
  return found;
}

// The page: the editor's own HTML with the harness, the mock and the scenario around the bundle.
const work = mkdtempSync(join(tmpdir(), 'editor-tests-'));
cpSync(resources, work, { recursive: true });
for (const file of ['harness.js', 'mock.js']) cpSync(join(here, file), join(work, file));
const html = readFileSync(join(resources, 'editor.html'), 'utf8');
if (!html.includes('<script src="editor.bundle.js"></script>')) throw new Error('editor.html no longer loads editor.bundle.js as expected');

const filter = process.argv[2] || '';
const scenarios = readdirSync(join(here, 'scenarios')).filter((f) => f.endsWith('.js') && f.includes(filter)).sort();

const browser = await puppeteer.launch({
  executablePath: browserPath(),
  headless: true,
  userDataDir: join(work, 'profile'),
  args: ['--allow-file-access-from-files', '--no-sandbox', '--window-size=1000,700'],
});

let failed = 0;
for (const name of scenarios) {
  cpSync(join(here, 'scenarios', name), join(work, name));
  const page = name.replace(/\.js$/, '.html');
  writeFileSync(join(work, page), html.replace('<script src="editor.bundle.js"></script>',
    `<script src="harness.js"></script><script src="mock.js"></script><script src="editor.bundle.js"></script><script src="${name}"></script>`));
  const tab = await browser.newPage();
  await tab.setViewport({ width: 1000, height: 700 });
  const errors = [];
  tab.on('pageerror', (e) => errors.push(e.message));
  // CodeMirror reports a crashed extension on the console rather than throwing.
  tab.on('console', (m) => { if (m.type() === 'error' && /CodeMirror|TypeError|ReferenceError/.test(m.text())) errors.push(m.text().slice(0, 300)); });
  const started = Date.now();
  let results;
  try {
    await tab.goto(pathToFileURL(join(work, page)).href);
    await tab.waitForFunction(() => window.__done === true, { timeout: TIMEOUT, polling: 200 });
    results = await tab.evaluate(() => window.__results);
  } catch (e) {
    results = [...(await tab.evaluate(() => window.__results).catch(() => []) || []), { name: 'finished in time', ok: false, detail: e.message }];
  }
  for (const message of errors) results.push({ name: 'no page errors', ok: false, detail: message });
  const bad = results.filter((r) => !r.ok);
  if (!results.length) bad.push({ name: 'made checks', ok: false, detail: 'the scenario checked nothing' });
  failed += bad.length ? 1 : 0;
  console.log(`${bad.length ? 'FAIL' : 'ok  '} ${name} (${results.length} checks, ${((Date.now() - started) / 1000).toFixed(1)} s)`);
  for (const r of bad) console.log(`     ✗ ${r.name}${r.detail ? ': ' + r.detail : ''}`);
  if (process.env.VERBOSE) for (const r of results.filter((x) => x.ok)) console.log(`     ✓ ${r.name}${r.detail ? ': ' + r.detail : ''}`);
  await tab.close();
}

await browser.close();
rmSync(work, { recursive: true, force: true });
console.log(failed ? `\n${failed} of ${scenarios.length} scenarios failed.` : `\nAll ${scenarios.length} scenarios passed.`);
process.exit(failed ? 1 : 0);
