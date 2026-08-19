---
name: dsh-tailscale-web
description: Deploy, fix, or troubleshoot the DeepSeek Harness (dsh) web UI exposed over Tailscale, including the reverse proxy, HTTPS via Tailscale Serve, WebSocket proxying, and persistence behavior. Use when setting up dsh on a new machine, when the UI shows no workspaces/history after refresh, or when diagnosing WebSocket/connection failures in the proxy.
---

# DeepSeek Harness (dsh) over Tailscale — Deployment & Troubleshooting

## Overview

dsh (`@deepseek-ai/dsh`) is an open-source (MIT) agentic coding harness with a web UI. `dsh web` deliberately refuses to bind beyond `127.0.0.1` because it exposes remote code execution. To use it from other devices (e.g. an iPhone), run a Node reverse proxy on the tailnet-facing port and optionally terminate HTTPS with Tailscale Serve.

## Architecture

```
Tailscale device ──► Tailscale Serve :443 (HTTPS) ────────┐
Tailscale device ──► 0.0.0.0:3080 (plain HTTP) ──────────┤
                                                         ▼
                                        web-proxy.js (0.0.0.0:3080)
                                                         │ forwards to
                                                         ▼
                                                127.0.0.1:3081 (dsh web)
```

- dsh web binds `127.0.0.1:3081` only.
- The Node proxy binds `0.0.0.0:3080` and forwards to `127.0.0.1:3081`.
- The proxy injects a `crypto.randomUUID` polyfill into HTML (only available in secure contexts; needed over plain HTTP) and normalizes the `Host` header to the browser Origin so dsh's origin-vs-host trust fence passes behind Tailscale Serve.
- Tailscale Serve terminates HTTPS with a Let's Encrypt cert and forwards to `http://127.0.0.1:3080`.
- A Windows Firewall rule restricts inbound `3080` to the Tailscale CGNAT ranges (`100.64.0.0/10`, `fd7a:115c:a1e0::/48`).

## Setup steps (fresh machine)

1. Tailscale: install client, join tailnet, note node name + 100.x IP (`tailscale status`).
2. HTTPS certs: enable in Tailscale admin console (DNS → HTTPS Certificates); verify with `tailscale cert <node>.<tailnet>.ts.net`.
3. Node.js >= 24 (`scoop install nodejs-lts`).
4. `npm install -g @deepseek-ai/dsh`.
5. Copy `web-proxy.js` and `start-harness.ps1` into any folder (e.g. `%USERPROFILE%\dsh\`). No edits needed — the launcher auto-detects Node.js (PATH), the dsh install (`npm root -g`), and the Tailscale identity (`tailscale status`), then derives the trusted-host list. Override anything with env vars (see Configuration).
6. Firewall rule (adjust `-LocalPort` if you set `DSH_PROXY_PORT`):
   ```powershell
   New-NetFirewallRule -DisplayName 'DeepSeek Harness (Tailscale only)' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 3080 -RemoteAddress 100.64.0.0/10, fd7a:115c:a1e0::/48
   ```
7. `tailscale serve --bg http://127.0.0.1:3080` (adjust the port if you set `DSH_PROXY_PORT`)
8. Scheduled task at logon running `start-harness.ps1` (hidden, unlimited runtime).
9. Run `start-harness.ps1` once (idempotent) and verify.

Launcher essentials (already handled by the script):
- Sets `$env:SSH_CONNECTION = 'remote'` before starting dsh so it mounts the web-safe in-browser directory picker (`host.listDirectory`/`host.createDirectory`) instead of the native OS dialog (loopback-only, 403s from remote devices).
- Passes `--trusted-host` for the tailnet hostname and IP, both bare and with `:<proxy port>`.
- Starts the proxy only if the proxy port is free; starts dsh only if the web port is free (idempotent).

### Configuration (environment variables)

All optional; defaults are auto-detected, so a fresh clone runs as-is on a machine with Node, dsh, and Tailscale installed:

| Variable | Default | Purpose |
|---|---|---|
| `DSH_NODE` | `node` on PATH | Node.js executable path |
| `DSH_DSH_BIN` | `<npm global root>/@deepseek-ai/dsh/lib/bin.js` | dsh CLI entry |
| `DSH_TS_HOST` | this node's name from `tailscale status` | Tailscale MagicDNS name |
| `DSH_TS_IP` | this node's 100.x IP from `tailscale status` | Tailscale IP for `--trusted-host` |
| `DSH_PROXY_PORT` | `3080` | tailnet-facing proxy port |
| `DSH_WEB_PORT` | `3081` | loopback dsh web port |
| `DSH_UPDATE_TRACK` | `next` | npm dist-tag checked for updates (`next` = newest; `latest` = stable) |
| `DSH_AUTO_UPDATE` | unset (`0`) | set `1` to auto-install newer dsh on startup (backs up `~/.dsh` first) |

The proxy itself reads `PROXY_PORT`, `UPSTREAM_PORT`, and `UPSTREAM_HOST` (default `127.0.0.1`) from its environment, so ports and the upstream target are configurable without editing files. The launcher also runs `check-updates.ps1` at logon to compare the installed dsh version against the `DSH_UPDATE_TRACK` dist-tag and log the result to `update-check.log` (notifying via toast when `BurntToast` is installed, or auto-updating when `DSH_AUTO_UPDATE=1`).

## Critical: WebSocket proxying (workspaces/history missing after refresh)

dsh's web client reaches its "connected" state only after two WebSocket connections open:
- `/api/events.mux`
- `/api/events.host`

Only then does it pull the workspace/session baseline (`SessionManager.handleConnected()` → `refreshList()`, `Workspace.handleConnected()`) and render history. If these fail, the UI sits on "Add workspace / Choose workspace" and history looks lost — even though everything persists on disk under `~/.dsh\` (sessions JSONL, `storages\workspace.json`, `storages\session_projcache.json`, `settings.yaml`).

The client opens these with plain `new WebSocket(url)` (no subprotocol) in `dsh-client-connection/lib/client.js` (`WebApiClient.readWebSocket`). The dsh server rejects handshakes with an empty `Sec-WebSocket-Protocol` header: `400 Invalid Sec-WebSocket-Protocol header`.

### Correct upgrade handler pattern

A naive `net.connect`-based tunnel that always writes `Sec-WebSocket-Protocol:` / `Sec-WebSocket-Extensions:` (even when empty) and drops `Origin`/`Host` normalization breaks the handshake. Use `http.request` so Node relays the upstream `101` faithfully, preserve all original headers, only forward optional `Sec-WebSocket-*` headers when present, and normalize `Host` to the browser Origin authority:

```js
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
  const origin = headers['origin'];
  if (typeof origin === 'string' && origin !== '') {
    try { headers['host'] = new URL(origin).host; } catch {}
  }
  const upstreamReq = http.request({
    host: UPSTREAM_HOST, port: UPSTREAM_PORT,
    method: req.method, path: req.url, headers,
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
```

### Quick handshake test

```js
node -e "const http=require('http');function t(path){const r=http.request({host:'127.0.0.1',port:3080,path,headers:{'Connection':'Upgrade','Upgrade':'websocket','Sec-WebSocket-Version':'13','Sec-WebSocket-Key':'dGhlIHNhbXBsZSBub25jZQ==','Origin':'http://127.0.0.1:3080'}});r.on('upgrade',(res,sock)=>{console.log(path,'->',res.statusCode);sock.destroy();});r.on('response',res=>{console.log(path,'->',res.statusCode);res.resume();});r.on('error',e=>console.log(path,'ERR',e.message));r.end();}t('/api/events.mux');setTimeout(()=>t('/api/events.host'),600);"
```

Expect `101` for both. A `400 Invalid Sec-WebSocket-Protocol header` means the proxy emits empty optional headers; `403` from a direct-to-dsh test means a Host/Origin trust mismatch.

## Persistence notes

Persistence is built in (not something to build): workspaces and sessions live under `~/.dsh\`. On refresh, the client restores the current session from `localStorage['dsh.sessions.current']`; if none is set (or the browser blocks storage, e.g. iOS private mode), it auto-connects the most recent workspace and creates/opens its blank session — history still exists server-side. If the UI appears empty after refresh, check the WebSockets first, then confirm `workspace.list` / `session.list` RPCs return data:
- `POST /api/<method>` with `{"type":"client-request","rpcId":"...","method":"...","payload":{}}`.

## Troubleshooting

- Empty UI / "Add workspace" after refresh → WebSocket proxy bug (see above). Check browser console for `WebSocket connection to 'ws://.../api/events.mux' failed` and `connection lost, retry`.
- `host.pickDirectory` HTTP 403 from phone → ensure `SSH_CONNECTION=remote` is set in the launcher and the bare trusted-host is present.
- MagicDNS name won't resolve on the PC itself → expected if the local resolver isn't Tailscale's; use the 100.x IP.
- Restart proxy only: find PID on 3080 (`Get-NetTCPConnection -LocalPort 3080`), `Stop-Process`, then start `node web-proxy.js` again (dsh on 3081 can stay up).

## Verification checklist

1. Raw WebSocket handshakes through the proxy return `101` for `/api/events.mux` and `/api/events.host`.
2. Page loads with all workspaces listed in the sidebar.
3. Opening a conversation, then reloading the page, restores the same session with history intact.
4. Workspace creation from a remote device works via the in-browser picker (no 403).
