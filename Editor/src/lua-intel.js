// Lua + LÖVE language intelligence: completions, light type inference, signature help,
// enum suggestions inside strings, syntax/unknown-API diagnostics, and docs lookup.
import api from './love-api.json';
import { stdlib, stdlibNamespaces, keywords } from './lua-stdlib.js';
import { autocompletion, snippetCompletion, completionKeymap } from '@codemirror/autocomplete';
import { linter } from '@codemirror/lint';
import { hoverTooltip, showTooltip, keymap } from '@codemirror/view';
import { StateField } from '@codemirror/state';
import luaparse from 'luaparse';
import { renderDocHTML } from './docs.js';
import { snippetSource } from './ext/snippets.js';
import { extensionCompletions } from './ext/host.js';
import { uniformInitialiserDiagnostics } from './glsl-intel.js';

// --- API lookup ---------------------------------------------------------------

export function lookupFunction(name) {
  return api.functions[name] || stdlib[name] || null;
}

/** All methods of a type, including inherited ones (nearest definition wins). */
function methodsOf(type) {
  const out = {};
  const seen = new Set();
  const queue = [type];
  while (queue.length) {
    const t = queue.shift();
    if (seen.has(t) || !api.types[t]) continue;
    seen.add(t);
    for (const [name, doc] of Object.entries(api.types[t].methods)) out[name] ??= { doc, owner: t };
    queue.push(...api.types[t].parents);
  }
  return out;
}

function firstReturnType(doc) {
  const t = doc?.signatures?.[0]?.returns?.[0]?.type;
  return t ? t.replace(/[?|].*$/, '') : null;
}

const escapeRe = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

/**
 * Infers the LÖVE type of an expression like `img`, `self.font` or `world:newBody(...)`'s
 * receiver from its last assignment before `pos`, e.g. `img = love.graphics.newImage(...)`.
 */
export function inferType(text, pos, expr, depth = 0) {
  if (depth > 3 || !expr) return null;
  const before = text.slice(0, pos);
  const re = new RegExp(`(?:^|[^\\w.:])${escapeRe(expr)}\\s*=\\s*([\\w.:]+)\\s*\\(`, 'g');
  let callee = null;
  for (const m of before.matchAll(re)) callee = m[1];
  if (!callee) return null;
  const doc = resolveCallee(text, pos, callee, depth + 1)?.doc;
  return firstReturnType(doc);
}

/** Resolves `love.graphics.draw`, `img:getWidth`, `string.format` … to its docs. */
export function resolveCallee(text, pos, callee, depth = 0) {
  const colon = callee.lastIndexOf(':');
  if (colon > 0) {
    const recv = callee.slice(0, colon);
    const method = callee.slice(colon + 1);
    const type = inferType(text, pos, recv, depth);
    const entry = type && methodsOf(type)[method];
    return entry ? { name: `${entry.owner}:${method}`, doc: entry.doc, kind: 'method' } : null;
  }
  const doc = lookupFunction(callee);
  if (doc) return { name: callee, doc, kind: 'function' };
  // obj.method(...) style on a typed value.
  const dot = callee.lastIndexOf('.');
  if (dot > 0) {
    const type = inferType(text, pos, callee.slice(0, dot), depth);
    const entry = type && methodsOf(type)[callee.slice(dot + 1)];
    if (entry) return { name: `${entry.owner}:${callee.slice(dot + 1)}`, doc: entry.doc, kind: 'method' };
  }
  return null;
}

// --- Call context (for signature help and enum completions) --------------------

/**
 * Finds the innermost unclosed call around `pos`: its callee text, the index of the
 * argument being typed, and whether the cursor is inside a string.
 */
function callContext(state, pos) {
  const startLine = state.doc.lineAt(pos).number;
  const from = state.doc.line(Math.max(1, startLine - 40)).from;
  const text = state.doc.sliceString(from, pos);
  const stack = [];
  let quote = null;
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (quote) {
      if (ch === '\\') i++;
      else if (ch === quote) quote = null;
      continue;
    }
    if (ch === '-' && text[i + 1] === '-') {
      const nl = text.indexOf('\n', i);
      if (nl < 0) break;
      i = nl;
      continue;
    }
    if (ch === '"' || ch === "'") quote = ch;
    else if (ch === '(' || ch === '{' || ch === '[') stack.push({ ch, at: i, args: 0 });
    else if (ch === ')' || ch === '}' || ch === ']') stack.pop();
    else if (ch === ',' && stack.length) stack[stack.length - 1].args++;
  }
  const open = stack[stack.length - 1];
  if (!open || open.ch !== '(') return null;
  const callee = text.slice(0, open.at).match(/([\w.:]+)\s*$/)?.[1];
  if (!callee || keywords.includes(callee)) return null;
  return { callee, argIndex: open.args, inString: quote !== null, openPos: from + open.at };
}

function bestSignature(doc, argIndex) {
  const sigs = doc.signatures || [];
  return sigs.find((s) => s.params.length > argIndex || s.params.some((p) => p.name === '...')) || sigs[0];
}

// --- Completions ------------------------------------------------------------------

const GLOBALS = ['love', ...stdlibNamespaces, ...Object.keys(stdlib).filter((n) => !n.includes('.')), 'self', '_G', 'arg'];

const STATEMENT_SNIPPETS = [
  snippetCompletion('function ${name}(${})\n\t${}\nend', { label: 'function', detail: 'function … end', type: 'keyword' }),
  snippetCompletion('local function ${name}(${})\n\t${}\nend', { label: 'local function', detail: 'local function … end', type: 'keyword' }),
  snippetCompletion('if ${condition} then\n\t${}\nend', { label: 'if', detail: 'if … then … end', type: 'keyword' }),
  snippetCompletion('for ${i} = ${1}, ${n} do\n\t${}\nend', { label: 'for', detail: 'numeric for', type: 'keyword' }),
  snippetCompletion('for ${k}, ${v} in pairs(${t}) do\n\t${}\nend', { label: 'for pairs', detail: 'for k, v in pairs', type: 'keyword' }),
  snippetCompletion('for ${i}, ${v} in ipairs(${t}) do\n\t${}\nend', { label: 'for ipairs', detail: 'for i, v in ipairs', type: 'keyword' }),
  snippetCompletion('while ${condition} do\n\t${}\nend', { label: 'while', detail: 'while … do … end', type: 'keyword' }),
];

function signatureLabel(doc) {
  const sig = doc?.signatures?.[0];
  if (!sig) return '';
  return `(${sig.params.map((p) => p.name + (p.optional ? '?' : '')).join(', ')})`;
}

function infoFor(name, doc, kind) {
  if (!doc) return undefined;
  return () => {
    const el = document.createElement('div');
    el.innerHTML = renderDocHTML({ name, doc, kind }, { compact: true });
    return el;
  };
}

function fnOption(label, fullName, doc, kind = 'function') {
  const returns = doc?.signatures?.[0]?.returns?.map((r) => r.type).join(', ');
  return {
    label,
    type: kind === 'method' ? 'method' : 'function',
    detail: signatureLabel(doc) + (returns ? ` → ${returns}` : ''),
    info: infoFor(fullName, doc, kind),
    boost: doc?.description ? 1 : 0,
  };
}

/** Identifiers already used after `prefix` in this document, e.g. fields of a user table. */
function documentMembers(text, prefix, sep) {
  const re = new RegExp(`${escapeRe(prefix)}${escapeRe(sep)}([A-Za-z_]\\w*)`, 'g');
  return [...new Set([...text.matchAll(re)].map((m) => m[1]))];
}

function luaCompletions(context) {
  const { state, pos } = context;
  const text = state.doc.toString();
  const call = callContext(state, pos);

  // Inside a string argument: suggest enum values ("fill", "line", …).
  if (call?.inString) {
    const resolved = resolveCallee(text, pos, call.callee);
    const param = resolved && bestSignature(resolved.doc, call.argIndex)?.params[call.argIndex];
    const values = param && api.enums[param.type];
    if (!values) return null;
    const word = context.matchBefore(/[\w ]*/);
    return {
      from: word ? word.from : pos,
      options: values.map((v) => ({ label: v.value, type: 'enum', detail: param.type, info: v.description || undefined })),
      validFor: /^[\w ]*$/,
    };
  }

  const chain = context.matchBefore(/[A-Za-z_][\w.:]*[.:]\w*$/);
  if (chain) {
    const t = chain.text;
    const sepAt = Math.max(t.lastIndexOf('.'), t.lastIndexOf(':'));
    const recv = t.slice(0, sepAt);
    const sep = t[sepAt];
    const from = chain.from + sepAt + 1;
    const line = state.doc.lineAt(pos).text;
    const defining = /^\s*function\s+[\w.:]*$/.test(line.slice(0, pos - state.doc.lineAt(pos).from));
    let options = [];

    if (sep === '.' && recv === 'love') {
      if (defining) {
        // `function love.` → callback skeletons with their parameters.
        options = api.callbacks.map((cb) => {
          const doc = api.functions[`love.${cb}`];
          const params = doc?.signatures?.[0]?.params.map((p) => p.name).join(', ') || '';
          return snippetCompletion(`${cb}(${params})\n\t\${}\nend`, {
            label: cb, type: 'function', detail: `(${params})  callback`, info: infoFor(`love.${cb}`, doc, 'function'),
          });
        });
      } else {
        options = [
          ...api.modules.map((m) => ({ label: m, type: 'namespace', detail: 'module' })),
          ...Object.entries(api.functions)
            .filter(([n]) => /^love\.\w+$/.test(n) && !api.callbacks.includes(n.slice(5)))
            .map(([n, doc]) => fnOption(n.slice(5), n, doc)),
        ];
      }
    } else if (sep === '.' && /^love\.\w+$/.test(recv)) {
      options = Object.entries(api.functions)
        .filter(([n]) => n.startsWith(recv + '.') && !n.slice(recv.length + 1).includes('.'))
        .map(([n, doc]) => fnOption(n.slice(recv.length + 1), n, doc));
    } else if (sep === '.' && stdlibNamespaces.includes(recv)) {
      options = Object.entries(stdlib)
        .filter(([n]) => n.startsWith(recv + '.'))
        .map(([n, doc]) => fnOption(n.slice(recv.length + 1), n, doc));
    } else {
      const type = inferType(text, pos, recv);
      if (type) {
        options = Object.entries(methodsOf(type)).map(([m, { doc, owner }]) => fnOption(m, `${owner}:${m}`, doc, 'method'));
      }
      // Fields and methods this file already uses on the same name.
      const known = new Set(options.map((o) => o.label));
      for (const m of documentMembers(text, recv, sep)) {
        if (!known.has(m) && m !== chain.text.slice(sepAt + 1)) options.push({ label: m, type: 'property' });
      }
    }
    if (!options.length) return null;
    return { from, options, validFor: /^\w*$/ };
  }

  const word = context.matchBefore(/[A-Za-z_]\w*/);
  if (!word && !context.explicit) return null;
  const current = word?.text;
  const locals = [...new Set([...text.matchAll(/\b[A-Za-z_]\w*\b/g)].map((m) => m[0]))]
    .filter((w) => w !== current && !keywords.includes(w) && !GLOBALS.includes(w) && w.length > 1);
  return {
    from: word ? word.from : pos,
    options: [
      ...STATEMENT_SNIPPETS,
      ...keywords.map((k) => ({ label: k, type: 'keyword' })),
      ...GLOBALS.map((g) => (stdlib[g] ? fnOption(g, g, stdlib[g]) : { label: g, type: 'namespace' })),
      ...locals.map((l) => ({ label: l, type: 'variable', boost: -1 })),
    ],
    validFor: /^\w*$/,
  };
}

// --- Signature help ------------------------------------------------------------------

function signatureTooltip(state) {
  const sel = state.selection.main;
  if (!sel.empty) return null;
  const call = callContext(state, sel.head);
  if (!call) return null;
  const resolved = resolveCallee(state.doc.toString(), sel.head, call.callee);
  if (!resolved || !resolved.doc.signatures?.length) return null;
  const sig = bestSignature(resolved.doc, call.argIndex);
  return {
    pos: call.openPos,
    above: true,
    strictSide: false,
    arrow: false,
    create() {
      const dom = document.createElement('div');
      dom.className = 'dc-signature';
      const params = sig.params.map((p, i) => {
        const text = `${p.name}${p.optional ? '?' : ''}: ${p.type}`;
        return i === call.argIndex || (p.name === '...' && i < call.argIndex) ? `<b>${escapeHTML(text)}</b>` : escapeHTML(text);
      });
      const active = sig.params[Math.min(call.argIndex, sig.params.length - 1)];
      const more = resolved.doc.signatures.length > 1 ? ` <span class="dc-more">+${resolved.doc.signatures.length - 1} overload${resolved.doc.signatures.length > 2 ? 's' : ''}</span>` : '';
      dom.innerHTML = `<div class="dc-sig">${escapeHTML(resolved.name)}(${params.join(', ')})${more}</div>` +
        (active?.description ? `<div class="dc-param">${escapeHTML(active.description)}</div>` : '');
      return { dom };
    },
  };
}

const signatureField = StateField.define({
  create: signatureTooltip,
  update(value, tr) {
    return tr.docChanged || tr.selection ? signatureTooltip(tr.state) : value;
  },
  provide: (f) => showTooltip.from(f),
});

// --- Docs at a position (long press / hover) -------------------------------------------

/** The symbol under `pos`: resolves `love.graphics.rectangle`, `img:getWidth`, `pairs` … */
export function symbolAt(state, pos) {
  const line = state.doc.lineAt(pos);
  const text = line.text;
  let start = pos - line.from;
  let end = start;
  while (start > 0 && /[\w.:]/.test(text[start - 1])) start--;
  while (end < text.length && /\w/.test(text[end])) end++;
  const chain = text.slice(start, end).replace(/^[.:]+/, '');
  if (!chain || !/\w/.test(chain)) return null;
  const full = state.doc.toString();
  const resolved = resolveCallee(full, line.from + start, chain);
  if (resolved) return resolved;
  if (chain === 'love' || /^love\.\w+$/.test(chain) && api.modules.includes(chain.slice(5))) {
    return { name: chain, kind: 'module', doc: { description: chain === 'love' ? 'The LÖVE framework.' : `The ${chain} module.`, signatures: [] } };
  }
  return null;
}

const hoverDocs = hoverTooltip((view, pos) => {
  const sym = symbolAt(view.state, pos);
  if (!sym) return null;
  return {
    pos,
    above: true,
    create() {
      const dom = document.createElement('div');
      dom.className = 'dc-hover';
      dom.innerHTML = renderDocHTML(sym, { compact: true });
      return { dom };
    },
  };
}, { hoverTime: 400 });

// --- Diagnostics --------------------------------------------------------------------

function levenshtein(a, b) {
  const d = Array.from({ length: a.length + 1 }, (_, i) => [i]);
  for (let j = 1; j <= b.length; j++) d[0][j] = j;
  for (let i = 1; i <= a.length; i++) {
    for (let j = 1; j <= b.length; j++) {
      d[i][j] = Math.min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1));
    }
  }
  return d[a.length][b.length];
}

function closest(name, candidates) {
  let best = null, bestScore = 3;
  for (const c of candidates) {
    const score = levenshtein(name.toLowerCase(), c.toLowerCase());
    if (score < bestScore) { best = c; bestScore = score; }
  }
  return best;
}

function walk(node, visit) {
  if (!node || typeof node !== 'object') return;
  if (Array.isArray(node)) { node.forEach((n) => walk(n, visit)); return; }
  if (node.type) visit(node);
  for (const key of Object.keys(node)) {
    if (key !== 'loc' && key !== 'range') walk(node[key], visit);
  }
}

function luaDiagnostics(view) {
  const text = view.state.doc.toString();
  // Shader code usually lives in Lua strings; check it even when the Lua doesn't parse.
  const diagnostics = uniformInitialiserDiagnostics(text);
  let ast;
  try {
    ast = luaparse.parse(text, { luaVersion: 'LuaJIT', ranges: true, comments: false, scope: false });
  } catch (e) {
    if (typeof e.index === 'number') {
      const from = Math.min(e.index, text.length);
      const lineEnd = view.state.doc.lineAt(from).to;
      diagnostics.push({
        from, to: Math.max(from, Math.min(lineEnd, from + 12)), severity: 'error',
        message: String(e.message).replace(/^\[\d+:\d+\]\s*/, ''), source: 'Lua syntax',
      });
    }
    return diagnostics;
  }

  // Assignment targets (function love.update / love.graphics.helper = …) define names; don't flag them.
  const defined = new Set();
  walk(ast, (n) => {
    if (n.type === 'AssignmentStatement') n.variables.forEach((v) => defined.add(v));
    if (n.type === 'FunctionDeclaration' && n.identifier) defined.add(n.identifier);
  });
  const userDefined = new Set();
  defined.forEach((v) => {
    if (v.type === 'MemberExpression' && v.base?.type === 'MemberExpression') {
      userDefined.add(`${exprName(v.base)}.${v.identifier.name}`);
    }
  });

  walk(ast, (n) => {
    if (n.type !== 'MemberExpression' || n.indexer !== '.' || defined.has(n)) return;
    const base = n.base;
    if (base?.type !== 'MemberExpression' || base.base?.type !== 'Identifier' || base.base.name !== 'love') return;
    const mod = base.identifier.name;
    const fn = n.identifier.name;
    if (!api.modules.includes(mod)) {
      const guess = closest(mod, api.modules);
      diagnostics.push({
        from: base.identifier.range[0], to: base.identifier.range[1], severity: 'warning', source: 'LÖVE',
        message: `love.${mod} isn’t a LÖVE module.${guess ? ` Did you mean love.${guess}?` : ''}`,
      });
      return;
    }
    const full = `love.${mod}.${fn}`;
    if (api.functions[full] || userDefined.has(full)) return;
    const siblings = Object.keys(api.functions).filter((k) => k.startsWith(`love.${mod}.`)).map((k) => k.slice(mod.length + 6));
    const guess = closest(fn, siblings);
    diagnostics.push({
      from: n.identifier.range[0], to: n.identifier.range[1], severity: 'warning', source: 'LÖVE',
      message: `${full} isn’t a LÖVE ${api.loveVersion} function.${guess ? ` Did you mean love.${mod}.${guess}?` : ''}`,
    });
  });
  return diagnostics;
}

function exprName(node) {
  if (node.type === 'Identifier') return node.name;
  if (node.type === 'MemberExpression') return `${exprName(node.base)}.${node.identifier.name}`;
  return '?';
}

function escapeHTML(s) {
  return String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);
}

/** Everything Lua files get on top of syntax highlighting. */
/** suggestions: completion popup and signature help while typing (Settings → Code Suggestions). */
export function luaSupport(language, suggestions = true) {
  return [
    language,
    suggestions ? [
      autocompletion({ override: [luaCompletions, snippetSource, extensionCompletions], icons: true, activateOnTyping: true, closeOnBlur: true }),
      keymap.of(completionKeymap),
      signatureField,
    ] : [],
    hoverDocs,
    linter(luaDiagnostics, { delay: 600 }),
  ];
}
