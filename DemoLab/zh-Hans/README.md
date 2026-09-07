<!-- LANGUAGE-LINKS:START -->
[English](../README.md) · [한국어](../ko/README.md) · [日本語](../ja/README.md) · [简体中文](README.md) · [繁體中文](../zh-Hant/README.md)
<!-- LANGUAGE-LINKS:END -->

<a id="tatami-demo-lab"></a>
# Tatami Demo Lab

录制实际的 Tatami，导出一致的产品视频并放在对应功能说明旁。应用和内容为演示数据，工作区切换、平铺、借用和焦点由已安装的 Tatami 实际执行。

<a id="publication-contract"></a>
## 发布约定

[`publication.json`](../publication.json) 定义视频清单和编辑预算，映射网站区块并限制时长和文件大小。

主视频依次展示设计、写作、评审、借用、自动化，最后实际改变显示器拓扑。专题涵盖工作区、配置方案与显示器、平铺与焦点、借用、窗口模式、CLI/钩子和引导设置。清单由 `publication.json` 生成，无需维护重复列表。

主视频传达**切换任务，保留工作位置**。专题展示不同活动，不重复主视频。完整范围见[覆盖与证据边界](../docs/zh-Hans/COVERAGE.md)。

<a id="capture--export--review--install-locally"></a>
## 录制 → 导出 → 检查 → 本地安装

使用专用 Tart VM。`reset` 和 `seed` 会退出其运行机器上的 Tatami 并改变偏好。配置和布局隔离在 `.build/lab/`，偏好域单独备份，可通过 `democtl restore` 恢复。

```sh
# Host: copy source into the running VM and rebuild the independent Swift package.
./vm/tart/sync.sh

# Guest: a fresh seed for every scene. Existing takes are never overwritten.
tart exec tatami-demo /bin/bash -lc \
  'cd ~/DemoLab && ./scripts/record-suite.sh /Users/admin/DemoLab/recordings/publish'

# Host: fetch that exact batch, including originals, metadata and scene snapshots.
GUEST_DIR=DemoLab/recordings/publish ./vm/tart/fetch-recordings.sh recordings/publish

# Host: new output directory; no ambiguous “latest take” selection.
python3 scripts/export.py --takes recordings/publish --output ~/Downloads/TatamiDemoLab-review

# Open index.html and inspect playback, opening frames, actions and every feature.
# Install the verified bundle into this checkout only; this does not push or deploy.
python3 scripts/install-assets.py ~/Downloads/TatamiDemoLab-review
```

主机需要 `tart`、Python 3.11+、支持 libass/libx264 的 `mpv`、`ffmpeg` 和 `ffprobe`。录制器为独立 SwiftPM 包，不改变 Tuist 构建图。虚拟机需要 Command Line Tools 和 Python 3，不需要第三方 Python 包；纯字符串目录编译器不需要完整 Xcode。

导出主机还需要 Fontconfig。编码前会验证指定字体及其对全部字幕字符的支持。OCR 审核会另行比较画面上的字幕和说明时间线。

<a id="a-small-set-of-useful-apps"></a>
## 实用的演示应用

|工作区|应用|实际操作|
| --- | --- | --- |
|Design|Canvas + Docs|更改配色，检查保存的草稿并导出 PNG。|
|Write|Editor + Docs|阅读说明，编辑标题并保存草稿。|
|Review|Review + Docs|检查保存的文案，留言并批准。|
|Chat|Chat|输入并发送本地演示回复。|
|Build|Terminal|执行实际 Tatami CLI 和附带自动化脚本。|
|Notes（仅借用）|Notes|添加待办并完成检查项。|
|Focus|Canvas + Notes|在工作区内使用置顶便笺。|
|共享应用|Monitor|观察保存的项目状态或实际工作区、HUD 钩子事件。|

八个应用使用持久化本地数据。保存会改变 Review、Canvas 读取的内容，PNG 导出实际写入图片，笔记和消息在切换后保留。Terminal 只执行明确允许的命令和附带脚本；钩子接收实际 Tatami 环境。不连接聊天服务，AI 演示使用明确标记的本地示例。

<a id="what-changed-in-the-capture-contract"></a>
## 录制约定的改进

场景分为两个阶段：

- `setup` 在**录制前**完成清理、启动、工作区预热、数据和布局准备。
- `steps` 是可见演示。录制前 `openingApps` 必须有几何稳定的可见窗口；`autoopen` 是有意的例外，短暂空画面用于展示自动打开。

录制前及每个操作前后检查系统权限和设置窗口，包括被其他窗口遮住的对话框。应解决请求，不能裁掉或压制错误。

**录制器权限不等于 Tatami 权限。** 以前即使通过 `doctor`，仍残留 Tatami 屏幕录制请求。置顶使用独立 ScreenCaptureKit 流，单独预热录制器不能验证它。先运行 `shared` 并检查实际状态窗口。Monitor 不再每场景自动打开，而由 `shared` 在录制前明确启动。

`waitWindows` 等待指定应用和稳定几何。`saveLayout`/`assertLayout` 在切换、归还和放大恢复后比较相同窗口 ID 与边界；缺少、增加窗口或超过 4 点的位移都会失败。

`key`、`hold` 根据实际输入生成按键显示，不能用 `keys` 标签把 CLI 操作伪装成按键。没有首个编码帧就拒绝启动，并共享其单调时间戳以对齐字幕与影片时钟。

<a id="presentation"></a>
## 画面呈现

原始 MOV 包含完整的桌面画面。导出保留 1920×1200 分辨率，双屏视频为 1920×600。说明字幕叠加在画面下方，章节名称位于左上角，实际按键位于右上角。半透明背景确保文字在深浅色应用上都清晰可读。颜色来自网站配色，调整呈现方式无需重新录制。

仅修改字幕时，只有录制的操作、输入内容、断言和等待时间均未改变，才可复用原始视频。导出工具会验证录制时冻结的场景哈希并比较操作，然后替换原时间线上的说明文字。证据资料同时保留原始和编辑后的场景及时间线。

每次录制包含：

- `.mov`：干净的原始录像。
- `.ass`：可编辑说明和实际按键时间。
- `.timeline.json`：所有事件及起止时间。
- `.take.json`：成败、场景哈希、Tatami 版本、语言、逐输出帧数和丢帧数、捕获时基及叠加模式。
- `.scene.json`：录制开始时冻结的准确场景字节。

失败的录制会保留用于诊断，但不能导出。导出要求拍摄条件验证通过、字幕正常、丢帧率低于 1%、开场字幕及时出现，并且视频与时间线时长一致。输出必须符合时长和大小限制，使用 H.264/yuv420p，并通过 FFmpeg 完整解码。`faststart` 会将 MP4 文件头放在媒体数据之前。

导出包包含播放图库、海报、抽样验证帧、原始与输出文件的哈希及所有附属文件。自动验收不能替代观看实际操作，尤其是共享窗口镜像和焦点目标仍需目视确认。网页播放器使用原生控件和 `preload="none"`，由用户主动播放，且一次只播放一个视频。每个视频集提供缩略图列表、数量和前后按钮。每个视频还链接到相关配置键。方向键、Home/End 和单独视频链接无需展开额外面板即可使用。

双屏录制连接实际的虚拟显示器，分别捕获并按首帧时间对齐。见[已验证 VM 配置](../docs/zh-Hans/MULTI-DISPLAY.md)。

<a id="work-on-one-scene"></a>
## 调整单个场景

在专用虚拟机内执行录制命令：

```sh
./bin/democtl doctor
./bin/democtl reset
./bin/democtl seed
./bin/democtl scene tour --dry-run    # prints setup and visible steps
./bin/democtl take tour --output recordings/iteration/tour.mov
python3 scripts/export.py --takes recordings/iteration \
  --output ~/Downloads/TatamiDemoLab-iteration --scenes tour
```

`democtl scene` 使用实时叠加排练。录制 `take` 默认 `--overlay off`，发布只接受该模式；排练面板不是输出设计。`subtitle burn` 可生成观看副本，预算检查、网页编码和证据应使用 `export.py`。

结束后在虚拟机执行 `democtl quit` 和 `democtl restore`，主机原有偏好与 Tatami 不参与此流程。

<a id="development-and-reference"></a>
## 开发与参考

```sh
swift test
./scripts/bundle-apps.sh
python3 -m unittest discover -s Tests -p 'test_*.py'
```

- [场景语法](../docs/zh-Hans/SCENES.md)
- [VM 设置](../docs/zh-Hans/VM-TART.md)
- [权限](../docs/zh-Hans/PERMISSIONS.md)
- [实际多显示器录制](../docs/zh-Hans/MULTI-DISPLAY.md)

<a id="five-language-production"></a>
## 五语言制作

支持 `en`、`ko`、`ja`、`zh-Hans`、`zh-Hant`。`Localization/Localizable.xcstrings` 管理演示 UI 和初始内容，`Localization/Films.json` 管理视频标题、说明和输入，`Localization/Interface.json` 管理检查图库。没有稳定标识符时使用产品目录的 Tatami AX 标签。应用、用户命名的工作区和配置方案名称保持不变。

```sh
python3 scripts/localize-scenes.py
./vm/tart/sync.sh
# Inside the guest:
python3 scripts/capture.py --locale ko --output recordings/ko-batch
# After fetching that explicit batch to the host:
python3 scripts/export.py --locale ko --takes recordings/ko-batch --output ~/Downloads/Tatami-ko
```

每次录制同步设置演示应用与 Tatami 的语言，输入和断言使用相同文案，实际 CLI 命令及机器输出不变。最终视频为 30 fps，因此录制也使用 30 fps，避免不必要的 60 fps 采样。

`record-locales.py` 会找出各语言缺失或未通过验证的录制。它不会将英语视频视为已验证翻译 UI 的证据。失败场景会保留用于诊断，其他语言可以独立继续。

小工具窗口从右下角开始，主视频以实际动作移到左下角。调整场景时保持文档主要阅读区域清晰。

要让本地网页预览在终端命令结束后继续运行，请在此目录执行 `python3 ../scripts/preview-site.py --background`。
