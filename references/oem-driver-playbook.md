# OEM Driver Playbook and Evidence Notes

## Why virtual cables do not fix SRS 1.10.x

SRS Audio Sandbox 1.10.x is a 2009 application. Its user-mode device check accepts the WDM/HDAUDIO-era identity of a physical codec and rejects modern Intel Smart Sound Technology (SST) devices enumerated as `INTELAUDIO\...`. VB-Cable and Virtual Audio Cable enumerate as `ROOT\MEDIA\...`; SRS rejects those too. SRS already installs its own virtual card (`ROOT\MEDIA\...`, `SRS_SSCFilter`), so a third-party cable is not required and can confuse the default-device path.

The app's exact Chinese resource string (in `SRSSAS_Resource_ZH_CN_0x0804.dll`) is:

```
没有 SRS Audio Sandbox 可用的兼容声卡。请向您的系统添加一个兼容设备。控制面板程序即将关闭。
```

## Evidence collected from a working case (Dell XPS 13 9360, ALC3246/ALC256)

- Controller: `PCI\VEN_8086&DEV_9D71...`, driver `IntcAudioBus` (Intel SST), bus enumerator `INTELAUDIO`.
- Codec: `INTELAUDIO\FUNC_01&VEN_10EC&DEV_0256&SUBSYS_1028082A...`, Realtek SST package; only enabled render interface was `...\RearLineOutWaveSST`.
- SRS driver `SRS_SSCFilter` was RUNNING and `ROOT\MEDIA\0002` was healthy; the error was purely the app's compatibility check.
- SRS enumerated `KSCATEGORY_RENDER` and CoreAudio endpoints, read the Realtek device instance, then rejected it. It never needed a third-party cable.
- Disabling VB-Cable and reordering interfaces did not change the error.
- Switching the controller to Microsoft HDAudio and installing a Dell/Realtek HDAUDIO INF (6.0.9960.1) made SRS start and removed a constant buzz from the Microsoft generic driver.
- Headphones were still silent because SRS stored the old SST path in `HKCU\Software\SRS Labs\SRS HD Audio Lab\defaultAudioDevice`. Updating it to the new HDAUDIO `RearLineOutWave3` interface fixed headphone output.

## Diagnostic commands

Run `scripts/diagnose-audio.ps1` first. Key manual checks:

```powershell
# Controller and codec identity
Get-PnpDevice -Class MEDIA | Select Status,Problem,FriendlyName,InstanceId
Get-PnpDevice -Class System | Where-Object { $_.FriendlyName -match 'Smart Sound|SST|Audio Controller' } |
  ForEach-Object { $_.FriendlyName; $_.InstanceId;
    Get-PnpDeviceProperty -InstanceId $_.InstanceId |
      Where-Object KeyName -match 'DriverInfPath|Service|DriverDesc|DriverVersion|HardwareIds' }
```

Classification:

| Evidence | Meaning |
|---|---|
| `INTELAUDIO\FUNC_01...`, service `IntcAudioBus`/`IntcAzAudAddService`, package name containing `SST` | Intel SST mode; SRS 1.10.x rejects it |
| `HDAUDIO\FUNC_01...`, service `IntcAzAudAddService`, OEM INF | Legacy HDAUDIO mode; SRS should accept it |
| `HDAUDIO...` but `DriverInfPath = hdaudio.inf` (Microsoft generic) | Audio may work, but amp/jack init can be incomplete: buzz, no headphones |
| `ROOT\MEDIA\...` VB-Audio/CABLE/VAC | Third-party virtual cable; not a compatible physical card |

Enabled render interfaces (`KSCATEGORY_RENDER` = `{65E8773E-8F56-11D0-A3B9-00A0C9223196}`):

- SST mode commonly shows `...\RearLineOutWaveSST`.
- HDAUDIO mode commonly shows `...\RearLineOutWave3`, `...\eSpeakerWave`, `...\SecondaryLineOutWave`.
- `scripts/diagnose-audio.ps1` prints the active paths.
- SRS's stored preferred path may still contain `INTELAUDIO`/`REARLINEOUTWAVESST`; that is the most common cause of "SRS starts but headphones are silent" after the switch.

SRS config:

```powershell
Get-ChildItem 'HKCU:\Software\SRS Labs' -Recurse |
  ForEach-Object { $p=Get-ItemProperty $_.PSPath; if($p.defaultAudioDevice){ $_.PSPath; $p.defaultAudioDevice } }
```

## Driver acquisition

### Dell

Dell publishes two catalogs on `downloads.dell.com`; the host is usually reachable even when `www.dell.com` blocks scripted access:

- `https://downloads.dell.com/catalog/CatalogPC.cab` — individual client driver packages (UTF-16 XML after extraction).
- `https://downloads.dell.com/catalog/DriverPackCatalog.cab` — driver-pack manifest (ASCII XML).

Extraction (use the native Windows `expand.exe`; Git Bash may resolve a GNU `expand` with different flags):

```bash
curl -sL -o CatalogPC.cab https://downloads.dell.com/catalog/CatalogPC.cab
MSYS_NO_PATHCONV=1 /c/Windows/System32/expand.exe -F:* \
  "C:\path\CatalogPC.cab" "C:\path\extracted"
```

The extracted `catalogpc.cab` is an XML file despite the extension. Parse `<SoftwareComponent>` entries whose `path` contains `Realtek-High-Definition-Audio`; read `packageID`, `vendorVersion`, `path`, and `<SupportedSystems>`. Download:

```
https://downloads.dell.com/<path>
```

Example (XPS 13 9360): the Dell systemID is `082A` (also `075B` for the 2016 SKU). The 2026 `6.0.9960.1` package `C7MPH` contained the exact HDAUDIO INF; its DUP path was `FOLDER14412779M/1/Realtek-High-Definition-Audio-Driver_C7MPH_WIN64_6.0.9960.1_A01.EXE`.

Verify:

- Compare the catalog `hashMD5` to the downloaded file.
- `Get-AuthenticodeSignature` must show `Valid` and Dell/Realtek as signer.
- Extract the DUP without installing:

```bash
MSYS_NO_PATHCONV=1 "C:\path\driver.exe" /s /e="C:\path\extracted"
```

Inspect the extracted INFs with `scripts/inspect-driver-package.ps1`:

- Prefer an INF containing the exact `HDAUDIO\FUNC_01&VEN_10EC&DEV_xxxx&SUBSYS_...`.
- Avoid packages that install `IntcAudioBus`, `IntcSST`, `IntcDMic`, `IntcOED`, or `IntcSdwBus`; these are Intel SST components and can revert the controller.
- If the DUP contains Intel SST components, do not run its full setup. Install the HDAUDIO INF directly with `pnputil /add-driver "<inf>" /install`; optionally install `RealtekService.inf`/`RtkAudUService64.exe` for the Realtek control panel, but the SRS headphone fix does not require it.

### HP

- Find the audio SoftPaq for the exact model on HP support (or the HP driver pack).
- Download `spXXXXX.exe`, verify the signature, and extract with the SoftPaq’s silent extract option (often `spXXXXX.exe -s -e -f<dir>`) or 7-Zip.
- Inspect INFs the same way. Many HP business packages are SST-only; if no HDAUDIO INF with the exact SUBSYS exists, use the Microsoft Update Catalog or a generic Realtek UAD HDAUDIO INF that lists the codec DEV/SUBSYS.
- Do not install HP’s Intel SST bus driver after switching to HDAudio.

### Microsoft Update Catalog

Search by hardware ID or codec, for example:

```
https://www.catalog.update.microsoft.com/Search.aspx?q=Realtek%20DEV_0256
https://www.catalog.update.microsoft.com/Search.aspx?q=SUBSYS_1028082A
```

Download flow:

1. Extract update GUIDs from the result page (`<a id="<guid>" ...>` / checkbox values).
2. POST to `https://www.catalog.update.microsoft.com/DownloadDialog.aspx` with
   `updateIDs=[{"size":0,"updateID":"<guid>","uidInfo":"<guid>","updateTitle":"..."}]`.
3. Parse the `download.windowsupdate.com/.../*.cab` URL from the response HTML.
4. Download, extract with native `expand.exe`, inspect INFs with `scripts/inspect-driver-package.ps1`.

Catalog packages are usually driver-only (no OEM service/control panel). They are often safer for HDAUDIO mode than a full OEM DUP because they do not include Intel SST bus components.

## Installing the HDAUDIO codec driver

```powershell
pnputil /add-driver "C:\path\to\HDX...HDAUDIO.inf" /install
```

Verify:

```powershell
Get-PnpDevice -Class MEDIA | Where-Object { $_.InstanceId -like 'HDAUDIO\*' }
# DriverDesc = Realtek Audio, DriverInfPath = the OEM INF, DriverVersion = expected
```

If the INF does not match the codec, do not edit/sign it. Find the OEM package that lists the exact `SUBSYS`, or use a generic codec entry. If you had to run a full OEM DUP that installed Intel SST, reapply `switch-controller-to-hdaudio.ps1`.

## SRS preferred-device fix

Old value (SST era):

```
\\?\INTELAUDIO#FUNC_01&VEN_10EC&DEV_0256&SUBSYS_1028082A&REV_1000#4&32B8B7C&0&0001#{65E8773E-8F56-11D0-A3B9-00A0C9223196}\REARLINEOUTWAVESST
```

New value (HDAUDIO era; use the exact active interface from the diagnostic):

```
\\?\HDAUDIO#FUNC_01&VEN_10EC&DEV_0256&SUBSYS_1028082A&REV_1000#4&32B8B7C&0&0001#{65E8773E-8F56-11D0-A3B9-00A0C9223196}\RearLineOutWave3
```

Use `scripts/fix-srs-device.ps1 -Apply` (closes/warns on a running SRS, backs up the old value, writes all SRS config keys with `defaultAudioDevice`), or use SRS Options → Preferences and select the Realtek “Speakers/Headphones” device. Relaunch SRS and test headphones.

## Verification checklist

- SRS starts with no “no compatible sound card” dialog.
- Audio plays; SRS on/off produces an audible difference.
- Headphones work through SRS; the constant buzz is gone.
- After a reboot, the controller is still `HDAudBus`, the codec is `HDAUDIO`, and the SRS preferred path still points at the active render interface.
- Windows Update has not reinstalled Intel SST; if it does, reapply the controller switch.

## Rollback

1. `scripts/rollback-controller.ps1 -Apply` restores the original OEM SST INF from `controller-backup.json`.
2. Reboot.
3. Normal audio/headphones return; SRS 1.10.x will reject INTELAUDIO again.
4. If the original OEM INF is no longer in `C:\Windows\INF`, reinstall the OEM SST audio package from the OEM support site.

If only the SRS path was wrong, `srs-device-backup.json` contains the old value; restore it with `Set-ItemProperty`.

## Optional REA/Frida evidence appendix

Static analysis of the SRS 1.10.1 executable is hard because it is packed (Ghidra sees only a small import stub), but runtime evidence is straightforward:

- `setupapi.dll!SetupDiGetClassDevsW` with `KSCATEGORY_RENDER`, `SetupDiEnumDeviceInterfaces`, `SetupDiGetDeviceInterfaceDetailW` show which interfaces the app sees.
- `dsound.dll!DirectSoundEnumerateW` and `MMDeviceEnumerator` COM calls show the CoreAudio endpoints.
- In the failing case the app opened the SRS interface and the virtual-cable interfaces, but never the `INTELAUDIO` physical interface; it still declared no compatible card.
- The error string is in `SRSSAS_Resource_ZH_CN_0x0804.dll`; the app also has English strings in the main executable.
- REA/Ghidra can be used to confirm the packed stub and the error resource, but the decision tree above does not require unpacking.

## Safety notes

- Create a restore point and keep the OEM driver package/DUP for rollback.
- Switching an Intel SST controller to HDAudio can disable SST-only digital microphones (DMIC) and OEM audio effects. Speakers/headphones usually still work via the codec. Confirm the user accepts this trade-off.
- Do not disable driver signature enforcement or edit signed INF/catalog files. Use signed OEM/Catalog packages with a matching SUBSYS.
- Do not let Windows Update reinstall Intel SST silently after the switch; check updates after the fix.
