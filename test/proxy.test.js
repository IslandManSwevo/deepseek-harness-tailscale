'use strict';

// Integration tests for web-proxy.js: WebSocket upgrade relay, Host->Origin
// normalization, HTML polyfill/integration-script injection, and the local
// /__files viewer. The proxy is spawned as a child against an in-process
// fake upstream; no dsh or Tailscale needed.
//
// Run: node --test test/proxy.test.js

const { test, before, after } = require('node:test');
const assert = require('node:assert');
const http = require('node:http');
const net = require('node:net');
const vm = require('node:vm');
const { spawn } = require('node:child_process');
const path = require('node:path');
const os = require('node:os');

const PROXY_JS = path.join(__dirname, '..', 'web-proxy.js');

function freePort() {
  return new Promise((resolve, reject) => {
    const srv = net.createServer();
    srv.once('error', reject);
    srv.listen(0, '127.0.0.1', () => {
      const port = srv.address().port;
      srv.close(() => resolve(port));
    });
  });
}

let upstream;
let upstreamPort;
let child;
let proxyPort;

before(async () => {
  upstreamPort = await freePort();
  upstream = http.createServer((req, res) => {
    if (req.url === '/html') {
      res.writeHead(200, { 'content-type': 'text/html' });
      res.end('<html><head><title>dsh</title></head><body>app</body></html>');
      return;
    }
    if (req.url === '/html-inline-uuid') {
      // The document itself references crypto.randomUUID (as dsh's HTML can).
      res.writeHead(200, { 'content-type': 'text/html' });
      res.end('<html><head><script>if (!crypto.randomUUID) {}</script></head><body>app</body></html>');
      return;
    }
    if (req.url === '/gzip-html') {
      const body = Buffer.from('<html><head></head><body>compressed</body></html>');
      res.writeHead(200, { 'content-type': 'text/html', 'content-encoding': 'gzip' });
      res.end(body);
      return;
    }
    if (req.url === '/echo-host') {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ host: req.headers.host }));
      return;
    }
    res.writeHead(404);
    res.end();
  });
  upstream.on('upgrade', (req, socket) => {
    if (req.url === '/api/events.mux') {
      socket.write(
        'HTTP/1.1 101 Switching Protocols\r\n' +
          'Connection: Upgrade\r\n' +
          'Upgrade: websocket\r\n' +
          'Sec-WebSocket-Accept: dGhlIHNhbXBsZSBub25jZQ==\r\n' +
          'X-Upstream-Saw-Origin: ' + (req.headers.origin || '') + '\r\n\r\n'
      );
      socket.end();
      return;
    }
    socket.write('HTTP/1.1 400 Invalid Sec-WebSocket-Protocol header\r\nConnection: close\r\n\r\n');
    socket.destroy();
  });
  await new Promise((resolve) => upstream.listen(upstreamPort, '127.0.0.1', resolve));

  proxyPort = await freePort();
  child = spawn(process.execPath, [PROXY_JS], {
    env: { ...process.env, PROXY_PORT: String(proxyPort), UPSTREAM_PORT: String(upstreamPort) },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  await new Promise((resolve, reject) => {
    let buf = '';
    const timer = setTimeout(() => reject(new Error('proxy start timeout')), 5000);
    child.stdout.on('data', (d) => {
      buf += d;
      if (buf.includes('listening on')) {
        clearTimeout(timer);
        resolve();
      }
    });
    child.once('exit', (code) => reject(new Error('proxy exited early: ' + code)));
  });
});

after(() => {
  if (child) child.kill();
  if (upstream) upstream.close();
});

function get(url) {
  return new Promise((resolve, reject) => {
    http
      .get(
        { host: '127.0.0.1', port: proxyPort, path: url, headers: { Host: '127.0.0.1:' + proxyPort } },
        (res) => {
          let body = '';
          res.on('data', (d) => (body += d));
          res.on('end', () => resolve(body));
        }
      )
      .on('error', reject);
  });
}

function getRaw(url) {
  return new Promise((resolve, reject) => {
    http
      .get(
        { host: '127.0.0.1', port: proxyPort, path: url, headers: { Host: '127.0.0.1:' + proxyPort } },
        (res) => {
          const chunks = [];
          res.on('data', (d) => chunks.push(d));
          res.on('end', () => resolve(Buffer.concat(chunks)));
        }
      )
      .on('error', reject);
  });
}

// --- WebSocket relay -----------------------------------------------------

test('relays WebSocket upgrades with a faithful 101', async () => {
  const result = await new Promise((resolve, reject) => {
    const req = http.request({
      host: '127.0.0.1',
      port: proxyPort,
      path: '/api/events.mux',
      headers: {
        Connection: 'Upgrade',
        Upgrade: 'websocket',
        'Sec-WebSocket-Version': '13',
        'Sec-WebSocket-Key': 'dGhlIHNhbXBsZSBub25jZQ==',
        Origin: 'http://127.0.0.1:' + proxyPort,
      },
    });
    req.on('upgrade', (res) => resolve({ status: res.statusCode, header: res.headers['x-upstream-saw-origin'] }));
    req.on('response', (res) => resolve({ status: res.statusCode }));
    req.on('error', reject);
    req.end();
  });
  assert.strictEqual(result.status, 101);
  // Origin must reach the upstream untouched (dsh trusts it).
  assert.strictEqual(result.header, 'http://127.0.0.1:' + proxyPort);
});

test('relays upstream WebSocket rejection status', async () => {
  const result = await new Promise((resolve, reject) => {
    const req = http.request({
      host: '127.0.0.1',
      port: proxyPort,
      path: '/api/events.bad',
      headers: {
        Connection: 'Upgrade',
        Upgrade: 'websocket',
        'Sec-WebSocket-Version': '13',
        'Sec-WebSocket-Key': 'dGhlIHNhbXBsZSBub25jZQ==',
      },
    });
    req.on('upgrade', (res) => resolve({ status: res.statusCode }));
    req.on('response', (res) => resolve({ status: res.statusCode }));
    req.on('error', reject);
    req.end();
  });
  assert.strictEqual(result.status, 400);
});

test('survives abrupt WebSocket teardown without crashing', async () => {
  // A phone dropping the connection mid-stream surfaces as ECONNRESET on one
  // of the tunnel sockets; the proxy must tear down the pair, not crash.
  for (let i = 0; i < 3; i++) {
    await new Promise((resolve) => {
      const req = http.request({
        host: '127.0.0.1',
        port: proxyPort,
        path: '/api/events.mux',
        headers: {
          Connection: 'Upgrade',
          Upgrade: 'websocket',
          'Sec-WebSocket-Version': '13',
          'Sec-WebSocket-Key': 'dGhlIHNhbXBsZSBub25jZQ==',
          Origin: 'http://127.0.0.1:' + proxyPort,
        },
      });
      req.on('upgrade', (_res, sock) => {
        // resetAndDestroy sends RST (the ECONNRESET path that used to crash).
        if (typeof sock.resetAndDestroy === 'function') sock.resetAndDestroy();
        else sock.destroy();
        resolve();
      });
      req.on('response', (res) => { res.resume(); resolve(); });
      req.on('error', () => resolve());
      req.end();
    });
  }
  await new Promise((r) => setTimeout(r, 250));
  assert.strictEqual(child.exitCode, null, 'proxy should still be running');
  const body = await get('/html');
  assert.match(body, /crypto\.randomUUID = function/);
});

// --- Header normalization ------------------------------------------------

test('normalizes Host to the browser Origin', async () => {
  const result = await new Promise((resolve, reject) => {
    const req = http.request({
      host: '127.0.0.1',
      port: proxyPort,
      path: '/echo-host',
      headers: { Host: 'something-else:9999', Origin: 'http://myhost.tail1234.ts.net:443' },
    });
    req.on('response', (res) => {
      let body = '';
      res.on('data', (d) => (body += d));
      res.on('end', () => resolve(JSON.parse(body)));
    });
    req.on('error', reject);
    req.end();
  });
  assert.strictEqual(result.host, 'myhost.tail1234.ts.net:443');
});

// --- HTML injection ------------------------------------------------------

test('injects the randomUUID polyfill into HTML', async () => {
  const body = await get('/html');
  assert.match(body, /crypto\.randomUUID = function/);
  assert.match(body, /\/__files/); // integration script (Files button)
});

test('injects the polyfill even when the document already references crypto.randomUUID', async () => {
  const body = await get('/html-inline-uuid');
  assert.match(body, /crypto\.randomUUID = function/);
});

test('does not rewrite compressed HTML', async () => {
  const raw = await getRaw('/gzip-html');
  assert.ok(raw.equals(Buffer.from('<html><head></head><body>compressed</body></html>')));
});

// --- /__files viewer -----------------------------------------------------

test('/__files serves the viewer and rejects traversal', async () => {
  const page = await get('/__files/');
  assert.match(page, /<title>Files<\/title>/);

  const escapePath = encodeURIComponent(path.join(os.homedir(), '..', 'dsh-escape-test'));
  const res = await new Promise((resolve, reject) => {
    http
      .get(
        { host: '127.0.0.1', port: proxyPort, path: '/__files/api/read?path=' + escapePath, headers: { Host: '127.0.0.1:' + proxyPort } },
        (r) => {
          r.resume();
          resolve(r.statusCode);
        }
      )
      .on('error', reject);
  });
  assert.strictEqual(res, 403);
});

test('interceptor catches host.openPath even when called with a URL object', async () => {
  // Regression: dsh calls fetch(fetch(new URL('/api/host.openPath', base), ...)).
  // A URL object has no `.url` — only `.href`. The interceptor previously read
  // `input.url`, got `undefined`, never matched, and the real fetch hit dsh's
  // loopback fence -> 403 from the phone. Reproduce that exact call shape here
  // and assert the interceptor intercepts (returns the synthetic ok), not the
  // real fetch.
  const body = await get('/html');
  const m = body.match(/<script>\s*\(function \(\) \{\s*function isLoopbackHost[\s\S]*?<\/script>/);
  assert.ok(m, 'integration script should be injected into HTML');
  const script = m[0].replace(/<\/?script>/g, '');

  const calls = { realFetch: 0, openViewer: 0, opened: null };
  const openedTab = { location: { assign: () => { calls.openViewer++; } } };
  const sandbox = {
    window: {
      open: () => { calls.openViewer++; return openedTab; },
    },
    location: { hostname: '100.85.211.6', assign: () => { calls.openViewer++; } },
    document: {
      readyState: 'complete',
      addEventListener: () => {},
      createElement: () => ({ setAttribute: () => {}, addEventListener: () => {}, style: {} }),
      body: { appendChild: () => {} },
      documentElement: { appendChild: () => {} },
    },
    // Real global fetch that would hit dsh — must NOT be reached for openPath.
    fetch: () => { calls.realFetch++; return Promise.resolve({ ok: false, status: 403 }); },
    Response: function (bodyArg, init) {
      this._body = typeof bodyArg === 'string' ? bodyArg : JSON.stringify(bodyArg);
      this.ok = (init && init.status === 200) ? true : false;
      this.status = (init && init.status) || 200;
      this.json = () => Promise.resolve(JSON.parse(this._body));
    },
    Promise,
    JSON,
    encodeURIComponent,
  };
  sandbox.globalThis = sandbox;
  sandbox.window.fetch = sandbox.fetch;
  vm.runInNewContext(script, sandbox);

  const interceptFetch = sandbox.window.fetch;
  const urlObj = new URL('http://100.85.211.6:3080/api/host.openPath');
  const payload = JSON.stringify({ type: 'client-request', rpcId: 'rpc-1', method: 'host.openPath', payload: { path: 'C:\\foo.md' } });
  const res = await interceptFetch(urlObj, { method: 'POST', body: payload, headers: { 'content-type': 'application/json' } });

  // The response is the synthetic success, and the real fetch was never reached.
  assert.strictEqual(calls.realFetch, 0, 'openPath must be intercepted, not sent to dsh');
  assert.ok(calls.openViewer >= 1, 'viewer should be opened for a produced file');
  assert.strictEqual(res.status, 200);
  const parsed = await res.json();
  assert.strictEqual(parsed.result.value.opened, true);

  // And the opposite: a non-openPath URL must still fall through to real fetch.
  calls.realFetch = 0;
  await interceptFetch(new URL('http://100.85.211.6:3080/api/workspace.list'), { method: 'POST', body: '{}' });
  assert.strictEqual(calls.realFetch, 1, 'non-openPath calls must reach the real fetch');
});
