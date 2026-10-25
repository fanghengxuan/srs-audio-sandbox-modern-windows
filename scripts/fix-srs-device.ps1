param(
    [switch]$Apply,
    [string]$InterfacePath,
    [string]$RegistryKey,
    [switch]$StopApp,
    [string]$BackupPath = "$PSScriptRoot\srs-device-backup.json"
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class KsIfFix {
  [DllImport("setupapi.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  public static extern IntPtr SetupDiGetClassDevs(ref Guid classGuid, IntPtr enumerator, IntPtr hwndParent, uint flags);
  [DllImport("setupapi.dll", SetLastError=true)]
  public static extern bool SetupDiEnumDeviceInterfaces(IntPtr hDevInfo, IntPtr devInfo, ref Guid interfaceClassGuid, uint memberIndex, IntPtr deviceInterfaceData);
  [DllImport("setupapi.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  public static extern bool SetupDiGetDeviceInterfaceDetail(IntPtr hDevInfo, IntPtr deviceInterfaceData, IntPtr deviceInterfaceDetailData, uint deviceInterfaceDetailDataSize, out uint requiredSize, IntPtr deviceInfoData);
  [DllImport("setupapi.dll")]
  public static extern bool SetupDiDestroyDeviceInfoList(IntPtr hDevInfo);
}
"@

function Get-RenderInterfaces {
    $guid = [Guid]'65e8773e-8f56-11d0-a3b9-00a0c9223196'
    $is64 = [IntPtr]::Size -eq 8
    $ifdSize = if ($is64) { 32 } else { 28 }
    $detailCb = if ($is64) { 8 } else { 6 }
    $pathOffset = 4
    $hdev = [KsIfFix]::SetupDiGetClassDevs([ref]$guid, [IntPtr]::Zero, [IntPtr]::Zero, 0x12)
    if ($hdev -eq [IntPtr]::Zero -or $hdev -eq [IntPtr](-1)) { return @() }
    $ifd = [Runtime.InteropServices.Marshal]::AllocHGlobal($ifdSize)
    $out = @()
    try {
        for ($i = 0; $i -lt 256; $i++) {
            [Runtime.InteropServices.Marshal]::WriteInt32($ifd, $ifdSize)
            if (-not [KsIfFix]::SetupDiEnumDeviceInterfaces($hdev, [IntPtr]::Zero, [ref]$guid, $i, $ifd)) { break }
            $flags = [Runtime.InteropServices.Marshal]::ReadInt32($ifd, 20)
            $req = 0
            [KsIfFix]::SetupDiGetDeviceInterfaceDetail($hdev, $ifd, [IntPtr]::Zero, 0, [ref]$req, [IntPtr]::Zero) | Out-Null
            if ($req -le 0) { continue }
            $buf = [Runtime.InteropServices.Marshal]::AllocHGlobal($req)
            try {
                [Runtime.InteropServices.Marshal]::WriteInt32($buf, $detailCb)
                if ([KsIfFix]::SetupDiGetDeviceInterfaceDetail($hdev, $ifd, $buf, $req, [ref]$req, [IntPtr]::Zero)) {
                    $out += [pscustomobject]@{
                        Path = [Runtime.InteropServices.Marshal]::PtrToStringUni([IntPtr]::Add($buf, $pathOffset))
                        Active = (($flags -band 1) -ne 0)
                    }
                }
            } finally { [Runtime.InteropServices.Marshal]::FreeHGlobal($buf) }
        }
    } finally {
        [Runtime.InteropServices.Marshal]::FreeHGlobal($ifd)
        [KsIfFix]::SetupDiDestroyDeviceInfoList($hdev) | Out-Null
    }
    $out
}

function Get-SrsConfigKeys {
    if ($RegistryKey) { return @($RegistryKey) }
    $root = 'HKCU:\Software\SRS Labs'
    if (-not (Test-Path $root)) { return @() }
    $keys = @()
    Get-ChildItem $root -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
        if ($p -and ($p.PSObject.Properties.Name -contains 'defaultAudioDevice')) { $keys += $_.PSPath }
    }
    $keys
}

$app = Get-Process SRSSSC -ErrorAction SilentlyContinue
if ($app -and $Apply -and -not $StopApp) {
    throw "SRS Audio Sandbox is running (PID $($app.Id)). Close it first, or pass -StopApp to stop it before editing its config."
}
if ($app -and $Apply -and $StopApp) {
    Stop-Process -Id $app.Id -Force
    Start-Sleep -Seconds 1
    Write-Host "Stopped SRS process $($app.Id)."
}

$active = @(Get-RenderInterfaces | Where-Object { $_.Active })
if ($active.Count -eq 0) { throw 'No active KSCATEGORY_RENDER interfaces found. Check the audio driver/controller state.' }

Write-Host 'Active KSCATEGORY_RENDER interfaces:'
foreach ($a in $active) { Write-Host "  $($a.Path)" }

if (-not $InterfacePath) {
    $physical = $active | Where-Object {
        $_.Path -notmatch 'root#media#0002' -and $_.Path -notmatch '^\\\\\?\\ROOT#MEDIA' -and $_.Path -notmatch 'SRS'
    }
    $preferred = @($physical | Where-Object { $_.Path -match '^\\\\\?\\HDAUDIO#|^\\\\\?\\PCI#' })
    if ($preferred.Count -eq 1) { $InterfacePath = $preferred[0].Path }
    elseif ($physical.Count -eq 1) { $InterfacePath = $physical[0].Path }
    else {
        throw 'Could not choose a single physical render interface. Re-run with -InterfacePath "<one of the active paths above>".'
    }
}
elseif (-not ($active | Where-Object { $_.Path -eq $InterfacePath })) {
    Write-Warning "The supplied -InterfacePath is not in the active interface list; using it anyway."
}

$keys = Get-SrsConfigKeys
if ($keys.Count -eq 0) {
    throw 'No SRS config with a defaultAudioDevice value found under HKCU\Software\SRS Labs. Use SRS Options -> Preferences to select the Realtek Speakers/Headphones device manually.'
}

Write-Host "Target SRS interface: $InterfacePath"
Write-Host "SRS config key(s): $($keys -join ', ')"

if (-not $Apply) {
    Write-Host ''
    Write-Host 'DRY RUN. Nothing changed.'
    foreach ($k in $keys) {
        $old = (Get-ItemProperty $k -Name defaultAudioDevice -ErrorAction SilentlyContinue).defaultAudioDevice
        $note = if ($old -and ($old -ieq $InterfacePath)) { ' (already set)' } else { '' }
        Write-Host "  $k : $old -> $InterfacePath$note"
    }
    Write-Host 'Re-run with -Apply to update the SRS preferred output device.'
    return
}

$backupPath = $BackupPath
$backup = @()
$changed = 0
foreach ($k in $keys) {
    $old = (Get-ItemProperty $k -Name defaultAudioDevice -ErrorAction SilentlyContinue).defaultAudioDevice
    if ($old -and ($old -ieq $InterfacePath)) {
        Write-Host "Already set: $k"
        continue
    }
    $backup += [pscustomobject]@{ Key = $k; OldValue = $old; NewValue = $InterfacePath; Timestamp = (Get-Date).ToString('o') }
    Set-ItemProperty -Path $k -Name defaultAudioDevice -Value $InterfacePath
    $changed++
    Write-Host "Updated $k"
    Write-Host "  old: $old"
    Write-Host "  new: $InterfacePath"
}
if ($changed -eq 0) {
    Write-Host 'No changes needed.'
    return
}
$backup | ConvertTo-Json -Depth 4 | Set-Content -Path $backupPath -Encoding UTF8
Write-Host "Backup written: $backupPath"
Write-Host 'Relaunch SRS Audio Sandbox, then test playback and headphones.'
