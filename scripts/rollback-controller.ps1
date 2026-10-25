param(
    [switch]$Apply,
    [string]$BackupPath = "$PSScriptRoot\controller-backup.json",
    [string]$InfPath
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class NewDevRollback {
  [DllImport("newdev.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  [return: MarshalAs(UnmanagedType.Bool)]
  public static extern bool UpdateDriverForPlugAndPlayDevicesW(
      IntPtr hwndParent,
      string HardwareId,
      string FullInfPath,
      uint InstallFlags,
      [MarshalAs(UnmanagedType.Bool)] out bool bRebootRequired);
}
"@

if (-not (Test-Path $BackupPath)) {
    throw "Rollback backup not found: $BackupPath. Re-run switch-controller-to-hdaudio.ps1 with -Apply to create it, or pass -InfPath explicitly."
}
$backup = Get-Content $BackupPath -Raw | ConvertFrom-Json
$hwid = $backup.ControllerHwid
if (-not $hwid) { throw "Backup does not contain ControllerHwid: $BackupPath" }

if (-not $InfPath) { $InfPath = $backup.OriginalInfPath }
if (-not $InfPath -or -not (Test-Path $InfPath)) {
    Write-Host "Original INF not found: $InfPath"
    Write-Host 'Candidates in the driver store (look for Intel Smart Sound / IntcAudioBus / IntcSST):'
    Get-ChildItem "$env:WINDIR\INF\oem*.inf" -ErrorAction SilentlyContinue | ForEach-Object {
        $c = Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue
        if ($c -and $c -match 'IntcAudioBus|IntcSST|Smart Sound') { "  $($_.FullName)" }
    } | Select-Object -First 10
    throw 'Reinstall the OEM Intel SST audio driver package, or pass -InfPath to a valid OEM INF. No change applied.'
}

Write-Host "Controller hardware ID: $hwid"
Write-Host "Restore INF:            $InfPath"
Write-Host "Original service:       $($backup.OriginalService)"
Write-Host "Original version:       $($backup.OriginalDriverVersion)"

if (-not $Apply) {
    Write-Host ''
    Write-Host 'DRY RUN. Nothing changed.'
    Write-Host 'Re-run with -Apply to restore the original OEM SST controller driver. A reboot is required afterwards.'
    return
}

$reboot = $false
$ok = [NewDevRollback]::UpdateDriverForPlugAndPlayDevicesW([IntPtr]::Zero, $hwid, $InfPath, 1, [ref]$reboot)
$err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
[ordered]@{ ok = $ok; rebootRequired = $reboot; lastError = $err; restoreInf = $InfPath } | ConvertTo-Json
if (-not $ok) {
    throw "Restore failed (Win32 error $err). Reinstall the OEM Intel SST driver package, then reboot."
}

Write-Host ''
Write-Host 'Controller restore applied. Reboot now. Normal audio should return; SRS 1.10.x will reject INTELAUDIO again.'
