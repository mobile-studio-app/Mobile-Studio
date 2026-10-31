// npm for JavaScript projects, without npm: packages come from the npm registry into the
// project's node_modules, as npm lays them out (shared where versions allow, nested where they
// clash). Install scripts don't run (there's no shell), and packages that build native code are
// left out, since native code can't load on iOS.
import https from 'https';
import zlib from 'zlib';
import fs from 'fs';
import path from 'path';
import crypto from 'crypto';

const REGISTRY = 'https://registry.npmjs.org/';

function get(url, headers = {}, redirects = 5) {
  return new Promise((resolve, reject) => {
    const req = https.get(url, { headers: { 'User-Agent': 'MobileStudio', ...headers } }, (res) => {
      if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location && redirects > 0) {
        res.resume();
        resolve(get(new URL(res.headers.location, url).toString(), headers, redirects - 1));
        return;
      }
      if (res.statusCode !== 200) {
        res.resume();
        reject(new Error(res.statusCode === 404 ? 'not found' : `the registry answered ${res.statusCode}`));
        return;
      }
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => resolve(Buffer.concat(chunks)));
      res.on('error', reject);
    });
    req.setTimeout(60000, () => req.destroy(new Error('the registry didn\'t answer')));
    req.on('error', reject);
  });
}

// MARK: - Versions (semver ranges)

export function parseVersion(text) {
  const m = /^\s*v?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+\S*)?\s*$/.exec(text);
  return m ? { major: +m[1], minor: +m[2], patch: +m[3], pre: m[4] ? m[4].split('.') : [] } : null;
}

export function compareVersions(a, b) {
  for (const k of ['major', 'minor', 'patch']) if (a[k] !== b[k]) return a[k] < b[k] ? -1 : 1;
  if (!a.pre.length || !b.pre.length) return a.pre.length ? -1 : b.pre.length ? 1 : 0;
  for (let i = 0; i < Math.max(a.pre.length, b.pre.length); i++) {
    const x = a.pre[i], y = b.pre[i];
    if (x === undefined) return -1;
    if (y === undefined) return 1;
    if (x === y) continue;
    const nx = /^\d+$/.test(x), ny = /^\d+$/.test(y);
    if (nx && ny) return +x < +y ? -1 : 1;
    if (nx !== ny) return nx ? -1 : 1;
    return x < y ? -1 : 1;
  }
  return 0;
}

const tuple = (major, minor, patch) => ({ major, minor, patch, pre: [] });

/** One comparator ("^1.2", ">=2", "~0.3.1", "1.x") as [lowest, highest) bounds: { lo, loIncl, hi, hiIncl }. */
function bounds(comparator) {
  const m = /^(<=|>=|<|>|=|~>?|\^)?\s*v?(.*)$/.exec(comparator.trim());
  const op = (m[1] || '=').replace('~>', '~');
  const raw = m[2];
  const full = parseVersion(raw);
  const parts = raw.split(/[-+]/)[0].split('.');
  const nums = [0, 1, 2].map((i) => (parts[i] === undefined || /^[xX*]?$/.test(parts[i]) ? null : parseInt(parts[i], 10)));
  if (full) {
    const v = full;
    if (op === '=') return { lo: v, loIncl: true, hi: v, hiIncl: true };
    if (op === '>') return { lo: v, loIncl: false };
    if (op === '>=') return { lo: v, loIncl: true };
    if (op === '<') return { hi: v, hiIncl: false };
    if (op === '<=') return { hi: v, hiIncl: true };
    if (op === '~') return { lo: v, loIncl: true, hi: tuple(v.major, v.minor + 1, 0), hiIncl: false };
    const hi = v.major ? tuple(v.major + 1, 0, 0) : v.minor ? tuple(0, v.minor + 1, 0) : tuple(0, 0, v.patch + 1);
    return { lo: v, loIncl: true, hi, hiIncl: false };
  }
  const [major, minor] = nums;
  if (major === null) return op === '<' ? { hi: tuple(0, 0, 0), hiIncl: false } : {};
  const lo = tuple(major, minor ?? 0, 0);
  // The next version past the partial one: 1 -> 2.0.0, 1.2 -> 1.3.0.
  const next = minor === null ? tuple(major + 1, 0, 0) : tuple(major, minor + 1, 0);
  if (op === '>=') return { lo, loIncl: true };
  if (op === '>') return { lo: next, loIncl: true };
  if (op === '<') return { hi: lo, hiIncl: false };
  if (op === '<=') return { hi: next, hiIncl: false };
  if (op === '^' && minor !== null && major === 0) return { lo, loIncl: true, hi: tuple(0, minor + 1, 0), hiIncl: false };
  if (op === '^') return { lo, loIncl: true, hi: tuple(major + 1, 0, 0), hiIncl: false };
  return { lo, loIncl: true, hi: next, hiIncl: false };
}

function within(v, b) {
  if (b.lo) { const c = compareVersions(v, b.lo); if (c < 0 || (c === 0 && !b.loIncl)) return false; }
  if (b.hi) { const c = compareVersions(v, b.hi); if (c > 0 || (c === 0 && !b.hiIncl)) return false; }
  return true;
}

export function satisfies(version, range) {
  const v = parseVersion(version);
  if (!v) return false;
  return String(range).split('||').some((part) => {
    part = part.trim();
    const hyphen = /^(\S+)\s+-\s+(\S+)$/.exec(part);
    const comparators = hyphen ? [`>=${hyphen[1]}`, `<=${hyphen[2]}`] : part.replace(/(<=|>=|<|>|=|~>?|\^)\s+/g, '$1').split(/\s+/).filter(Boolean);
    if (!comparators.length) return !v.pre.length;
    // A prerelease only matches a range that names a prerelease of the same version.
    if (v.pre.length && !comparators.some((c) => {
      const p = parseVersion(c.replace(/^(<=|>=|<|>|=|~>?|\^)/, ''));
      return p && p.pre.length && p.major === v.major && p.minor === v.minor && p.patch === v.patch;
    })) return false;
    return comparators.every((c) => within(v, bounds(c)));
  });
}

/** The newest version (or dist-tag) a range allows. */
export function pickVersion(packument, range) {
  const tags = packument['dist-tags'] || {};
  if (!range || range === 'latest' || range === '*' || range === '') {
    if (tags.latest && packument.versions[tags.latest]) return tags.latest;
  }
  if (tags[range]) return tags[range];
  const versions = Object.keys(packument.versions || {}).filter((v) => satisfies(v, range))
    .sort((a, b) => compareVersions(parseVersion(b), parseVersion(a)));
  // npm prefers the latest tag when it's allowed.
  if (tags.latest && versions.includes(tags.latest)) return tags.latest;
  return versions[0] || null;
}

// MARK: - Packages

/** Unpacks a package tarball into `dest` (dropping its "package/" folder). */
export function untar(buffer, dest) {
  let offset = 0;
  let longName = null;
  while (offset + 512 <= buffer.length) {
    const header = buffer.subarray(offset, offset + 512);
    if (header.every((b) => b === 0)) break;
    const field = (start, length) => header.toString('utf8', start, start + length).replace(/\0[\s\S]*$/, '');
    let name = field(0, 100);
    const prefix = field(345, 155);
    if (prefix) name = prefix + '/' + name;
    const size = parseInt(field(124, 12).trim() || '0', 8) || 0;
    const type = String.fromCharCode(header[156]);
    const body = buffer.subarray(offset + 512, offset + 512 + size);
    offset += 512 + Math.ceil(size / 512) * 512;
    if (type === 'L') { longName = body.toString('utf8').replace(/\0[\s\S]*$/, ''); continue; }
    if (type === 'x') { const m = /\d+ path=([^\n]*)\n/.exec(body.toString('utf8')); if (m) longName = m[1]; continue; }
    if (type === 'g') continue;
    if (longName) { name = longName; longName = null; }
    const relative = name.split('/').slice(1).join('/');
    if (!relative) continue;
    const target = path.resolve(dest, relative);
    if (!target.startsWith(path.resolve(dest) + path.sep)) continue;   // nothing outside the package's folder
    if (type === '5') fs.mkdirSync(target, { recursive: true });
    else if (type === '0' || type === '\0' || type === '7') {
      fs.mkdirSync(path.dirname(target), { recursive: true });
      fs.writeFileSync(target, body);
    }
  }
}

function checkIntegrity(data, dist) {
  if (dist.integrity) {
    for (const entry of dist.integrity.split(/\s+/)) {
      const [algorithm, expected] = entry.split(/-(.*)/s);
      if (!['sha512', 'sha384', 'sha256', 'sha1'].includes(algorithm)) continue;
      return crypto.createHash(algorithm).update(data).digest('base64') === expected;
    }
  }
  if (dist.shasum) return crypto.createHash('sha1').update(data).digest('hex') === dist.shasum;
  return true;
}

/** Why a package can't work on iOS, or null. */
function nativeReason(dir, manifest) {
  if (manifest.gypfile || fs.existsSync(path.join(dir, 'binding.gyp'))) return 'it builds native code';
  const scripts = manifest.scripts || {};
  const script = [scripts.preinstall, scripts.install, scripts.postinstall].filter(Boolean).join(' ');
  if (/node-gyp|prebuild-install|node-pre-gyp|cmake-js/.test(script)) return 'it builds or downloads native code';
  return null;
}

const readJSON = (file) => { try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch (e) { return null; } };

/** Splits "name@range" ("@scope/name@1" too). */
export function parseSpec(spec) {
  const at = spec.indexOf('@', 1);
  return at > 0 ? { name: spec.slice(0, at), range: spec.slice(at + 1) || 'latest' } : { name: spec, range: '' };
}

async function inBatches(items, size, fn) {
  for (let i = 0; i < items.length; i += size) await Promise.all(items.slice(i, i + size).map(fn));
}

/** Installs `specs` (adding them to package.json), or with none, package.json's dependencies.
 * `write` gets progress text. Resolves with an exit code. */
export async function npmInstall(dir, specs, write) {
  const pkgFile = path.join(dir, 'package.json');
  const pkg = readJSON(pkgFile) || { name: path.basename(dir).toLowerCase().replace(/[^a-z0-9._-]+/g, '-'), version: '1.0.0', private: true };
  const requested = specs.length
    ? specs.map(parseSpec)
    : Object.entries({ ...(pkg.devDependencies || {}), ...(pkg.dependencies || {}) }).map(([name, range]) => ({ name, range }));
  if (!requested.length) { write('Nothing to install: package.json has no dependencies.\n'); return 0; }

  const root = path.join(dir, 'node_modules');
  const packuments = new Map();
  const packument = (name) => {
    if (!packuments.has(name)) {
      packuments.set(name, get(REGISTRY + name.replace('/', '%2f'), { Accept: 'application/vnd.npm.install-v1+json; q=1.0, application/json; q=0.8' })
        .then((data) => JSON.parse(data.toString('utf8'))));
    }
    return packuments.get(name);
  };
  // What's in each node_modules folder: folder -> name -> version (read from disk as needed).
  const placed = new Map();
  const versionAt = (modules, name) => {
    if (!placed.has(modules)) placed.set(modules, new Map());
    const here = placed.get(modules);
    if (!here.has(name)) here.set(name, readJSON(path.join(modules, name, 'package.json'))?.version || null);
    return here.get(name);
  };

  let failures = 0;
  let installed = 0;
  const skipped = [];
  // Breadth first, a level at a time: { name, range, from (the dependent's folder), optional }.
  let level = requested.map((r) => Object.assign(r, { from: dir, top: true }));
  const seen = new Set();
  while (level.length) {
    await Promise.all(level.map((d) => packument(d.name).catch(() => null)));
    const downloads = [];
    for (const dep of level) {
      // Where Node.js would find it from the dependent: its own node_modules, then upwards.
      let found = null;
      for (let folder = dep.from; folder.startsWith(dir); folder = path.dirname(folder)) {
        const modules = path.join(folder, 'node_modules');
        const version = versionAt(modules, dep.name);
        if (version) { found = { modules, version }; break; }
        if (folder === dir) break;
      }
      if (found && satisfies(found.version, dep.range || '*') && !dep.top) continue;
      let doc;
      try { doc = await packument(dep.name); } catch (e) {
        if (!dep.optional) { write(`✗ ${dep.name}: ${e.message}\n`); failures++; }
        continue;
      }
      if (!/^[~^<>=v\d*xX| .-]*$/.test(dep.range || '') && !(doc['dist-tags'] || {})[dep.range]) {
        if (!dep.optional) { write(`✗ ${dep.name}@${dep.range}: only registry versions can be installed\n`); failures++; }
        continue;
      }
      const version = pickVersion(doc, dep.range || 'latest');
      if (!version) {
        if (!dep.optional) { write(`✗ ${dep.name}: no version matches ${dep.range}\n`); failures++; }
        continue;
      }
      if (dep.top) dep.version = version;
      if (found && found.version === version) continue;
      // At the top if that's free (or it's asked for); otherwise inside the dependent.
      const modules = dep.top || !versionAt(root, dep.name) ? root : path.join(dep.from, 'node_modules');
      const key = modules + '|' + dep.name;
      if (seen.has(key)) continue;
      seen.add(key);
      if (!placed.has(modules)) placed.set(modules, new Map());
      placed.get(modules).set(dep.name, version);
      downloads.push({ dep, version, manifest: doc.versions[version], target: path.join(modules, dep.name) });
    }
    const next = [];
    await inBatches(downloads, 8, async ({ dep, version, manifest, target }) => {
      try {
        const data = await get(manifest.dist.tarball);
        if (!checkIntegrity(data, manifest.dist)) throw new Error('the download was damaged');
        fs.rmSync(target, { recursive: true, force: true });
        untar(zlib.gunzipSync(data), target);
        const own = readJSON(path.join(target, 'package.json')) || manifest;
        const reason = nativeReason(target, own);
        if (reason) {
          fs.rmSync(target, { recursive: true, force: true });
          placed.get(path.dirname(target))?.delete(dep.name);
          skipped.push(`${dep.name} (${reason}, which can't run on iOS)`);
          if (!dep.optional && dep.top) failures++;
          return;
        }
        installed++;
        write(`+ ${dep.name}@${version}\n`);
        const deps = { ...(own.optionalDependencies || {}), ...(own.dependencies || {}) };
        for (const [name, range] of Object.entries(deps)) {
          next.push({ name, range, from: target, optional: !!(own.optionalDependencies || {})[name] && !(own.dependencies || {})[name] });
        }
      } catch (e) {
        if (!dep.optional) { write(`✗ ${dep.name}@${version}: ${e.message}\n`); failures++; }
      }
    });
    level = next;
  }

  if (specs.length) {
    pkg.dependencies = pkg.dependencies || {};
    for (const r of requested) {
      if (!r.version) continue;
      pkg.dependencies[r.name] = '^' + r.version;   // as npm saves it
    }
    pkg.dependencies = Object.fromEntries(Object.entries(pkg.dependencies).sort(([a], [b]) => a.localeCompare(b)));
    fs.writeFileSync(pkgFile, JSON.stringify(pkg, null, 2) + '\n');
  }
  for (const s of skipped) write(`! Left out ${s}\n`);
  write(`\n${installed} package${installed === 1 ? '' : 's'} installed${failures ? `, ${failures} failed` : ''}.\n`);
  return failures ? 1 : 0;
}
