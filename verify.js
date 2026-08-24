// DeepSeek Harness health check.
//
// Asserts the proxy relays a WebSocket upgrade to dsh with the browser's
// Origin header - the exact request path a phone uses over Tailscale Serve.
// dsh's origin-vs-host trust fence accepts the upgrade only when it was
// started with the matching --trusted-host entries, so a 403 here means the
// tailnet UI will show "clean, no history".
//
// Exits 0 when /api/events.mux and /api/events.host both handshake to 101,
// non-zero otherwise. Invoked by `start-harness.ps1 -Verify`.
//
// Environment:
//   PROXY_HOST    - host the proxy listens on (default 127.0.0.1)
//   PROXY_PORT    - proxy port (default 3080)
//   VERIFY_ORIGIN - Origin header to simulate (default http://PROXY_HOST:PROXY_PORT)
'use strict';

const http = require('http');

const HOST = process.env.PROXY_HOST || '127.0.0.1';
const PORT = parseInt(process.env.PROXY_PORT || '3080', 10);
const ORIGIN = process.env.VERIFY_ORIGIN || ('http://' + HOST + ':' + PORT);
const PATHS = ['/api/events.mux', '/api/events.host'];

function handshake(path) {
  return new Promise((resolve) => {
    const req = http.request({
      host: HOST,
      port: PORT,
      path,
      headers: {
        Connection: 'Upgrade',
        Upgrade: 'websocket',
        'Sec-WebSocket-Version': '13',
        'Sec-WebSocket-Key': 'dGhlIHNhbXBsZSBub25jZQ==',
        Origin: ORIGIN,
      },
    });
    req.on('upgrade', (res, sock) => { sock.destroy(); resolve(res.statusCode); });
    req.on('response', (res) => { res.resume(); resolve(res.statusCode); });
    req.on('error', (e) => { console.error(path + ' ERROR ' + e.message); resolve(0); });
    req.end();
  });
}

(async () => {
  let failed = false;
  for (const path of PATHS) {
    const status = await handshake(path);
    console.log('WS ' + path + ' -> ' + status + (status === 101 ? '' : ' (expected 101)'));
    if (status !== 101) failed = true;
  }
  process.exit(failed ? 1 : 0);
})();
