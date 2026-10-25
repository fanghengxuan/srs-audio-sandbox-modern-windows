---
name: srs-audio-sandbox-modern-windows
description: Use when SRS Audio Sandbox 1.10.x (2009) shows "没有 SRS Audio Sandbox 可用的兼容声卡" / "no compatible sound card", or has no sound/headphones on Windows 10/11 Dell or HP PCs with Intel SST (INTELAUDIO) audio; also use for legacy audio apps that reject modern audio enumerators or need an HDAUDIO-compatible codec driver.
---

# SRS Audio Sandbox on Modern Windows

## Overview

SRS Audio Sandbox 1.10.x (2009) only recognizes PCI/HDAUDIO-era sound cards. Modern Intel Smart Sound Technology (SST) enumerates the Realtek codec as `INTELAUDIO\...`; the app's user-mode check rejects it even when the SRS kernel driver and virtual endpoint are healthy. Third-party virtual cables (VB-Cable, VAC) cannot satisfy that check.

Verified fix: switch the audio controller from Intel SST to Microsoft HDAudio, install an OEM HDAUDIO codec driver matching the exact codec hardware ID, then repoint SRS's stored preferred output device to the new KS render interface. Verify SRS starts, the constant buzz is gone, and headphones work.

## When to Use

- SRS Audio Sandbox 1.10.x on Windows 10/11, error `没有 SRS Audio Sandbox 可用的兼容声卡` or `no compatible sound card`.
- SRS starts but headphones are silent after an audio-controller or codec-driver change.
- A 2009-era audio app works on HDAUDIO machines but rejects Intel SST/INTELAUDIO devices.
- Not for SRS activation/license failures, a missing SRS driver install, or non-Intel audio buses without adapting the controller step.

## Diagnosis (read-only)

1. Identify the controller and codec enumerator. Run `scripts/diagnose-audio.ps1` or read:
   - `Get-PnpDevice -Class MEDIA` and `Get-PnpDevice -Class System`; inspect `DEVPKEY_Device_DriverInfPath`, `Service`, `DriverDesc`, `HardwareIds`.
   - `IntcAudioBus` + `INTELAUDIO\FUNC_01...` = Intel SST mode. `HDAUDIO\FUNC_01...` = legacy mode.
2. List enabled `KSCATEGORY_RENDER` interfaces (`{65E8773E-8F56-11D0-A3B9-00A0C9223196}`) and the SRS config:
   - In SST mode the only enabled physical interface is often `...\RearLineOutWaveSST`.
   - In HDAUDIO mode expect `...\RearLineOutWave3` / `...\eSpeakerWave`.
   - SRS config: `HKCU\Software\SRS Labs\...\defaultAudioDevice` (search recursively; the app may use `SRS HD Audio Lab`).
3. Confirm the SRS driver is healthy: `SRS_SSCFilter` RUNNING, `ROOT\MEDIA\0002` status OK, SRS endpoint present.
4. Treat virtual cables as a red herring: VB-Cable/VAC enumerate as `ROOT\MEDIA\...`, are rejected by the app, and are not needed — SRS provides its own virtual card.

## Fix (verified sequence)

1. **Back up and restore point.** Export the SRS config and record the controller's current INF/service. Create a Windows restore point if available.
2. **Switch the controller to Microsoft HDAudio.**
   - `scripts/switch-controller-to-hdaudio.ps1` (dry run), then `-Apply`.
   - It auto-detects the Intel SST audio controller and force-installs `%WINDIR%\INF\hdaudbus.inf` through `UpdateDriverForPlugAndPlayDevicesW`.
   - Reboot. Verify controller = `High Definition Audio Controller` / `HDAudBus`, and codec = `HDAUDIO\FUNC_01&VEN_10EC&DEV_xxxx&SUBSYS_...`.
3. **Install an OEM HDAUDIO codec driver matching the codec.**
   - Do not stop at Microsoft's generic `hdaudio.inf`: audio may play but codec amp/jack initialization can be incomplete (constant buzz, no headphones).
   - Find an INF containing the exact `HDAUDIO\FUNC_01&VEN_10EC&DEV_xxxx&SUBSYS_...` (or a generic codec entry). Prefer the OEM DUP or Microsoft Update Catalog.
   - Inspect packages with `scripts/inspect-driver-package.ps1`. Install the matching INF: `pnputil /add-driver <inf> /install`.
   - Avoid packages/components that install Intel SST (`IntcAudioBus`, `IntcSST`, `IntcDMic`, `IntcOED`); they revert the controller. If an OEM DUP contains them, install only its HDAUDIO INF (and service if needed) or reapply step 2 afterwards.
   - Verify: codec DriverDesc = Realtek Audio, DriverInfPath = the OEM HDAUDIO INF, no INTELAUDIO instance for this codec, no buzz.
4. **Repoint SRS to the new KS render interface.**
   - Close SRS first, or pass `-StopApp`.
   - `scripts/fix-srs-device.ps1 -Apply` (backs up the old value, finds the active non-SRS/non-virtual `KSCATEGORY_RENDER` interface, writes `defaultAudioDevice`). If several physical interfaces are active, pass `-InterfacePath "<path from the diagnosis>"`.
   - Or use SRS Options → Preferences and select the Realtek “Speakers/Headphones” device.
   - Required when headphones are silent after the switch: SRS often still stores `INTELAUDIO...\REARLINEOUTWAVESST`, which no longer exists.
5. **Verify.**
   - Launch SRS: no “no compatible sound card” dialog.
   - Play audio and toggle SRS on/off; processing is audible.
   - Plug headphones: sound switches; no constant buzz.
   - Reboot and repeat; confirm controller, codec driver, and SRS config persist.
6. **Rollback if audio breaks.** `scripts/rollback-controller.ps1 -Apply` restores the original OEM SST INF (from the backup written in step 1); reboot. Normal audio returns but SRS will fail again. Reinstall the OEM SST package if its INF is no longer in the driver store.

## Common Mistakes

| Mistake | Why it fails | Correct action |
|---|---|---|
| Installing VB-Cable/VAC so SRS “has a card” | App rejects ROOT virtual devices; SRS already has its own virtual card | Remove/disable virtual cables; use the SRS endpoint |
| Stopping after Microsoft’s generic “High Definition Audio Device” | Basic audio works, but amp/jack init is incomplete: constant buzz, headphones dead | Install the OEM HDAUDIO INF matching the codec SUBSYS |
| Installing a full OEM DUP without inspecting it | DUP may include Intel SST bus drivers and revert the controller | Inspect INFs; skip SST components or reapply HDAudio |
| Only switching the controller | SRS starts, but headphones stay silent because the app stores the old SST path | Update SRS `defaultAudioDevice` to the new active render interface |
| Assuming the headphone jack is broken | Jack may be fine; audio is routed to a stale device | Test direct Realtek output, then fix the app path |
| Reaching for compatibility mode or test signing | Does not change the enumerator; security downgrade | Fix the audio-stack identity first |
| Editing/signing INF files | Unsigned package rejected or insecure | Use signed OEM/Catalog packages with a matching SUBSYS |

## References

- `references/oem-driver-playbook.md` — Dell/HP/Windows Update Catalog acquisition, extraction, verification, exact diagnostic commands, and the REA/Frida evidence appendix.
- `scripts/diagnose-audio.ps1` — controller/codec/KS-interface/endpoint/SRS report.
- `scripts/switch-controller-to-hdaudio.ps1` — force Microsoft HDAudio controller; writes a rollback backup.
- `scripts/rollback-controller.ps1` — restore the original OEM SST controller driver.
- `scripts/fix-srs-device.ps1` — update SRS's stored preferred output device with backup.
- `scripts/inspect-driver-package.ps1` — classify extracted INFs (HDAUDIO exact/generic, SST-only, SST components, service).

## Portable Use

Copy this folder to `%USERPROFILE%\.claude\skills\` (or `~/.claude/skills/`) on the target PC. On HP machines, follow the HP section of the playbook; the decision tree is the same. The scripts write backups next to themselves by default; pass `-BackupPath` if the skill folder is read-only.
