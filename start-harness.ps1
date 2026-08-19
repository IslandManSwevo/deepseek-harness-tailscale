# DeepSeek Harness launcher
# Starts both pieces of the deployment:
#   1. web-proxy.js  -> tailnet front-end on 0.0.0.0:3080 (Node reverse proxy)
#   2. dsh web UI    -> loopback 127.0.0.1:3081 (dsh refuses to bind beyond
#                       loopback by design; the proxy forwards to it)
# Access on 3080 is restricted to the tailnet by the "DeepSeek Harness
# (Tailscale only)" Windows Firewall rule and the --trusted-host
# browser-trust fence. HTTPS is terminated by Tailscale Serve -> 127.0.0.1:3080.
$ErrorActionPreference = 'Stop'

$dir   = 'C:\Users\green\dsh'
$node  = 'C:\Users\green\scoop\apps\nodejs-lts\24.19.0\node.exe'
$bin   = 'C:\Users\green\AppData\Roaming\npm\node_modules\@deepseek-ai\dsh\lib\bin.js'
$dlog  = Join-Path $dir 'dsh-web.log'
$derr  = Join-Path $dir 'dsh-web.err.log'
$plog  = Join-Path $dir 'proxy.log'
$perr  = Join-Path $dir 'proxy.err.log'

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

# Start the proxy only if nothing is listening on 3080 (idempotent).
if (-not (Test-PortOpen 3080)) {
    Start-Process -FilePath $node -ArgumentList (Join-Path $dir 'web-proxy.js') `
        -WindowStyle Hidden -WorkingDirectory $dir `
        -RedirectStandardOutput $plog -RedirectStandardError $perr
}

# Skip the dsh start if something is already listening on 3081.
if (Test-PortOpen 3081) { exit 0 }

# Signal a remote operator so dsh mounts the web-safe 'browse' directory
# picker (host.listDirectory / host.createDirectory) instead of the native OS
# dialog (host.pickDirectory), which is loopback-only and would 403 from the
# phone. SSH_CONNECTION is the documented signal the picker resolver checks.
$env:SSH_CONNECTION = 'remote'

Start-Process -FilePath $node -ArgumentList @(
    $bin, 'web',
    '--host', '127.0.0.1',
    '--port', '3081',
    '--trusted-host', '100.85.211.6:3080',
    '--trusted-host', '100.85.211.6',
    '--trusted-host', 'shervin-pc.tail41da1a.ts.net:3080',
    '--trusted-host', 'shervin-pc.tail41da1a.ts.net'
) -WindowStyle Hidden -RedirectStandardOutput $dlog -RedirectStandardError $derr
