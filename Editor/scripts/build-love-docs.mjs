// Builds src/love-api.json: LÖVE API names, signatures and descriptions for the editor's
// completions, signature help and long-press docs.
//
// Descriptions and signatures come from LuaCATS/love2d (generated from the LÖVE 11.5 wiki).
// The list of functions and type methods comes from the pinned LÖVE 12 source, so 12.0
// additions still complete (without docs until the upstream docs catch up).
//
// usage: npm run docs     (needs git and network)
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname, basename } from 'node:path';
import { fileURLToPath } from 'node:url';

const LUACATS = { repo: 'https://github.com/LuaCATS/love2d.git', sha: 'c630dd883cda128a19d850bd5e3911110b271609' };
// Keep in step with LOVE_SHA in scripts/build-love-ios.sh.
const LOVE = { repo: 'https://github.com/love2d/love.git', sha: 'ef388d4371f5932491fbdcdd65ac7240e11c31a8' };

const here = dirname(fileURLToPath(import.meta.url));
const outFile = join(here, '..', 'src', 'love-api.json');
const work = mkdtempSync(join(tmpdir(), 'duocode-docs-'));

function fetch(repo, sha, dir, sparse) {
  const git = (...args) => execFileSync('git', args, { cwd: dir, stdio: 'pipe' });
  execFileSync('git', ['init', '-q', dir]);
  git('remote', 'add', 'origin', repo);
  if (sparse) git('sparse-checkout', 'set', '--no-cone', ...sparse);
  git('fetch', '-q', '--depth', '1', '--filter=blob:none', 'origin', sha);
  git('checkout', '-q', 'FETCH_HEAD');
}

const MAX_DESCRIPTION = 700;

// --- LuaCATS annotations ------------------------------------------------------

/** Reads a type expression at the start of `s`, balancing (), <>, {} and []. */
function readType(s) {
  let depth = 0;
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if ('(<{['.includes(c)) depth++;
    else if (')>}]'.includes(c)) depth--;
    else if (c === ' ' && depth === 0) {
      // "fun(...): ret" continues past the space after the colon.
      if (s[i - 1] === ':') continue;
      return [s.slice(0, i), s.slice(i + 1)];
    }
  }
  return [s, ''];
}

function cleanType(t) {
  return t.replace(/\blove\./g, '');
}

function parseParam(rest) {
  const m = rest.match(/^(\S+)\s+(.*)$/);
  if (!m) return null;
  let [, name, tail] = m;
  const [type, after] = readType(tail);
  const description = after.replace(/^#\s*/, '').trim();
  const optional = name.endsWith('?') || /\?$/.test(type);
  return { name: name.replace(/\?$/, ''), type: cleanType(type), optional, description };
}

function parseReturn(rest) {
  const [type, after] = readType(rest.trim());
  const m = after.match(/^([A-Za-z_]\w*)?\s*(?:#\s*)?(.*)$/) || [];
  return { type: cleanType(type), name: m[1] || '', description: (m[2] || '').trim() };
}

/** fun(a: number, b?: string): ret  →  params */
function parseOverload(sig) {
  const m = sig.match(/^fun\((.*)\)(?::\s*(.*))?$/);
  if (!m) return null;
  const params = [];
  let depth = 0, cur = '';
  for (const c of m[1]) {
    if ('(<{['.includes(c)) depth++;
    if (')>}]'.includes(c)) depth--;
    if (c === ',' && depth === 0) { params.push(cur); cur = ''; } else cur += c;
  }
  if (cur.trim()) params.push(cur);
  return {
    params: params.map((p) => {
      const [name, ...type] = p.trim().split(':');
      return { name: name.replace(/\?$/, ''), type: cleanType(type.join(':').trim()), optional: name.endsWith('?'), description: '' };
    }),
    returns: m[2] ? m[2].split(',').map((t) => ({ type: cleanType(t.trim()), name: '', description: '' })) : [],
  };
}

function trimDescription(lines) {
  const text = lines.join('\n').replace(/\n{3,}/g, '\n\n').trim();
  return text.length > MAX_DESCRIPTION ? text.slice(0, MAX_DESCRIPTION).replace(/\s+\S*$/, '') + '…' : text;
}

function parseLuaCats(libDir) {
  const functions = {};   // "love.graphics.rectangle" → doc
  const types = {};       // "Image" → { parents, description, methods: { name → doc } }
  const enums = {};       // "DrawMode" → [{ value, description }]

  const files = [join(libDir, 'love.lua'), ...readdirSync(join(libDir, 'love')).map((f) => join(libDir, 'love', f))];
  for (const file of files) {
    const lines = readFileSync(file, 'utf8').split(/\r?\n/);
    const localClass = {};   // local var → class name
    let doc = null;

    const reset = () => { doc = { text: [], params: [], returns: [], overloads: [], url: '' }; };
    reset();

    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      if (line.startsWith('---@alias love.')) {
        // Enum: description lines followed by `---| "value"`.
        const name = line.slice('---@alias love.'.length).trim();
        const values = [];
        let pending = [];
        for (i++; i < lines.length && lines[i].startsWith('---'); i++) {
          const l = lines[i].slice(3);
          const v = l.match(/^\|\s*"(.*)"/) || l.match(/^\|\s*'(.*)'/);
          if (v) { values.push({ value: v[1], description: trimDescription(pending) }); pending = []; }
          else if (l.trim()) pending.push(l.trim());
        }
        enums[name] = values;
        reset();
        continue;
      }
      if (line.startsWith('---@class love.')) {
        const m = line.match(/^---@class love\.(\w+)(?::\s*(.*))?/);
        const name = m[1];
        const parents = (m[2] || '').split(',').map((p) => p.trim().replace(/^love\./, '')).filter(Boolean);
        types[name] = { parents, description: trimDescription(doc.text), methods: {} };
        const local = lines[i + 1]?.match(/^local (\w+) = \{\}/);
        if (local) localClass[local[1]] = name;
        reset();
        continue;
      }
      if (line.startsWith('---@param ')) { const p = parseParam(line.slice(10)); if (p) doc.params.push(p); continue; }
      if (line.startsWith('---@return ')) { doc.returns.push(parseReturn(line.slice(11))); continue; }
      if (line.startsWith('---@overload ')) { const o = parseOverload(line.slice(13).trim()); if (o) doc.overloads.push(o); continue; }
      if (line.startsWith('---@')) continue;
      if (line.startsWith('---')) {
        const text = line.slice(3);
        const url = text.match(/^\[Open in Browser\]\((.*)\)/);
        if (url) doc.url = url[1]; else doc.text.push(text);
        continue;
      }
      const fn = line.match(/^function ([\w.]+)([.:])(\w+)\((.*)\) end/);
      if (fn) {
        const [, owner, sep, name] = fn;
        const entry = {
          description: trimDescription(doc.text),
          signatures: [{ params: doc.params, returns: doc.returns }, ...doc.overloads],
          url: doc.url,
        };
        if (sep === ':' && localClass[owner]) types[localClass[owner]].methods[name] = entry;
        else if (sep === '.') functions[`${owner}.${name}`] = entry;
      }
      reset();
    }
  }
  return { functions, types, enums };
}

// --- LÖVE 12 source: what actually exists -------------------------------------

function walk(dir, out = []) {
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) walk(p, out); else out.push(p);
  }
  return out;
}

function parseLoveSource(modulesDir) {
  const arrays = {};     // C array name → [lua names]
  const typeArrays = {}; // Type → [array names]
  const moduleFns = {};  // "graphics" → [names]

  const files = walk(modulesDir).filter((f) => /wrap_\w+\.cpp$/.test(f));
  for (const file of files) {
    const src = readFileSync(file, 'utf8');
    for (const m of src.matchAll(/luaL_Reg\s+(\w+)\s*\[\]\s*=\s*\{([\s\S]*?)\};/g)) {
      arrays[m[1]] = [...m[2].matchAll(/\{\s*"(\w+)"\s*,/g)].map((x) => x[1]);
    }
    for (const m of src.matchAll(/luax_register_type\(\s*L\s*,\s*&[\w:]*?(\w+)::type\s*,([^;]*?)\)\s*;/g)) {
      typeArrays[m[1]] = m[2].split(',').map((s) => s.trim()).filter((s) => s && s !== 'nullptr');
    }
    // Module wrappers declare `static const luaL_Reg functions[]`; the module is the first
    // folder under src/modules (physics lives in physics/box2d, data in wrap_DataModule.cpp, …).
    const fns = src.match(/static const luaL_Reg (?:module_)?functions\[\]\s*=\s*\{([\s\S]*?)\};/);
    if (fns) {
      const mod = file.slice(modulesDir.length + 1).split(/[\\/]/)[0];
      moduleFns[mod] = [...new Set([...(moduleFns[mod] || []), ...[...fns[1].matchAll(/\{\s*"(\w+)"\s*,/g)].map((x) => x[1])])];
    }
  }
  const typeMethods = {};
  for (const [type, names] of Object.entries(typeArrays)) {
    typeMethods[type] = [...new Set(names.flatMap((a) => arrays[a] || []))];
  }
  return { moduleFns, typeMethods };
}

// --- Merge ------------------------------------------------------------------------

const CALLBACKS = [
  'load', 'update', 'draw', 'quit', 'focus', 'visible', 'resize', 'keypressed', 'keyreleased', 'textinput', 'textedited',
  'mousepressed', 'mousereleased', 'mousemoved', 'wheelmoved', 'mousefocus', 'touchpressed', 'touchreleased', 'touchmoved',
  'joystickpressed', 'joystickreleased', 'joystickaxis', 'joystickhat', 'joystickadded', 'joystickremoved',
  'gamepadpressed', 'gamepadreleased', 'gamepadaxis', 'joysticksensorupdated', 'sensorupdated', 'displayrotated',
  'directorydropped', 'filedropped', 'lowmemory', 'threaderror', 'errorhandler', 'run', 'conf', 'localechanged',
  'audiodisconnected', 'dropbegan', 'dropmoved', 'dropcompleted', 'exposed', 'occluded',
];

try {
  console.log(`Fetching LuaCATS/love2d ${LUACATS.sha.slice(0, 7)}`);
  fetch(LUACATS.repo, LUACATS.sha, join(work, 'luacats'));
  console.log(`Fetching LÖVE ${LOVE.sha.slice(0, 7)} (src/modules)`);
  fetch(LOVE.repo, LOVE.sha, join(work, 'love'), ['/src/modules/']);

  const docs = parseLuaCats(join(work, 'luacats', 'library'));
  const src = parseLoveSource(join(work, 'love', 'src', 'modules'));
  const empty = () => ({ description: '', signatures: [], url: '' });

  const functions = {};
  for (const [mod, names] of Object.entries(src.moduleFns)) {
    for (const name of names) {
      const full = `love.${mod}.${name}`;
      functions[full] = docs.functions[full] || empty();
    }
  }
  // love.* itself (getVersion, …) and callbacks come from the docs.
  for (const [full, doc] of Object.entries(docs.functions)) {
    if (/^love\.\w+$/.test(full)) functions[full] = doc;
  }
  for (const cb of CALLBACKS) {
    functions[`love.${cb}`] ??= empty();
  }

  const types = {};
  for (const [type, methods] of Object.entries(src.typeMethods)) {
    const d = docs.types[type];
    types[type] = { parents: d?.parents || [], description: d?.description || '', methods: {} };
    for (const m of methods) {
      // Docs keep inherited methods on the parent class, so look them up the chain.
      let doc = null;
      const queue = [type];
      while (queue.length && !doc) {
        const t = queue.shift();
        doc = docs.types[t]?.methods[m] || null;
        queue.push(...(docs.types[t]?.parents || []));
      }
      types[type].methods[m] = doc || empty();
    }
  }
  // Types LÖVE 12 dropped or merged (e.g. Image → Texture) stay as aliases, so a value
  // documented as returning Image still completes Texture's methods via its parents.
  for (const [type, d] of Object.entries(docs.types)) {
    types[type] ??= { parents: d.parents, description: d.description, methods: {} };
  }

  const out = {
    loveVersion: '12.0',
    docsVersion: '11.5',
    modules: Object.keys(src.moduleFns).sort(),
    callbacks: CALLBACKS,
    functions,
    types,
    enums: docs.enums,
  };
  writeFileSync(outFile, JSON.stringify(out));
  const undocumented = Object.values(functions).filter((f) => !f.description && !f.signatures.length).length;
  console.log(`Wrote ${outFile}: ${Object.keys(functions).length} functions (${undocumented} without docs), ` +
    `${Object.keys(types).length} types, ${Object.keys(docs.enums).length} enums, ${(statSync(outFile).size / 1024).toFixed(0)} KB`);
} finally {
  rmSync(work, { recursive: true, force: true });
}
