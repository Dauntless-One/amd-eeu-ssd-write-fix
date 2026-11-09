<#
.SYNOPSIS
    Stop-gap fix for the AMD External Events Utility SSD write bug (atieclxx.exe self-copy loop).

.DESCRIPTION
    On affected AMD Radeon drivers, atieclxx.exe (AMD External Events Client Module) repeatedly
    copies itself to:

        %WINDIR%\System32\config\systemprofile\AppData\Local\AMD\atieclxx.exe

    roughly once per second, then resets the file timestamps so the activity is invisible in
    Explorer. Measured on one system: about 40 MB/min of physical SSD writes (about 57 GB/day
    if the PC runs 24/7).

    Disabling the "AMD External Events Utility" service stops the writes but BREAKS FreeSync/VRR
    (measured with PresentMon). This script keeps the service running and instead adds an NTFS
    deny rule for SYSTEM on that one copied file, so the copy fails and nothing is written.

    Tested result on one system (RX 7900 XT, Adrenalin 26.20 / driver 32.0.32015.7029,
    Windows 11 Pro build 26200, PowerShell 5.1 and 7.6):
      - Writes to the file: about 78 copies/min -> 0
      - atieclxx.exe stays running, about 0.04% CPU
      - FreeSync/VRR still works
      - Survives reboot

    This is an UNOFFICIAL workaround. Remove it once AMD ships a fixed driver.

.PARAMETER Action
    Status   (default) Show service state, file state, deny rule, and whether the copy is stale.
    Measure  Count write events on the file for -Seconds seconds (read-only).
    Apply    Add the deny rule (idempotent).
    Remove   Remove the deny rule (rollback).

.PARAMETER Seconds
    Measurement window for -Action Measure. Default 30.

.EXAMPLE
    .\Fix-AmdEeuSsdWrites.ps1                    # status
    .\Fix-AmdEeuSsdWrites.ps1 -Action Measure    # see if the bug is active on this PC
    .\Fix-AmdEeuSsdWrites.ps1 -Action Apply      # apply the fix
    .\Fix-AmdEeuSsdWrites.ps1 -Action Remove     # undo

.NOTES
    Run from an elevated PowerShell (Run as administrator).
    Works in Windows PowerShell 5.1 and PowerShell 7.
    After an AMD driver update: run -Action Remove, reboot, then -Action Measure; if the bug is
    still present, run -Action Apply again.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('Status', 'Measure', 'Apply', 'Remove')]
    [string]$Action = 'Status',

    [ValidateRange(5, 600)]
    [int]$Seconds = 30
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- configuration
$ServiceName = 'AMD External Events Utility'
$ClientExe   = 'atieclxx.exe'
$CopyDir     = Join-Path $env:WINDIR 'System32\config\systemprofile\AppData\Local\AMD'
$CopyPath    = Join-Path $CopyDir $ClientExe
$SystemSid   = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')  # NT AUTHORITY\SYSTEM, locale independent
$DenyRights  = [System.Security.AccessControl.FileSystemRights]'WriteData, AppendData, WriteExtendedAttributes, WriteAttributes, Delete'
$IcaclsGrant = '*S-1-5-18:(WD,AD,WEA,WA,DE)'

# ---------------------------------------------------------------- helpers
function Write-Info($msg) { Write-Host "[*] $msg" }
function Write-Good($msg) { Write-Host "[+] $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "[!] $msg" -ForegroundColor Yellow }
function Write-Bad($msg)  { Write-Host "[-] $msg" -ForegroundColor Red }

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-DenyRule {
    # Returns the explicit SYSTEM deny rule on the copy, or $null.
    if (-not (Test-Path -LiteralPath $CopyPath)) { return $null }
    $acl = Get-Acl -LiteralPath $CopyPath   # Get-Acl works in PS 5.1 and 7 (FileInfo.GetAccessControl does not exist in .NET 5+)
    $rules = $acl.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier])
    foreach ($r in $rules) {
        if ($r.AccessControlType -eq 'Deny' -and $r.IdentityReference -eq $SystemSid -and
            (($r.FileSystemRights -band $DenyRights) -eq $DenyRights)) { return $r }
    }
    return $null
}

function Get-RunningClientPath {
    $p = Get-Process -Name ($ClientExe -replace '\.exe$', '') -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($p) { try { return $p.Path } catch { return $null } }
    return $null
}

function Measure-CopyWrites([int]$Window) {
    # Counts change notifications on the copied file. Read-only.
    $w = New-Object System.IO.FileSystemWatcher($CopyDir, $ClientExe)
    $w.NotifyFilter = [System.IO.NotifyFilters]'LastWrite, Size, FileName, Attributes'
    $w.IncludeSubdirectories = $false
    $count = 0
    $end = (Get-Date).AddSeconds($Window)
    try {
        while ((Get-Date) -lt $end) {
            $r = $w.WaitForChanged([System.IO.WatcherChangeTypes]::All, 1000)
            if (-not $r.TimedOut) { $count++ }
        }
    } finally { $w.Dispose() }
    return $count
}

function Show-Status {
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Warn "Service '$ServiceName' not found. This PC is likely not affected (no AMD Radeon driver)."
        return
    }
    $startType = (Get-CimInstance Win32_Service -Filter "Name='$ServiceName'").StartMode
    Write-Info "Service: $($svc.Status), start type $startType"
    if ($svc.Status -ne 'Running') {
        Write-Warn "Service is not running. FreeSync/VRR may not work while it is stopped or disabled."
    }

    $running = Get-RunningClientPath
    if ($running) { Write-Info "Running client: $running" } else { Write-Warn "$ClientExe is not running." }

    if (-not (Test-Path -LiteralPath $CopyPath)) {
        Write-Info "Copy not present: $CopyPath"
        Write-Info "Either this driver version is not affected, or the service has not run yet."
        return
    }
    $item = Get-Item -LiteralPath $CopyPath -Force
    Write-Info "Copy: $CopyPath ($($item.Length) bytes, created $($item.CreationTime))"

    if ($running) {
        $h1 = (Get-FileHash -LiteralPath $CopyPath -Algorithm SHA256).Hash
        $h2 = (Get-FileHash -LiteralPath $running -Algorithm SHA256).Hash
        if ($h1 -eq $h2) { Write-Info "Copy matches the running driver's $ClientExe." }
        else { Write-Warn "Copy differs from the running $ClientExe (driver updated?). See -Action Remove notes." }
    }

    if (Get-DenyRule) { Write-Good "Fix is APPLIED (SYSTEM deny-write rule present)." }
    else { Write-Warn "Fix is NOT applied." }
}

# ---------------------------------------------------------------- main
if (-not (Test-IsAdmin)) {
    Write-Bad 'This script must be run from an elevated PowerShell (Run as administrator).'
    exit 1
}

switch ($Action) {

    'Status' {
        Show-Status
    }

    'Measure' {
        if (-not (Test-Path -LiteralPath $CopyPath)) {
            Write-Info "Copy not present: $CopyPath. Nothing to measure."
            break
        }
        Write-Info "Watching $CopyPath for $Seconds s (leave the PC idle)..."
        $n = Measure-CopyWrites -Window $Seconds
        $perMin = [math]::Round($n * 60 / $Seconds, 1)
        $size = (Get-Item -LiteralPath $CopyPath -Force).Length
        Write-Info "Change events: $n in $Seconds s (about $perMin per minute)."
        if ($n -eq 0) {
            Write-Good 'No writes detected. Either the fix is applied or this driver is not affected.'
        } else {
            # Each copy produces several notifications; this is a rough upper bound.
            $mbDay = [math]::Round($perMin * $size * 60 * 24 / 1GB, 1)
            Write-Warn "Bug is ACTIVE. Rough upper bound: up to about $mbDay GB/day if the PC runs 24/7."
        }
    }

    'Apply' {
        $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
        if (-not $svc) { Write-Warn "Service '$ServiceName' not found; nothing to do."; break }
        if (-not (Test-Path -LiteralPath $CopyPath)) {
            Write-Warn "Copy not present yet: $CopyPath"
            Write-Warn 'Make sure the service is running, wait a minute, then run -Action Apply again.'
            exit 2
        }
        if (Get-DenyRule) { Write-Good 'Fix already applied. No change made.'; break }

        if ($PSCmdlet.ShouldProcess($CopyPath, "Deny SYSTEM write/delete ($IcaclsGrant)")) {
            $out = & icacls.exe $CopyPath /deny $IcaclsGrant 2>&1
            if ($LASTEXITCODE -ne 0) { Write-Bad "icacls failed: $out"; exit 3 }
            if (Get-DenyRule) {
                Write-Good 'Fix applied.'
                Write-Info 'Verifying for 15 s...'
                $n = Measure-CopyWrites -Window 15
                if ($n -eq 0) { Write-Good 'No writes in 15 s. Done.' }
                else { Write-Warn "$n change events still seen. Run -Action Measure later to confirm." }
                Write-Info 'Check FreeSync/VRR in a game. Undo with: -Action Remove'
            } else {
                Write-Bad 'icacls reported success but the deny rule was not found. Not applied.'
                exit 3
            }
        }
    }

    'Remove' {
        if (-not (Test-Path -LiteralPath $CopyPath)) { Write-Info 'Copy not present; nothing to remove.'; break }
        if (-not (Get-DenyRule)) { Write-Info 'Fix is not applied. No change made.'; break }
        if ($PSCmdlet.ShouldProcess($CopyPath, 'Remove SYSTEM deny rule')) {
            $out = & icacls.exe $CopyPath /remove:d '*S-1-5-18' 2>&1
            if ($LASTEXITCODE -ne 0) { Write-Bad "icacls failed: $out"; exit 3 }
            if (Get-DenyRule) { Write-Bad 'Deny rule still present after removal.'; exit 3 }
            Write-Good 'Fix removed. atieclxx.exe will resume copying itself (the original bug).'
        }
    }
}
