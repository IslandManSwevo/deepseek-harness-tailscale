# DeepSeek Harness over Tailscale — Deployment Guide

This is the full technical guide for [deepseek-harness-tailscale](../README.md): deploying the [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (`dsh`) on a Windows PC and exposing it to a [Tailscale](https://tailscale.com) tailnet so it can be used from any device (PC, phone, tablet, etc.) over the encrypted Tailscale tunnel.

> **Placeholders**: values in angle brackets (`<...>`) are placeholders. Replace them with your own values — the node name, tailnet, and 100.x IP come from `tailscale status`; the folder paths are wherever you copy the files.

## Access

| Where | URL |
|---|---|
| Tailscale devices — HTTPS | `https://<node-name>.<tailnet-name>.ts.net` |
| Tailscale devices — plain HTTP (fallback) | `http://<tailscale-ip>:3080` |
| This PC only (loopback, bypasses proxy) | `http://127.0.0.1:3081` |

The HTTPS endpoint is served by Tailscale Serve with a Let's Encrypt certificate (tailnet-only). The MagicDNS name may not resolve on the host PC itself if its local resolver isn't Tailscale's — it resolves on Tailscale devices using MagicDNS (e.g. a phone). Use `<tailscale-ip>` for the plain-HTTP fallback.

Requirements to connect:
- The connecting device must have Tailscale running and be logged into the same tailnet.
- Phones need the Tailscale app installed and the VPN enabled.
- No login needed on the harness itself; it is bound to loopback and trusted hosts are pre-configured.

## Deployment steps

Fresh install from scratch on a new Windows machine:

1. **Tailscale**: install the Tailscale client, log in to the tailnet, and verify the node is up (`tailscale status`). Note the node name and 100.x IP — these become `<node-name>`, `<tailnet-name>`, and `<tailscale-ip>` below.
2. **HTTPS certificates**: enable HTTPS in the Tailscale admin console (DNS → HTTPS Certificates), then verify issuance: `tailscale cert <node-name>.<tailnet-name>.ts.net`. This writes `.crt`/`.key` files — keep them out of the repo, they're machine-local secrets.
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
8. **Scheduled task** (start on logon) — the path resolves to your dsh folder:
   ```powershell
   $dshPath = Join-Path $env:USERPROFILE 'dsh\start-harness.ps1'
   Register-ScheduledTask -TaskName 'DeepSeek Harness' -Action (New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$dshPath`"") -Trigger (New-ScheduledTaskTrigger -AtLogOn) -Settings (New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Seconds 0))
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
- The proxy also serves a local web file browser/viewer/editor under `/__files` (see [Web file viewer](#web-file-viewer)); it never forwards that prefix to dsh.
- WebSocket upgrades (`/api/events.mux`, `/api/events.host`) are forwarded with `http.request` so the upstream `101` is relayed faithfully: original headers (including `Origin` and `Cookie`) are preserved, optional `Sec-WebSocket-*` headers are only sent when present, and `Host` is normalized to the browser origin — same as the HTTP path.
- Tailscale Serve terminates HTTPS on the tailnet with a Let's Encrypt certificate and forwards `https://<node-name>.<tailnet-name>.ts.net` to `http://127.0.0.1:3080`.
- The Windows Firewall rule allows inbound TCP `3080` only from the Tailscale CGNAT ranges (`100.64.0.0/10` and `fd7a:115c:a1e0::/48`); Tailscale manages its own `:443` listener. Public internet traffic is blocked.

## Components

| Component | Location / Value |
|---|---|
| Node.js (required ^22.19 or >=24) | auto-detected from PATH; override with `DSH_NODE` |
| dsh package (global) | auto-detected from `<npm global root>/@deepseek-ai/dsh`; override with `DSH_DSH_BIN` |
| Launcher script | `start-harness.ps1` (e.g. `%USERPROFILE%\dsh\start-harness.ps1`) |
| Proxy (tailnet front-end) | `web-proxy.js` (`0.0.0.0:$DSH_PROXY_PORT` → `$UPSTREAM_HOST:$DSH_WEB_PORT`) |
| Web file viewer | `web-files.js` + `web-files-page.html` (served at `/__files`) |
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
| `DSH_TS_WAIT_SECONDS` | `60` | seconds the launcher polls Tailscale for its identity at startup (Tailscale is often still starting at logon) |
| `DSH_TS_RETRY_SECONDS` | `600` | seconds a background retry keeps polling Tailscale after startup so the proxy starts automatically once the tailnet connects (`0` disables the retry) |
| `DSH_PROXY_PORT` | `3080` | tailnet-facing proxy port |
| `DSH_WEB_PORT` | `3081` | loopback dsh web port |
| `DSH_UPDATE_TRACK` | `next` | npm dist-tag checked for updates (`next` = newest; `latest` = stable) |
| `DSH_AUTO_UPDATE` | unset (`0`) | set `1` to auto-install newer dsh on startup (backs up `~/.dsh` first) |
| `DSH_FILES_ROOT` | host account home directory | semicolon-separated roots the `/__files` viewer may read/write |

The launcher derives the full trusted-host list from `DSH_TS_HOST`/`DSH_TS_IP` × `DSH_PROXY_PORT` (both the `host:port` and bare `host` spellings), starts the proxy with `PROXY_PORT`/`UPSTREAM_PORT` set, and passes `--trusted-host` for each. Set variables persistently with `setx` or in the scheduled task action if you customize them.

## Manual start / stop

Start (idempotent — exits if already running):
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\dsh\start-harness.ps1"
```

Stop (ownership-aware — stops only this deployment's processes; a foreign process squatting on the ports is reported and left running):
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\dsh\start-harness.ps1" -Stop
```
(`-Restart` stops then starts again; plain runs are idempotent. `-Verify` runs a one-shot health check — component ownership, that dsh carries its `--trusted-host` list, and both WebSocket handshakes with the tailnet `Origin` — and exits non-zero if anything is wrong.)

The launcher starts `web-proxy.js` (if the proxy port is free) and then dsh (if the web port is free). It exports `SSH_CONNECTION=remote` to mount the web-safe directory picker, then runs dsh with `--trusted-host` entries derived from the Tailscale identity and proxy port (both `host:port` and bare `host` spellings).

## Auto-start on boot

A scheduled task named `DeepSeek Harness` starts the harness at user logon:
- Action: `powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "<path to your dsh folder>\start-harness.ps1"`
- Runs as the logged-in user, interactive logon, limited privileges.
- Unlimited execution time limit; restarts up to 3 times, 1 minute apart.

Note: this is a logon task, not a boot task — the harness starts when you sign in. To make it start before login you'd need a SYSTEM-level boot task (Tailscale Serve and the Node proxy would also need to be started, or made system-wide).

**Tailscale race at logon:** the launcher polls Tailscale for its identity for `DSH_TS_WAIT_SECONDS` (default 60) and, if the tailnet still hasn't connected, starts dsh on loopback and arms a background retry (`DSH_TS_RETRY_SECONDS`, default 600) that re-runs the launcher the moment the identity appears — so the proxy comes up automatically a short while after sign-in even when the logon task fired before Tailscale finished connecting.

## Networking details

- Tailscale node: `<node-name>`, IP `<tailscale-ip>`, tailnet `<tailnet-name>.ts.net` (from `tailscale status`).
- Tailscale Serve: `https://<node-name>.<tailnet-name>.ts.net` → `http://127.0.0.1:3080` (check with `tailscale serve status`). HTTPS certificates are enabled in the Tailscale admin console (`tailscale cert <node-name>.<tailnet-name>.ts.net` succeeds).
- Node proxy: `web-proxy.js` in your dsh folder (e.g. `%USERPROFILE%\dsh\web-proxy.js`) listens on `0.0.0.0:3080` and forwards to `127.0.0.1:3081`. (The earlier `netsh portproxy` rule was removed — the proxy replaced it.)
- Firewall rule:
  ```
  Name=DeepSeek Harness (Tailscale only)
  Action=Allow, Direction=Inbound, Enabled=Yes
  Protocol=TCP, LocalPort=3080
  RemoteAddress=100.64.0.0/10, fd7a:115c:a1e0::/48
  ```

## Web file viewer

`host.openPath` (opening a file with the OS default app) is loopback-only in dsh, so clicking a produced-file chip from a phone returns `transport failure for /api/host.openPath: HTTP 403`. The proxy fixes this with a built-in browser for files the agent created:

- **Viewing**: on any non-loopback device, clicking a produced file (or its inline mention) now opens the `/__files` viewer in a new tab instead of hitting the 403. On the host PC (`127.0.0.1`) the native `Invoke-Item` behavior is kept.
- **Standalone entry point**: a floating **Files** button is injected into the dsh UI (bottom-right) and opens `/__files`.
- **Capabilities**: browse directories, view/edit text files (save preserves CRLF), download binary or >2 MB files. URL hash routes: `#/dir?path=<abs>` and `#/view?path=<abs>`.

Security model (same spirit as dsh's own browser-trust fence):
- Requests are accepted only when `Host`/`Origin` is a loopback authority or one of the trusted Tailscale authorities (`DSH_TS_HOST`/`DSH_TS_IP`); cross-site and Origin-mismatched requests are rejected.
- Every path is contained to `DSH_FILES_ROOT` (default `~`); `..` traversal, symlink escapes, and null bytes are rejected. Read/write only — no code execution.

## Troubleshooting

- **Tailnet URL down after reboot, but `http://127.0.0.1:3081` works**: the logon task started dsh before Tailscale reconnected, so the proxy (3080) was deferred. Wait for the background retry (`DSH_TS_RETRY_SECONDS`, default 600) to pick it up, or re-run `start-harness.ps1` once now that Tailscale is connected. If it recurs, raise `DSH_TS_WAIT_SECONDS` or `DSH_TS_RETRY_SECONDS`, or install the watchdog task (`watchdog.ps1`).
- **`http://<tailscale-ip>:3080` fails from a phone**:
  1. Confirm Tailscale VPN is ON in the mobile app and the device is connected (`tailscale status` on the PC should show the device as active).
  2. Confirm the harness is up: `http://127.0.0.1:3081` on the PC.
  3. Confirm the proxy is up: `http://127.0.0.1:3080` returns the app (it forwards to `3081`).
  4. Confirm the firewall rule is enabled and scoped to Tailscale ranges.
- **dsh won't start**: check `%USERPROFILE%\dsh\dsh-web.err.log` (or wherever you copied the files); the most common cause is a Node version below `^22.19 || >=24` — install a recent Node.js LTS.
- **MagicDNS name won't resolve on the PC**: expected if the local resolver isn't Tailscale's. Use the IP `<tailscale-ip>` instead.
- **Creating a workspace from the phone shows `transport failure for /api/host.pickDirectory: HTTP 403`**: the native OS folder dialog is loopback-only by design in dsh. The harness is launched with `SSH_CONNECTION=remote` so it mounts the web-safe in-browser directory picker (`host.listDirectory` / `host.createDirectory`) instead. If this regresses, confirm `start-harness.ps1` still sets `$env:SSH_CONNECTION` and includes the bare `<node-name>.<tailnet-name>.ts.net` trusted-host.
- **Clicking a file from the phone shows `transport failure for /api/host.openPath: HTTP 403`**: fixed by the web file viewer — the proxy intercepts remote `host.openPath` calls and opens `/__files` instead (see [Web file viewer](#web-file-viewer)).
- **Workspaces/history missing after a page refresh (UI stuck on "Add workspace / Choose workspace")**: the proxy's WebSocket upgrade forwarding is broken. dsh only loads the workspace/session baseline after two WebSocket connections open (`/api/events.mux` and `/api/events.host`), opened by the client with `new WebSocket(url)` (no subprotocol). The old `net.connect`-based tunnel always emitted empty `Sec-WebSocket-Protocol:`/`Sec-WebSocket-Extensions:` headers (dsh rejects with `400 Invalid Sec-WebSocket-Protocol header`) and dropped `Origin`/`Host` normalization. Verify the fix with a raw handshake — both paths must return `101`:
  ```js
  node -e "const http=require('http');function t(path){const r=http.request({host:'127.0.0.1',port:3080,path,headers:{'Connection':'Upgrade','Upgrade':'websocket','Sec-WebSocket-Version':'13','Sec-WebSocket-Key':'dGhlIHNhbXBsZSBub25jZQ==','Origin':'http://127.0.0.1:3080'}});r.on('upgrade',(res,sock)=>{console.log(path,'->',res.statusCode);sock.destroy();});r.on('response',res=>{console.log(path,'->',res.statusCode);res.resume();});r.on('error',e=>console.log(path,'ERR',e.message));r.end();}t('/api/events.mux');setTimeout(()=>t('/api/events.host'),600);"
  ```
  Note: persistence itself is built into dsh — workspaces/sessions live on disk under `~/.dsh\` and survive restarts; the UI only appeared empty because the client never connected.
- **Phone shows a clean UI with no history, but the PC works fine**: dsh is running without its `--trusted-host` list — it started on loopback before Tailscale was ready, and the background retry only brought up the proxy (which forwards tailnet requests that dsh then rejects with `403`). The launcher now detects a running dsh without `--trusted-host` and restarts it with the trusted hosts on its next run. Re-run `start-harness.ps1`, then confirm with `start-harness.ps1 -Verify`; the dsh process command line must contain `--trusted-host <node-name>.<tailnet-name>.ts.net`.
- **Proxy dies with `read ECONNRESET` in `proxy.err.log`**: an unhandled socket error in the WebSocket tunnel (typically a phone dropping the connection mid-stream). `web-proxy.js` now tears down the socket pair instead of crashing; deploy the latest copy and re-run the launcher.

## Change log

- **2026-08-24 — Trusted-host self-heal + proxy crash fix + `-Verify`**: (1) `start-harness.ps1` now restarts dsh with its `--trusted-host` list when it finds dsh running loopback-only (started before Tailscale was ready) — this was the root cause of the phone showing a clean UI with no history while the PC worked. (2) `web-proxy.js` now handles `error`/`close` on both sides of an established WebSocket tunnel, so a phone dropping mid-stream tears down the pair instead of crashing the proxy with an unhandled `ECONNRESET`. (3) Added `start-harness.ps1 -Verify` (via `verify.js`): a one-shot health check asserting ownership, the trusted-host list, and `101` on both WebSocket handshakes with the tailnet `Origin`. A regression test for abrupt-disconnect resilience was added to `test/proxy.test.js`.
- **2026-08-24 — Tailscale startup retry**: `start-harness.ps1` now polls Tailscale for its identity (`DSH_TS_WAIT_SECONDS`, default 60) and, when the tailnet is still connecting at logon, arms a background retry (`DSH_TS_RETRY_SECONDS`, default 600) that starts the proxy automatically once the identity appears — fixing the case where a reboot left the tailnet URL down until a manual re-run. See [Auto-start on boot](#auto-start-on-boot).
- **2026-08-20 — Web file viewer/editor for remote devices**: added `web-files.js` + `web-files-page.html`, served by the proxy at `/__files`. Remote `host.openPath` (loopback-only in dsh, 403s from the phone) is intercepted so file chips open the viewer instead; a floating **Files** button links to it. Browse, view, edit (Save), and download within `DSH_FILES_ROOT` (default `~`), behind the same loopback/trusted-host fence as dsh. See [Web file viewer](#web-file-viewer).
- **2026-08-19 — Startup update checks**: added `check-updates.ps1` (run by `start-harness.ps1` at logon) to compare the installed dsh version against the npm registry and log/notify — or auto-update via `DSH_AUTO_UPDATE=1` with an automatic `~/.dsh` backup. See [Configuration](#configuration).
- **2026-08-19 — WebSocket proxy fix (persistence looked broken on refresh)**: rewrote the `upgrade` handler in `web-proxy.js` to proxy WebSockets with `http.request` instead of a raw `net.connect` tunnel. This preserves `Origin`/`Cookie`/`Sec-WebSocket-*` headers (no more empty optional headers → no more `400 Invalid Sec-WebSocket-Protocol header`), applies the same `Host`→origin normalization as the HTTP path, and relays the upstream `101`/error response faithfully. Without it, the client's `/api/events.mux` and `/api/events.host` WebSockets failed and the UI never loaded workspaces or history. See the troubleshooting entry above.

## Notes

- HTTPS is terminated by Tailscale Serve with a Let's Encrypt certificate (tailnet-only). The earlier plain-HTTP portproxy workaround was replaced by this HTTPS route; the plain-HTTP `:3080` path still works as a fallback.
- `--trusted-host` values keep the browser-trust fence in place so the UI only accepts the tailnet origins listed above. The bare hostnames (no port) are required for the HTTPS origin.
