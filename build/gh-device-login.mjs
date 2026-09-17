// Non-interactive GitHub device-flow login. Prints a one-time code the user enters at
// https://github.com/login/device, then writes the resulting token to a temp file (the
// token itself is NEVER printed). The caller feeds that file to `gh auth login --with-token`
// and deletes it.
//
// Client id: the public GitHub CLI OAuth app id (same one `gh auth login` uses).
// Usage: node gh-device-login.mjs [tokenFile]
import fs from 'node:fs';
import path from 'node:path';

const CLIENT_ID = '178c6fc778ccc68e1d6a';
const SCOPES = 'repo read:org gist';
const out = path.resolve(process.argv[2] || path.join(process.env.LOCALAPPDATA || '.', 'Programs', 'gh', '.device-token'));

const codeRes = await fetch('https://github.com/login/device/code', {
  method: 'POST',
  headers: { accept: 'application/json', 'content-type': 'application/json' },
  body: JSON.stringify({ client_id: CLIENT_ID, scope: SCOPES }),
});
const code = await codeRes.json();
if (!code.device_code) { console.error('DEVICE-CODE-FAIL ' + JSON.stringify(code)); process.exit(1); }

console.log('=========================================================');
console.log(' 请打开：' + code.verification_uri);
console.log(' 输入一次性代码：' + code.user_code);
console.log(' 然后点 Authorize（授权你的 GitHub 账号）');
console.log('=========================================================');
console.log(`WAITING expires_in=${code.expires_in}s interval=${code.interval}s`);

const interval = Math.max(5, Number(code.interval) || 5) * 1000;
const deadline = Date.now() + (Number(code.expires_in) || 900) * 1000;
let slow = 0;

while (Date.now() < deadline) {
  await new Promise((r) => setTimeout(r, interval + slow));
  const tokRes = await fetch('https://github.com/login/oauth/access_token', {
    method: 'POST',
    headers: { accept: 'application/json', 'content-type': 'application/json' },
    body: JSON.stringify({
      client_id: CLIENT_ID,
      device_code: code.device_code,
      grant_type: 'urn:ietf:params:oauth:grant-type:device_code',
    }),
  });
  const tok = await tokRes.json();
  if (tok.access_token) {
    fs.mkdirSync(path.dirname(out), { recursive: true });
    fs.writeFileSync(out, tok.access_token, 'utf8');
    console.log(`AUTH-OK token-saved-to=${out} scopes=${tok.scope || SCOPES}`);
    process.exit(0);
  }
  if (tok.error === 'authorization_pending') continue;
  if (tok.error === 'slow_down') { slow += 5000; continue; }
  if (tok.error === 'expired_token') { console.error('AUTH-EXPIRED'); process.exit(1); }
  if (tok.error === 'access_denied') { console.error('AUTH-DENIED'); process.exit(1); }
  console.error('AUTH-ERROR ' + JSON.stringify(tok));
  process.exit(1);
}
console.error('AUTH-TIMEOUT');
process.exit(1);
