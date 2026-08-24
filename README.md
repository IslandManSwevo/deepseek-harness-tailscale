# DeepSeek Harness · Anywhere, over Tailscale

**Run the [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (`dsh`) on one machine — drive it securely from your phone, tablet, and laptop over a private [Tailscale](https://tailscale.com) network.**

*Zero-config launcher · WebSocket-safe reverse proxy · built-in file viewer · automatic updates · optional HTTPS*

**Requires:** Windows (PowerShell + Windows Firewall) · Node.js ≥ 24 · Tailscale on the host and on every connecting device.

---

## Why this exists

`dsh` has a genuinely great web UI — but it **refuses to bind beyond `127.0.0.1`**, on purpose, because it can execute code on your machine. Out of the box, you can only use it in a browser on the same computer.

The naive fix — put a reverse proxy in front of it — fails in ways that look catastrophic:

- **You refresh and your workspaces & history are "gone."** The client only loads them after two WebSocket connections open. A broken proxy silently kills those, and the UI sits on *"Add workspace / Choose workspace"* while you panic.
- **Creating a workspace from your phone** → `HTTP 403` (the native folder picker is loopback-only).
- **Opening a produced file from your phone** → `HTTP 403` (`host.openPath` is loopback-only).

This project fixes all three, for real.

## What it is

| Component | What it does |
|---|---|
| **`start-harness.ps1`** | One command. Auto-detects Node.js, your `dsh` install, and your Tailscale identity, then starts the proxy (if the port is free) and dsh (if the port is free). Idempotent — no config files to edit. If the tailnet is still connecting at logon it keeps polling in the background and starts the proxy automatically once Tailscale is ready. |
| **`web-proxy.js`** | Hardened Node reverse proxy: relays **WebSocket** upgrades (`/api/events.mux`, `/api/events.host`) faithfully so a refresh restores your history; normalizes `Host`/`Origin` so dsh's browser-trust fence passes; injects the `crypto.randomUUID` polyfill needed over plain HTTP. |
| **`web-files.js` + `web-files-page.html`** | Built-in file browser/viewer/editor at `/__files` — click a produced file from your phone and it opens instead of 403-ing. |
| **`check-updates.ps1`** | Notifies (or auto-updates, with a `~/.dsh` backup) when a newer `dsh` is available. |
| **Optional HTTPS** | Via `tailscale serve` + a free Let's Encrypt cert. Tailscale-native — nothing exposed to the public internet. |

## Quick start

1. Install Tailscale on the host machine and sign in. Enable **HTTPS certificates** in the Tailscale admin console (DNS → HTTPS Certificates).
2. Install the harness: `npm install -g @deepseek-ai/dsh` (Node.js ≥ 24).
3. Copy this repo's files into a folder, e.g. `%USERPROFILE%\dsh\`.
4. Restrict the proxy port to the tailnet (adjust `-LocalPort` if you change `DSH_PROXY_PORT`):
   ```powershell
   New-NetFirewallRule -DisplayName 'DeepSeek Harness (Tailscale only)' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 3080 -RemoteAddress 100.64.0.0/10, fd7a:115c:a1e0::/48
   ```
5. Start it (idempotent — safe to run again):
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\dsh\start-harness.ps1"
   ```
6. Optional HTTPS: `tailscale serve --bg http://127.0.0.1:3080`
7. From any Tailscale device: `https://<node-name>.<tailnet-name>.ts.net`

**That's it.** The launcher derives the trusted-host list from your Tailscale identity automatically. For scheduled start-on-logon, stopping, every configuration option, and deep troubleshooting, see the **[full deployment guide](docs/DEPLOY.md)**.

## The part nobody else gets right

Refresh → history-lost is **not a data problem — your data was never lost** (workspaces and sessions live in `~/.dsh`). It's a WebSocket problem: dsh only pulls its workspace/session baseline after `/api/events.mux` and `/api/events.host` connect. Most proxies forward HTTP fine but break the `101` upgrade handshake, so the UI *looks* wiped. This proxy was built to get both handshakes right — and the [deployment guide](docs/DEPLOY.md#troubleshooting) includes the raw-handshake test that proves it.

## Security model

- dsh stays **loopback-only**; the proxy owns the tailnet-facing port and is the only way in.
- The Windows Firewall rule admits the proxy port **only from Tailscale CGNAT ranges** (`100.64.0.0/10`, `fd7a:115c:a1e0::/48`) — nothing is exposed to the public internet.
- Every request passes a **browser-trust fence**: loopback or trusted Tailscale authorities only; cross-site and Origin/Host-mismatched requests are rejected.
- The `/__files` viewer is **read/write only** (no code execution), path-contained to `DSH_FILES_ROOT`, with `..`, symlink-escape, and null-byte traversal rejected.

> **Heads-up:** anything on your tailnet can reach the harness through the proxy. That's the point — but keep your tailnet to people you trust. dsh has no login; on a shared tailnet, restrict who can reach this node's `:3080`/`:443` with **Tailscale ACLs** rather than relying on tailnet membership alone.

## Configuration

Every setting is optional and auto-detected; override with environment variables (`DSH_NODE`, `DSH_DSH_BIN`, `DSH_TS_HOST`, `DSH_TS_IP`, `DSH_TS_WAIT_SECONDS`, `DSH_TS_RETRY_SECONDS`, `DSH_PROXY_PORT`, `DSH_WEB_PORT`, `DSH_UPDATE_TRACK`, `DSH_AUTO_UPDATE`, `DSH_FILES_ROOT`). If Tailscale is still connecting at logon, the launcher polls for it (`DSH_TS_WAIT_SECONDS`, default 60) and then arms a background retry (`DSH_TS_RETRY_SECONDS`, default 600) so the proxy starts automatically once the tailnet appears. Details in the [deployment guide](docs/DEPLOY.md#configuration).

## Troubleshooting at a glance

- **History "missing" after a refresh** → WebSocket proxying; run the raw-handshake test from the [guide](docs/DEPLOY.md#troubleshooting).
- **`HTTP 403` creating a workspace from your phone** → the launcher sets `SSH_CONNECTION=remote` to enable the in-browser directory picker.
- **`HTTP 403` opening a produced file from your phone** → use the built-in `/__files` viewer.

## Testing

`node --test` runs the proxy and file-viewer suites against an in-process fake upstream — no dsh or Tailscale needed:

- WebSocket `101` relay and upstream-rejection passthrough
- `Host` → `Origin` normalization
- polyfill + integration-script injection (including when the document already references `crypto.randomUUID`)
- `/__files` path containment, trust fence, and CRLF-preserving writes

## FAQ

- **Is this a public internet service?** No — tailnet-only by design (firewall + HTTPS via Tailscale).
- **Does it replace `dsh`?** No — it deploys and safely exposes the real `@deepseek-ai/dsh` web UI.
- **Why a proxy at all?** Because `dsh web` deliberately refuses to bind beyond loopback.
- **Does it work on macOS/Linux?** The scripts target Windows (PowerShell, Windows Firewall, scheduled tasks). The proxy itself is plain Node and could be adapted.

## License

MIT. Issues and PRs welcome.
