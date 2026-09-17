// 自检：验证本地 MITM 的证书链（Windows PKI 签发）能被信任方正常握手，且能代理取到 200。
// 用法: node tests/mitm-selftest.mjs [--state <dir>] [--port 18099] [--host channels.weixin.qq.com]
import net from 'node:net';
import tls from 'node:tls';
import fs from 'node:fs';
import path from 'node:path';
import { spawn, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
// 仓库布局: <root>/tests/mitm-selftest.mjs ；打包布局: <base>/scripts/mitm-selftest.mjs
// 统一按“proxy.mjs 所在目录”定位根，避免两种布局互相踩
const ROOT = [HERE, path.resolve(HERE, '..')].find((d) => fs.existsSync(path.join(d, 'proxy.mjs'))) || HERE;
const argv = process.argv.slice(2);
const arg = (n, d) => { const i = argv.indexOf('--' + n); return i >= 0 && argv[i + 1] ? argv[i + 1] : d; };

const HOST = arg('host', 'channels.weixin.qq.com');
const PORT = Number(arg('port', '18099'));
const STATE = path.resolve(arg('state', path.join(ROOT, 'state-selftest')));
const KEEP_STATE = argv.includes('--keep-state');

const say = (s) => console.log(s);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Start from a clean cert dir: a leftover ca.crt from an earlier generation must never
// be able to masquerade as the CA we are about to trust.
fs.mkdirSync(path.join(STATE, 'certs'), { recursive: true });
if (!KEEP_STATE) {
  for (const f of fs.readdirSync(path.join(STATE, 'certs'))) {
    if (/^(ca\.(pfx|crt|cer)|pass\.txt|catag\.txt|index\.json|leaf-.*\.pfx)$/.test(f)) {
      fs.rmSync(path.join(STATE, 'certs', f), { force: true });
    }
  }
}

function waitListen(port, ms = 15000) {
  const end = Date.now() + ms;
  return new Promise((resolve) => {
    const tick = () => {
      const s = net.connect({ host: '127.0.0.1', port }, () => { s.destroy(); resolve(true); });
      s.on('error', () => { s.destroy(); Date.now() > end ? resolve(false) : setTimeout(tick, 250); });
    };
    tick();
  });
}

const proxy = spawn(process.execPath, [path.join(ROOT, 'proxy.mjs'), '--port', String(PORT), '--state', STATE],
  { stdio: ['ignore', 'pipe', 'pipe'] });
let proxyOut = '';
proxy.stdout.on('data', (d) => { proxyOut += d; });
proxy.stderr.on('data', (d) => { proxyOut += d; });

// Walk what the server ACTUALLY sent: leaf first, then its issuer chain. This catches
// the failure mode where the PFX carries the wrong (same-subject) parent cert.
function servedChain(leafCert) {
  const out = [];
  let cur = leafCert;
  for (let i = 0; i < 6 && cur; i++) {
    out.push({ cn: (cur.subject && cur.subject.CN) || null, fingerprint: cur.fingerprint });
    const up = cur.issuerCertificate;
    if (!up || up.fingerprint === cur.fingerprint) break;
    cur = up;
  }
  return out;
}

let failed = false;
const check = (ok, msg) => { say(`${ok ? '✅' : '✗'} ${msg}`); if (!ok) failed = true; };

try {
  // 1) CA 是否生成（Windows PKI）
  if (!(await waitListen(PORT))) throw new Error('proxy 未在超时内监听\n' + proxyOut.slice(-800));
  const caPath = path.join(STATE, 'certs', 'ca.crt');
  check(fs.existsSync(caPath), `CA 已生成: ${caPath}`);
  const caPem = fs.readFileSync(caPath, 'utf8');
  check(/BEGIN CERTIFICATE/.test(caPem), 'CA 是 PEM 格式');

  // 2) 经 CONNECT 隧道做 TLS 握手，且显式信任我们的 CA
  const result = await new Promise((resolve) => {
    const sock = net.connect({ host: '127.0.0.1', port: PORT }, () => {
      sock.write(`CONNECT ${HOST}:443 HTTP/1.1\r\nHost: ${HOST}:443\r\n\r\n`);
    });
    let buf = '';
    let upgraded = false;
    const fail = (e) => resolve({ ok: false, err: String(e && e.message || e) });
    sock.on('data', (d) => {
      if (upgraded) return;
      buf += d.toString('latin1');
      if (!/^HTTP\/1\.[01] 200/.test(buf)) return;
      upgraded = true;
      const t = tls.connect({ socket: sock, ca: [caPem], servername: HOST }, () => {
        const peer = t.getPeerCertificate();
        const chain = servedChain(t.getPeerCertificate(true));
        const body = `GET /finder-preview/pages/sph?id=AI98twzu7x HTTP/1.1\r\nHost: ${HOST}\r\nUser-Agent: wx-sph-dl-selftest\r\nConnection: close\r\n\r\n`;
        t.write(body);
        let resp = '';
        t.on('data', (c) => { resp += c.toString('latin1'); });
        t.on('end', () => resolve({ ok: true, authorized: t.authorized, issuer: peer && peer.issuer, chain, status: (resp.match(/^HTTP\/1\.[01] (\d+)/) || [])[1], respHead: resp.slice(0, 120) }));
      });
      t.on('error', fail);
    });
    sock.on('error', fail);
    setTimeout(() => resolve({ ok: false, err: 'timeout' }), 45000);
  });

  if (!result.ok) throw new Error('握手/请求失败: ' + result.err);
  check(result.authorized === true, `TLS 握手通过且证书链被信任 (authorized=${result.authorized})`);
  check(/DSH Local MITM CA/.test(JSON.stringify(result.issuer || {})), '叶子证书的签发者是 DSH Local MITM CA: ' + JSON.stringify(result.issuer));
  const cn = (result.chain || []).map((c) => c.cn);
  check(cn.length === 2, `服务端发来的链正好两级（叶子 + CA），实为 ${cn.length}: ${cn.join(' -> ')}`);
  check(/^DSH Local MITM CA/.test(String(cn[1] || '')), '链的第二级就是本地 CA: ' + String(cn[1]));
  // ASCII marker so scripts (and the packaged exe selftest) can assert on the chain.
  say(`CHAIN depth=${cn.length} leaf=${cn[0]} ca=${cn[1] || '-'} chain-ok=${cn.length === 2 && /^DSH Local MITM CA/.test(String(cn[1] || ''))}`);
  check(result.status === '200', `经代理取到 HTTP ${result.status}（${HOST}）`);
} catch (e) {
  say('✗ ' + e.message);
  failed = true;
} finally {
  try { proxy.kill(); } catch { }
  await sleep(300);
  try { proxy.kill('SIGKILL'); } catch { }
  // 自检会产生临时 CA/叶子证书，必须自己清掉，别在用户证书存储里留垃圾
  try {
    spawnSync(process.env.WXSPH_PS || 'C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe',
      ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', path.join(ROOT, 'ps', 'certs.ps1'),
        '-Mode', 'cleanup', '-State', STATE], { encoding: 'utf8', timeout: 60000 });
  } catch { }
}

const certLog = (() => { try { return fs.readFileSync(path.join(STATE, 'proxy.log'), 'utf8').split('\n').filter((l) => /leaf ready|CA ready|TLS-ERR/.test(l)).slice(-3).join('\n'); } catch { return ''; } })();
if (certLog) say('\nproxy 证书相关日志:\n' + certLog);
say(failed ? '\nSELFTEST-FAIL' : '\nSELFTEST-OK');
process.exit(failed ? 1 : 0);
