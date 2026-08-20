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

const LISTEN_HOST = '0.0.0.0';
const LISTEN_PORT = parseInt(process.env.PROXY_PORT || '3080', 10);
const UPSTREAM_HOST = process.env.UPSTREAM_HOST || '127.0.0.1';
const UPSTREAM_PORT = parseInt(process.env.UPSTREAM_PORT || '3081', 10);

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

const server = http.createServer((req, res) => {
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
      if (html.includes('crypto.randomUUID') === false) {
        html = html.replace(/<head([^>]*)>/i, (m, attrs) => '<head' + attrs + '>' + POLYFILL);
      }
      // The integration script (file-viewer fetch interception + Files button)
      // is injected separately: it references crypto.randomUUID, which must
      // not defeat the polyfill guard above.
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
    clientSocket.write(
      'HTTP/' + upstreamRes.httpVersion + ' ' + upstreamRes.statusCode +
        ' ' + (upstreamRes.statusMessage || '') + '\r\n' +
        rawHeaderLines(upstreamRes.rawHeaders) + '\r\n'
    );
    if (upstreamHead && upstreamHead.length) clientSocket.write(upstreamHead);
    upstreamSocket.pipe(clientSocket);
    clientSocket.pipe(upstreamSocket);
  });

  upstreamReq.on('response', (upstreamRes) => {
    clientSocket.write(
      'HTTP/' + upstreamRes.httpVersion + ' ' + upstreamRes.statusCode +
        ' ' + (upstreamRes.statusMessage || '') + '\r\n' +
        rawHeaderLines(upstreamRes.rawHeaders) + '\r\n'
    );
    upstreamRes.pipe(clientSocket);
  });

  upstreamReq.on('error', () => clientSocket.destroy());
  clientSocket.on('error', () => upstreamReq.destroy());

  if (head && head.length) upstreamReq.write(head);
  upstreamReq.end();
});

server.listen(LISTEN_PORT, LISTEN_HOST, () => {
  process.stdout.write('dsh web proxy listening on ' + LISTEN_HOST + ':' + LISTEN_PORT +
    ' -> ' + UPSTREAM_HOST + ':' + UPSTREAM_PORT + '\n');
});
