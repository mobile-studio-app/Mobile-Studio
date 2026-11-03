// VS Code's "when" clauses, for extensions' menus: !, &&, ||, parentheses, ==, !=, =~ (a regular
// expression), <, <=, >, >=, `in` and `not in`, over context keys. `lookup(key)` gives a key's
// value; unknown keys are undefined, so they're false (as in VS Code).

function tokenize(text) {
  const tokens = [];
  const re = /\s*(\(|\)|!==?|===?|=~|&&|\|\||<=|>=|<|>|!|'(?:[^'\\]|\\.)*'|"(?:[^"\\]|\\.)*"|\/(?:[^/\\]|\\.)+\/[gimsuy]*|[^\s()!=<>&|'"]+)/y;
  let m;
  while (re.lastIndex < text.length && (m = re.exec(text))) tokens.push(m[1]);
  return tokens;
}

const truthy = (v) => !!v && v !== 'false';

/** Whether `when` holds; an empty one always does, and one that can't be read doesn't. */
export function evaluateWhen(when, lookup) {
  if (!when || !String(when).trim()) return true;
  const tokens = tokenize(String(when));
  let i = 0;
  const peek = () => tokens[i];
  const next = () => tokens[i++];

  const literal = (t) => {
    if (t === undefined) return undefined;
    if (/^'.*'$|^".*"$/.test(t)) return t.slice(1, -1).replace(/\\(.)/g, '$1');
    if (t === 'true') return true;
    if (t === 'false') return false;
    if (/^-?\d+(\.\d+)?$/.test(t)) return Number(t);
    return t;
  };
  const value = (t) => {
    if (t === 'true') return true;
    if (t === 'false') return false;
    if (/^'.*'$|^".*"$/.test(t) || /^-?\d+(\.\d+)?$/.test(t)) return literal(t);
    return lookup(t);
  };

  function primary() {
    const t = next();
    if (t === '!') return !primary();
    if (t === '(') { const v = or(); if (peek() === ')') next(); return v; }
    const left = value(t);
    const op = peek();
    if (op === '==' || op === '===' || op === '!=' || op === '!==') {
      next();
      const right = literal(next());
      // "key == true" compares truthiness; otherwise values compare as text.
      const equal = typeof right === 'boolean' ? truthy(left) === right : String(left ?? '') === String(right ?? '') && left !== undefined;
      return op.startsWith('!') ? !equal : equal;
    }
    if (op === '=~') {
      next();
      const m = /^\/(.*)\/([a-z]*)$/.exec(next() || '');
      if (!m || typeof left !== 'string') return false;
      try { return new RegExp(m[1], m[2].replace(/[^imsu]/g, '')).test(left); } catch (e) { return false; }
    }
    if (op === '<' || op === '<=' || op === '>' || op === '>=') {
      next();
      const a = Number(left), b = Number(literal(next()));
      return op === '<' ? a < b : op === '<=' ? a <= b : op === '>' ? a > b : a >= b;
    }
    if (op === 'in' || (op === 'not' && tokens[i + 1] === 'in')) {
      const negate = next() === 'not';
      if (negate) next();
      const container = lookup(next());
      const has = Array.isArray(container) ? container.includes(left) : container && typeof container === 'object' ? left in container : false;
      return negate ? !has : has;
    }
    return truthy(left);
  }
  function and() {
    let v = primary();
    while (peek() === '&&') { next(); const r = primary(); v = v && r; }
    return v;
  }
  function or() {
    let v = and();
    while (peek() === '||') { next(); const r = and(); v = v || r; }
    return v;
  }
  try { return !!or(); } catch (e) { return false; }
}
