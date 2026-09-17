// Identity records for destructive cleanup.
//
// Why this exists: cleanup must stop a proxy process and remove a PAC that THIS tool
// installed, and must never touch a look-alike - another project's proxy.mjs on the same
// port, a user's own local PAC server, or a PID that Windows recycled. Pattern matching a
// command line ("/proxy\.mjs/ + port") or a URL shape ("localhost/proxy.pac") is too
// broad, so ownership is proved by records we wrote ourselves.
//
// Records live in ONE machine-global place, never inside the state dir, because the whole
// point is to survive both a wiped state and a cleanup invocation that uses a different
// --state (the real incident: the proxy was started by the packaged exe under
// %LOCALAPPDATA%\wx-sph-dl while cleanup ran from the CLI checkout - a base-relative
// record would not have matched, which is exactly the case that must be provable):
//
//   <LOCALAPPDATA>/wx-sph-dl/records/proxy-registry.json : [{pid, script, port, state, startedAt}]
//   <LOCALAPPDATA>/wx-sph-dl/records/pac-endpoints.json  : [{url, state, ts}]
//
// WXSPH_RECORDS overrides the directory (used by the regression tests for isolation).
import fs from 'node:fs';
import path from 'node:path';

export const RECORDS_DIRNAME = 'records';

export function recordsRoot() {
  if (process.env.WXSPH_RECORDS) return path.resolve(process.env.WXSPH_RECORDS);
  const la = process.env.LOCALAPPDATA || '';
  if (la) return path.join(la, 'wx-sph-dl', RECORDS_DIRNAME);
  const home = process.env.HOME || process.cwd();
  return path.join(home, '.wx-sph-dl', RECORDS_DIRNAME);
}

function readJSONArray(file) {
  try {
    const raw = fs.readFileSync(file, 'utf8').replace(/^\uFEFF/, '');
    const v = JSON.parse(raw);
    return Array.isArray(v) ? v : [];
  } catch {
    return [];
  }
}

function writeJSON(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify(value, null, 2) + '\n', 'utf8');
}

export function normalizePath(p) {
  return path.resolve(String(p)).replace(/\\/g, '/').toLowerCase();
}

export function isAlive(pid) {
  const n = Number(pid);
  if (!Number.isFinite(n) || n <= 0) return false;
  try { process.kill(n, 0); return true; } catch { return false; }
}

// ---------- running proxies ----------
export function proxyRegistryFile() {
  return path.join(recordsRoot(), 'proxy-registry.json');
}

export function readProxyRecords() {
  return readJSONArray(proxyRegistryFile()).filter((r) => r && isAlive(r.pid));
}

export function addProxyRecord(rec) {
  const file = proxyRegistryFile();
  const kept = readJSONArray(file).filter((r) => r && isAlive(r.pid) && Number(r.pid) !== Number(rec.pid));
  kept.push(rec);
  writeJSON(file, kept.slice(-20));
}

export function removeProxyRecord(pid) {
  const file = proxyRegistryFile();
  if (!fs.existsSync(file)) return;
  writeJSON(file, readJSONArray(file).filter((r) => Number(r && r.pid) !== Number(pid)));
}

// ---------- PAC endpoints this tool installed ----------
function pacKey(u) {
  return String(u || '').trim().replace(/\/+$/, '').toLowerCase();
}

export function pacEndpointsFile() {
  return path.join(recordsRoot(), 'pac-endpoints.json');
}

export function readPacEndpoints() {
  return readJSONArray(pacEndpointsFile());
}

export function addPacEndpoint(ep) {
  const file = pacEndpointsFile();
  const kept = readJSONArray(file).filter((r) => r && pacKey(r.url) !== pacKey(ep.url));
  kept.push(ep);
  writeJSON(file, kept.slice(-20));
}

export function ownsPacUrl(url) {
  return readPacEndpoints().some((r) => r && pacKey(r.url) === pacKey(url));
}

// ---------- canonical install paths for this tool's proxy script ----------
// A recorded script must resolve to one of the known install locations of THIS tool, so a
// same-basename proxy.mjs from an unrelated project can never satisfy the ownership check.
export function canonicalProxyScripts(stateDir, hereDir) {
  const set = new Set();
  const add = (p) => { if (p) set.add(normalizePath(p)); };
  add(path.join(hereDir, 'proxy.mjs'));                          // this script's own directory
  const base = path.dirname(path.resolve(stateDir));             // install base of this invocation
  add(path.join(base, 'proxy.mjs'));
  add(path.join(base, 'scripts', 'proxy.mjs'));
  const la = process.env.LOCALAPPDATA || '';
  add(path.join(la, 'wx-sph-dl', 'scripts', 'proxy.mjs'));       // packaged single-file exe
  add(path.join(la, 'wx-sph-dl', 'proxy.mjs'));
  const runtimeDir = path.dirname(process.execPath);             // <base>/runtime/node.exe
  add(path.join(runtimeDir, 'scripts', 'proxy.mjs'));
  add(path.join(path.dirname(runtimeDir), 'scripts', 'proxy.mjs'));
  return set;
}
