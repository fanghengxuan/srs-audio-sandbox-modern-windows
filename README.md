# SRS Audio Sandbox on Modern Windows — Claude Skill

Fix the original **SRS Audio Sandbox 1.10.x (2009)** on Windows 10/11 PCs where the Realtek codec is enumerated through Intel Smart Sound Technology (SST, `INTELAUDIO`). The app reports:

> 没有 SRS Audio Sandbox 可用的兼容声卡。请向您的系统添加一个兼容设备。

or

> no compatible sound card

Third-party virtual cables (VB-Cable, Virtual Audio Cable) do **not** fix this: SRS already provides its own virtual card, and it rejects `ROOT\MEDIA` virtual devices.

## 中文简介

这个 Claude Code skill 用于修复 2009 年的原厂 SRS Audio Sandbox 在 Win10/Win11 上遇到的“没有兼容声卡”问题。根因通常是 Realtek codec 通过 Intel 智音技术（`INTELAUDIO`）枚举，而老程序只认 `HDAUDIO`/PCI 时代设备。流程包括：诊断 → 把音频控制器切到 Microsoft HDAudio → 安装匹配 codec SUBSYS 的 OEM HDAUDIO 驱动 → 修正 SRS 保存的旧设备路径 → 验证/回滚。已在 Dell XPS 13 9360（ALC3246/ALC256）上实测通过；Dell/HP 机器按 playbook 的对应分支操作。

## What it does

- Diagnoses the audio controller, codec enumerator, enabled `KSCATEGORY_RENDER` interfaces, default endpoints, and SRS config.
- Switches the Intel SST controller to the Microsoft HDAudio controller (`hdaudbus.inf`), with a rollback backup.
- Guides OEM HDAUDIO driver acquisition for Dell, HP, and the Microsoft Update Catalog; classifies extracted INFs and warns about Intel SST components.
- Repoints SRS's stored `defaultAudioDevice` to the new active HDAUDIO render interface (the usual cause of "SRS starts but headphones are silent").
- Verifies SRS starts, the constant buzz is gone, and headphones work; provides a controller rollback script.

## Install

Copy or clone this repository into your Claude skills directory:

```powershell
git clone https://github.com/fanghengxuan/srs-audio-sandbox-modern-windows.git "$env:USERPROFILE\.claude\skills\srs-audio-sandbox-modern-windows"
```

Or download the ZIP and extract it so that this path exists:

```
%USERPROFILE%\.claude\skills\srs-audio-sandbox-modern-windows\SKILL.md
```

## Use

Ask Claude:

> Use the `srs-audio-sandbox-modern-windows` skill to fix SRS Audio Sandbox on this PC. It shows "没有 SRS Audio Sandbox 可用的兼容声卡".

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

Read `SKILL.md` and `references/oem-driver-playbook.md` for the complete decision tree, OEM package acquisition steps, and evidence notes.

## Requirements

- Windows 10 or 11, PowerShell 5.1+, administrator rights for driver changes.
- SRS Audio Sandbox 1.10.x installed; its `SRS_SSCFilter` kernel service running.
- An OEM HDAUDIO codec driver package that matches the codec hardware ID, or a Microsoft Update Catalog package. Inspect it before installing.

## Safety and disclaimer

This skill changes audio controller and codec drivers. It can disable SST-only digital microphones and OEM audio effects. Create a restore point, keep the original OEM driver package, and test on a machine you can restore. Use at your own risk.

Not affiliated with SRS Labs, Dell, HP, Microsoft, or Realtek. OEM driver packages remain subject to their vendors' licenses. The SRS Audio Sandbox software itself is not included.

## Verification

The procedure was validated on a Dell XPS 13 9360 with an Intel SST `PCI\VEN_8086&DEV_9D71` controller and a Realtek ALC3246/ALC256 codec (`DEV_0256&SUBSYS_1028082A`):

- Before: SRS reported no compatible sound card; generic HDAudio produced constant buzz.
- After: SRS starts, buzz is gone, headphones work through SRS after the stored device path is corrected.

## License

MIT — see [LICENSE](LICENSE).
