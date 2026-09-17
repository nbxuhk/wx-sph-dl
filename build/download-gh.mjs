// Download the latest GitHub CLI release zip for Windows (no token needed for public
// releases). Uses Node's fetch because this box's PowerShell schannel TLS is unreliable.
// Usage: node download-gh.mjs [targetDir]
import fs from 'node:fs';
import path from 'node:path';

const target = path.resolve(process.argv[2] || path.join(process.env.LOCALAPPDATA || '.', 'Programs', 'gh'));
fs.mkdirSync(target, { recursive: true });

const api = 'https://api.github.com/repos/cli/cli/releases/latest';
const res = await fetch(api, { headers: { 'user-agent': 'wx-sph-dl-installer' } });
if (!res.ok) { console.error('API-FAIL ' + res.status); process.exit(1); }
const rel = await res.json();
const asset = (rel.assets || []).find((a) => /_windows_amd64\.zip$/.test(a.name));
if (!asset) { console.error('NO-ASSET for ' + rel.tag_name); process.exit(1); }
console.log(`GH-RELEASE ${rel.tag_name} asset=${asset.name} bytes=${asset.size}`);

const zip = path.join(target, asset.name);
const dl = await fetch(asset.browser_download_url, { headers: { 'user-agent': 'wx-sph-dl-installer' } });
if (!dl.ok) { console.error('DOWNLOAD-FAIL ' + dl.status); process.exit(1); }
const buf = Buffer.from(await dl.arrayBuffer());
fs.writeFileSync(zip, buf);
console.log(`GH-DOWNLOADED ${zip} (${buf.length} bytes)`);
