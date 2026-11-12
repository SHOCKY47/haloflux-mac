# HaloFlux for macOS v0.1

**原作 / Original work: [HALOFLUX by Ryder191 (RYDER CODE / Ms MAIKEBAIs CAT)](https://github.com/Ryder191/haloflux)**

感谢 Ryder191 创作并分享原版粒子、光束与圆环视觉。此版本基于 HALOFLUX 修改，新增 macOS 桌面壁纸承载和 Orca 本地 Agent 状态接入，由本项目独立维护。

Thank you to Ryder191 for the original animation and visual design. This independent macOS adaptation preserves that artwork and adds live local Orca activity. It is not an official release from Ryder191 or Orca.

## 安装 / Install

1. 下载 **HaloFlux-v0.1-macOS-arm64.zip**，解压后双击 **Install.command**。
2. 菜单栏出现 **◉**；壁纸自动启动，并启用登录自启。
3. 打开 Orca、安装其 CLI 并开始任务，即可显示真实 Agent 活动。

**Apple Silicon（M 系列）· macOS 13+。** 不需要 Xcode、Python、Node.js 或管理员权限。GitHub 自动生成的 Source code 是源码，不是安装包。

Download the **arm64 ZIP**, extract it, and run **Install.command**. The prebuilt app installs for the current user and starts at GUI login. Requires an Apple Silicon Mac and macOS 13+. Open Orca with its CLI installed for live activity; standby visuals work without Orca.

**首次打开：本版为 ad-hoc 签名，未经过 Apple 公证。** 若 macOS 拦截，确认来源后按 [Apple 官方说明](https://support.apple.com/en-us/102445)，在“系统设置 → 隐私与安全性 → 仍要打开”中允许。详见 [README](https://github.com/SHOCKY47/haloflux-mac#快速安装)。The app is not Developer ID signed or notarized; first launch may require macOS approval.

## 本版功能 / Included

- Original detailed particles, beams, and ring animation on the macOS desktop.
- Read-only Orca workspace, model, main/sub-Agent, and tool activity display.
- Up to four eligible workspaces; 15-second transitions; fixed focus when only one is active.
- Original lavender plus red, blue, and green workspace accents.
- Slow standby ring when idle; four named default workspaces.
- Breathing inner and outer barcode ticks for confirmed human questions/approvals.
- Calm 25% default motion, menu-bar/notch spacing, automatic login startup.
- English app UI, Chinese/English documentation, installer and uninstaller.

## 范围与已知限制 / Scope

- **仅桌面壁纸。没有锁屏视频、锁屏扩展或屏保。** Desktop only; no lock-screen assets or extensions.
- arm64 only. macOS 13 is the build target; every macOS version has not been individually validated.
- Model and reply detection use version-dependent local Orca/session metadata. Basic state comes from `orca worktree ps --limit 10000 --json`.
- HaloFlux does not upload session data or control Agents. Metadata such as workspace names and short task titles may be visible on the desktop.
- `SHA256SUMS.txt` contains the installer's SHA-256 checksum. After downloading it and the ZIP into one directory, `shasum -a 256 -c SHA256SUMS.txt` compares the downloaded bytes.

## License / 许可

**Noncommercial use only.** PolyForm Noncommercial 1.0.0 plus the original notices. Source is available; this is not a permissive MIT/Apache open-source license. Keep the original copyright, [LICENSE](https://github.com/SHOCKY47/haloflux-mac/blob/v0.1/LICENSE), and attribution when redistributing or sharing imagery.

Original project: **https://github.com/Ryder191/haloflux**
