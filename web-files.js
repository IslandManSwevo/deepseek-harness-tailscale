// Web file browser / viewer / editor for dsh (mount: /__files)
//
// Served locally by web-proxy.js on the tailnet-facing port. Lets a remote
// device (e.g. the iPhone) browse, view, edit, and download files the dsh
// agent created — something host.openPath cannot do remotely (it is pinned
// to loopback in dsh-client-connection's PRIVILEGED_METHODS).
//
// Security model (mirrors dsh's own browser-trust fence):
//   - Requests are only accepted when the Host (or Origin when present) is a
//     loopback authority or one of the trusted Tailscale authorities
//     (DSH_TS_HOST / DSH_TS_IP, bare and with :port). Cross-site requests
//     (sec-fetch-site: cross-site) and Origin/Host mismatches are rejected.
//   - Every path is contained to the configured root(s): DSH_FILES_ROOT
//     (semicolon-separated; default the host account home directory).
//     '..' traversal, symlink escapes, and null bytes are rejected.
//   - Read/write only; no code execution, no shell. Writes are limited to
//     text content from the built-in editor.

'use strict';

const fs = require('fs');
const path = require('path');
const os = require('os');
const { URL } = require('url');

const MAX_TEXT_BYTES = 2 * 1024 * 1024;
const MAX_WRITE_BODY_BYTES = 16 * 1024 * 1024;

function splitRoots() {
  const raw = process.env.DSH_FILES_ROOT || '';
  const roots = raw
    ? raw.split(';').map((s) => s.trim()).filter(Boolean)
    : [os.homedir()];
  return roots.map((r) => path.resolve(r));
}

function isLoopbackHostname(hostname) {
  if (hostname === 'localhost' || hostname === '[::1]') return true;
  const parts = hostname.split('.');
  return (
    parts.length === 4 &&
    parts[0] === '127' &&
    parts.every((part) => /^\d{1,3}$/.test(part) && Number(part) <= 255)
  );
}

function parseAuthority(authority) {
  try {
    return new URL('http://' + authority);
  } catch (e) {
    return undefined;
  }
}

function canonicalAuthority(entry, entryUrl) {
  const port = entryUrl.port !== '' ? entryUrl.port : new URL('https://' + entry).port;
  return port === '' ? entryUrl.hostname : entryUrl.hostname + ':' + port;
}

function matchesTrustedAuthority(hostUrl, entry) {
  const entryUrl = parseAuthority(entry);
  if (entryUrl === undefined) return false;
  const canonical = canonicalAuthority(entry, entryUrl);
  if (canonical === entryUrl.hostname) return entryUrl.hostname === hostUrl.hostname;
  return entryUrl.host === hostUrl.host;
}

function buildTrustedAuthorities() {
  const port = process.env.DSH_PROXY_PORT || process.env.PROXY_PORT || '3080';
  const hosts = [];
  if (process.env.DSH_TS_HOST) hosts.push(process.env.DSH_TS_HOST);
  if (process.env.DSH_TS_IP) hosts.push(process.env.DSH_TS_IP);
  // IPv6 ULAs are bracketed so 'host' (with optional port) compares correctly.
  if (process.env.DSH_TS_IPV6) hosts.push('[' + process.env.DSH_TS_IPV6 + ']');
  const list = [];
  for (const h of hosts) {
    list.push(h);
    list.push(h + ':' + port);
  }
  return list;
}

// Mirror dsh's api-request-trust fence: the browser request is ours only if
// Host is loopback/trusted, no cross-site marker is set, and Origin (when
// present) matches Host.
function isTrustedRequest(req, trusted) {
  const headers = req.headers;
  const origin = headers.origin || '';
  let host = headers.host || '';
  if (origin) {
    try {
      host = new URL(origin).host;
    } catch (e) {
      return false;
    }
  }
  if (!host) return false;
  let hostUrl;
  try {
    hostUrl = new URL('http://' + host);
  } catch (e) {
    return false;
  }
  if (!isLoopbackHostname(hostUrl.hostname) && !trusted.some((a) => matchesTrustedAuthority(hostUrl, a))) {
    return false;
  }
  if (headers['sec-fetch-site'] === 'cross-site') return false;
  if (origin) {
    try {
      return new URL(origin).host === hostUrl.host;
    } catch (e) {
      return false;
    }
  }
  return true;
}

function pathWithin(container, candidate) {
  const a = container.toLowerCase();
  const b = candidate.toLowerCase();
  return b === a || b.startsWith(a + path.sep);
}

// Resolve a user-supplied path against the configured roots, rejecting
// traversal, symlink escapes, and out-of-root targets.
function safeResolve(rawPath, roots) {
  if (typeof rawPath !== 'string' || rawPath === '' || rawPath.includes('\0')) return null;
  const abs = path.resolve(rawPath);
  if (!roots.some((root) => pathWithin(root, abs))) return null;

  const rootsReal = roots.map((r) => {
    try {
      return fs.realpathSync.native(r);
    } catch (e) {
      return r;
    }
  });

  // Deepest existing ancestor (handles new files being written).
  let ancestor = abs;
  for (;;) {
    try {
      fs.statSync(ancestor);
      break;
    } catch (e) {
      const parent = path.dirname(ancestor);
      if (parent === ancestor) return null;
      ancestor = parent;
    }
  }
  let ancReal;
  try {
    ancReal = fs.realpathSync.native(ancestor);
  } catch (e) {
    return null;
  }
  if (!rootsReal.some((root) => pathWithin(root, ancReal))) return null;

  // If the full path already exists (possibly a symlink), it must also stay
  // inside the roots once resolved.
  try {
    const fullReal = fs.realpathSync.native(abs);
    if (!rootsReal.some((root) => pathWithin(root, fullReal))) return null;
  } catch (e) {
    // not an error: the path simply does not exist yet
  }
  return abs;
}

function sendJson(res, status, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': Buffer.byteLength(body),
    'cache-control': 'no-store',
  });
  res.end(body);
}

function listDir(abs) {
  const entries = fs
    .readdirSync(abs, { withFileTypes: true })
    .map((d) => {
      const p = path.join(abs, d.name);
      let isDirectory = d.isDirectory();
      let size = 0;
      let mtime = null;
      try {
        const st = fs.statSync(p);
        isDirectory = st.isDirectory();
        size = st.size;
        mtime = st.mtime.toISOString();
      } catch (e) {
        // broken link / permission — keep the dirent facts
      }
      return { name: d.name, path: p, isDirectory, size, mtime };
    })
    .sort((a, b) => {
      if (a.isDirectory !== b.isDirectory) return a.isDirectory ? -1 : 1;
      return a.name.toLowerCase() < b.name.toLowerCase() ? -1 : a.name.toLowerCase() > b.name.toLowerCase() ? 1 : 0;
    });
  const parent = abs === path.dirname(abs) ? null : path.dirname(abs);
  return { path: abs, parent, entries };
}

function readText(abs) {
  const st = fs.statSync(abs);
  if (st.isDirectory()) return { error: 'is-directory' };
  if (st.size > MAX_TEXT_BYTES) return { tooLarge: true, size: st.size };
  const buf = fs.readFileSync(abs);
  if (buf.includes(0)) return { binary: true, size: buf.length };
  const content = buf.toString('utf8');
  return {
    content,
    size: buf.length,
    mtime: st.mtime.toISOString(),
    crlf: content.includes('\r\n'),
  };
}

function writeText(abs, content) {
  fs.mkdirSync(path.dirname(abs), { recursive: true });
  let previous = null;
  try {
    previous = fs.readFileSync(abs, 'utf8');
  } catch (e) {
    // new file
  }
  let out = content;
  // Browsers normalize textarea line endings to LF; restore CRLF when the
  // original file used it.
  if (previous !== null && previous.includes('\r\n') && !out.includes('\r\n')) {
    out = out.replace(/\n/g, '\r\n');
  }
  // Atomic write: write to a sibling temp file, then rename over the target,
  // so a crash mid-save can never leave a truncated file behind.
  const tmp = abs + '.tmp-' + process.pid + '-' + Date.now();
  try {
    fs.writeFileSync(tmp, out, 'utf8');
    fs.renameSync(tmp, abs);
  } catch (e) {
    try { fs.unlinkSync(tmp); } catch (_) { /* best effort */ }
    throw e;
  }
  return { path: abs, size: Buffer.byteLength(out, 'utf8') };
}

let pageHtml = null;
function servePage(res) {
  if (pageHtml === null) {
    try {
      pageHtml = fs.readFileSync(path.join(__dirname, 'web-files-page.html'), 'utf8');
    } catch (e) {
      pageHtml = '';
    }
  }
  if (!pageHtml) {
    res.writeHead(500, { 'content-type': 'text/plain' });
    res.end('page missing');
    return;
  }
  res.writeHead(200, {
    'content-type': 'text/html; charset=utf-8',
    'content-length': Buffer.byteLength(pageHtml),
    'cache-control': 'no-store',
  });
  res.end(pageHtml);
}

function handle(req, res) {
  const trusted = buildTrustedAuthorities();
  if (!isTrustedRequest(req, trusted)) {
    res.writeHead(403, { 'content-type': 'text/plain' });
    res.end('forbidden');
    return;
  }

  const u = new URL(req.url, 'http://dsh.internal');
  const route = u.pathname.replace(/\/+$/, '') || '/';
  const roots = splitRoots();

  if (route === '/__files' || route === '/__files/index.html') {
    servePage(res);
    return;
  }
  if (route === '/__files/api/roots') {
    sendJson(res, 200, {
      ok: true,
      roots: roots.map((r) => ({
        name: r === os.homedir() ? 'Home' : path.basename(r),
        path: r,
      })),
    });
    return;
  }
  if (route === '/__files/api/list') {
    const raw = u.searchParams.get('path');
    const abs = raw ? safeResolve(raw, roots) : roots[0];
    if (!abs) return sendJson(res, 403, { ok: false, error: 'path-not-allowed' });
    try {
      return sendJson(res, 200, Object.assign({ ok: true }, listDir(abs)));
    } catch (e) {
      return sendJson(res, 400, { ok: false, error: 'list-failed', message: String((e && e.message) || e) });
    }
  }
  if (route === '/__files/api/read') {
    const raw = u.searchParams.get('path');
    const abs = raw ? safeResolve(raw, roots) : null;
    if (!abs) return sendJson(res, 403, { ok: false, error: 'path-not-allowed' });
    try {
      const r = readText(abs);
      if (r.error) return sendJson(res, 400, { ok: false, error: r.error });
      return sendJson(res, 200, Object.assign({ ok: true }, r));
    } catch (e) {
      return sendJson(res, 404, { ok: false, error: 'read-failed', message: String((e && e.message) || e) });
    }
  }
  if (route === '/__files/api/download') {
    const raw = u.searchParams.get('path');
    const abs = raw ? safeResolve(raw, roots) : null;
    if (!abs) return sendJson(res, 403, { ok: false, error: 'path-not-allowed' });
    try {
      const st = fs.statSync(abs);
      if (st.isDirectory()) return sendJson(res, 400, { ok: false, error: 'is-directory' });
      const name = path.basename(abs);
      res.writeHead(200, {
        'content-type': 'application/octet-stream',
        'content-disposition':
          'attachment; filename="' + name.replace(/"/g, '') + '\"; filename*=UTF-8\'\'' + encodeURIComponent(name),
        'content-length': st.size,
        'cache-control': 'no-store',
      });
      fs.createReadStream(abs).pipe(res);
      return;
    } catch (e) {
      return sendJson(res, 404, { ok: false, error: 'read-failed' });
    }
  }
  if (route === '/__files/api/write' && req.method === 'POST') {
    let body = '';
    req.on('data', (c) => {
      body += c;
      if (body.length > MAX_WRITE_BODY_BYTES) req.destroy();
    });
    req.on('end', () => {
      let parsed;
      try {
        parsed = JSON.parse(body);
      } catch (e) {
        return sendJson(res, 400, { ok: false, error: 'bad-json' });
      }
      const abs = safeResolve(parsed && parsed.path, roots);
      if (!abs) return sendJson(res, 403, { ok: false, error: 'path-not-allowed' });
      if (typeof parsed.content !== 'string') return sendJson(res, 400, { ok: false, error: 'bad-content' });
      try {
        return sendJson(res, 200, Object.assign({ ok: true }, writeText(abs, parsed.content)));
      } catch (e) {
        return sendJson(res, 500, { ok: false, error: 'write-failed', message: String((e && e.message) || e) });
      }
    });
    return;
  }
  sendJson(res, 404, { ok: false, error: 'not-found' });
}

// Script injected by web-proxy.js into dsh's HTML. When the app is served to
// a non-loopback device, intercept host.openPath (which dsh pins to loopback
// and would 403 from the phone) and open the /__files viewer instead. Also
// adds a floating "Files" button.
function integrationScript() {
  return `<script>
(function () {
  function isLoopbackHost() {
    var h = location.hostname;
    if (h === 'localhost' || h === '[::1]') return true;
    return /^127\\./.test(h);
  }
  function openViewer(pathValue) {
    var target = '/__files/#/view?path=' + encodeURIComponent(pathValue);
    var w = null;
    try { w = window.open(target, '_blank'); } catch (e) {}
    if (!w) { try { location.assign(target); } catch (e) {} }
  }
  if (!isLoopbackHost()) {
    var realFetch = window.fetch;
    window.fetch = function (input, init) {
      try {
        // input may be a string, a URL object, or a Request. A URL object has
        // no url property — the full string lives on href. Reading url first
        // (for a Request) then href (for a URL) then the raw string covers
        // every case. Before this fix, a URL object resolved to nothing, so
        // the host.openPath match never fired and the real fetch hit dsh's
        // loopback fence -> 403 from the phone.
        var url = (typeof input === 'string')
          ? input
          : ((input && (input.url || input.href)) || '');
        var method = (init && init.method) || (input && input.method) || 'GET';
        if (method === 'POST' && url.indexOf('/api/host.openPath') !== -1) {
          var body = init && init.body ? String(init.body) : '';
          var parsed = null;
          try { parsed = JSON.parse(body); } catch (e) {}
          var p = parsed && parsed.payload && parsed.payload.path;
          if (typeof p === 'string' && p.length > 0) {
            openViewer(p);
            var id = (parsed && parsed.rpcId) || 'intercepted-open-path';
            var envelope = JSON.stringify({
              type: 'server-response',
              rpcId: id,
              result: { ok: true, value: { opened: true } }
            });
            return Promise.resolve(new Response(envelope, {
              status: 200,
              headers: { 'content-type': 'application/json' }
            }));
          }
        }
      } catch (e) {}
      return realFetch.apply(this, arguments);
    };
  }
  function addButton() {
    var b = document.createElement('button');
    b.type = 'button';
    b.textContent = 'Files';
    b.setAttribute('aria-label', 'Open file browser');
    b.style.cssText = 'position:fixed;right:12px;bottom:80px;z-index:99999;background:rgba(30,36,44,0.92);color:#d6dee8;border:1px solid #39434f;border-radius:8px;padding:8px 12px;font:500 13px/1.2 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;cursor:pointer;box-shadow:0 2px 8px rgba(0,0,0,0.35);';
    b.addEventListener('click', function () { location.href = '/__files/'; });
    (document.body || document.documentElement).appendChild(b);
  }
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', addButton);
  } else {
    addButton();
  }
})();
</script>`;
}

module.exports = {
  handle,
  isTrustedRequest,
  buildTrustedAuthorities,
  safeResolve,
  isLoopbackHostname,
  readText,
  writeText,
  integrationScript,
};
