// MITM 代理：只抓腾讯系域名的视频取流地址（证书由 Windows PKI 签发，无需 openssl）
// 用法: node proxy.mjs --port 18080 --state <stateDir> --pac <pacFile> [--fallback host:port|DIRECT]
import http from 'node:http';
import https from 'node:https';
import tls from 'node:tls';
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { addProxyRecord, removeProxyRecord } from './records.mjs';
import { fileURLToPath } from 'node:url';

const argv = process.argv.slice(2);
const arg = (name, dflt) => {
  const i = argv.indexOf('--' + name);
  return i >= 0 && argv[i + 1] ? argv[i + 1] : dflt;
};

const HERE = path.dirname(fileURLToPath(import.meta.url));
const PS_EXE = process.env.WXSPH_PS || 'C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe';
const CERTS_PS = path.join(HERE, 'ps', 'certs.ps1');

const PORT = Number(arg('port', '18080'));
const STATE = path.resolve(arg('state', './state'));
const PACFILE = path.resolve(arg('pac', path.join(STATE, 'proxy.pac')));
const FALLBACK = arg('fallback', 'DIRECT');

const CERTDIR = path.join(STATE, 'certs');
const CA_PFX = path.join(CERTDIR, 'ca.pfx');
const CA_CRT = path.join(CERTDIR, 'ca.crt');
const PASS_FILE = path.join(CERTDIR, 'pass.txt');
const CAPTURE = path.join(STATE, 'capture.jsonl');
const VIDEO_INDEX = path.join(STATE, 'videos.jsonl');

for (const d of [STATE, CERTDIR]) fs.mkdirSync(d, { recursive: true });

const log = (s) => {
  const line = `${new Date().toISOString()} ${s}`;
  fs.appendFileSync(path.join(STATE, 'proxy.log'), line + '\n');
  console.log(line.slice(0, 300));
};

// ---------- CA / 证书（Windows PKI，PFX 直接喂给 Node tls） ----------
function runCerts(mode, extra = []) {
  const r = spawnSync(PS_EXE, ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', CERTS_PS,
    '-Mode', mode, '-State', STATE, ...extra], { encoding: 'utf8', timeout: 120000 });
  const out = `${r.stdout || ''}${r.stderr || ''}`.trim();
  return { ok: r.status === 0, out };
}

function passphrase() {
  const enc = 'utf8';
  let t = fs.readFileSync(PASS_FILE, enc);
  if (t.charCodeAt(0) === 0xFEFF) t = t.slice(1);
  return t.trim();
}

// Always let certs.ps1 decide. It reuses this state's CA only while that exact
// certificate is still in the store, and regenerates otherwise. Testing "ca.pfx
// exists" here used to hide a CA that had been purged from the store, which silently
// broke every leaf issued afterwards.
function ensureCa() {
  const r = runCerts('ca');
  log((r.ok ? (r.out.includes('CA-EXISTS') ? 'CA reuse: ' : 'CA ready: ') : 'CA FAILED: ') + r.out);
  return r.ok && fs.existsSync(CA_PFX) && fs.existsSync(CA_CRT);
}

if (!ensureCa()) {
  log('FATAL: cannot create local CA via Windows PKI; proxy cannot start');
  process.exit(1);
}

const ctxCache = new Map();
function contextFor(host) {
  if (ctxCache.has(host)) return ctxCache.get(host);
  const safe = host.replace(/[^A-Za-z0-9._-]/g, '_');
  const pfx = path.join(CERTDIR, `leaf-${safe}.pfx`);
  // Always ask certs.ps1: it re-issues when the recorded CA changed, and it verifies
  // that the exported PFX chain is exactly {leaf + the CA this state owns} before we
  // are allowed to serve it.
  const r = runCerts('leaf', ['-HostName', host]);
  log((r.ok ? (r.out.includes('LEAF-EXISTS') ? 'leaf reuse: ' : 'leaf ready: ') : 'leaf FAILED: ') + r.out);
  if (!r.ok || !fs.existsSync(pfx)) throw new Error(`leaf cert unavailable for ${host}: ${r.out}`);
  const ctx = tls.createSecureContext({ pfx: fs.readFileSync(pfx), passphrase: passphrase() });
  ctxCache.set(host, ctx);
  return ctx;
}

// ---------- 抓取记录 ----------
const isVideo = (url) => /\/251\/2030\d\/stodownload|\.mp4(\?|$)/i.test(url);
const seen = new Set();

function recordVideo(url) {
  let u;
  try { u = new URL(url); } catch { return; }
  const key = [u.searchParams.get('encfilekey'), u.searchParams.get('uzid'), u.searchParams.get('basedata')].join('|');
  if (seen.has(key)) return;
  seen.add(key);
  fs.appendFileSync(VIDEO_INDEX, JSON.stringify({ ts: Date.now(), url: url.replace(/&taskid=[^&]*/g, '') }) + '\n');
}

// ---------- 转发 ----------
function forward(req, res, { host, port, scheme }) {
  const headers = { ...req.headers, host };
  delete headers['proxy-connection'];
  const url = `${scheme}://${host}${req.url}`;
  const video = isVideo(url);
  const opts = { host, port: port || (scheme === 'https' ? 443 : 80), method: req.method, path: req.url, headers };

  const up = (scheme === 'https' ? https : http).request(opts, (upRes) => {
    if (video) {
      recordVideo(url);
      fs.appendFileSync(CAPTURE, JSON.stringify({
        ts: Date.now(), method: req.method, url,
        range: req.headers.range || null,
        status: upRes.statusCode,
        contentType: upRes.headers['content-type'] || null,
        contentRange: upRes.headers['content-range'] || null,
        encflag: upRes.headers['x-encflag'] ?? null,
        enclen: upRes.headers['x-enclen'] ?? null,
      }) + '\n');
      log(`VIDEO ${upRes.statusCode} enc=${upRes.headers['x-encflag'] ?? '-'}/${upRes.headers['x-enclen'] ?? '-'} ${url.slice(0, 120)}`);
    }
    res.writeHead(upRes.statusCode, upRes.headers);
    upRes.pipe(res);
  });
  up.on('error', (e) => { if (video) log(`UP-ERR ${e.message}`); try { res.writeHead(502); res.end('proxy error'); } catch { } });
  req.pipe(up);
}

const inner = http.createServer((req, res) => {
  const host = (req.headers.host || '').split(':')[0];
  forward(req, res, { host, port: Number((req.headers.host || '').split(':')[1]) || 443, scheme: 'https' });
});

const server = http.createServer((req, res) => {
  if (req.url === '/proxy.pac') {
    res.writeHead(200, { 'content-type': 'application/x-ns-proxy-autoconfig' });
    return res.end(fs.existsSync(PACFILE) ? fs.readFileSync(PACFILE) : 'function FindProxyForURL(){return "DIRECT";}');
  }
  let u; try { u = new URL(req.url); } catch { res.writeHead(400); return res.end('bad request'); }
  forward(req, res, { host: u.hostname, port: Number(u.port) || 80, scheme: 'http' });
});

server.on('connect', (req, clientSocket, head) => {
  const [host, portStr] = req.url.split(':');
  clientSocket.write('HTTP/1.1 200 Connection Established\r\n\r\n');
  if (head && head.length) clientSocket.unshift(head);
  let ctx;
  try { ctx = contextFor(host); } catch (e) { log(`CERT-ERR ${host} ${e.message}`); return clientSocket.destroy(); }
  const tlsSocket = new tls.TLSSocket(clientSocket, { isServer: true, secureContext: ctx, requestCert: false });
  tlsSocket.on('error', (e) => log(`TLS-ERR ${host} ${e.message}`));
  inner.emit('connection', tlsSocket);
});

server.listen(PORT, '127.0.0.1', () => {
  log(`mitm proxy listening on 127.0.0.1:${PORT}  pac=${PACFILE}  fallback=${FALLBACK}`);
  // Record our own identity (pid + absolute script path + port + start time) in a file
  // OUTSIDE the state dir. cleanup proves ownership from this record before it kills a
  // process on this port, which is what keeps another project's proxy.mjs safe.
  try {
    addProxyRecord({
      pid: process.pid,
      script: fileURLToPath(import.meta.url),
      port: PORT,
      state: STATE,
      startedAt: new Date().toISOString(),
    });
  } catch (e) {
    log('RECORD-ERR ' + e.message);
  }
});

const dropRecord = () => { try { removeProxyRecord(process.pid); } catch { } };
process.on('exit', dropRecord);
for (const sig of ['SIGINT', 'SIGTERM', 'SIGHUP', 'SIGBREAK']) {
  try { process.on(sig, () => { dropRecord(); process.exit(0); }); } catch { }
}
