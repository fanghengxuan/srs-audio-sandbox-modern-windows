param(
    [Parameter(Mandatory = $true)]
    [string]$Folder,
    [string]$CodecHwid,
    [string]$CodecDev
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

if (-not (Test-Path $Folder)) { throw "Folder not found: $Folder" }
if (-not $CodecDev -and $CodecHwid -match 'DEV_([0-9A-Fa-f]{4})') { $CodecDev = $Matches[1].ToUpper() }
if (-not $CodecHwid -and $CodecDev) { $CodecHwid = "HDAUDIO\FUNC_01&VEN_10EC&DEV_$CodecDev" }
if (-not $CodecHwid) {
    throw 'Pass -CodecHwid "HDAUDIO\FUNC_01&VEN_10EC&DEV_xxxx&SUBSYS_..." or -CodecDev "0256".'
}

$codecDevEsc = [regex]::Escape($CodecDev)
$exactEsc = [regex]::Escape($CodecHwid)

$sstFiles = @(Get-ChildItem $Folder -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^(IntcAudioBus|IntcSST|IntcDMic|IntcOED|IntcSdwBus)\.sys$' })
$serviceFiles = @(Get-ChildItem $Folder -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^RtkAudUService(64)?\.exe$|^RtkAudioService(64)?\.exe$' })

$rows = @()
Get-ChildItem $Folder -Recurse -Filter *.inf -File -ErrorAction SilentlyContinue | ForEach-Object {
    $c = Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue
    if (-not $c) { return }
    $ver = ''
    $m = [regex]::Match($c, 'DriverVer\s*=\s*([^\r\n]+)', 'IgnoreCase')
    if ($m.Success) { $ver = $m.Groups[1].Value.Trim() }

    $exact = $c -imatch $exactEsc
    $generic = $false
    if ($CodecDev) {
        $generic = $c -imatch ("HDAUDIO\\FUNC_01&VEN_10EC&DEV_" + $codecDevEsc + "(?!&SUBSYS)")
    }
    $intelaudio = $c -imatch 'INTELAUDIO'
    $intelSst = ($c -imatch 'IntcAudioBus|IntcSST|IntcDMic|IntcOED|IntcSdwBus')
    $service = ($c -imatch 'RtkAudUService|RtkAudioService|RtkAudioUniversalService')
    $extension = ($c -imatch 'ExtensionId')

    $verdict = if ($extension) { 'Extension INF (APO/component) - not the base driver' }
        elseif ($exact) { 'EXACT HDAUDIO MATCH - prefer' }
        elseif ($generic) { 'GENERIC HDAUDIO - may work; jack/amp may be incomplete' }
        elseif ($intelaudio) { 'INTELAUDIO/SST only - do not use for HDAUDIO mode' }
        else { 'no matching DEV entry found' }

    $rows += [pscustomobject]@{
        INF = $_.FullName.Substring($Folder.Length).TrimStart('\')
        DriverVer = $ver
        Extension = $extension
        ExactHDAUDIO = $exact
        GenericHDAUDIO = $generic
        INTELAUDIO = $intelaudio
        IntelSSTComponents = $intelSst
        ServiceINF = $service
        Verdict = $verdict
    }
}

$rows | Format-Table -AutoSize -Wrap

Write-Host ''
Write-Host "Codec hardware ID searched: $CodecHwid"
Write-Host "Intel SST component files in package: $($sstFiles.Count)"
foreach ($f in $sstFiles) { Write-Host "  $($f.FullName)" }
Write-Host "Realtek user-mode service files in package: $($serviceFiles.Count)"
foreach ($f in $serviceFiles) { Write-Host "  $($f.FullName)" }

if ($sstFiles.Count -gt 0 -or ($rows | Where-Object { $_.IntelSSTComponents })) {
    Write-Warning 'This package includes Intel SST bus/component drivers. Do NOT install the whole package for HDAUDIO mode; install only the HDAUDIO INF (and optionally the Realtek service), or reapply switch-controller-to-hdaudio.ps1 afterwards.'
}
if (-not ($rows | Where-Object { $_.ExactHDAUDIO })) {
    Write-Warning 'No INF contains the exact codec hardware ID. A generic HDAUDIO entry may bind, but jack/amp control can be incomplete. Prefer an OEM package for this exact model.'
}
