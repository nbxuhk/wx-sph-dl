// Stand-in for "some other program" holding the proxy port, used by
// tests/orphan-proxy-tests.ps1 to prove cleanup refuses to kill a process whose
// command line is not our proxy.mjs. Usage: node foreign-listener.mjs [port] [seconds]
import net from 'node:net';

const port = Number(process.argv[2] || 18080);
const seconds = Number(process.argv[3] || 25);
const srv = net.createServer((s) => s.end());
srv.on('error', (e) => { console.log('FOREIGN-LISTENER-ERR ' + e.message); process.exit(1); });
srv.listen(port, '127.0.0.1', () => console.log('FOREIGN-LISTENER ' + port));
setTimeout(() => { try { srv.close(); } catch { } process.exit(0); }, seconds * 1000);
