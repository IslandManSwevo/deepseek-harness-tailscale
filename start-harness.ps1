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
#   DSH_NODE       - Node.js >= 24 executable path (default: scoop nodejs-lts,
#                    then node on PATH; older nodes are rejected)
#   DSH_DSH_BIN    - dsh CLI entry, e.g. .../@deepseek-ai/dsh/lib/bin.js
#                    (default: <npm global root>/@deepseek-ai/dsh/lib/bin.js)
#   DSH_TS_HOST    - Tailscale MagicDNS name, e.g. myhost.tailXXXX.ts.net
#                    (default: this node's name from `tailscale status`)
#   DSH_TS_IP      - Tailscale 100.x IP (default: from `tailscale status`)
#   DSH_TS_WAIT_SECONDS - seconds to poll Tailscale for its identity at startup
#                    (default: 60; accounts for Tailscale still starting at logon)
#   DSH_PROXY_PORT - tailnet-facing proxy port (default 3080)
#   DSH_WEB_PORT   - loopback dsh web port (default 3081)
#   DSH_UPDATE_TRACK - npm dist-tag for update checks: "next" (default) or
#                      "latest" (see check-updates.ps1)
#   DSH_AUTO_UPDATE  - "1" to auto-install newer dsh versions on startup
#                      (default: check-and-notify only)
#   DSH_FILES_ROOT   - semicolon-separated roots the /__files web viewer may
#                      read/write (default: the host account home directory)
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

# Locate a Node.js >= 24 runtime. dsh rc.8 reaches into Node's internal ESM
# loader and needs the Node 24 API, but PATH often resolves `node` to an older
# system Node (e.g. C:\Program Files\nodejs, v22) ahead of scoop's Node 24.
# Priority: DSH_NODE override, scoop's nodejs-lts "current", then PATH node —
# but any candidate must report a major version >= 24.
function Get-NodeMajor([string]$nodePath) {
    try {
        $v = & $nodePath --version 2>$null
        if ($v -match '^v(\d+)') { return [int]$Matches[1] }
    } catch { }
    return 0
}

function Resolve-Node {
    if ($env:DSH_NODE) {
        if (-not (Test-Path -LiteralPath $env:DSH_NODE)) { throw "DSH_NODE points to a missing file: $($env:DSH_NODE)" }
        return $env:DSH_NODE
    }

    $candidates = @()
    if ($env:SCOOP)       { $candidates += (Join-Path $env:SCOOP 'apps\nodejs-lts\current\node.exe') }
    if ($env:USERPROFILE) { $candidates += (Join-Path $env:USERPROFILE 'scoop\apps\nodejs-lts\current\node.exe') }
    if ($env:SCOOP)       { $candidates += (Join-Path $env:SCOOP 'shims\node.exe') }
    if ($env:USERPROFILE) { $candidates += (Join-Path $env:USERPROFILE 'scoop\shims\node.exe') }

    $cmd = Get-Command node -ErrorAction SilentlyContinue
    if ($cmd) { $candidates += $cmd.Source }

    $seen = @{}
    foreach ($candidate in $candidates) {
        if (-not $candidate -or -not (Test-Path -LiteralPath $candidate)) { continue }
        if ($seen[$candidate]) { continue }
        $seen[$candidate] = $true
        if ((Get-NodeMajor $candidate) -ge 24) { return $candidate }
    }

    $foundLines = @()
    foreach ($candidate in $candidates) {
        if (-not $candidate -or -not (Test-Path -LiteralPath $candidate)) { continue }
        $foundLines += "$candidate ($(& $candidate --version 2>$null))"
    }
    $foundLines = @($foundLines | Select-Object -Unique)
    if ($foundLines.Count -gt 0) {
        throw "dsh requires Node.js >= 24. Found only:`n    " + ($foundLines -join "`n    ") + "`nInstall Node 24 (e.g. `"scoop install nodejs-lts`") or set DSH_NODE to a Node 24+ executable."
    }
    throw 'node not found; install Node.js >= 24 or set DSH_NODE'
}

$node = Resolve-Node

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

# Discover the Tailscale identity: env vars win, otherwise poll `tailscale
# status` until the node reports its MagicDNS name and 100.x IP. At logon the
# Tailscale service is often still starting, so retry instead of failing
# immediately. Configurable via DSH_TS_WAIT_SECONDS (default 60).
$tsHost = $env:DSH_TS_HOST
$tsIp   = $env:DSH_TS_IP
if (-not $tsHost -or -not $tsIp) {
    $waitSeconds = 60
    if ($env:DSH_TS_WAIT_SECONDS -match '^\d+$') { $waitSeconds = [int]$env:DSH_TS_WAIT_SECONDS }
    $deadline = (Get-Date).AddSeconds($waitSeconds)
    do {
        try {
            $ts = tailscale status --json 2>$null | ConvertFrom-Json
            if (-not $tsHost -and $ts.Self.DNSName) { $tsHost = ([string]$ts.Self.DNSName).TrimEnd('.') }
            if (-not $tsIp -and $ts.Self.TailscaleIPs) { $tsIp = @($ts.Self.TailscaleIPs | Where-Object { $_ -like '100.*' })[0] }
        } catch { }
        if ($tsHost -and $tsIp) { break }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)
}
if (-not $tsHost) { throw 'Tailscale hostname unknown after waiting; set DSH_TS_HOST' }
if (-not $tsIp)   { throw 'Tailscale IP unknown after waiting; set DSH_TS_IP' }

# Start the proxy only if nothing is listening on the proxy port (idempotent).
# web-proxy.js reads PROXY_PORT/UPSTREAM_PORT from the environment; the
# /__files viewer reads DSH_TS_HOST/DSH_TS_IP to build its trusted-authority
# list and DSH_FILES_ROOT for its allowed roots.
if (-not (Test-PortOpen $proxyPort)) {
    $env:PROXY_PORT    = "$proxyPort"
    $env:UPSTREAM_PORT = "$webPort"
    if ($tsHost) { $env:DSH_TS_HOST = $tsHost }
    if ($tsIp)   { $env:DSH_TS_IP   = $tsIp }
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
