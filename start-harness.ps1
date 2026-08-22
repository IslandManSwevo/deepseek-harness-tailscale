# DeepSeek Harness launcher
# Starts both pieces of the deployment:
#   1. web-proxy.js  -> tailnet front-end on 0.0.0.0:3080 (Node reverse proxy)
#   2. dsh web UI    -> loopback 127.0.0.1:3081 (dsh refuses to bind beyond
#                       loopback by design; the proxy forwards to it)
# Access on 3080 is restricted to the tailnet by the "DeepSeek Harness
# (Tailscale only)" Windows Firewall rule and the --trusted-host
# browser-trust fence. HTTPS is terminated by Tailscale Serve -> 127.0.0.1:3080.
# The launcher owns the firewall rule: it creates the rule when missing and
# recreates it when the proxy port changes (needs elevation for that step).
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
#   DSH_SKIP_FIREWALL - "1" to skip automatic Windows Firewall rule
#                      management (default: manage the rule when possible)
#   DSH_TS_IPV6       - Tailscale ULA (fd7a::/48) address (default: from
#                      `tailscale status`; used for IPv6 tailnet access)
#
# Switches:
#   -Status   - report proxy/dsh/firewall/serve state and exit
#   -Stop     - stop proxy and dsh (port ownership + PID files) and exit
#   -Restart  - stop, then start both (default behavior when no switch given)
#
# The launcher also writes proxy.pid / dsh.pid for the watchdog and rotates
# the log files (keeps the last 3 x 1 MB) when it starts a component.
param(
    [switch]$Status,
    [switch]$Stop,
    [switch]$Restart
)

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

# --- Port ownership -----------------------------------------------------
# Test-PortOpen only proves *something* listens on a port. These helpers also
# verify the owner is our own process (web-proxy.js / dsh web), so a foreign
# process squatting on 3080/3081 is reported instead of being mistaken for a
# healthy deployment.

function Get-PortOwnerProcess([int] $port) {
    try {
        $conn = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if (-not $conn) { return $null }
        return Get-CimInstance Win32_Process -Filter "ProcessId = $($conn.OwningProcess)" -ErrorAction SilentlyContinue
    } catch {
        return $null
    }
}

function Test-PortIsProxy([int] $port) {
    $p = Get-PortOwnerProcess $port
    return [bool]($p -and $p.Name -eq 'node.exe' -and $p.CommandLine -like '*web-proxy.js*')
}

function Test-PortIsDsh([int] $port) {
    $p = Get-PortOwnerProcess $port
    if (-not $p -or $p.Name -ne 'node.exe') { return $false }
    return [bool]($p.CommandLine -match "\sweb\s" -and $p.CommandLine -match "--port\s+$port(\s|$)")
}

# --- PID files ----------------------------------------------------------
# proxy.pid / dsh.pid let the watchdog and -Stop find our processes even when
# port inspection is unavailable; refreshed on every successful check.
function Get-PidFile([string]$name) {
    $p = Join-Path $dir "$name.pid"
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try {
        $v = (Get-Content -LiteralPath $p -Raw).Trim()
        if ($v -match '^\d+$') { return [int]$v }
    } catch { }
    return $null
}

function Write-PidFile([string]$name, [int]$procId) {
    Set-Content -LiteralPath (Join-Path $dir "$name.pid") -Value "$procId"
}

function Remove-PidFile([string]$name) {
    Remove-Item -LiteralPath (Join-Path $dir "$name.pid") -ErrorAction SilentlyContinue
}

function Component-State([string]$name) {
    $port = if ($name -eq 'proxy') { $proxyPort } else { $webPort }
    if ((Test-PortIsProxy $port) -or (Test-PortIsDsh $port)) { return 'running (ours)' }
    if (Test-PortOpen $port) { return 'OCCUPIED by foreign process' }
    return 'stopped'
}

function Stop-Deployment {
    $stopped = @()
    foreach ($name in @('proxy', 'dsh')) {
        $port = if ($name -eq 'proxy') { $proxyPort } else { $webPort }
        $targets = @()
        $owner = Get-PortOwnerProcess $port
        if ($owner -and $owner.ProcessId) { $targets += [int]$owner.ProcessId }
        $fromFile = Get-PidFile $name
        if ($fromFile) { $targets += $fromFile }
        foreach ($procId in ($targets | Select-Object -Unique)) {
            try {
                Stop-Process -Id $procId -Force -ErrorAction Stop
                $stopped += "$name (pid $procId)"
            } catch {
                Write-Warning "could not stop $name pid ${procId}: $($_.Exception.Message)"
            }
        }
        Remove-PidFile $name
    }
    if ($stopped.Count -eq 0) { Write-Output 'nothing to stop' } else { Write-Output ('stopped: ' + ($stopped -join ', ')) }
}

function Show-Status {
    Write-Output "proxy ($proxyPort)   : $(Component-State proxy)"
    Write-Output "dsh web ($webPort)   : $(Component-State dsh)"
    try {
        $rule = Get-NetFirewallRule -DisplayName $fwRuleName -ErrorAction SilentlyContinue
        if ($rule) {
            $pf = $rule | Get-NetFirewallPortFilter
            Write-Output "firewall            : present (port $($pf.LocalPort), Tailscale CGNAT only)"
        } else {
            Write-Output 'firewall            : MISSING (tailnet access will not work)'
        }
    } catch {
        Write-Output 'firewall            : unknown (cannot query)'
    }
    $serve = ''
    if (Get-Command tailscale -ErrorAction SilentlyContinue) {
        $serve = tailscale serve status 2>$null | Out-String
    }
    if ($serve -match "127\.0\.0\.1:$proxyPort") {
        Write-Output 'tailscale serve     : active (HTTPS frontend configured)'
    } else {
        Write-Output 'tailscale serve     : not configured (optional; see watchdog DSH_TAILSCALE_SERVE)'
    }
    $ulog = Join-Path $dir 'update-check.log'
    if (Test-Path -LiteralPath $ulog) {
        Write-Output ("last update check   : " + (Get-Content -LiteralPath $ulog -Tail 1))
    }
}

function Rotate-Log([string]$path) {
    # Keep the last 3 rotated copies of a log that exceeds 1 MB.
    try {
        if (-not (Test-Path -LiteralPath $path)) { return }
        if ((Get-Item -LiteralPath $path).Length -lt 1MB) { return }
        Remove-Item -LiteralPath "$path.3" -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath "$path.2") { Rename-Item -LiteralPath "$path.2" -NewName "$([IO.Path]::GetFileName($path)).3" -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath "$path.1") { Rename-Item -LiteralPath "$path.1" -NewName "$([IO.Path]::GetFileName($path)).2" -ErrorAction SilentlyContinue }
        Rename-Item -LiteralPath $path -NewName "$([IO.Path]::GetFileName($path)).1" -ErrorAction SilentlyContinue
    } catch { }
}

# --- Windows Firewall ---------------------------------------------------
# The tailnet-facing proxy port must only be reachable from Tailscale CGNAT
# ranges. This used to be a manual step in the README; the launcher now owns
# it: create the rule when missing, recreate it when the proxy port changed.
# Requires elevation - when not elevated we warn and print the exact command
# so the operator can add it once.
$fwRuleName      = 'DeepSeek Harness (Tailscale only)'
$fwRemoteAddress = @('100.64.0.0/10', 'fd7a:115c:a1e0::/48')

function Ensure-FirewallRule([int] $port, [string] $name) {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]$identity
    $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Warning "not elevated - cannot ensure firewall rule '$name'. Run once as admin:`n  New-NetFirewallRule -DisplayName '$name' -Direction Inbound -Action Allow -Protocol TCP -LocalPort $port -RemoteAddress $($fwRemoteAddress -join ', ')"
        return $false
    }
    try {
        $rule = Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue
        if ($rule) {
            $portFilter = $rule | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue
            $ports = @($portFilter.LocalPort | ForEach-Object { "$_" })
            if ($ports -notcontains "$port") {
                Write-Output "firewall rule '$name' targets port $($ports -join ',') - recreating for port $port"
                Remove-NetFirewallRule -DisplayName $name -ErrorAction Stop
                $rule = $null
            }
        }
        if (-not $rule) {
            New-NetFirewallRule -DisplayName $name -Direction Inbound -Action Allow `
                -Protocol TCP -LocalPort $port -RemoteAddress $fwRemoteAddress -ErrorAction Stop | Out-Null
            Write-Output "firewall rule '$name' ensured (port $port, Tailscale CGNAT only)"
        }
        return $true
    } catch {
        Write-Warning "could not ensure firewall rule '$name': $($_.Exception.Message)"
        return $false
    }
}

# Locate a Node.js >= 24 runtime. dsh rc.8 reaches into Node's internal ESM
# loader and needs the Node 24 API, but PATH often resolves `node` to an older
# system Node (e.g. C:\Program Files\nodejs, v22) ahead of scoop's Node 24.
# Priority: DSH_NODE override, scoop's nodejs-lts "current", then PATH node -
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
# status` until the node reports its MagicDNS name and 100.x / fd7a::/48
# addresses. At logon the Tailscale service is often still starting, so retry
# instead of failing immediately. Configurable via DSH_TS_WAIT_SECONDS (default 60).
# A missing identity is NOT fatal: dsh still starts on loopback, and the
# watchdog (or a later run) starts the proxy once the tailnet is reachable.
$tsHost = $env:DSH_TS_HOST
$tsIp   = $env:DSH_TS_IP
$tsIpV6 = $env:DSH_TS_IPV6
if (-not $tsHost -or -not $tsIp) {
    $waitSeconds = 60
    if ($env:DSH_TS_WAIT_SECONDS -match '^\d+$') { $waitSeconds = [int]$env:DSH_TS_WAIT_SECONDS }
    $deadline = (Get-Date).AddSeconds($waitSeconds)
    do {
        try {
            $ts = tailscale status --json 2>$null | ConvertFrom-Json
            if (-not $tsHost -and $ts.Self.DNSName) { $tsHost = ([string]$ts.Self.DNSName).TrimEnd('.') }
            if (-not $tsIp -and $ts.Self.TailscaleIPs) { $tsIp = @($ts.Self.TailscaleIPs | Where-Object { $_ -like '100.*' })[0] }
            if (-not $tsIpV6 -and $ts.Self.TailscaleIPs) { $tsIpV6 = @($ts.Self.TailscaleIPs | Where-Object { $_ -like 'fd7a:*' })[0] }
        } catch { }
        if ($tsHost -and $tsIp) { break }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)
}
$tsReady = [bool]($tsHost -and $tsIp)
if (-not $tsReady) {
    Write-Warning 'Tailscale identity not resolved after waiting - starting dsh loopback only (no tailnet proxy). Set DSH_TS_HOST/DSH_TS_IP or retry later.'
}

# Command-mode switches: status/stop/restart. Stop uses port ownership and PID
# files; restart falls through to the normal start flow below.
if ($Status)  { Show-Status; exit 0 }
if ($Stop)    { Stop-Deployment; exit 0 }
if ($Restart) { Stop-Deployment }

# Ensure the tailnet firewall rule exists (idempotent). Requires elevation;
# when not elevated we warn and continue - loopback still works, tailnet does
# not until the rule is added.
if ($env:DSH_SKIP_FIREWALL -ne '1') {
    Ensure-FirewallRule -Port $proxyPort -Name $fwRuleName | Out-Null
}

# Start the proxy only if the proxy port is free. If the port is occupied,
# require that the owner is *our* proxy (web-proxy.js) - a foreign process
# squatting on the port would otherwise be mistaken for a running deployment.
# web-proxy.js reads PROXY_PORT/UPSTREAM_PORT (with DSH_PROXY_PORT/DSH_WEB_PORT
# fallbacks) from the environment; the /__files viewer reads DSH_TS_HOST,
# DSH_TS_IP, DSH_TS_IPV6 to build its trusted-authority list and DSH_FILES_ROOT
# for its allowed roots.
if ($tsReady) {
    if (Test-PortIsProxy $proxyPort) {
        Write-Output "web proxy already running on port $proxyPort (owned by this deployment)"
        $owner = Get-PortOwnerProcess $proxyPort
        if ($owner -and $owner.ProcessId) { Write-PidFile 'proxy' ([int]$owner.ProcessId) }
    } elseif (Test-PortOpen $proxyPort) {
        Write-Warning "port $proxyPort is occupied by another process - the web proxy was NOT started; the tailnet UI will be unreachable."
    } else {
        Rotate-Log $plog
        Rotate-Log $perr
        $env:PROXY_PORT     = "$proxyPort"
        $env:UPSTREAM_PORT  = "$webPort"
        $env:DSH_PROXY_PORT = "$proxyPort"
        $env:DSH_WEB_PORT   = "$webPort"
        if ($tsHost) { $env:DSH_TS_HOST = $tsHost }
        if ($tsIp)   { $env:DSH_TS_IP   = $tsIp }
        if ($tsIpV6) { $env:DSH_TS_IPV6 = $tsIpV6 }
        $proc = Start-Process -FilePath $node -ArgumentList (Join-Path $dir 'web-proxy.js') `
            -WindowStyle Hidden -WorkingDirectory $dir `
            -RedirectStandardOutput $plog -RedirectStandardError $perr -PassThru
        if ($proc) { Write-PidFile 'proxy' $proc.Id }
        Write-Output "web proxy started on port $proxyPort -> 127.0.0.1:$webPort"
    }
} else {
    Write-Warning 'skipping web proxy (Tailscale identity unavailable)'
}

# Skip the dsh start if dsh is already up on the web port - but only when
# the port is owned by dsh; a foreign listener means the harness is NOT running.
if (Test-PortIsDsh $webPort) {
    Write-Output "dsh web already running on port $webPort (owned by this deployment)"
    $owner = Get-PortOwnerProcess $webPort
    if ($owner -and $owner.ProcessId) { Write-PidFile 'dsh' ([int]$owner.ProcessId) }
    exit 0
}
if (Test-PortOpen $webPort) {
    Write-Warning "port $webPort is occupied by another process - dsh was NOT started."
    exit 0
}

# Check for a newer dsh release (logs; optionally toasts or auto-updates).
# Fired asynchronously so a slow npm registry never delays dsh startup.
Start-Process powershell -NoProfile -ExecutionPolicy Bypass `
    -ArgumentList '-File', (Join-Path $dir 'check-updates.ps1') `
    -WindowStyle Hidden | Out-Null

# Signal a remote operator so dsh mounts the web-safe 'browse' directory
# picker (host.listDirectory / host.createDirectory) instead of the native OS
# dialog (host.pickDirectory), which is loopback-only and would 403 from the
# phone. SSH_CONNECTION is the documented signal the picker resolver checks.
$env:SSH_CONNECTION = 'remote'

# Build the trusted-host list from the Tailscale identity when available
# (loopback-only fallback when it is not). IPv6 entries are bracketed.
$trustedHosts = @()
if ($tsReady) {
    foreach ($h in @("${tsIp}:${proxyPort}", $tsIp, "${tsHost}:${proxyPort}", $tsHost)) {
        $trustedHosts += '--trusted-host'
        $trustedHosts += $h
    }
    if ($tsIpV6) {
        $trustedHosts += '--trusted-host'
        $trustedHosts += "[${tsIpV6}]:${proxyPort}"
        $trustedHosts += '--trusted-host'
        $trustedHosts += "[${tsIpV6}]"
    }
}

Rotate-Log $dlog
Rotate-Log $derr
$proc = Start-Process -FilePath $node -ArgumentList (@($bin, 'web', '--host', '127.0.0.1', '--port', "$webPort") + $trustedHosts) `
    -WindowStyle Hidden -RedirectStandardOutput $dlog -RedirectStandardError $derr -PassThru
if ($proc) { Write-PidFile 'dsh' $proc.Id }
