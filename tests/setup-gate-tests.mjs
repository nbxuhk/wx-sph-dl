// setup 安全闸门回归测试（T1–T8 对照组）
// 目标：证明「备份缺失/损坏/schema 非法/saveproxy 失败」时 setup 一定中止，且【不改动系统网络设置】。
// 用法: node tests/setup-gate-tests.mjs
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '..');
const CLI = path.join(ROOT, 'sph.mjs');
const WINPS = path.join(ROOT, 'ps', 'win.ps1');
const PS_EXE = process.env.WXSPH_PS || 'C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe';
const TMP = path.join(os.tmpdir(), 'wx-sph-dl-gate-tests');

const say = (s) => console.log(s);
let failed = 0;
const check = (ok, label, detail = '') => {
  say(`${ok ? '✅' : '✗'} ${label}${detail ? '  —— ' + detail : ''}`);
  if (!ok) failed++;
};

function runCli(args) {
  const r = spawnSync(process.execPath, [CLI, ...args], { encoding: 'utf8', timeout: 120000 });
  return { status: r.status, out: `${r.stdout || ''}${r.stderr || ''}` };
}

function snapshotProxy() {
  const r = spawnSync(PS_EXE, ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', WINPS, '-Mode', 'getproxy', '-State', TMP], { encoding: 'utf8' });
  const m = String(r.stdout || '').match(/PROXY\s+(\{[\s\S]*\})/);
  return m ? m[1].replace(/\s+/g, '') : `UNREADABLE(${r.status})`;
}

function makeState(name, { backup }) {
  const dir = path.join(TMP, name);
  fs.rmSync(dir, { recursive: true, force: true });
  fs.mkdirSync(path.join(dir, 'heads'), { recursive: true });
  fs.mkdirSync(path.join(dir, 'keys'), { recursive: true });
  const f = path.join(dir, 'original-proxy.json');
  if (backup === 'MISSING') return dir;
  if (backup === 'DIR') { fs.mkdirSync(f, { recursive: true }); return dir; }   // 让写入必然失败
  if (typeof backup === 'string') { fs.writeFileSync(f, backup, 'utf8'); return dir; }
  if (backup && backup.bom) {
    fs.writeFileSync(f, '\uFEFF' + JSON.stringify(backup.value), 'utf8');
  } else {
    fs.writeFileSync(f, JSON.stringify(backup.value), 'utf8');
  }
  return dir;
}

const GOOD = { ProxyEnable: 1, ProxyServer: '127.0.0.1:1080', ProxyOverride: '<local>', AutoConfigURL: '' };
fs.mkdirSync(TMP, { recursive: true });
const before = snapshotProxy();
say(`测试前系统代理快照: ${before}\n`);
// Assertions must never hardcode the machine's own proxy: derive it from the live snapshot.
let liveProxy = '';
try { liveProxy = JSON.parse(before).ProxyServer || ''; } catch { }

// ---- C1: dry-run + 无备份 → 必须如实报告“当前系统代理”，且 PAC 用真实值兜底 ----
{
  const st = makeState('c1-nobackup', { backup: 'MISSING' });
  const r = runCli(['setup', '--dry-run', '--state', st]);
  check(r.status === 0, 'C1 dry-run 无备份：正常返回', `exit=${r.status}`);
  check(/当前系统代理/.test(r.out), 'C1 如实报告"当前系统代理"（不臆测为无代理）');
  check(liveProxy !== '' && r.out.includes('PROXY ' + liveProxy), 'C1 PAC 兜底沿用真实当前代理', `live=${liveProxy}`);
  check(!/尚无代理备份，正式运行时/.test(r.out) || /当前系统代理/.test(r.out), 'C1 未把"缺备份"误述成"用户没有代理"');
}

// ---- C2: 合法 JSON 但非法 schema（{}）→ 中止 ----
{
  const st = makeState('c2-emptyobj', { backup: { value: {} } });
  const r = runCli(['setup', '--dry-run', '--state', st]);
  check(r.status === 1, 'C2 {} 被拒绝', `exit=${r.status}`);
  check(/schema 不合法/.test(r.out), 'C2 提示 schema 不合法');
}

// ---- C3: 字段类型错 → 中止 ----
{
  const st = makeState('c3-badtype', { backup: { value: { ProxyEnable: '1', ProxyServer: 'x', ProxyOverride: '', AutoConfigURL: '' } } });
  const r = runCli(['setup', '--dry-run', '--state', st]);
  check(r.status === 1, 'C3 ProxyEnable 为字符串被拒绝', `exit=${r.status}`);
}

// ---- C4: JSON 截断 → 中止（回归） ----
{
  const st = makeState('c4-truncated', { backup: '{ "ProxyEnable": 1, "ProxyServer": ' });
  const r = runCli(['setup', '--dry-run', '--state', st]);
  check(r.status === 1, 'C4 截断 JSON 被拒绝', `exit=${r.status}`);
}

// ---- C5: 带 BOM 的合法备份 → 通过且保留原代理（回归） ----
{
  const st = makeState('c5-bom', { backup: { bom: true, value: GOOD } });
  const r = runCli(['setup', '--dry-run', '--state', st]);
  check(r.status === 0, 'C5 带 BOM 的合法备份可通过', `exit=${r.status}`);
  check(r.out.includes('PROXY ' + GOOD.ProxyServer), 'C5 PAC 保留原代理', GOOD.ProxyServer);
}

// ---- C6: 合法 + ProxyEnable=1 → PAC 兜底 = 原代理 ----
{
  const st = makeState('c6-good', { backup: { value: GOOD } });
  const r = runCli(['setup', '--dry-run', '--state', st]);
  check(r.status === 0 && r.out.includes('PROXY ' + GOOD.ProxyServer), 'C6 合法备份：PAC 兜底为该代理', GOOD.ProxyServer);
}

// ---- C7: 合法 + ProxyEnable=0 → 明示无系统代理，兜底 DIRECT ----
{
  const st = makeState('c7-noproxy', { backup: { value: { ...GOOD, ProxyEnable: 0 } } });
  const r = runCli(['setup', '--dry-run', '--state', st]);
  check(r.status === 0 && /未启用系统代理/.test(r.out), 'C7 ProxyEnable=0：明确提示未启用系统代理');
  check(/return "DIRECT";/.test(r.out), 'C7 兜底为 DIRECT');
}

// ---- C8: saveproxy 必然失败（备份路径被目录占用）→ 中止且未改网络 ----
{
  const st = makeState('c8-saveproxy-fails', { backup: 'DIR' });
  const r = runCli(['setup', '--state', st]);
  check(r.status === 1, 'C8 saveproxy 失败时 setup 中止', `exit=${r.status}`);
  check(/备份失败|未做任何网络改动/.test(r.out), 'C8 提示备份失败且未改网络');
  check(snapshotProxy() === before, 'C8 系统代理未被改动');
}

// ---- C9: 非 dry-run + 非法 schema → 中止且未改网络（核心 fail-open 修复） ----
{
  const st = makeState('c9-invalid-schema', { backup: { value: {} } });
  const r = runCli(['setup', '--state', st]);
  check(r.status === 1, 'C9 非法 schema 时 setup 中止（不再 fail-open）', `exit=${r.status}`);
  check(/schema 不合法/.test(r.out), 'C9 明确报 schema 不合法');
  check(snapshotProxy() === before, 'C9 系统代理未被改动');
}

// ---- C10: 非 dry-run + 无备份 + saveproxy 不可用 → 中止且未改网络 ----
{
  const st = makeState('c10-nobackup-nofail', { backup: 'MISSING' });
  // 让 saveproxy 失败：把 state 目录设为只读是不行的（我们是属主），改用同名目录占位
  fs.mkdirSync(path.join(st, 'original-proxy.json'), { recursive: true });
  const r = runCli(['setup', '--state', st]);
  check(r.status === 1, 'C10 无备份且无法生成备份时中止', `exit=${r.status}`);
  check(snapshotProxy() === before, 'C10 系统代理未被改动');
}

const after = snapshotProxy();
check(after === before, '全程结束后系统代理快照与开始时一致', `${before} -> ${after}`);

say(`\n${failed ? 'GATE-TESTS-FAIL' : 'GATE-TESTS-OK'}  (失败 ${failed} 项)`);
fs.rmSync(TMP, { recursive: true, force: true });
process.exit(failed ? 1 : 0);
