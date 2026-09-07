<!-- LANGUAGE-LINKS:START -->
[English](../PERMISSIONS.md) · [한국어](../ko/PERMISSIONS.md) · [日本語](../ja/PERMISSIONS.md) · [简体中文](PERMISSIONS.md) · [繁體中文](../zh-Hant/PERMISSIONS.md)
<!-- LANGUAGE-LINKS:END -->

<a id="capture-permissions"></a>
# 录制权限

通过实际录制启动路径检查权限。录制器预检通过，不代表 Tatami 可以平铺或镜像窗口。

|进程|用途|证据|
| --- | --- | --- |
|Tatami|辅助功能：移动和聚焦实际窗口|可见工作区变化和布局断言|
|Tatami|屏幕录制：置顶镜像|共享状态窗口在放大窗口上方仍可见|
|democtl / 启动器|辅助功能：键盘、指针、原生控件|实际输入和控件值断言|
|DemoRecorder / 启动器|屏幕录制：捕获显示器|首个编码帧、完成的影片与解码验证|

在**专用录制 VM**的系统设置 → 隐私与安全性中授予缺少的权限。重新启动相关进程，再运行 `democtl doctor` 和短片检查，不修改主机权限或个人 Tatami 配置。

`record start` 在调用者已有捕获权限时直接启动，否则使用 LaunchServices。当前 `tart exec` 通过预授权代理运行；这是该镜像和启动路径的实测结果，不代表所有 VM 或重建的执行文件。

<a id="a-window-can-outlive-the-process-that-requested-it"></a>
## 请求进程退出后，对话框仍可能保留

旧主视频残留请求 **Tatami** 权限的 `Screen Recording` 对话框。它被窗口遮住，关闭后才出现，旧预检只检查录制器而漏检；这不是定期录制提醒的证据。

即使被其他应用遮挡，权限或设置窗口也会被拒绝。先在 VM 中解决再重试。关闭旧请求不等于授予权限；确实缺少授权时，应在系统设置中授予并验证相关行为。

`democtl record warmup` 只测试录制器，Tatami 独立的捕获路径还需排练 `shared`。不能裁掉权限界面或把未验证录制标为成功。

<a id="repeatable-recording-image"></a>
## 可重复使用的录制镜像

构建准确的工具与应用，解决权限并验证工作后保存镜像。重建或变更启动器可能改变权限归属，应重新验证，不能复制数据库行或假定旧授权有效。直接修改 TCC 数据库的旧脚本已移除。
