<#
.SYNOPSIS
  One-time, per-machine Windows-side setup for the local BeekeepingIT dev cluster.

.DESCRIPTION
  infra/cluster/dev-up.sh brings up the whole dev environment from inside WSL, but two
  things sit outside what a WSL bash script can do on its own, because they touch Windows
  itself and need Administrator:

    1. The gateway (infra/helm/beekeepingit/charts/gateway, ADR-0016) routes by Host header
       on two dev hostnames — app.beekeepingit.local and auth.beekeepingit.local (see
       infra/README.md) — so a browser on Windows needs both resolving to 127.0.0.1. That's
       an entry in C:\Windows\System32\drivers\etc\hosts, which requires elevation to edit.
    2. The shared k3d cluster's server node has been observed (2026-07-17) getting
       SIGTERM'd and gracefully drained by WSL tearing itself down between commands, even
       though `vmIdleTimeout=-1` disables WSL's own idle-VM shutdown — see dev-up.sh's
       keep-alive heartbeat for the complementary in-session fix. Making sure `.wslconfig`
       actually carries `vmIdleTimeout=-1` is the one-time half of that fix.

  Run this once per machine (idempotent — safe to re-run; a re-run is a no-op needing no
  elevation once both are already in place). After that, infra/cluster/dev-up.sh alone is
  enough, every time, to go from nothing to a browser-ready environment.

  NOTE: this does NOT trust the gateway's self-signed dev TLS cert (trusted-cert issuance
  is EPIC-14 scope, infra/helm/beekeepingit/charts/gateway/Chart.yaml) — the first visit to
  https://app.beekeepingit.local:8443 still needs one manual click-through past the
  browser's cert warning. See infra/README.md.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$HostsFile = "$env:WINDIR\System32\drivers\etc\hosts"
$DevHosts = @('app.beekeepingit.local', 'auth.beekeepingit.local')
$WslConfigFile = "$env:USERPROFILE\.wslconfig"

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# A "live" (non-comment) hosts line mapping the name to 127.0.0.1 — tolerant of
# whatever else is already in the file (extra whitespace, unrelated entries).
function Get-MissingDevHosts {
    $existing = Get-Content -Path $HostsFile -ErrorAction SilentlyContinue
    $missing = @()
    foreach ($name in $DevHosts) {
        $pattern = "^\s*127\.0\.0\.1\s+$([regex]::Escape($name))\s*$"
        if (-not ($existing | Where-Object { $_ -match $pattern })) {
            $missing += $name
        }
    }
    return $missing
}

function Test-WslConfigNeedsFix {
    if (-not (Test-Path $WslConfigFile)) { return $true }
    $content = Get-Content -Path $WslConfigFile -Raw
    return -not ($content -match '(?m)^\s*vmIdleTimeout\s*=\s*-1\s*$')
}

$missingHosts = Get-MissingDevHosts
$wslConfigNeedsFix = Test-WslConfigNeedsFix

if (-not $missingHosts -and -not $wslConfigNeedsFix) {
    Write-Host 'Already set up (hosts entries + .wslconfig both in place) — nothing to do.' -ForegroundColor Green
    exit 0
}

if (-not (Test-IsAdministrator)) {
    Write-Host 'Elevation required (editing the hosts file / .wslconfig) — relaunching as Administrator...' -ForegroundColor Yellow
    $scriptPath = $MyInvocation.MyCommand.Path
    $proc = Start-Process -FilePath 'powershell' -Verb RunAs -Wait -PassThru `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath)
    exit $proc.ExitCode
}

if ($missingHosts) {
    Write-Host "Adding missing hosts entries: $($missingHosts -join ', ')"
    Add-Content -Path $HostsFile -Value ''
    Add-Content -Path $HostsFile -Value '# BeekeepingIT local dev cluster (infra/cluster/windows-host-setup.ps1)'
    foreach ($name in $missingHosts) {
        Add-Content -Path $HostsFile -Value "127.0.0.1 $name"
    }
    Write-Host 'Hosts file updated.' -ForegroundColor Green
}
else {
    Write-Host 'Hosts entries already present — skipping.'
}

if ($wslConfigNeedsFix) {
    Write-Host "Updating $WslConfigFile (vmIdleTimeout=-1 under [wsl2])"
    $content = ''
    if (Test-Path $WslConfigFile) { $content = Get-Content -Path $WslConfigFile -Raw }
    # Drop any existing (possibly wrong) vmIdleTimeout line — re-added under [wsl2] below.
    $content = [regex]::Replace($content, '(?m)^\s*vmIdleTimeout\s*=.*\r?\n?', '')
    if ($content -notmatch '(?m)^\[wsl2\]\s*$') {
        $content = $content.TrimEnd() + "`r`n`r`n[wsl2]`r`n"
    }
    $content = [regex]::Replace(
        $content, '(?m)^\[wsl2\]\s*$',
        "[wsl2]`r`nvmIdleTimeout=-1  # keep the shared k3d dev cluster alive between commands (infra/cluster/windows-host-setup.ps1)",
        1)
    Set-Content -Path $WslConfigFile -Value $content -NoNewline
    Write-Host 'Restarting WSL so the new .wslconfig takes effect (this stops any WSL distro/cluster currently running)...' -ForegroundColor Yellow
    wsl --shutdown
    Write-Host '.wslconfig updated and WSL restarted.' -ForegroundColor Green
}
else {
    Write-Host 'vmIdleTimeout already set — skipping .wslconfig change (and WSL restart).'
}

Write-Host ''
Write-Host 'One-time setup complete. From here on, every bring-up is just:' -ForegroundColor Cyan
Write-Host '  wsl -- bash -lc "cd /path/to/beekeepingit && infra/cluster/dev-up.sh"'
Write-Host 'then open the URL it prints once it finishes (see infra/README.md#quickstart).'
