# DeepSeek Harness update check
# Compares the installed dsh version against a configured npm dist-tag and,
# when a newer version exists, logs it and (optionally) notifies via toast and
# (optionally) auto-updates. Invoked automatically by start-harness.ps1 at
# logon, or manually:
#   powershell -NoProfile -ExecutionPolicy Bypass -File check-updates.ps1
#
# Configuration (env vars):
#   DSH_UPDATE_TRACK - npm dist-tag to track: "next" (default, newest) or
#                      "latest" (stable). dsh currently ships only pre-releases.
#   DSH_AUTO_UPDATE  - "1" to auto-install the newer version (backs up ~/.dsh
#                      first); unset/"0" (default) to check-and-notify only.

$ErrorActionPreference = 'Stop'

# Ensure TLS 1.2 for the registry call (Windows PowerShell 5.1 default is older).
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$track    = if ($env:DSH_UPDATE_TRACK) { $env:DSH_UPDATE_TRACK } else { 'next' }
$auto     = ($env:DSH_AUTO_UPDATE -eq '1')
$logFile  = Join-Path $PSScriptRoot 'update-check.log'
$registry = 'https://registry.npmjs.org/@deepseek-ai%2fdsh'

function Write-UpdateLog([string]$message) {
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $message
    Add-Content -LiteralPath $logFile -Value $line
}

function Resolve-InstalledVersion {
    # Find the dsh bin.js the same way start-harness.ps1 does, then read the
    # version from its sibling package.json.
    $bin = $env:DSH_DSH_BIN

    if (-not $bin) {
        $dshCmd = Get-Command dsh -ErrorAction SilentlyContinue
        if ($dshCmd) {
            $candidate = Join-Path (Split-Path $dshCmd.Source) 'node_modules\@deepseek-ai\dsh\lib\bin.js'
            if (Test-Path -LiteralPath $candidate) { $bin = $candidate }
        }
    }

    if (-not $bin) {
        $npmRoot = & npm root -g 2>$null | Select-Object -First 1
        if ($npmRoot) {
            $candidate = Join-Path $npmRoot '@deepseek-ai\dsh\lib\bin.js'
            if (Test-Path -LiteralPath $candidate) { $bin = $candidate }
        }
    }

    if (-not $bin -and $env:APPDATA) {
        $candidate = Join-Path (Join-Path $env:APPDATA 'npm') 'node_modules\@deepseek-ai\dsh\lib\bin.js'
        if (Test-Path -LiteralPath $candidate) { $bin = $candidate }
    }

    if (-not $bin -or -not (Test-Path -LiteralPath $bin)) { return $null }
    $pkg = Join-Path (Split-Path (Split-Path $bin)) 'package.json'
    if (-not (Test-Path -LiteralPath $pkg)) { return $null }
    return (Get-Content -LiteralPath $pkg -Raw | ConvertFrom-Json).version
}

function ConvertTo-DshVersion([string]$version) {
    # Parse X.Y.Z[-suffix] into comparable numeric fields. A stable release
    # (no suffix) sorts above any pre-release of the same X.Y.Z. Only rc.N
    # prereleases are shipped today, but any other suffix (beta, next, ...)
    # must still sort below the stable release instead of being mistaken for
    # one, so non-rc suffixes compare as rc = -1.
    $m = [regex]::Match($version, '^(\d+)\.(\d+)\.(\d+)(?:-(.+))?$')
    if (-not $m.Success) { return $null }
    $rc = [int]::MaxValue
    if ($m.Groups[4].Success) {
        $rcMatch = [regex]::Match($m.Groups[4].Value, '^rc\.(\d+)$')
        if ($rcMatch.Success) { $rc = [int]$rcMatch.Groups[1].Value } else { $rc = -1 }
    }
    return [pscustomobject]@{
        major = [int]$m.Groups[1].Value
        minor = [int]$m.Groups[2].Value
        patch = [int]$m.Groups[3].Value
        rc    = $rc
    }
}

function Compare-DshVersion([string]$a, [string]$b) {
    # Returns 1 if a > b, -1 if a < b, 0 if equal.
    $pa = ConvertTo-DshVersion $a
    $pb = ConvertTo-DshVersion $b
    if (-not $pa -or -not $pb) { return 0 }
    foreach ($key in @('major', 'minor', 'patch', 'rc')) {
        if ($pa.$key -gt $pb.$key) { return 1 }
        if ($pa.$key -lt $pb.$key) { return -1 }
    }
    return 0
}

try {
    $installed = Resolve-InstalledVersion
    if (-not $installed) { Write-UpdateLog 'could not resolve installed dsh version'; exit 0 }

    $doc = Invoke-RestMethod -Uri $registry -TimeoutSec 15
    $distTags = $doc.'dist-tags'
    $available = $distTags.$track
    if (-not $available) { Write-UpdateLog "unknown update track '$track'"; exit 0 }

    if ((Compare-DshVersion $available $installed) -le 0) {
        Write-UpdateLog "up to date (installed=$installed, track=$track=$available)"
        exit 0
    }

    Write-UpdateLog "newer version available: installed=$installed track=$track=$available"

    if (Get-Module -ListAvailable -Name BurntToast -ErrorAction SilentlyContinue) {
        try {
            Import-Module BurntToast -ErrorAction Stop
            New-BurntToastNotification -Text "DeepSeek Harness update available", "v$available (installed v$installed)"
        } catch { }
    }

    if ($auto) {
        $dshHome = Join-Path $env:USERPROFILE '.dsh'
        if (Test-Path -LiteralPath $dshHome) {
            $stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
            $backup = Join-Path $env:USERPROFILE ".dsh-backup-$installed-$stamp"
            Copy-Item -Recurse -Force $dshHome $backup
            Write-UpdateLog "backed up $dshHome -> $backup"
        }
        npm install -g "@deepseek-ai/dsh@$available" 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-UpdateLog "auto-updated to @deepseek-ai/dsh@$available"
        } else {
            Write-UpdateLog "auto-update FAILED (npm exit $LASTEXITCODE)"
        }
    }
    exit 0
} catch {
    Write-UpdateLog "update check failed: $($_.Exception.Message)"
    exit 0
}
