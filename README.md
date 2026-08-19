# DeepSeek Harness (dsh) — Local Setup on shervin-pc

The [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) runs locally on this PC and is exposed to the Tailscale tailnet so it can be used from any device (this PC, iPhone, etc.) over the encrypted Tailscale tunnel.

## Access

| Where | URL |
|---|---|
| Tailscale devices (iPhone, this PC) — HTTPS | `https://shervin-pc.tail41da1a.ts.net` |
| Tailscale devices — plain HTTP (fallback) | `http://100.85.211.6:3080` |
| This PC only (loopback, bypasses proxy) | `http://127.0.0.1:3081` |

MagicDNS name: `shervin-pc.tail41da1a.ts.net`. The HTTPS endpoint is served by Tailscale Serve with a Let's Encrypt certificate (tailnet-only). The name may not resolve from this PC (NextDNS is the local resolver) but resolves on Tailscale devices using MagicDNS (e.g. the iPhone); use `100.85.211.6` for the plain-HTTP fallback.

Requirements to connect:
- The connecting device must have Tailscale running and be logged into the tailnet (`green.joshua08@gmail.com`).
- The iPhone must have the Tailscale app installed and the VPN enabled.
- No login needed on the harness itself; it is bound to loopback and trusted hosts are pre-configured.

## Deployment steps

Fresh install from scratch on a new Windows machine:

1. **Tailscale**: install the Tailscale client, log in to the tailnet, and verify the node is up (`tailscale status`). Note the node name and 100.x IP (here `shervin-pc`, `100.85.211.6`).
2. **HTTPS certificates**: enable HTTPS in the Tailscale admin console (DNS → HTTPS Certificates), then verify issuance: `tailscale cert shervin-pc.tail41da1a.ts.net`. This writes `.crt`/`.key` next to the cert (kept out of this repo — they're machine-local secrets).
3. **Node.js >= 24**: `scoop install nodejs-lts` (or another install method); `node --version` must be `>= 24`.
4. **Install dsh**: `npm install -g @deepseek-ai/dsh`.
5. **Deployment files**: copy `web-proxy.js`, `start-harness.ps1`, and this README into any folder (e.g. `%USERPROFILE%\dsh\`). No edits needed — the launcher auto-detects Node.js, the dsh install, and the Tailscale hostname/IP, and derives the trusted-host list from them. See [Configuration](#configuration) to override anything.
6. **Firewall rule** (restrict 3080 to the tailnet):
   ```powershell
   New-NetFirewallRule -DisplayName 'DeepSeek Harness (Tailscale only)' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 3080 -RemoteAddress 100.64.0.0/10, fd7a:115c:a1e0::/48
   ```
7. **Tailscale Serve** (HTTPS termination to the proxy):
   ```powershell
   tailscale serve --bg http://127.0.0.1:3080
   ```
8. **Scheduled task** (start on logon):
   ```powershell
   Register-ScheduledTask -TaskName 'DeepSeek Harness' -Action (New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\Users\green\dsh\start-harness.ps1"') -Trigger (New-ScheduledTaskTrigger -AtLogOn) -Settings (New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Seconds 0))
   ```
9. **Start now**: run `start-harness.ps1` once (idempotent), then verify the endpoints below.

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

- `dsh web` intentionally refuses to bind beyond `127.0.0.1` (it would expose remote code execution to the network), so `web-proxy.js` (a Node reverse proxy) owns the tailnet-facing port `3080` and forwards everything to `127.0.0.1:3081`.
- The proxy injects a `crypto.randomUUID` polyfill into HTML responses (needed only over plain HTTP) and normalizes the `Host` header to the browser origin so dsh's origin-vs-host trust fence passes behind Tailscale Serve.
- WebSocket upgrades (`/api/events.mux`, `/api/events.host`) are forwarded with `http.request` so the upstream `101` is relayed faithfully: original headers (including `Origin` and `Cookie`) are preserved, optional `Sec-WebSocket-*` headers are only sent when present, and `Host` is normalized to the browser origin — same as the HTTP path.
- Tailscale Serve terminates HTTPS on the tailnet with a Let's Encrypt certificate and forwards `https://shervin-pc.tail41da1a.ts.net` to `http://127.0.0.1:3080`.
- The Windows Firewall rule allows inbound TCP `3080` only from the Tailscale CGNAT ranges (`100.64.0.0/10` and `fd7a:115c:a1e0::/48`); Tailscale manages its own `:443` listener. Public internet traffic is blocked.

## Components

| Component | Location / Value |
|---|---|
| Node.js (required ^22.19 or >=24) | auto-detected from PATH; override with `DSH_NODE` (this machine: scoop `nodejs-lts` 24.19.0) |
| dsh package (global) | auto-detected from `<npm global root>/@deepseek-ai/dsh` (this machine: v0.1.0-rc.8); override with `DSH_DSH_BIN` |
| Launcher script | `start-harness.ps1` (this machine: `C:\Users\green\dsh\start-harness.ps1`) |
| Proxy (tailnet front-end) | `web-proxy.js` (`0.0.0.0:$DSH_PROXY_PORT` → `$UPSTREAM_HOST:$DSH_WEB_PORT`) |
| Logs | next to the launcher: `dsh-web.log`, `dsh-web.err.log`, `proxy.log`, `proxy.err.log`, `update-check.log` |
| Scheduled task | `DeepSeek Harness` (runs at user logon) |
| Firewall rule | `DeepSeek Harness (Tailscale only)` (TCP `$DSH_PROXY_PORT` from Tailscale CGNAT ranges) |

## Configuration

Everything is optional — the launcher auto-detects the common values and every setting can be overridden with an environment variable:

| Variable | Default | Purpose |
|---|---|---|
| `DSH_NODE` | `node` on PATH | Node.js executable path |
| `DSH_DSH_BIN` | `<npm global root>/@deepseek-ai/dsh/lib/bin.js` | dsh CLI entry |
| `DSH_TS_HOST` | this node's name from `tailscale status` | Tailscale MagicDNS name, e.g. `myhost.tailXXXX.ts.net` |
| `DSH_TS_IP` | this node's 100.x IP from `tailscale status` | Tailscale IP used for `--trusted-host` |
| `DSH_PROXY_PORT` | `3080` | tailnet-facing proxy port |
| `DSH_WEB_PORT` | `3081` | loopback dsh web port |
| `DSH_UPDATE_TRACK` | `next` | npm dist-tag checked for updates (`next` = newest; `latest` = stable) |
| `DSH_AUTO_UPDATE` | unset (`0`) | set `1` to auto-install newer dsh on startup (backs up `~/.dsh` first) |

The launcher derives the full trusted-host list from `DSH_TS_HOST`/`DSH_TS_IP` × `DSH_PROXY_PORT` (both the `host:port` and bare `host` spellings), starts the proxy with `PROXY_PORT`/`UPSTREAM_PORT` set, and passes `--trusted-host` for each. Set variables persistently with `setx` or in the scheduled task action if you customize them.

## Manual start / stop

Start (idempotent — exits if already running):
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\green\dsh\start-harness.ps1"
```

Stop:
```powershell
Get-Process node | Where-Object { $_.Path -like '*scoop*nodejs-lts*' } | Stop-Process
```
(or find the PID listening on 3081 and stop it.)

The launcher starts `web-proxy.js` (if the proxy port is free) and then dsh (if the web port is free). It exports `SSH_CONNECTION=remote` to mount the web-safe directory picker, then runs dsh with `--trusted-host` entries derived from the Tailscale identity and proxy port (both `host:port` and bare `host` spellings).

## Auto-start on boot

A scheduled task named `DeepSeek Harness` starts the harness at user logon:
- Action: `powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\Users\green\dsh\start-harness.ps1"`
- Runs as the logged-in user, interactive logon, limited privileges.
- Unlimited execution time limit; restarts up to 3 times, 1 minute apart.

Note: this is a logon task, not a boot task — the harness starts when you sign in. To make it start before login you'd need a SYSTEM-level boot task (Tailscale Serve and the Node proxy would also need to be started, or made system-wide).

## Networking details

- Tailscale node: `shervin-pc`, IP `100.85.211.6`, tailnet `tail41da1a.ts.net`.
- Tailscale Serve: `https://shervin-pc.tail41da1a.ts.net` → `http://127.0.0.1:3080` (check with `tailscale serve status`). HTTPS certificates are enabled in the Tailscale admin console (`tailscale cert shervin-pc.tail41da1a.ts.net` succeeds).
- Node proxy: `C:\Users\green\dsh\web-proxy.js` listens on `0.0.0.0:3080` and forwards to `127.0.0.1:3081`. (The earlier `netsh portproxy` rule was removed — the proxy replaced it.)
- Firewall rule:
  ```
  Name=DeepSeek Harness (Tailscale only)
  Action=Allow, Direction=Inbound, Enabled=Yes
  Protocol=TCP, LocalPort=3080
  RemoteAddress=100.64.0.0/10, fd7a:115c:a1e0::/48
  ```

## Troubleshooting

- **`http://100.85.211.6:3080` fails from iPhone**:
  1. Confirm Tailscale VPN is ON in the iOS app and the phone is connected (`tailscale status` on the PC should show `iphone174` as active).
  2. Confirm the harness is up: `http://127.0.0.1:3081` on the PC.
  3. Confirm the proxy is up: `http://127.0.0.1:3080` returns the app (it forwards to `3081`).
  4. Confirm the firewall rule is enabled and scoped to Tailscale ranges.
- **dsh won't start**: check `C:\Users\green\dsh\dsh-web.err.log`; the most common cause is a Node version below `^22.19 || >=24` — use the scoop Node 24.19.0.
- **MagicDNS name won't resolve on the PC**: expected — NextDNS is the local resolver. Use the IP `100.85.211.6` instead.
- **Creating a workspace from the phone shows `transport failure for /api/host.pickDirectory: HTTP 403`**: the native OS folder dialog is loopback-only by design in dsh. The harness is launched with `SSH_CONNECTION=remote` so it mounts the web-safe in-browser directory picker (`host.listDirectory` / `host.createDirectory`) instead. If this regresses, confirm `start-harness.ps1` still sets `$env:SSH_CONNECTION` and includes the bare `shervin-pc.tail41da1a.ts.net` trusted-host.
- **Workspaces/history missing after a page refresh (UI stuck on "Add workspace / Choose workspace")**: the proxy's WebSocket upgrade forwarding is broken. dsh only loads the workspace/session baseline after two WebSocket connections open (`/api/events.mux` and `/api/events.host`), opened by the client with `new WebSocket(url)` (no subprotocol). The old `net.connect`-based tunnel always emitted empty `Sec-WebSocket-Protocol:`/`Sec-WebSocket-Extensions:` headers (dsh rejects with `400 Invalid Sec-WebSocket-Protocol header`) and dropped `Origin`/`Host` normalization. Verify the fix with a raw handshake — both paths must return `101`:
  ```js
  node -e "const http=require('http');function t(path){const r=http.request({host:'127.0.0.1',port:3080,path,headers:{'Connection':'Upgrade','Upgrade':'websocket','Sec-WebSocket-Version':'13','Sec-WebSocket-Key':'dGhlIHNhbXBsZSBub25jZQ==','Origin':'http://127.0.0.1:3080'}});r.on('upgrade',(res,sock)=>{console.log(path,'->',res.statusCode);sock.destroy();});r.on('response',res=>{console.log(path,'->',res.statusCode);res.resume();});r.on('error',e=>console.log(path,'ERR',e.message));r.end();}t('/api/events.mux');setTimeout(()=>t('/api/events.host'),600);"
  ```
  Note: persistence itself is built into dsh — workspaces/sessions live on disk under `~/.dsh\` and survive restarts; the UI only appeared empty because the client never connected.

## Change log

- **2026-08-19 — Startup update checks**: added `check-updates.ps1` (run by `start-harness.ps1` at logon) to compare the installed dsh version against the npm registry and log/notify — or auto-update via `DSH_AUTO_UPDATE=1` with an automatic `~/.dsh` backup. See [Configuration](#configuration).
- **2026-08-19 — WebSocket proxy fix (persistence looked broken on refresh)**: rewrote the `upgrade` handler in `web-proxy.js` to proxy WebSockets with `http.request` instead of a raw `net.connect` tunnel. This preserves `Origin`/`Cookie`/`Sec-WebSocket-*` headers (no more empty optional headers → no more `400 Invalid Sec-WebSocket-Protocol header`), applies the same `Host`→origin normalization as the HTTP path, and relays the upstream `101`/error response faithfully. Without it, the client's `/api/events.mux` and `/api/events.host` WebSockets failed and the UI never loaded workspaces or history. See the troubleshooting entry above.

## Notes

- HTTPS is terminated by Tailscale Serve with a Let's Encrypt certificate (tailnet-only). The earlier plain-HTTP portproxy workaround was replaced by this HTTPS route; the plain-HTTP `:3080` path still works as a fallback.
- `--trusted-host` values keep the browser-trust fence in place so the UI only accepts the tailnet origins listed above. The bare hostnames (no port) are required for the HTTPS origin.
