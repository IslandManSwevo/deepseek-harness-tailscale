# DeepSeek Harness launcher
# Starts both pieces of the deployment:
#   1. web-proxy.js  -> tailnet front-end on 0.0.0.0:3080 (Node reverse proxy)
#   2. dsh web UI    -> loopback 127.0.0.1:3081 (dsh refuses to bind beyond
#                       loopback by design; the proxy forwards to it)
# Access on 3080 is restricted to the tailnet by the "DeepSeek Harness
# (Tailscale only)" Windows Firewall rule and the --trusted-host
# browser-trust fence. HTTPS is terminated by Tailscale Serve -> 127.0.0.1:3080.
#
# Configuration (all optional; values are auto-detected when unset):
#   DSH_NODE       - Node.js executable path (default: node on PATH)
#   DSH_DSH_BIN    - dsh CLI entry, e.g. .../@deepseek-ai/dsh/lib/bin.js
#                    (default: <npm global root>/@deepseek-ai/dsh/lib/bin.js)
#   DSH_TS_HOST    - Tailscale MagicDNS name, e.g. myhost.tailXXXX.ts.net
#                    (default: this node's name from `tailscale status`)
#   DSH_TS_IP      - Tailscale 100.x IP (default: from `tailscale status`)
#   DSH_PROXY_PORT - tailnet-facing proxy port (default 3080)
#   DSH_WEB_PORT   - loopback dsh web port (default 3081)
#   DSH_UPDATE_TRACK - npm dist-tag for update checks: "next" (default) or
#                      "latest" (see check-updates.ps1)
#   DSH_AUTO_UPDATE  - "1" to auto-install newer dsh versions on startup
#                      (default: check-and-notify only)
$ErrorActionPreference = 'Stop'

$dir       = $PSScriptRoot
$proxyPort = if ($env:DSH_PROXY_PORT) { [int]$env:DSH_PROXY_PORT } else { 3080 }
$webPort   = if ($env:DSH_WEB_PORT)   { [int]$env:DSH_WEB_PORT }   else { 3081 }
$dlog      = Join-Path $dir 'dsh-web.log'
$derr      = Join-Path $dir 'dsh-web.err.log'
$plog      = Join-Path $dir 'proxy.log'
$perr      = Join-Path $dir 'proxy.err.log'

function Test-PortOpen([int] $port) {
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $c.Connect('127.0.0.1', $port)
        $c.Close()
        return $true
    } catch {
        return $false
    }
}

# Locate Node.js: DSH_NODE wins, otherwise the node on PATH.
$node = $env:DSH_NODE
if (-not $node) {
    $cmd = Get-Command node -ErrorAction SilentlyContinue
    if (-not $cmd) { throw 'node not found on PATH; install Node.js >= 24 or set DSH_NODE' }
    $node = $cmd.Source
}

# Locate the dsh CLI entry: DSH_DSH_BIN wins, otherwise resolve the dsh shim or
# a known npm global root (scoop's root and the per-user default prefix differ).
$bin = $env:DSH_DSH_BIN
if (-not $bin) {
    $relPkg    = '@deepseek-ai\dsh\lib\bin.js'
    $relPrefix = Join-Path 'node_modules' $relPkg

    $candidates = @()

    # 1. The dsh command shim (npm places bin shims next to node_modules).
    $dshCmd = Get-Command dsh -ErrorAction SilentlyContinue
    if ($dshCmd) { $candidates += Join-Path (Split-Path $dshCmd.Source) $relPrefix }

    # 2. npm's reported global node_modules root.
    $npmRoot = & npm root -g 2>$null | Select-Object -First 1
    if ($npmRoot) { $candidates += Join-Path $npmRoot $relPkg }

    # 3. npm's reported global prefix.
    $npmPrefix = & npm prefix -g 2>$null | Select-Object -First 1
    if ($npmPrefix) { $candidates += Join-Path $npmPrefix $relPrefix }

    # 4. Default per-user npm global prefix.
    if ($env:APPDATA) { $candidates += Join-Path (Join-Path $env:APPDATA 'npm') $relPrefix }

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { $bin = $candidate; break }
    }
    if (-not $bin) { throw 'dsh not found; install with "npm install -g @deepseek-ai/dsh" or set DSH_DSH_BIN' }
}

# Discover the Tailscale identity: env vars win, otherwise `tailscale status`.
$tsHost = $env:DSH_TS_HOST
$tsIp   = $env:DSH_TS_IP
if (-not $tsHost -or -not $tsIp) {
    try {
        $ts = tailscale status --json 2>$null | ConvertFrom-Json
        if (-not $tsHost -and $ts.Self.DNSName) { $tsHost = ([string]$ts.Self.DNSName).TrimEnd('.') }
        if (-not $tsIp -and $ts.Self.TailscaleIPs) { $tsIp = @($ts.Self.TailscaleIPs | Where-Object { $_ -like '100.*' })[0] }
    } catch { }
}
if (-not $tsHost) { throw 'Tailscale hostname unknown; set DSH_TS_HOST' }
if (-not $tsIp)   { throw 'Tailscale IP unknown; set DSH_TS_IP' }

# Start the proxy only if nothing is listening on the proxy port (idempotent).
# web-proxy.js reads PROXY_PORT/UPSTREAM_PORT from the environment.
if (-not (Test-PortOpen $proxyPort)) {
    $env:PROXY_PORT    = "$proxyPort"
    $env:UPSTREAM_PORT = "$webPort"
    Start-Process -FilePath $node -ArgumentList (Join-Path $dir 'web-proxy.js') `
        -WindowStyle Hidden -WorkingDirectory $dir `
        -RedirectStandardOutput $plog -RedirectStandardError $perr
}

# Skip the dsh start if something is already listening on the web port.
if (Test-PortOpen $webPort) { exit 0 }

# Check for a newer dsh release (logs; optionally toasts or auto-updates).
# Placed here so it runs once per logon and never when dsh is already up.
& (Join-Path $dir 'check-updates.ps1')

# Signal a remote operator so dsh mounts the web-safe 'browse' directory
# picker (host.listDirectory / host.createDirectory) instead of the native OS
# dialog (host.pickDirectory), which is loopback-only and would 403 from the
# phone. SSH_CONNECTION is the documented signal the picker resolver checks.
$env:SSH_CONNECTION = 'remote'

Start-Process -FilePath $node -ArgumentList @(
    $bin, 'web',
    '--host', '127.0.0.1',
    '--port', "$webPort",
    '--trusted-host', "${tsIp}:${proxyPort}",
    '--trusted-host', $tsIp,
    '--trusted-host', "${tsHost}:${proxyPort}",
    '--trusted-host', $tsHost
) -WindowStyle Hidden -RedirectStandardOutput $dlog -RedirectStandardError $derr
