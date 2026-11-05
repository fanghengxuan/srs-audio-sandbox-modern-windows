# SRS Audio Sandbox on Modern Windows

**Fix the original SRS Audio Sandbox 1.10.x (2009) on Windows 10/11 PCs with Intel Smart Sound Technology (SST).**

The app reports `没有 SRS Audio Sandbox 可用的兼容声卡` / `no compatible sound card`, even though the SRS kernel driver and virtual endpoint are healthy.

![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)
![Platform: Windows 10 / 11](https://img.shields.io/badge/Platform-Windows%2010%20%2F%2011-blue.svg)

## 中文摘要

这个 Claude Skill 修复 2009 年的 SRS Audio Sandbox 在 Win10/Win11 上的“没有兼容声卡”问题。根因是 Realtek codec 经 Intel 智音技术（`INTELAUDIO`）枚举，而老程序只认 `HDAUDIO` 设备。流程为：诊断 → 把控制器切到 Microsoft HDAudio → 安装匹配 codec SUBSYS 的 OEM HDAUDIO 驱动 → 修正 SRS 保存的旧设备路径 → 验证或回滚。

## Symptoms

- SRS Audio Sandbox 1.10.x on Windows 10/11 shows “no compatible sound card”.
- The Realtek codec is enumerated as `INTELAUDIO\FUNC_01...` instead of `HDAUDIO\FUNC_01...`.
- SRS starts but headphones are silent after an audio-controller or codec-driver change.
- Third-party virtual cables (VB-Cable, Virtual Audio Cable) do not help: SRS already provides its own virtual card and rejects `ROOT\MEDIA` devices.

## What it does

- Diagnoses the audio controller, codec enumerator, enabled `KSCATEGORY_RENDER` interfaces, default endpoints, and the SRS config.
- Switches the Intel SST controller to the Microsoft HDAudio controller (`hdaudbus.inf`), with a rollback backup.
- Guides OEM HDAUDIO driver acquisition for Dell, HP, and the Microsoft Update Catalog; classifies extracted INFs and warns about Intel SST components.
- Repoints SRS's stored `defaultAudioDevice` to the new HDAUDIO render interface — the usual cause of “SRS starts but headphones are silent”.
- Provides verification steps and a controller rollback script.

## Install

Clone into your Claude skills directory:

```powershell
git clone https://github.com/fanghengxuan/srs-audio-sandbox-modern-windows.git "$env:USERPROFILE\.claude\skills\srs-audio-sandbox-modern-windows"
```

Or download the ZIP and extract it so that `%USERPROFILE%\.claude\skills\srs-audio-sandbox-modern-windows\SKILL.md` exists.

## Use

Ask Claude:

> Use the `srs-audio-sandbox-modern-windows` skill to fix SRS Audio Sandbox on this PC. It shows “没有 SRS Audio Sandbox 可用的兼容声卡”.

Or run the scripts manually in an elevated PowerShell:

```powershell
# Read-only diagnosis
powershell -ExecutionPolicy Bypass -File scripts\diagnose-audio.ps1

# Controller switch: dry run first, then apply and reboot
powershell -ExecutionPolicy Bypass -File scripts\switch-controller-to-hdaudio.ps1
powershell -ExecutionPolicy Bypass -File scripts\switch-controller-to-hdaudio.ps1 -Apply

# Inspect an extracted OEM driver package
powershell -ExecutionPolicy Bypass -File scripts\inspect-driver-package.ps1 `
  -Folder "C:\path\to\extracted" `
  -CodecHwid "HDAUDIO\FUNC_01&VEN_10EC&DEV_0256&SUBSYS_1028082A"

# After installing the OEM HDAUDIO INF: repoint SRS
powershell -ExecutionPolicy Bypass -File scripts\fix-srs-device.ps1
powershell -ExecutionPolicy Bypass -File scripts\fix-srs-device.ps1 -Apply -StopApp

# Rollback if needed
powershell -ExecutionPolicy Bypass -File scripts\rollback-controller.ps1 -Apply
```

Read [`SKILL.md`](SKILL.md) and [`references/oem-driver-playbook.md`](references/oem-driver-playbook.md) for the full decision tree, OEM package acquisition, and evidence notes.

## Requirements

- Windows 10 or 11, PowerShell 5.1+, administrator rights for driver changes.
- SRS Audio Sandbox 1.10.x installed, with the `SRS_SSCFilter` kernel service running.
- An OEM HDAUDIO codec driver package matching the codec hardware ID, or a Microsoft Update Catalog package. Inspect it before installing.

## Verification status

**Validated:** Dell XPS 13 9360 with an Intel SST `PCI\VEN_8086&DEV_9D71` controller and a Realtek ALC3246/ALC256 codec (`DEV_0256&SUBSYS_1028082A`).

- Before: SRS reported no compatible sound card; generic HDAudio produced constant buzz.
- After: SRS starts, buzz is gone, headphones work once the stored device path is corrected.

**Not validated:** the Dell and HP branches in the playbook are adaptation guides, not tested configurations. Treat them as a starting point and verify each step on the target machine.

## Safety and disclaimer

This skill changes audio controller and codec drivers. It can disable SST-only digital microphones and OEM audio effects. Create a restore point, keep the original OEM driver package, and test on a machine you can restore. Use at your own risk.

Not affiliated with SRS Labs, Dell, HP, Microsoft, or Realtek. OEM driver packages remain subject to their vendors' licenses. The SRS Audio Sandbox software itself is not included.

## License

MIT — see [LICENSE](LICENSE).
