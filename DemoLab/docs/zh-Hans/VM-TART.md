<!-- LANGUAGE-LINKS:START -->
[English](../VM-TART.md) · [한국어](../ko/VM-TART.md) · [日本語](../ja/VM-TART.md) · [简体中文](VM-TART.md) · [繁體中文](../zh-Hant/VM-TART.md)
<!-- LANGUAGE-LINKS:END -->

<a id="recording-in-a-tart-vm"></a>
# 在 Tart VM 中录制

专用 `tatami-demo` 隔离个人窗口、偏好和权限。当前使用 macOS 26.6.2、固定 1920×1200 主屏、实际 Tatami 和八个演示应用；第二屏来自 VM 内虚拟显示器，见 [MULTI-DISPLAY.md](MULTI-DISPLAY.md)。

<a id="prepare-the-guest"></a>
## 准备虚拟机

主机需 Apple silicon 和支持 `exec` 的 Tart，VM 需代理、Command Line Tools、Python 3 和 Tatami。除非明确进入 VM，否则从 `DemoLab/` 执行命令。

```sh
./vm/tart/host-bootstrap.sh
```

通过 `1920x1200px` 和 `--no-display-refit` 固定分辨率，调整主机 VM 窗口不改变录制画布，共享挂载于 `/Volumes/My Shared Files/demolab`。

通过单独的共享提供要演示的 Tatami 构建：

```sh
# Include both shares when starting the dedicated VM.
tart run tatami-demo --dir="demolab:$PWD" --dir="tatami:/Applications"

# From a separate host terminal:
tart exec tatami-demo /bin/bash -lc \
  'TATAMI_APP="/Volumes/My Shared Files/tatami/Tatami.app" \
   "/Volumes/My Shared Files/demolab/vm/tart/guest-provision.sh"'
```

也接受 `TATAMI_DMG` 代替 `TATAMI_APP`。SwiftPM 在虚拟机本地磁盘构建，打包时把全部演示应用注册到 LaunchServices，以便按包 ID 解析。

通过 VM 窗口或屏幕共享打开，按 [PERMISSIONS.md](PERMISSIONS.md) 在系统设置中授权，同时测试录制器与置顶。当前代理路径有捕获和输入权限，但新镜像或启动器需另查。不要修改 TCC 行，也不能仅凭录制器预热判断镜像权限。

<a id="record-an-explicit-batch"></a>
## 录制明确的批次

```sh
# Host: sync current sources and rebuild in the guest.
./vm/tart/sync.sh

# Guest: each scene gets fresh lab data and preferences suppression.
tart exec tatami-demo /bin/bash -lc \
  'cd ~/DemoLab && python3 scripts/capture.py --continue-on-error \
   --output /Users/admin/DemoLab/recordings/review-batch'

# Host: a new destination, retaining originals and all provenance sidecars.
GUEST_DIR=DemoLab/recordings/review-batch \
  ./vm/tart/fetch-recordings.sh recordings/review-batch

python3 scripts/export.py --takes recordings/review-batch \
  --output ~/Downloads/TatamiDemoLab-review
```

用 `--scenes tour cli desk` 排练子集，不覆盖已有录制。`--continue-on-error` 保留失败、在场景间清理，任一失败即返回非零码。`capture-report.json` 记录各项结果，只导出匹配当前场景的通过片段。

录制时避免主机进行繁重编码或编译。VM 与主机共享 CPU，丢帧逐显示器计量，应在录制结束后编码。

<a id="shared-filesystem-correctness"></a>
## 共享文件系统正确性

两向传输都使用唯一归档名。实测主机移动旧文件后，virtiofs 重写同名文件可能暴露旧字节或旧 inode；新名称消除了该复用路径。

只同步受管源码目录，删除的 Swift 文件不会留在 VM，保留 `.build` 与录像。通过唯一标记确认共享位置，比较两端 SHA256，再解压到新目录。包含影片、字幕、时间线、元数据、冻结场景与批次报告。

<a id="finish-or-preserve-the-image"></a>
## 结束或保存镜像

```sh
tart exec tatami-demo /bin/bash -lc \
  'cd ~/DemoLab && ./bin/democtl quit && ./bin/democtl display disconnect && ./bin/democtl restore'
```

`restore` 恢复录制前备份的偏好，不涉及个人主机设置。关闭并验证的 VM 可用 `tart clone` 保存，淘汰镜像前请先把原始文件和证据存到外部。

<a id="verified-boundary"></a>
## 已验证边界

v4 验证了实际 ScreenCaptureKit、输入与 AX 回读、平铺和借用、独立双屏捕获、工作区链及连接断开自动方案。实体扩展坞、手势、混合 DPI/HDR 和新系统需另查；原生全屏恢复失败见 [COVERAGE.md](COVERAGE.md)。
