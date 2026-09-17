// Test fixture: a look-alike "proxy.mjs" from ANOTHER project, listening on the same
// port. cleanup must refuse to kill it: it has no entry in this tool's
// records/proxy-registry.json, and its path is not one of this tool's install locations.
// Usage: node proxy.mjs [--port N]
import net from 'node:net';

const argv = process.argv.slice(2);
const i = argv.indexOf('--port');
const port = Number(i >= 0 ? argv[i + 1] : 18080);
const srv = net.createServer((s) => s.end());
srv.on('error', (e) => { console.log('FOREIGN-PROXY-ERR ' + e.message); process.exit(1); });
srv.listen(port, '127.0.0.1', () => console.log('FOREIGN-PROXY listening ' + port));
