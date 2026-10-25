param(
    [switch]$Apply,
    [string]$ControllerHwid,
    [string]$InfPath = "$env:WINDIR\INF\hdaudbus.inf",
    [string]$BackupPath = "$PSScriptRoot\controller-backup.json"
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class NewDev {
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

function Get-Props([string]$InstanceId) {
    $h = @{}
    foreach ($k in 'DEVPKEY_Device_DriverInfPath', 'DEVPKEY_Device_Service', 'DEVPKEY_Device_DriverDesc',
        'DEVPKEY_Device_DriverVersion', 'DEVPKEY_Device_HardwareIds') {
        $v = (Get-PnpDeviceProperty -InstanceId $InstanceId -KeyName $k -ErrorAction SilentlyContinue).Data
        if ($null -ne $v) { $h[$k] = ($v -join ' ') }
    }
    $h
}

$device = $null
if ($ControllerHwid) {
    $device = Get-PnpDevice -Class System | Where-Object {
        $p = Get-Props $_.InstanceId
        $p['DEVPKEY_Device_HardwareIds'] -and ($p['DEVPKEY_Device_HardwareIds'] -split '\s+') -contains $ControllerHwid
    } | Select-Object -First 1
} else {
    $candidates = Get-PnpDevice -Class System | Where-Object {
        $_.FriendlyName -match 'Smart Sound|SST|智音|Audio Controller|High Definition Audio Controller'
    }
    foreach ($c in $candidates) {
        $p = Get-Props $c.InstanceId
        if ($p['DEVPKEY_Device_Service'] -match 'IntcAudioBus|IntcSST|HDAudBus' -or
            $c.FriendlyName -match 'Smart Sound|SST|智音') {
            $device = $c
            if ($p['DEVPKEY_Device_Service'] -match 'IntcAudioBus|IntcSST') { break }
        }
    }
    if ($device) {
        $p = Get-Props $device.InstanceId
        $ControllerHwid = ($p['DEVPKEY_Device_HardwareIds'] -split '\s+') | Select-Object -First 1
    }
}

if (-not $ControllerHwid) {
    throw "Could not identify the Intel SST audio controller. Re-run with -ControllerHwid 'PCI\VEN_8086&DEV_xxxx&SUBSYS_...' (first entry of the controller's DEVPKEY_Device_HardwareIds)."
}
if (-not (Test-Path $InfPath)) {
    throw "HDAudio INF not found: $InfPath"
}
if (-not $device) {
    Write-Warning "No matching PnP device found for $ControllerHwid; the driver update will still be attempted by hardware ID."
    $device = [pscustomobject]@{ FriendlyName = '(unknown)'; InstanceId = '(unknown)'; Status = '(unknown)' }
}

$current = Get-Props $device.InstanceId
$backup = [ordered]@{
    Timestamp = (Get-Date).ToString('o')
    ControllerInstanceId = $device.InstanceId
    ControllerFriendlyName = $device.FriendlyName
    ControllerHwid = $ControllerHwid
    OriginalInfPath = $current['DEVPKEY_Device_DriverInfPath']
    OriginalService = $current['DEVPKEY_Device_Service']
    OriginalDriverDesc = $current['DEVPKEY_Device_DriverDesc']
    OriginalDriverVersion = $current['DEVPKEY_Device_DriverVersion']
    TargetInfPath = $InfPath
}

Write-Host "Controller: $($device.FriendlyName)"
Write-Host "Instance:   $($device.InstanceId)"
Write-Host "HardwareId: $ControllerHwid"
Write-Host "Current:    INF=$($current['DEVPKEY_Device_DriverInfPath']) service=$($current['DEVPKEY_Device_Service']) version=$($current['DEVPKEY_Device_DriverVersion'])"
Write-Host "Target INF: $InfPath (Microsoft High Definition Audio Controller)"

if (-not $Apply) {
    Write-Host ''
    Write-Host 'DRY RUN. Nothing changed.'
    Write-Host "Would write rollback backup to: $BackupPath"
    Write-Host 'Re-run with -Apply to perform the switch. A reboot is required afterwards.'
    return
}

$backup | ConvertTo-Json -Depth 4 | Set-Content -Path $BackupPath -Encoding UTF8
Write-Host "Rollback backup written: $BackupPath"

$reboot = $false
$ok = [NewDev]::UpdateDriverForPlugAndPlayDevicesW([IntPtr]::Zero, $ControllerHwid, $InfPath, 1, [ref]$reboot)
$err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
$result = [ordered]@{ ok = $ok; rebootRequired = $reboot; lastError = $err; backupPath = $BackupPath }
$result | ConvertTo-Json
if (-not $ok) {
    throw "UpdateDriverForPlugAndPlayDevicesW failed (Win32 error $err). No reboot was requested; check the INF/hardware ID and event log."
}

Write-Host ''
Write-Host 'Controller switched. Reboot now, then verify:'
Write-Host '  - controller DriverDesc = High Definition Audio Controller, Service = HDAudBus'
Write-Host '  - codec instance = HDAUDIO\FUNC_01&VEN_10EC&DEV_xxxx&SUBSYS_...'
Write-Host 'Next: install an OEM HDAUDIO codec INF matching the codec SUBSYS (see SKILL.md step 3).'
