// DeepSeek Harness web proxy (port 3080 -> 127.0.0.1:3081)
//
// dsh binds loopback-only by design. This proxy owns the tailnet-facing port
// 3080 and forwards everything to 127.0.0.1:3081. For HTML responses it
// injects a crypto.randomUUID polyfill (getRandomValues-based), because
// crypto.randomUUID() is only available in secure contexts (HTTPS/localhost)
// and the harness is served over plain HTTP on the Tailscale tailnet.
// Everything else (assets, SSE streams, WebSocket upgrades) passes through
// untouched.

'use strict';

const http = require('http');
const files = require('./web-files.js');

// Bind the unspecified dual-stack address so both Tailscale address families
// (100.x CGNAT and fd7a::/48 ULA) can reach the proxy. DSH_PROXY_PORT /
// DSH_WEB_PORT are accepted as documented fallbacks alongside PROXY_PORT /
// UPSTREAM_PORT (the launcher sets all four).
const LISTEN_HOST = '::';
const LISTEN_PORT = parseInt(process.env.PROXY_PORT || process.env.DSH_PROXY_PORT || '3080', 10);
const UPSTREAM_HOST = process.env.UPSTREAM_HOST || '127.0.0.1';
const UPSTREAM_PORT = parseInt(process.env.UPSTREAM_PORT || process.env.DSH_WEB_PORT || '3081', 10);

const POLYFILL = `<script>
(function () {
  if (typeof crypto !== 'undefined' && !crypto.randomUUID && crypto.getRandomValues) {
    crypto.randomUUID = function () {
      var b = new Uint8Array(16);
      crypto.getRandomValues(b);
      b[6] = (b[6] & 0x0f) | 0x40;
      b[8] = (b[8] & 0x3f) | 0x80;
      var h = '';
      for (var i = 0; i < 16; i++) h += ('0' + b[i].toString(16)).slice(-2);
      return h.slice(0, 8) + '-' + h.slice(8, 12) + '-' + h.slice(12, 16) + '-' + h.slice(16, 20) + '-' + h.slice(20);
    };
  }
})();
</script>`;

// Compact access log on stdout (the launcher redirects it to proxy.log):
// ISO time, remote address, method, path, upstream status, duration. The
// remote address is what makes remote-device outages diagnosable: if nothing
// appears while a phone "can't load", the packets never reached the proxy.
function logLine(line) {
  process.stdout.write(line + '\n');
}

const server = http.createServer((req, res) => {
  const startedAt = Date.now();
  const remote = String((req.socket && req.socket.remoteAddress) || '-').replace(/^::ffff:/, '');
  res.on('finish', () => {
    logLine(new Date().toISOString() + ' ' + remote + ' ' + req.method + ' ' + req.url +
      ' -> ' + res.statusCode + ' (' + (Date.now() - startedAt) + 'ms)');
  });

  // Serve the web file browser/viewer locally (never forwarded to dsh).
  if (req.url.startsWith('/__files')) {
    files.handle(req, res);
    return;
  }

  const headers = Object.assign({}, req.headers);
  // Keep hop-by-hop headers handled by Node out of the forwarded request.
  delete headers['connection'];
  delete headers['proxy-connection'];

  // Normalize Host to the browser Origin's authority so dsh's origin-vs-host
  // trust fence passes behind Tailscale Serve (which may rewrite Host).
  const origin = headers['origin'];
  if (typeof origin === 'string' && origin !== '') {
    try { headers['host'] = new URL(origin).host; } catch {}
  }

  const upstreamReq = http.request({
    host: UPSTREAM_HOST,
    port: UPSTREAM_PORT,
    method: req.method,
    path: req.url,
    headers,
  }, (upstreamRes) => {
    const contentType = String(upstreamRes.headers['content-type'] || '').toLowerCase();
    const contentEncoding = String(upstreamRes.headers['content-encoding'] || '').toLowerCase();
    const isHtml = upstreamRes.statusCode === 200 &&
      contentType.includes('text/html') &&
      contentEncoding === ''; // do not try to rewrite compressed bodies

    if (!isHtml) {
      res.writeHead(upstreamRes.statusCode, upstreamRes.headers);
      upstreamRes.pipe(res);
      return;
    }

    // Buffer the (small) HTML doc, inject the polyfill after <head>, resend.
    let chunks = [];
    upstreamRes.on('data', (c) => chunks.push(c));
    upstreamRes.on('end', () => {
      let html = Buffer.concat(chunks).toString('utf8');
      // Always inject: the polyfill's own IIFE is idempotent (!crypto.randomUUID),
      // so injecting over a page that already provides randomUUID is a no-op,
      // while a page that merely *references* the method (e.g. an inlined
      // script) still gets a working implementation over plain HTTP. Must run
      // before dsh's own scripts, hence the injection right after <head>.
      html = html.replace(/<head([^>]*)>/i, (m, attrs) => '<head' + attrs + '>' + POLYFILL);
      // The integration script (file-viewer fetch interception + Files button)
      // is injected separately, after the polyfill.
      html = html.replace(/<head([^>]*)>/i, (m, attrs) => '<head' + attrs + '>' + files.integrationScript());
      const outHeaders = Object.assign({}, upstreamRes.headers);
      delete outHeaders['content-length'];
      delete outHeaders['connection'];
      outHeaders['content-type'] = upstreamRes.headers['content-type'] || 'text/html; charset=utf-8';
      res.writeHead(200, outHeaders);
      res.end(html);
    });
    upstreamRes.on('error', () => {
      if (!res.headersSent) res.writeHead(502, { 'content-type': 'text/plain' });
      res.end('upstream error');
    });
  });

  upstreamReq.on('error', (err) => {
    if (!res.headersSent) res.writeHead(502, { 'content-type': 'text/plain' });
    res.end('proxy upstream error: ' + err.message);
  });

  req.pipe(upstreamReq);
});

// WebSocket upgrade tunneling. Forward the handshake with http.request so Node
// relays the upstream 101 (or error) response faithfully, preserving Origin,
// Cookie, and the client's Sec-WebSocket-* headers (never emitting empty
// optional headers). Mirror the HTTP handler's Host->Origin normalization so
// dsh's origin-vs-host trust fence passes behind Tailscale Serve.
function rawHeaderLines(rawHeaders) {
  let out = '';
  for (let i = 0; i < rawHeaders.length; i += 2) {
    out += rawHeaders[i] + ': ' + rawHeaders[i + 1] + '\r\n';
  }
  return out;
}

server.on('upgrade', (req, clientSocket, head) => {
  const headers = Object.assign({}, req.headers);
  delete headers['proxy-connection'];

  // Normalize Host to the browser Origin's authority (same trust fence as HTTP).
  const origin = headers['origin'];
  if (typeof origin === 'string' && origin !== '') {
    try { headers['host'] = new URL(origin).host; } catch {}
  }

  const upstreamReq = http.request({
    host: UPSTREAM_HOST,
    port: UPSTREAM_PORT,
    method: req.method,
    path: req.url,
    headers,
  });

  upstreamReq.on('upgrade', (upstreamRes, upstreamSocket, upstreamHead) => {
    logLine(new Date().toISOString() + ' ' +
      String(clientSocket.remoteAddress || '-').replace(/^::ffff:/, '') +
      ' WS ' + req.url + ' -> ' + upstreamRes.statusCode);
    clientSocket.write(
      'HTTP/' + upstreamRes.httpVersion + ' ' + upstreamRes.statusCode +
        ' ' + (upstreamRes.statusMessage || '') + '\r\n' +
        rawHeaderLines(upstreamRes.rawHeaders) + '\r\n'
    );
    if (upstreamHead && upstreamHead.length) clientSocket.write(upstreamHead);
    // The raw sockets are piped directly and are no longer covered by the
    // handshake-phase error handlers below. A phone dropping mid-stream (or
    // dsh resetting the connection) surfaces as an ECONNRESET on one of these
    // sockets; without handlers that 'error' is unhandled and crashes the
    // whole proxy. Tear down the pair on either side's error/close.
    const teardown = () => {
      try { upstreamSocket.destroy(); } catch {}
      try { clientSocket.destroy(); } catch {}
    };
    upstreamSocket.on('error', teardown);
    clientSocket.on('error', teardown);
    upstreamSocket.on('close', () => clientSocket.destroy());
    clientSocket.on('close', () => upstreamSocket.destroy());
    upstreamSocket.pipe(clientSocket);
    clientSocket.pipe(upstreamSocket);
  });

  upstreamReq.on('response', (upstreamRes) => {
    logLine(new Date().toISOString() + ' ' +
      String(clientSocket.remoteAddress || '-').replace(/^::ffff:/, '') +
      ' WS ' + req.url + ' -> ' + upstreamRes.statusCode + ' (no upgrade)');
    clientSocket.write(
      'HTTP/' + upstreamRes.httpVersion + ' ' + upstreamRes.statusCode +
        ' ' + (upstreamRes.statusMessage || '') + '\r\n' +
        rawHeaderLines(upstreamRes.rawHeaders) + '\r\n'
    );
    upstreamRes.on('error', () => clientSocket.destroy());
    upstreamRes.pipe(clientSocket);
  });

  upstreamReq.on('error', () => clientSocket.destroy());
  clientSocket.on('error', () => upstreamReq.destroy());

  if (head && head.length) upstreamReq.write(head);
  upstreamReq.end();
});

server.on('clientError', (err, socket) => {
  // Malformed/aborted request - drop it instead of letting Node warn-and-hang.
  try { socket.destroy(); } catch {}
});

server.listen(LISTEN_PORT, LISTEN_HOST, () => {
  // Report the actual bound port (server.address()), so LISTEN_PORT=0 (OS
  // picks a free port) is usable by operators and by the test suite.
  const addr = server.address();
  const port = addr && typeof addr === 'object' ? addr.port : LISTEN_PORT;
  process.stdout.write('dsh web proxy listening on ' + LISTEN_HOST + ':' + port +
    ' -> ' + UPSTREAM_HOST + ':' + UPSTREAM_PORT + '\n');
});
