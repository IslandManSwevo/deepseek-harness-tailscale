# DeepSeek Harness watchdog
# Self-healing supervisor for the dsh deployment. Every cycle it re-runs
# start-harness.ps1 (idempotent and ownership-aware), so a crashed proxy or
# dsh process is restarted automatically. When DSH_TAILSCALE_SERVE=1 it also
# re-asserts the optional `tailscale serve` HTTPS frontend.
#
# Modes:
#   -Once      - run a single check cycle and exit (also used for testing)
#   -Install   - register a logon scheduled task that runs the watchdog
#   -Uninstall - remove that scheduled task
#
# Configuration (env vars):
#   DSH_WATCH_INTERVAL   - seconds between cycles (default 120)
#   DSH_TAILSCALE_SERVE  - "1" to manage `tailscale serve` HTTPS (default: no)
#   DSH_PROXY_PORT       - must match the launcher's proxy port (default 3080)
#
# All output is appended to watchdog.log (stdout + stderr).
param(
    [switch]$Once,
    [switch]$Install,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'

$dir        = $PSScriptRoot
$launcher   = Join-Path $dir 'start-harness.ps1'
$logFile    = Join-Path $dir 'watchdog.log'
$taskName   = 'DeepSeek Harness Watchdog'
$proxyPort  = if ($env:DSH_PROXY_PORT) { [int]$env:DSH_PROXY_PORT } else { 3080 }

function Write-WatchdogLog([string]$message) {
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $message
    Add-Content -LiteralPath $logFile -Value $line
}

function Ensure-Serve {
    # Re-assert `tailscale serve` when it should exist but does not. Requires
    # HTTPS certificates enabled in the Tailscale admin console; fails soft.
    if (Get-Command tailscale -ErrorAction SilentlyContinue) {
        try {
            $status = tailscale serve status 2>$null | Out-String
            if ($status -match "127\.0\.0\.1:$proxyPort") {
                Write-WatchdogLog "tailscale serve: already configured for port $proxyPort"
            } else {
                tailscale serve --bg "http://127.0.0.1:$proxyPort" 2>&1 | Out-Null
                Write-WatchdogLog "tailscale serve: (re)configured http://127.0.0.1:$proxyPort"
            }
        } catch {
            Write-WatchdogLog "tailscale serve: failed: $($_.Exception.Message)"
        }
    } else {
        Write-WatchdogLog 'tailscale serve: skipped (tailscale not found)'
    }
}

function Invoke-Cycle {
    if (-not (Test-Path -LiteralPath $launcher)) {
        throw "launcher not found: $launcher"
    }
    & $launcher *>> $logFile
    if ($LASTEXITCODE -ne 0) {
        Write-WatchdogLog "launcher exited with code $LASTEXITCODE"
    }
    if ($env:DSH_TAILSCALE_SERVE -eq '1') {
        Ensure-Serve
    }
}

if ($Install) {
    $taskTr = "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$(Join-Path $dir 'watchdog.ps1')`""
    schtasks /Create /TN $taskName /TR $taskTr /SC ONLOGON /F | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Output "scheduled task '$taskName' installed (runs at logon)."
        Write-Output "to also start it now:  schtasks /Run /TN `"$taskName`""
    } else {
        Write-Output "could not install scheduled task (schtasks exit $LASTEXITCODE). Run as admin:"
        Write-Output "  $taskTr"
    }
    exit 0
}

if ($Uninstall) {
    schtasks /Delete /TN $taskName /F | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Output "scheduled task '$taskName' removed."
    } else {
        Write-Output "could not remove scheduled task (schtasks exit $LASTEXITCODE)."
    }
    exit 0
}

$interval = if ($env:DSH_WATCH_INTERVAL -match '^\d+$') { [int]$env:DSH_WATCH_INTERVAL } else { 120 }

Write-WatchdogLog "watchdog started (interval=${interval}s, serve=$(if ($env:DSH_TAILSCALE_SERVE -eq '1') { 'on' } else { 'off' }))"
do {
    try {
        Invoke-Cycle
    } catch {
        Write-WatchdogLog "cycle failed: $($_.Exception.Message)"
    }
    if ($Once) { break }
    Start-Sleep -Seconds $interval
} while ($true)

if ($Once) { Write-WatchdogLog 'watchdog -Once cycle complete' }
