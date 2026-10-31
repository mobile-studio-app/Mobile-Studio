// Module paths for web extensions' CommonJS requires, shared by the host page (which preloads
// the files) and the worker (which runs them).

/** The file a relative require names: "./x" as x, x.js or x/index.js. */
export function resolveModule(modules, dir, name) {
  const parts = dir ? dir.split('/') : [];
  for (const p of name.split('/')) {
    if (p === '..') parts.pop(); else if (p && p !== '.') parts.push(p);
  }
  const base = parts.join('/');
  return [base, base + '.js', base + '/index.js'].find((p) => (modules instanceof Set ? modules.has(p) : p in modules));
}

/** Relative paths a source file requires ("./x", "../y"). */
export function relativeRequires(source) {
  const out = new Set();
  const re = /\brequire\(\s*["'](\.{1,2}\/[^"']+)["']\s*\)/g;
  let m;
  while ((m = re.exec(source))) out.add(m[1]);
  return [...out];
}

/** The path with ".js" if it has no extension. */
export function candidates(dir, name) {
  const parts = dir ? dir.split('/') : [];
  for (const p of name.split('/')) {
    if (p === '..') parts.pop(); else if (p && p !== '.') parts.push(p);
  }
  const base = parts.join('/');
  return /\.[cm]?js$/.test(base) ? [base] : [base + '.js', base, base + '/index.js'];
}
