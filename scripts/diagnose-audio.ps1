param(
    [switch]$Json
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'SilentlyContinue'

function Get-DevProps {
    param([string]$InstanceId)
    $keys = @(
        'DEVPKEY_Device_DriverInfPath',
        'DEVPKEY_Device_Service',
        'DEVPKEY_Device_DriverDesc',
        'DEVPKEY_Device_DriverVersion',
        'DEVPKEY_Device_DriverProvider',
        'DEVPKEY_Device_HardwareIds',
        'DEVPKEY_Device_EnumeratorName'
    )
    $h = [ordered]@{}
    foreach ($k in $keys) {
        $v = (Get-PnpDeviceProperty -InstanceId $InstanceId -KeyName $k -ErrorAction SilentlyContinue).Data
        if ($null -ne $v) { $h[$k] = ($v -join ' ') }
    }
    $h
}

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class KsIf {
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
    $hdev = [KsIf]::SetupDiGetClassDevs([ref]$guid, [IntPtr]::Zero, [IntPtr]::Zero, 0x12)
    if ($hdev -eq [IntPtr]::Zero -or $hdev -eq [IntPtr](-1)) { return @() }
    $ifd = [Runtime.InteropServices.Marshal]::AllocHGlobal($ifdSize)
    $out = @()
    try {
        for ($i = 0; $i -lt 256; $i++) {
            [Runtime.InteropServices.Marshal]::WriteInt32($ifd, $ifdSize)
            $ok = [KsIf]::SetupDiEnumDeviceInterfaces($hdev, [IntPtr]::Zero, [ref]$guid, $i, $ifd)
            if (-not $ok) { break }
            $flags = [Runtime.InteropServices.Marshal]::ReadInt32($ifd, 20)
            $req = 0
            [KsIf]::SetupDiGetDeviceInterfaceDetail($hdev, $ifd, [IntPtr]::Zero, 0, [ref]$req, [IntPtr]::Zero) | Out-Null
            if ($req -le 0) { continue }
            $buf = [Runtime.InteropServices.Marshal]::AllocHGlobal($req)
            try {
                [Runtime.InteropServices.Marshal]::WriteInt32($buf, $detailCb)
                $ok2 = [KsIf]::SetupDiGetDeviceInterfaceDetail($hdev, $ifd, $buf, $req, [ref]$req, [IntPtr]::Zero)
                if ($ok2) {
                    $path = [Runtime.InteropServices.Marshal]::PtrToStringUni([IntPtr]::Add($buf, $pathOffset))
                    $out += [pscustomobject]@{ Path = $path; Active = (($flags -band 1) -ne 0); Flags = $flags }
                }
            } finally { [Runtime.InteropServices.Marshal]::FreeHGlobal($buf) }
        }
    } finally {
        [Runtime.InteropServices.Marshal]::FreeHGlobal($ifd)
        [KsIf]::SetupDiDestroyDeviceInfoList($hdev) | Out-Null
    }
    $out
}

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumeratorComObject { }
[ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDeviceEnumerator {
  int NotImpl1();
  int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice device);
  int NotImpl3();
  int NotImpl4();
  int NotImpl5();
}
[ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDevice {
  int NotImpl1();
  int NotImpl2();
  int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
  int NotImpl4();
}
public static class DefaultAudio {
  public static string Get(int flow, int role) {
    var e = (IMMDeviceEnumerator)(new MMDeviceEnumeratorComObject());
    IMMDevice d; int hr = e.GetDefaultAudioEndpoint(flow, role, out d);
    if (hr != 0) return "hr=0x" + hr.ToString("X8");
    string id; hr = d.GetId(out id);
    return id ?? ("hr2=0x" + hr.ToString("X8"));
  }
}
"@

function Get-FriendlyName([string]$EndpointId) {
    if (-not $EndpointId) { return '' }
    $d = Get-PnpDevice -Class AudioEndpoint | Where-Object { $_.InstanceId -like "*$EndpointId" } | Select-Object -First 1
    if ($d) { return $d.FriendlyName }
    return '(not found)'
}

$report = [ordered]@{
    Computer = (Get-CimInstance Win32_ComputerSystem | Select-Object Manufacturer, Model, SystemSKUNumber)
    OS = (Get-CimInstance Win32_OperatingSystem | Select-Object Caption, Version, BuildNumber)
    AudioControllers = @()
    MediaDevices = @()
    RenderInterfaces = @()
    DefaultEndpoints = @()
    ActiveEndpoints = @()
    Srs = [ordered]@{}
    Warnings = @()
}

$systemCandidates = Get-PnpDevice -Class System | Where-Object {
    $_.FriendlyName -match 'Audio|Sound|Smart Sound|SST|智音|高清晰度音频' -or
    $_.InstanceId -match '^PCI\\VEN_8086'
}
foreach ($d in $systemCandidates) {
    $p = Get-DevProps $d.InstanceId
    if ($p['DEVPKEY_Device_Service'] -match 'IntcAudioBus|IntcSST|HDAudBus' -or $d.FriendlyName -match 'Smart Sound|SST|智音|Audio Controller') {
        $report.AudioControllers += [pscustomobject]@{
            Status = $d.Status; FriendlyName = $d.FriendlyName; InstanceId = $d.InstanceId; Props = $p
        }
    }
}

foreach ($d in (Get-PnpDevice -Class MEDIA)) {
    $p = Get-DevProps $d.InstanceId
    $report.MediaDevices += [pscustomobject]@{
        Status = $d.Status; Problem = $d.Problem; FriendlyName = $d.FriendlyName; InstanceId = $d.InstanceId; Props = $p
    }
}

$report.RenderInterfaces = @(Get-RenderInterfaces | Sort-Object Active -Descending)

foreach ($flow in 0, 1) {
    foreach ($role in 0, 1, 2) {
        $id = [DefaultAudio]::Get($flow, $role)
        $report.DefaultEndpoints += [pscustomobject]@{
            Flow = $(if ($flow -eq 0) { 'render' } else { 'capture' })
            Role = $role; EndpointId = $id; FriendlyName = (Get-FriendlyName $id)
        }
    }
}

$report.ActiveEndpoints = @(Get-PnpDevice -Class AudioEndpoint | Where-Object { $_.Status -ne 'Unknown' } |
    Select-Object Status, FriendlyName, InstanceId)

$srsRoot = 'HKCU:\Software\SRS Labs'
if (Test-Path $srsRoot) {
    $configs = @()
    Get-ChildItem $srsRoot -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
        if ($p -and $p.PSObject.Properties.Name -contains 'defaultAudioDevice') {
            $configs += [pscustomobject]@{ Key = $_.PSPath; DefaultAudioDevice = $p.defaultAudioDevice }
        }
    }
    $report.Srs.Config = $configs
}
$report.Srs.Process = @(Get-Process SRSSSC -ErrorAction SilentlyContinue | Select-Object Id, MainWindowTitle)
$report.Srs.Service = @(Get-Service SRS_SSCFilter -ErrorAction SilentlyContinue | Select-Object Name, Status, StartType)
$report.Srs.Device = @(Get-PnpDevice -InstanceId 'ROOT\MEDIA\0002' -ErrorAction SilentlyContinue |
    Select-Object Status, Problem, FriendlyName, InstanceId)

$hasIntelaudio = $report.MediaDevices | Where-Object { $_.InstanceId -like 'INTELAUDIO\*' -and $_.Status -eq 'OK' }
$hasHdaudio = $report.MediaDevices | Where-Object { $_.InstanceId -like 'HDAUDIO\*' -and $_.Status -eq 'OK' }
$genericHdaudio = $hasHdaudio | Where-Object { $_.Props['DEVPKEY_Device_DriverInfPath'] -eq 'hdaudio.inf' }
$staleSrs = $report.Srs.Config | Where-Object { $_.DefaultAudioDevice -match 'INTELAUDIO|SST' }
$virtual = $report.MediaDevices | Where-Object { $_.InstanceId -like 'ROOT\MEDIA\*' -and $_.FriendlyName -match 'VB-Audio|CABLE|Virtual Audio Cable' }

if ($hasIntelaudio) {
    $report.Warnings += 'INTELAUDIO codec present: SRS 1.10.x likely rejects it. Switch the controller to Microsoft HDAudio.'
}
if ($genericHdaudio) {
    $report.Warnings += 'HDAUDIO codec uses Microsoft generic hdaudio.inf: audio may work but amp/jack control can be incomplete (buzz/no headphones). Prefer an OEM HDAUDIO INF matching the codec SUBSYS.'
}
if ($staleSrs) {
    $report.Warnings += 'SRS defaultAudioDevice still points at an INTELAUDIO/SST path. After switching to HDAUDIO, update it to the new active KSCATEGORY_RENDER interface.'
}
if ($virtual) {
    $report.Warnings += 'Third-party virtual cable device(s) present. They do not satisfy SRS and are not required.'
}
if (-not $hasIntelaudio -and -not $hasHdaudio) {
    $report.Warnings += 'No active physical HDAUDIO/INTELAUDIO codec found. Check driver installation and device status.'
}

if ($Json) {
    $report | ConvertTo-Json -Depth 8
} else {
    '=== SYSTEM ==='
    $report.Computer | Format-List
    $report.OS | Format-List

    '=== AUDIO CONTROLLERS ==='
    foreach ($c in $report.AudioControllers) {
        "[$($c.Status)] $($c.FriendlyName)"
        "  $($c.InstanceId)"
        foreach ($k in $c.Props.Keys) { "  $k = $($c.Props[$k])" }
    }

    '=== MEDIA DEVICES ==='
    foreach ($d in $report.MediaDevices) {
        "[$($d.Status)/$(if ($d.Problem) { $d.Problem } else { 'OK' })] $($d.FriendlyName)"
        "  $($d.InstanceId)"
        foreach ($k in $d.Props.Keys) { "  $k = $($d.Props[$k])" }
    }

    '=== KSCATEGORY_RENDER INTERFACES (DIGCF_PRESENT) ==='
    foreach ($r in $report.RenderInterfaces) {
        "{0} {1}" -f $(if ($r.Active) { '[ACTIVE]  ' } else { '[disabled]' }), $r.Path
    }

    '=== DEFAULT ENDPOINTS ==='
    foreach ($e in $report.DefaultEndpoints) {
        "$($e.Flow)/$($e.Role): $($e.EndpointId) => $($e.FriendlyName)"
    }

    '=== ACTIVE AUDIO ENDPOINTS ==='
    $report.ActiveEndpoints | Format-Table -AutoSize -Wrap

    '=== SRS ==='
    $report.Srs | ConvertTo-Json -Depth 6

    '=== WARNINGS / NEXT ACTIONS ==='
    foreach ($w in $report.Warnings) { "- $w" }
}
