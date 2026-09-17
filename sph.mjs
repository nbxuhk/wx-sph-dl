#!/usr/bin/env node
// wx-sph-dl —— 微信视频号（finder）视频下载工具
// 流程: setup → watch → key（需在微信里播放视频）→ decrypt → cleanup
import fs from 'node:fs';
import path from 'node:path';
import net from 'node:net';
import { spawn, spawnSync, execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { readProxyRecords, canonicalProxyScripts, normalizePath, ownsPacUrl, recordsRoot, readPacEndpoints } from './records.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const PS = path.join(HERE, 'ps', 'win.ps1');
const PS_EXE = process.env.WXSPH_PS || 'C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe';
const IS_WIN = process.platform === 'win32';

const argv = process.argv.slice(2);
const cmd = argv[0];
const opt = (name, dflt) => {
  const i = argv.indexOf('--' + name);
  return i >= 0 && argv[i + 1] ? argv[i + 1] : dflt;
};
const flag = (name) => argv.includes('--' + name);

const STATE = path.resolve(opt('state', path.join(HERE, 'state')));
const PORT = Number(opt('port', '18080'));
const OUT = path.resolve(opt('outdir', path.join(HERE, 'output')));
const KEY_LEN = 131072;                 // CDN 只加密文件前 128KB
const HEADS_DIR = path.join(STATE, 'heads');
const KEYS_DIR = path.join(STATE, 'keys');
const PROXY_PID = path.join(STATE, 'proxy.pid');
const SCAN_PIDS = path.join(STATE, 'scan.pids');

const TENCNT = /(^|\.)(qq\.com|weixin\.com|wechat\.com|qpic\.cn|gtimg\.cn|tencent\.com|wxs\.qq\.com|wxqcloud\.qq\.com)$/i;

const say = (...a) => console.log(...a);
const ensure = (d) => fs.mkdirSync(d, { recursive: true });
const stripBom = (s) => String(s).replace(/^\uFEFF/, '');
const readJSON = (f, dflt = null) => { try { return JSON.parse(stripBom(fs.readFileSync(f, 'utf8'))); } catch { return dflt; } };
// 备份这类“读错就会破坏用户网络”的文件用严格解析：失败必须中止，不能静默兜底
const readJSONStrict = (f) => JSON.parse(stripBom(fs.readFileSync(f, 'utf8')));
const redact = (s) => String(s).replace(/(token|encfilekey|sign|basedata|svrbypass|svrnonce|pass_ticket|exportkey|taskid)=[^&\s"']{2,}/gi, '$1=<r>');

const BACKUP_PATH = path.join(STATE, 'original-proxy.json');
const CERTS_PS = path.join(HERE, 'ps', 'certs.ps1');
const BACKUP_FIELDS = ['ProxyEnable', 'ProxyServer', 'ProxyOverride', 'AutoConfigURL'];

// 任何“会动用户网络”的失败都必须停在这里，且必须留下可追溯记录
function fail(msg) {
  say('✗ ' + msg);
  try { ensure(STATE); fs.appendFileSync(path.join(STATE, 'sph.log'), `${new Date().toISOString()} FAIL ${msg.replace(/\n/g, ' | ')}\n`); } catch { }
  process.exit(1);
}

function certsPs(mode, extra = []) {
  const r = spawnSync(PS_EXE, ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', CERTS_PS,
    '-Mode', mode, '-State', STATE, ...extra], { encoding: 'utf8', timeout: 120000 });
  const out = `${r.stdout || ''}${r.stderr || ''}`.trim();
  return { ok: r.status === 0, out };
}

// 备份方案：存在 + 无 BOM 可解析 + schema 合法（空对象/类型错/缺字段全部拒绝）
function validateBackup(o) {
  const errs = [];
  if (o === null || typeof o !== 'object' || Array.isArray(o)) return ['不是 JSON 对象'];
  const has = (k) => Object.prototype.hasOwnProperty.call(o, k);
  for (const k of BACKUP_FIELDS) if (!has(k)) errs.push(`缺字段 ${k}`);
  if (has('ProxyEnable')) {
    const v = o.ProxyEnable;
    if (typeof v !== 'number' || !Number.isInteger(v) || (v !== 0 && v !== 1)) errs.push('ProxyEnable 必须是整数 0 或 1');
  }
  for (const k of ['ProxyServer', 'ProxyOverride', 'AutoConfigURL']) {
    if (has(k) && typeof o[k] !== 'string') errs.push(`${k} 必须是字符串`);
  }
  return errs;
}

function readCurrentProxy() {
  const r = ps('getproxy');
  if (r.status !== 0) return { ok: false, err: String(r.stdout || r.stderr || '').trim() || `exit ${r.status}` };
  const m = String(r.stdout || '').match(/PROXY\s+(\{[\s\S]*\})/);
  if (!m) return { ok: false, err: '输出无法解析' };
  try { return { ok: true, value: JSON.parse(m[1]) }; } catch (e) { return { ok: false, err: e.message }; }
}

/**
 * 关键安全闸门：**任何网络改动之前**必须有一份可验证的代理备份。
 * - 非 dry-run：缺失则先 saveproxy，并校验其退出码与产物；任何一步不满足即中止。
 * - dry-run：不臆测，直接只读读取“当前真实设置”并如实呈现。
 */
function requireValidBackup({ dryRun }) {
  if (!fs.existsSync(BACKUP_PATH)) {
    if (dryRun) return { ok: false, missing: true };
    const r = ps('saveproxy');
    const out = String(r.stdout || '').trim();
    if (r.status !== 0 || !/^SAVED\b/m.test(out)) {
      fail(`代理备份失败，setup 已中止（未做任何网络改动）。\n  saveproxy 退出码=${r.status}\n  输出：${out || '(空)'}`);
    }
    if (!fs.existsSync(BACKUP_PATH)) fail('代理备份命令报成功，但备份文件不存在 —— setup 已中止（未做任何网络改动）。');
  }
  let parsed;
  try {
    parsed = readJSONStrict(BACKUP_PATH);
  } catch (e) {
    fail(`代理备份无法解析：${BACKUP_PATH}\n  ${String(e.message).split('\n')[0]}\n  为防止把你原有代理改成 DIRECT（会打断上网），已中止且未做任何网络改动。\n  处理：删除该文件后重跑 setup 重新备份。`);
  }
  const errs = validateBackup(parsed);
  if (errs.length) {
    fail(`代理备份 schema 不合法：${errs.join('；')}\n  为防止把你原有代理改成 DIRECT（会打断上网），已中止且未做任何网络改动。\n  处理：删除该文件后重跑 setup 重新备份。`);
  }
  return { ok: true, value: parsed };
}


function ffprobePath() {
  const cands = [
    process.env.WXSPH_FFPROBE,
    path.join(process.env.LOCALAPPDATA || '', 'Microsoft', 'WinGet', 'Packages'),
    'ffprobe',
  ];
  for (const c of cands) {
    if (!c) continue;
    try {
      if (fs.existsSync(c) && fs.statSync(c).isDirectory()) {
        for (const d of fs.readdirSync(c)) {
          const p = path.join(c, d);
          if (!fs.statSync(p).isDirectory()) continue;
          const hit = findFile(p, 'ffprobe.exe', 6);
          if (hit) return hit;
        }
      } else if (fs.existsSync(c)) return c;
    } catch { }
  }
  try { execFileSync('ffprobe', ['-version'], { stdio: 'ignore' }); return 'ffprobe'; } catch { return null; }
}
function findFile(dir, name, depth) {
  if (depth <= 0) return null;
  let ents = [];
  try { ents = fs.readdirSync(dir, { withFileTypes: true }); } catch { return null; }
  for (const e of ents) {
    const p = path.join(dir, e.name);
    if (e.isFile() && e.name.toLowerCase() === name.toLowerCase()) return p;
    if (e.isDirectory()) { const r = findFile(p, name, depth - 1); if (r) return r; }
  }
  return null;
}

// 证书由 Windows PKI 生成（ps/certs.ps1），这里不再依赖 openssl

function ps(mode, extra = [], inherit = true, timeout = 60000) {
  const args = ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', PS, '-Mode', mode, '-State', STATE, ...extra];
  return spawnSync(PS_EXE, args, inherit ? { encoding: 'utf8', timeout } : { timeout });
}

function psDetached(mode, extra = []) {
  const args = ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', PS, '-Mode', mode, '-State', STATE, ...extra];
  const p = spawn(PS_EXE, args, { detached: true, stdio: 'ignore', windowsHide: true });
  p.unref();
  return p.pid;
}

function waitPort(port, ms = 8000) {
  const end = Date.now() + ms;
  return new Promise((resolve) => {
    const tick = () => {
      const s = net.connect({ host: '127.0.0.1', port }, () => { s.destroy(); resolve(true); });
      s.on('error', () => { s.destroy(); Date.now() > end ? resolve(false) : setTimeout(tick, 250); });
    };
    tick();
  });
}

function buildPac(fallback) {
  const fb = fallback ? `PROXY ${fallback}` : 'DIRECT';
  return `function FindProxyForURL(url, host) {
  if (isPlainHostName(host) || shExpMatch(host, "127.*") || shExpMatch(host, "10.*") ||
      shExpMatch(host, "192.168.*") || shExpMatch(host, "172.1[6-9].*") ||
      shExpMatch(host, "172.2[0-9].*") || shExpMatch(host, "172.3[01].*") || host == "localhost") return "DIRECT";
  if (/${TENCNT.source}/.test(host)) return "PROXY 127.0.0.1:${PORT}";
  return "${fb}";
}
`;
}

function videosFromLog() {
  const f = path.join(STATE, 'videos.jsonl');
  if (!fs.existsSync(f)) return [];
  const out = [];
  for (const line of fs.readFileSync(f, 'utf8').split('\n')) {
    if (!line.trim()) continue;
    try { out.push(JSON.parse(line)); } catch { }
  }
  return out;
}

// ---------------- setup ----------------
async function setup() {
  const dryRun = flag('dry-run');
  ensure(STATE); ensure(OUT); ensure(HEADS_DIR); ensure(KEYS_DIR);

  if (!IS_WIN) fail('目前只支持 Windows（依赖 Windows PKI 与注册表代理设置）');
  const pki = certsPs('check');
  if (!pki.ok) fail(`证书环境不可用：${pki.out}\n  需要 Windows PowerShell 5.1 的 PKI 模块（系统自带）。`);

  // ---- 安全闸门：备份必须可验证，否则绝不动网络 ----
  const backup = requireValidBackup({ dryRun });

  let orig = {};
  let backupState = '';
  if (backup.ok) {
    orig = backup.value;
    backupState = `已备份（${BACKUP_PATH}）`;
  } else {
    // dry-run 且尚无备份：只读读取当前真实设置，如实呈现，不臆测
    const cur = readCurrentProxy();
    if (cur.ok) {
      orig = cur.value;
      backupState = `尚未备份；当前系统代理（只读读取）= ProxyEnable ${cur.value.ProxyEnable} / ProxyServer ${JSON.stringify(cur.value.ProxyServer || '')} / AutoConfigURL ${JSON.stringify(cur.value.AutoConfigURL || '')}`;
      say('· [dry-run] 尚无代理备份，正式运行时 setup 会先 saveproxy 并校验，失败即中止。');
      say(`  当前系统代理：ProxyEnable=${cur.value.ProxyEnable}  ProxyServer=${cur.value.ProxyServer || '(空)'}  AutoConfigURL=${cur.value.AutoConfigURL || '(空)'}`);
    } else {
      backupState = `尚未备份；且当前系统代理读取失败：${cur.err}`;
      say(`· [dry-run] 尚无代理备份，且无法读取当前系统代理：${cur.err}`);
    }
  }

  const hadProxy = Number(orig.ProxyEnable) === 1 && !!orig.ProxyServer;
  const fallback = hadProxy ? String(orig.ProxyServer) : '';
  const pacText = buildPac(fallback);

  // PAC 自检：原代理启用时，必须原样出现在 PAC 兜底里
  if (hadProxy && !pacText.includes(`PROXY ${fallback}`)) {
    fail('PAC 自检失败：未能保留你原有的代理，setup 已中止（未做任何网络改动）。');
  }
  if (!hadProxy) {
    say('· 注意：按当前设置你并未启用系统代理 —— PAC 兜底将是 DIRECT。');
  }
  say(`· PAC 已生成（腾讯域名 → 127.0.0.1:${PORT}，其余 → ${fallback || 'DIRECT'}）`);

  if (dryRun) {
    say('\n[dry-run] 只做校验与生成，不改系统设置、不装 CA、不起代理。\n');
    say(`代理备份：${backupState}`);
    say('PAC 内容：\n');
    say(pacText);
    return;
  }

  const pac = path.join(STATE, 'proxy.pac');
  fs.writeFileSync(pac, pacText, 'utf8');

  // 起代理（证书由 Windows PKI 生成，无需 openssl）
  if (fs.existsSync(PROXY_PID)) {
    const old = Number(fs.readFileSync(PROXY_PID, 'utf8'));
    try { process.kill(old, 0); say(`· 代理已在运行 (pid ${old})`); } catch { fs.rmSync(PROXY_PID); }
  }
  if (!fs.existsSync(PROXY_PID)) {
    const logFd = fs.openSync(path.join(STATE, 'proxy.out'), 'a');
    const p = spawn(process.execPath, [path.join(HERE, 'proxy.mjs'), '--port', String(PORT), '--state', STATE, '--pac', pac],
      { detached: true, stdio: ['ignore', logFd, logFd], windowsHide: true });
    p.unref();
    fs.writeFileSync(PROXY_PID, String(p.pid));
    say(`· 代理已启动 (pid ${p.pid})`);
  }
  if (!(await waitPort(PORT))) fail('代理端口未就绪，看 state/proxy.log');

  // 安装 CA（用户级，无需管理员）
  const caCrt = path.join(STATE, 'certs', 'ca.crt');
  if (!fs.existsSync(caCrt)) fail(`CA 证书不存在：${caCrt}（代理启动时应已生成，请检查 state/proxy.log）`);
  const r = spawnSync('certutil', ['-user', '-addstore', 'Root', caCrt], { encoding: 'utf8' });
  const info = ps('certinfo');
  if ((info.stdout || '').includes('present')) {
    say('· 临时 CA 已装入 当前用户\\受信任的根（cleanup 时移除）');
  } else {
    fail(`CA 安装失败：${((r.stderr || '') + (r.stdout || '')).trim()}`);
  }

  // 指向 PAC
  const sp = ps('setpac', ['-PacUrl', `http://127.0.0.1:${PORT}/proxy.pac`]);
  if (sp.status !== 0) fail('设置系统代理失败，请检查注册表权限');
  say('· 系统代理已指向 PAC');
  say('\n下一步：让微信走一遍这条路 ——');
  say('  1) 完全退出微信并重新打开（让它读到新代理）');
  say('  2) 在微信里打开视频号链接并播放（或循环播放）');
  say('  3) 然后运行： node sph.mjs watch');
}

// ---------------- doctor ----------------
async function doctor() {
  ensure(STATE);
  let bad = 0;
  const ok = (cond, label, extra = '') => { say(`${cond ? '✅' : '✗'} ${label}${extra ? '  —— ' + extra : ''}`); if (!cond) bad++; };

  ok(IS_WIN, '运行平台是 Windows');
  const pki = certsPs('check');
  ok(pki.ok, 'Windows PKI 可用（New-SelfSignedCertificate + -Signer）', pki.out);
  const certutil = spawnSync('certutil', ['-?'], { encoding: 'utf8' });
  ok(fs.existsSync('C:\\Windows\\System32\\certutil.exe'), 'certutil 存在');

  const cur = readCurrentProxy();
  ok(cur.ok, '可读注册表代理设置', cur.ok ? `ProxyEnable=${cur.value.ProxyEnable} ProxyServer=${cur.value.ProxyServer || '(空)'} AutoConfigURL=${cur.value.AutoConfigURL || '(空)'}` : cur.err);
  if (cur.ok) {
    const ac = String(cur.value.AutoConfigURL || '');
    const recorded = ac !== '' && ownsPacUrl(ac);
    ok(!recorded, '系统里没有残留的本工具 PAC', recorded ? `${ac} —— 运行 cleanup 移除（或 ps/win.ps1 -Mode dropownpac）` : '');
    if (!recorded && /^https?:\/\/(127\.0\.0\.1|localhost)(:\d+)?\/proxy\.pac$/i.test(ac)) {
      say(`· 注意：AutoConfigURL=${ac} 形似本地 PAC，但不在本工具的安装记录里 —— 视为你自己的设置，不动它`);
    }
  }
  say(`· 运行记录：${recordsRoot()}（proxies=${readProxyRecords().length} pac=${readPacEndpoints().length}）`);

  const backupExists = fs.existsSync(BACKUP_PATH);
  if (backupExists) {
    let errs = [];
    try { errs = validateBackup(readJSONStrict(BACKUP_PATH)); } catch (e) { errs = ['无法解析: ' + e.message.split('\n')[0]]; }
    ok(errs.length === 0, '代理备份存在且 schema 合法', errs.join('；'));
  } else {
    say('· 代理备份尚不存在（首次 setup 会自动创建并校验）');
  }

  const portInUse = await waitPort(PORT, 500);
  say(`· 代理端口 ${PORT}：${portInUse ? '已在监听（可能已有实例在运行）' : '空闲'}`);

  const wechat = spawnSync(PS_EXE, ['-NoProfile', '-Command',
    "(Get-Process Weixin,WeChatAppEx -ErrorAction SilentlyContinue | Measure-Object).Count"], { encoding: 'utf8' });
  const n = Number(String(wechat.stdout || '0').trim()) || 0;
  say(`· 微信进程数：${n}${n === 0 ? '  ← 抓包前请先登录并打开微信' : ''}`);

  const residue = certResidue();
  ok(residue.root === 0, '受信任根里没有本工具的残留 CA', residue.root ? `${residue.root} 个，运行 cleanup 清理` : '');
  say(`· 证书残留：My=${residue.my} CA=${residue.intermediate} Root=${residue.root}${residue.total ? '  ← 建议运行 cleanup' : '（干净）'}`);

  say(bad ? `\nDOCTOR-FAIL (${bad} 项不满足)` : '\nDOCTOR-OK');
  return bad === 0 ? 0 : 1;
}

// Count certs this tool owns in each user store. Subject AND issuer are matched, so
// leaves signed by a stale CA still show up even after the CA itself is gone.
function certResidue() {
  const script = [
    `$s='*DSH Local MITM CA*'`,
    `$n=@{my=0;intermediate=0;root=0}`,
    `$n.my=@(Get-ChildItem Cert:\\CurrentUser\\My -ErrorAction SilentlyContinue | Where-Object { $_.Subject -like $s -or $_.Issuer -like $s }).Count`,
    `$n.intermediate=@(Get-ChildItem Cert:\\CurrentUser\\CA -ErrorAction SilentlyContinue | Where-Object { $_.Subject -like $s -or $_.Issuer -like $s }).Count`,
    `$n.root=@(Get-ChildItem Cert:\\CurrentUser\\Root -ErrorAction SilentlyContinue | Where-Object { $_.Subject -like $s -or $_.Issuer -like $s }).Count`,
    `Write-Output ($n.my.ToString() + ' ' + $n.intermediate.ToString() + ' ' + $n.root.ToString())`,
  ].join('; ');
  const r = spawnSync(PS_EXE, ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', script], { encoding: 'utf8' });
  const m = String(r.stdout || '').trim().match(/(\d+)\s+(\d+)\s+(\d+)/);
  const out = { my: 0, intermediate: 0, root: 0, total: 0 };
  if (m) { out.my = Number(m[1]); out.intermediate = Number(m[2]); out.root = Number(m[3]); }
  out.total = out.my + out.intermediate + out.root;
  return out;
}

// ---------------- status ----------------
async function status() {
  const listening = await waitPort(PORT, 800);
  const ca = ps('certinfo');
  const orig = readJSON(path.join(STATE, 'original-proxy.json'), null);
  say('状态');
  say('  代理监听:', listening ? `是 (127.0.0.1:${PORT})` : '否');
  say('  代理 pid :', fs.existsSync(PROXY_PID) ? fs.readFileSync(PROXY_PID, 'utf8').trim() : '-');
  say('  临时 CA  :', (ca.stdout || '').trim() || '?');
  say('  代理备份 :', orig ? JSON.stringify({ ProxyEnable: orig.ProxyEnable, ProxyServer: orig.ProxyServer, AutoConfigURL: orig.AutoConfigURL || '' }) : '无');
  const vids = videosFromLog();
  say('  抓到视频 :', vids.length, '条唯一取流地址');
  const heads = fs.existsSync(HEADS_DIR) ? fs.readdirSync(HEADS_DIR).filter((f) => f.endsWith('.bin')) : [];
  say('  密文头   :', heads.length, '个');
  const keystream = path.join(KEYS_DIR, 'keystream.bin');
  say('  密钥流   :', fs.existsSync(keystream) ? `${keystream} (${fs.statSync(keystream).size} bytes)` : '未找到');
  if (vids.length) {
    say('\n  最近 5 条取流:');
    for (const v of vids.slice(-5)) {
      let h = '';
      try { const u = new URL(v.url); h = `${u.host}${u.pathname} encfilekey.len=${(u.searchParams.get('encfilekey') || '').length}`; } catch { }
      say('   ', new Date(v.ts).toLocaleString(), h);
    }
  }
}

// ---------------- watch：下载密文头 ----------------
async function watch() {
  ensure(HEADS_DIR);
  const n = Number(opt('head', '8'));
  const vids = videosFromLog();
  if (!vids.length) { say('还没有抓到取流地址。确认 setup 完成且微信已在播放视频。'); return; }
  const uniq = [];
  const seen = new Set();
  for (let i = vids.length - 1; i >= 0 && uniq.length < n; i--) {
    const v = vids[i];
    let k = v.url;
    try { const u = new URL(v.url); k = [u.searchParams.get('encfilekey'), u.searchParams.get('uzid'), u.searchParams.get('basedata')].join('|'); } catch { }
    if (seen.has(k)) continue;
    seen.add(k);
    uniq.push(v);
  }
  const index = [];
  let i = 0;
  for (const v of uniq) {
    i++;
    const name = `head${i}`;
    const file = path.join(HEADS_DIR, name + '.bin');
    try {
      const res = await fetch(v.url, {
        headers: {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36 MicroMessenger/7.0.20.1781(0x6700143B) WindowsWechat(0x63090a13) XWEB/8447',
          Referer: 'https://channels.weixin.qq.com/',
          Range: `bytes=0-${KEY_LEN * 2 - 1}`,
        },
      });
      if (!res.ok && res.status !== 206) { say(`  ${name}: HTTP ${res.status}`); continue; }
      const buf = Buffer.from(await res.arrayBuffer());
      fs.writeFileSync(file, buf);
      index.push({ name, url: v.url, bytes: buf.length, encflag: res.headers.get('x-encflag'), enclen: res.headers.get('x-enclen'), ts: v.ts });
      say(`  ${name}: ${buf.length} bytes  x-encflag=${res.headers.get('x-encflag')} x-enclen=${res.headers.get('x-enclen')}`);
    } catch (e) { say(`  ${name}: ERR ${e.message}`); }
  }
  fs.writeFileSync(path.join(HEADS_DIR, 'index.json'), JSON.stringify(index, null, 2));
  say(`\n已保存 ${index.length} 个密文头 → state/heads/`);
  say('下一步：保持视频在播放，然后运行  node sph.mjs key');
}

// ---------------- key：内存里找密钥流 ----------------
async function key() {
  ensure(KEYS_DIR);
  const heads = fs.existsSync(HEADS_DIR) ? fs.readdirSync(HEADS_DIR).filter((f) => f.endsWith('.bin')) : [];
  if (!heads.length) { say('没有密文头，先跑 node sph.mjs watch（并确保抓到的是你正在播的那个视频）'); return; }
  if (!IS_WIN) { say('内存扫描目前只实现了 Windows'); return; }
  const minutes = Number(opt('minutes', '20'));
  const shards = Number(opt('shards', '3'));
  say(`用 ${heads.length} 个密文头做特征，${shards} 个分片并行扫描内存，最长 ${minutes} 分钟。`);
  say('⚠ 现在请在微信里播放目标视频并保持 30 秒以上（密钥流只在播放期间驻留内存）\n');
  const found = path.join(KEYS_DIR, 'FOUND.txt');
  fs.rmSync(found, { force: true });
  const pids = [];
  for (let s = 0; s < shards; s++) {
    pids.push(psDetached('scan', ['-HeadsDir', HEADS_DIR, '-OutFile', KEYS_DIR, '-Shard', String(s), '-Shards', String(shards), '-Minutes', String(minutes)]));
  }
  fs.writeFileSync(SCAN_PIDS, pids.join('\n'));
  const end = Date.now() + minutes * 60 * 1000;
  while (Date.now() < end) {
    await new Promise((r) => setTimeout(r, 3000));
    if (fs.existsSync(found)) {
      const line = fs.readFileSync(found, 'utf8').trim();
      const m = line.match(/file=(.+)$/m);
      if (m && fs.existsSync(m[1])) {
        fs.copyFileSync(m[1], path.join(KEYS_DIR, 'keystream.bin'));
        say('✓ 找到密钥流：' + line);
        say(`  已保存 state/keys/keystream.bin`);
        killScanners();
        say('\n下一步：node sph.mjs decrypt   （自动下载并解密对应视频）');
        return;
      }
    }
  }
  killScanners();
  say('✗ 超时未找到。常见原因：扫描与播放没重叠（请保持播放 30s+ 再跑一次 key）；或密文头不是正在播放的那个视频（重新 watch）。');
}

function killScanners() {
  if (!fs.existsSync(SCAN_PIDS)) return;
  for (const s of fs.readFileSync(SCAN_PIDS, 'utf8').split('\n')) {
    const pid = Number(s.trim());
    if (!pid) continue;
    try { process.kill(pid); } catch { }
  }
  fs.rmSync(SCAN_PIDS, { force: true });
}

// ---------------- decrypt ----------------
async function decrypt() {
  const ksFile = path.resolve(opt('key', path.join(KEYS_DIR, 'keystream.bin')));
  if (!fs.existsSync(ksFile)) { say('没有密钥流，先跑 node sph.mjs key'); return; }
  const ks = fs.readFileSync(ksFile);

  // 直接解密本地密文（离线/自测用）
  const localIn = opt('in', '');
  if (localIn) {
    const buf = Buffer.from(fs.readFileSync(path.resolve(localIn)));
    for (let i = 0; i < Math.min(KEY_LEN, buf.length, ks.length); i++) buf[i] ^= ks[i];
    ensure(OUT);
    const out = path.resolve(opt('out', path.join(OUT, `decrypted-${path.basename(localIn)}.mp4`)));
    fs.writeFileSync(out, buf);
    say(`✓ 已写出 ${out}  ${(buf.length / 1048576).toFixed(2)} MB`);
    const probe = ffprobePath();
    if (probe) {
      try {
        const r = execFileSync(probe, ['-v', 'error', '-show_entries', 'format=duration,size,format_name:stream=codec_type,codec_name,width,height', '-of', 'json', out], { encoding: 'utf8', timeout: 120000 });
        say(r.replace(/\s+/g, ' ').slice(0, 500));
      } catch (e) { say('ffprobe:', String(e.message).split('\n')[0].slice(0, 160)); }
    }
    return;
  }

  const idx = readJSON(path.join(HEADS_DIR, 'index.json'), []);
  const want = opt('head', '');
  const headFile = want ? path.join(HEADS_DIR, want.endsWith('.bin') ? want : want + '.bin') : null;

  let target = null;
  if (headFile && fs.existsSync(headFile)) {
    const name = path.basename(headFile, '.bin');
    target = idx.find((x) => x.name === name) || null;
  } else {
    // 自动挑选：哪个头的密文能被这把密钥流解成合法 MP4
    for (const h of idx) {
      const f = path.join(HEADS_DIR, h.name + '.bin');
      if (!fs.existsSync(f)) continue;
      if (looksDecryptable(fs.readFileSync(f), ks)) { target = h; break; }
    }
  }
  if (!target) { say('没有能找到匹配密钥流的密文头。请重新 watch（用正在播的那个视频）再 key。'); return; }

  say(`命中密文头 ${target.name}，下载完整文件…`);
  const res = await fetch(target.url, {
    headers: {
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36 MicroMessenger/7.0.20.1781(0x6700143B) WindowsWechat(0x63090a13) XWEB/8447',
      Referer: 'https://channels.weixin.qq.com/',
    },
  });
  if (!res.ok) { say(`✗ 下载失败 HTTP ${res.status}（签名 URL 可能已过期，请重新播放一次再 watch/key）`); return; }
  const buf = Buffer.from(await res.arrayBuffer());
  for (let i = 0; i < Math.min(KEY_LEN, buf.length, ks.length); i++) buf[i] ^= ks[i];
  ensure(OUT);
  const out = path.join(OUT, `wechat-channels-${new Date().toISOString().replace(/[:.]/g, '-')}.mp4`);
  fs.writeFileSync(out, buf);
  say(`✓ 已写出 ${out}  ${(buf.length / 1048576).toFixed(2)} MB`);
  const probe = ffprobePath();
  if (probe) {
    try {
      const r = execFileSync(probe, ['-v', 'error', '-show_entries', 'format=duration,size,bit_rate,format_name:stream=codec_type,codec_name,width,height', '-of', 'json', out], { encoding: 'utf8', timeout: 120000 });
      say(JSON.stringify(JSON.parse(r)).slice(0, 600));
    } catch (e) { say('ffprobe 报错（文件可能不完整）:', String(e.message).split('\n')[0].slice(0, 160)); }
  } else {
    say('（未找到 ffprobe，跳过校验；可用 ffprobe 自行确认）');
  }
}

function looksDecryptable(buf, ks) {
  const head = Buffer.from(buf.subarray(0, Math.min(KEY_LEN, buf.length)));
  for (let i = 0; i < Math.min(KEY_LEN, head.length, ks.length); i++) head[i] ^= ks[i];
  if (head.subarray(4, 8).toString('latin1') !== 'ftyp') return false;
  return head.includes('moov') || head.includes('mdat');
}

// ---------------- cleanup ----------------

/**
 * A wiped/lost state dir leaves the MITM proxy running with no pid file while it keeps
 * holding 127.0.0.1:<port>. Stopping it requires PROOF of ownership, because a bare
 * "a proxy.mjs is on this port" test would also match another project's proxy and a
 * recycled PID would match an unrelated process. Three independent checks, all of which
 * must pass:
 *   1. <base>/records/proxy-registry.json has an entry for this pid AND this port
 *      (written by proxy.mjs itself, kept outside the state dir so it survives a wipe);
 *   2. that entry's script path is one of THIS tool's canonical install paths, and the
 *      live process command line references exactly that path;
 *   3. the live process start time matches the recorded start time (rules out pid reuse).
 * Anything else is reported and left alone.
 */
async function stopOrphanProxy() {
  if (!(await waitPort(PORT, 600))) return '';
  const r = ps('portpid', ['-Port', String(PORT)]);
  const m = String(r.stdout || r.stderr || '').match(/PORTPID\s+(\d+)\s+(\d+)\s*(.*)/);
  if (!m) {
    return `ORPHAN-UNKNOWN 端口 ${PORT} 仍被占用，但无法确认属主（${String(r.stdout || '').trim() || '无输出'}）—— 未做任何终止操作`;
  }
  const pid = Number(m[1]);
  const liveStart = Number(m[2]) || 0;
  const liveCmd = m[3].trim();

  const rec = readProxyRecords().find((x) => Number(x.pid) === pid && Number(x.port) === PORT);
  if (!rec) {
    return `ORPHAN-REFUSED 端口 ${PORT} 被 pid ${pid} 占用，但本工具的运行记录（${recordsRoot()}）里没有「该 pid + 该端口」的条目 —— 未终止（可能是别的程序的 proxy.mjs，或 pid 已被系统回收）。cmdline: ${liveCmd.slice(0, 160)}`;
  }
  const canonical = canonicalProxyScripts(STATE, HERE);
  const recScript = normalizePath(rec.script);
  if (!canonical.has(recScript)) {
    return `ORPHAN-REFUSED 记录里的脚本路径不属于本工具的已知安装位置（${rec.script}）—— 未终止`;
  }
  if (!liveCmd.replace(/\\/g, '/').toLowerCase().includes(recScript)) {
    return `ORPHAN-REFUSED 记录指向 ${rec.script}，但该进程的命令行不是它 —— 未终止。cmdline: ${liveCmd.slice(0, 160)}`;
  }
  const recStart = Date.parse(String(rec.startedAt || ''));
  if (liveStart && Number.isFinite(recStart) && Math.abs(liveStart - recStart) > 15000) {
    return `ORPHAN-REFUSED pid ${pid} 的启动时间与记录不符（记录 ${rec.startedAt}，实际 ${new Date(liveStart).toISOString()}）—— pid 可能已被回收，未终止`;
  }

  try {
    process.kill(pid);
    // Windows keeps the socket in the table for a moment after the process is signalled,
    // so wait for the process itself to disappear OR the port to be released.
    let alive = true;
    let free = false;
    for (let i = 0; i < 30; i++) {
      await new Promise((r) => setTimeout(r, 500));
      alive = true;
      try { process.kill(pid, 0); } catch { alive = false; }
      free = !(await waitPort(PORT, 300));
      if (!alive || free) break;
    }
    if (!alive || free) {
      return `ORPHAN-STOPPED 已停掉没有 pid 文件的孤儿代理 pid ${pid}（记录脚本 ${rec.script}；进程${alive ? '仍在' : '已退出'}，端口 ${PORT} ${free ? '已释放' : '仍占用'}）`;
    }
    return `ORPHAN-FAIL 已向孤儿代理 pid ${pid} 发送终止信号，但 15 秒后它仍活着且端口 ${PORT} 仍被占用 —— 请手动处理`;
  } catch (e) {
    return `ORPHAN-FAIL 停孤儿代理 pid ${pid} 失败：${e.message}`;
  }
}

async function cleanup() {
  say('· 停止扫描器');
  killScanners();
  say('· 停止代理');
  if (fs.existsSync(PROXY_PID)) {
    const pid = Number(fs.readFileSync(PROXY_PID, 'utf8'));
    try { process.kill(pid); say(`  已停 pid ${pid}`); } catch { say('  代理已不在运行'); }
    fs.rmSync(PROXY_PID, { force: true });
  } else {
    say('  （无 pid 文件）');
  }
  const orphan = await stopOrphanProxy();
  if (orphan) say('  ' + orphan);
  say('· 还原系统代理设置');
  const r = ps('restoreproxy');
  const rOut = (r.stdout || '').trim();
  if (r.status === 0) {
    say('  ' + (rOut || 'restored'));
  } else {
    say('  ✗ 还原失败：' + rOut);
    // Backup gone (state dir wiped / interrupted run) but our own PAC may still be
    // installed, which leaves the machine routing through a dead local port. A PAC URL
    // on 127.0.0.1:<port>/proxy.pac can only be ours, so drop exactly that.
    const dp = ps('dropownpac');
    const dpOut = String(dp.stdout || '').trim();
    if (/^DROPPED/m.test(dpOut)) {
      say('  备份已丢失，但检测到系统里残留着本工具自己的 PAC —— 已移除：' + dpOut.replace(/^DROPPED\s*/m, ''));
    } else if (/^KEEP/m.test(dpOut)) {
      say('  当前 AutoConfigURL 不是本工具的 PAC，保持不动：' + dpOut.replace(/^KEEP\s*/m, ''));
    }
    say('    其余字段（ProxyEnable/ProxyServer/ProxyOverride）无法从丢失的备份推断，请在「Windows 设置 → 网络和 Internet → 代理」里核对。');
  }
  const nowProxy = readCurrentProxy();
  if (nowProxy.ok) {
    say(`  当前系统代理：ProxyEnable=${nowProxy.value.ProxyEnable} ProxyServer=${nowProxy.value.ProxyServer || '(空)'} AutoConfigURL=${nowProxy.value.AutoConfigURL || '(无)'}`);
  }
  say('· 移除临时 CA（Windows 会弹确认框，请在弹窗上点「是」）');
  const info = ps('certinfo');
  const thumbs = [...String(info.stdout || '').matchAll(/present\s+([0-9A-Fa-f]+)/g)].map((m) => m[1]);
  if (thumbs.length) {
    say(`  受信任根里有 ${thumbs.length} 个本工具的 CA，逐个删除（每个都要你点「是」）`);
    for (const t of thumbs) {
      say(`  （等待你在系统弹窗上点「是」…最多等 3 分钟）`);
      ps('delcert', ['-Thumb', t], false, 180000);
    }
  } else {
    say('  CA 不在受信任根里');
  }
  const after = ps('certinfo');
  say('  结果: ' + ((after.stdout || '').trim() || '?'));
  if ((after.stdout || '').includes('present')) {
    say('  ⚠ 仍在：请手动删除 —— Win+R → certmgr.msc → 受信任的根证书颁发机构 → 证书 → 找到 "DSH Local MITM CA" → 删除');
  }
  say('· 清理证书存储里的临时 CA/叶子证书（Cert:\\CurrentUser\\My 与 中间 CA 存储）');
  const cc = certsPs('cleanup');
  say('  ' + (cc.out || (cc.ok ? 'done' : 'failed')));
  // Belt and braces: certs.ps1 cleanup works from this state's index/tag, so run the
  // prefix sweep too and catch orphans left by an interrupted run or a deleted state dir.
  const purge = spawnSync(PS_EXE, ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
    path.join(HERE, 'ps', 'purge-certs.ps1'), '-State', STATE], { encoding: 'utf8', timeout: 120000 });
  const purgeOut = String((purge.stdout || '') + (purge.stderr || '')).trim().split('\n');
  say('  ' + (purgeOut[purgeOut.length - 2] || '').trim());
  say('  ' + (purgeOut[purgeOut.length - 1] || '').trim());
  const residue = certResidue();
  say(`· 残留复查：My=${residue.my} CA=${residue.intermediate} Root=${residue.root}${residue.total === 0 ? '（干净）' : '  ← 未清干净，见上面的提示'}`);
  say('\n· 完成。证据与中间文件都留在 state/ 与 output/，未删除。');
}

// ---------------- main ----------------
const usage = `wx-sph-dl —— 微信视频号视频下载

  node sph.mjs doctor                只读自检（平台/PKI/certutil/注册表可读/备份/端口/微信进程）
  node sph.mjs setup                 写 PAC、起本地 MITM、装临时 CA、把系统代理指向 PAC
  node sph.mjs setup --dry-run       只校验代理备份并打印将生成的 PAC（不改系统设置，务必先跑）
  node sph.mjs status                只读状态（代理/CA/抓到多少取流地址/密钥流是否已拿到）
  node sph.mjs watch [--head 8]      从抓到的取流地址里下载密文头（做内存搜索的特征）
  node sph.mjs key [--minutes 20]    并行扫描微信进程内存，取回 128KB 密钥流（需同时播放视频！）
  node sph.mjs decrypt [--head head3] 下载完整视频并用密钥流解密（默认自动挑匹配的）
  node sph.mjs decrypt --in x.bin     直接解密本地密文文件（离线/自测）
  node sph.mjs cleanup               停代理/扫描器、还原系统代理、移除临时 CA（需人工点确认）
  node sph.mjs stopscans             只停止后台内存扫描器（不影响代理与系统设置）

安全约定：setup 在改动任何网络设置之前，必须存在一份「本次写入且 schema 合法」的
          代理备份（state/original-proxy.json，无 BOM）；缺失/损坏/空对象一律中止。
可选: --state <dir>  --outdir <dir>  --port 18080

要点：视频号视频只能从已登录的微信客户端取流；CDN 只加密文件前 128KB，密钥流=ISAAC-64(decodeKey)；
      密钥流只在播放期间存在于进程内存 —— 所以 key 必须与播放同时进行。
`;

switch (cmd) {
  case 'doctor': process.exit(await doctor()); break;
  case 'setup': await setup(); break;
  case 'status': await status(); break;
  case 'watch': await watch(); break;
  case 'key': await key(); break;
  case 'decrypt': await decrypt(); break;
  case 'cleanup': await cleanup(); break;
  case 'stopscans': killScanners(); say('· 已停止后台扫描器'); break;
  default: say(usage); break;
}
