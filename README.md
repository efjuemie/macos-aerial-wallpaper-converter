# Aerial Wallpaper Converter

一个原生 SwiftUI macOS 应用：将短视频转换为带有 HEVC temporal sample groups 的 Aerial 兼容视频，并安全替换当前用户的 Apple 动态壁纸文件。

## 下载与安装

### 普通用户（推荐）

普通用户无需 clone 源码。当前仓库正在准备首个 `0.8.0` 发行包，GitHub Releases 暂无可下载附件；发行包完成并发布后，请从本仓库的 [Releases](https://github.com/efjuemie/macos-aerial-wallpaper-converter/releases) 页面下载与设备匹配的 Apple Silicon DMG 或 ZIP。

安装步骤：

1. 打开 `Aerial-Wallpaper-Converter-vX.Y.Z-Apple-Silicon.dmg`。
2. 将 `WallpaperConverter.app` 拖到“应用程序”。
3. 打开应用并查看“环境检查”。
4. 如果 macOS 首次拦截应用，打开“系统设置 → 隐私与安全性”，找到本应用提示并选择“仍要打开”。当前构建为 ad-hoc 签名，不声称 Developer ID 签名或 Apple 公证。

`git clone` 得到的是项目源码，不是已经安装好的 macOS App。只有开发或调试本项目时才需要从源码构建。

### 系统要求

普通运行需要：

- macOS 13 或更高版本；
- Apple Silicon（arm64）；
- 至少一个已从“系统设置 → 壁纸”下载的 Apple 动态壁纸；
- 至少 1.5 GB 可用磁盘空间。

普通用户不需要 Git、Python 3、Xcode、Xcode Command Line Tools 或手动安装 Swift。

## 使用前必须下载 Apple 动态壁纸

本应用不会在系统设置中创建新的动态壁纸条目。请先打开“系统设置 → 壁纸”，选择并下载一个 Apple 动态壁纸，等待下载完成。应用只替换已经下载到本机的系统 `.mov` 文件；没有可用目标时，环境检查会提供“打开系统设置→壁纸”按钮。

## 快速开始

1. 打开应用，等待“环境检查”完成；按提示修复红色的运行环境项目。
2. 将 `.mov`、`.mp4` 或 `.m4v` 视频拖入窗口，或点击“选择文件”。
3. 选择已下载的目标动态壁纸，确认 UUID、目标时长和码率。
4. 如视频比例不同，拖动裁剪框；不调整则使用居中裁剪。
5. 点击“处理并替换”并确认。应用会使用内置 arm64 VideoToolbox 编码器，验证画布元数据和四项 temporal sample groups 后才会安装。
6. 完成后在系统设置中重新点击对应动态壁纸，并连续测试 5 次“锁屏 → 解锁”。

桌面保持静态是 macOS 的正常现象；若出现黑屏、冻结或第二次不播放，请在应用中恢复备份。

## 环境检查与修复

应用启动和从后台回到 active 时会自动检查：macOS 版本、Apple Silicon 架构、应用内置编码器、已下载动态壁纸和 1.5 GB 磁盘空间。只有这些 required 项目失败才会阻止处理。

检查面板中的操作包括：

- “打开软件更新”：打开 macOS 官方软件更新设置；
- “打开系统设置→壁纸”：下载 Apple 动态壁纸；
- “打开存储设置”：清理空间后重新检测；
- “重新下载应用”：打开本项目 Releases 页面，适用于内置编码器资源缺失或损坏；
- “停用旧脚本”：卸载精确的旧 LaunchAgent 服务，安全保留配置并重新检测；
- “安装开发工具”：仅为源码构建或高级恢复唤起 macOS 官方 Command Line Tools 安装器，不使用 sudo、不自动安装 Homebrew。

Git、Python 3、Swift 和 Command Line Tools 位于折叠的“开发工具”区域，不是普通运行依赖。应用运行时使用原生 Swift temporal sample group validator，不调用 Python、Git 或 swiftc。

## 功能与安全流程

- 支持拖拽、文件选择器和路径输入；自动读取时长、分辨率并计算循环次数。
- 默认使用 HEVC Main 10、12 Mbps，并保留 `sgpd 'tscl'`、`sgpd 'tsas'`、`csgm 'tscl'`、`csgm 'tsas'` 四项验证。
- 使用目标 Aerial 的可信原生画布，保留 crop 映射、fixed canvas、显式 clean aperture、1:1 像素宽高比和恒等 transform 校验。
- 安装前保存应用备份和“壁纸”目录中的连续编号原壁纸归档；成功安装的新编码视频也保存到“已编码”历史。
- 输出先写临时文件，完成 SHA-256 校验后原子替换；安装失败会尝试回滚到备份。
- WallpaperAgent 最多只重载一次；应用不常驻后台，不使用 `killall WallpaperAerialsExtension`，不要求 root，不修改 SIP 或系统保护目录。

## 完整处理流程

应用先准备裁剪布局和目标原生画布，然后验证内置 `Encoder/bin/encode_temporal` 的存在、可执行权限、arm64 架构和 manifest 中的 SHA-256。接着执行 HEVC temporal 编码，检查输出几何（encoded、natural、clean aperture、presentation）、显式元数据和四项 sample group。所有检查通过后才确认目标文件、创建备份与归档，再执行 SHA-256 校验和临时文件原子替换。

任一关键检查失败都会停止安装，原始目标文件保持不变。上游 `groups.py` 仍随源码保留作参考和许可证合规用途，但普通运行不调用它。

## 历史壁纸、备份与数据位置

应用支持“历史壁纸”选项卡，可生成首帧预览、放大查看、重命名、删除和快速替换；原壁纸与成功安装过的新编码壁纸分别标记。历史预览损坏时会在刷新时重新生成，单个项目失败不会阻塞其他项目。

数据保存在当前用户目录，不会迁移或删除旧数据：

- 编码临时输出：`~/Library/Application Support/WallpaperConverter/Processed/`；
- 应用备份：`~/Library/Application Support/WallpaperConverter/Backups/`；
- 原壁纸归档：`~/Library/Application Support/WallpaperConverter/壁纸/`；
- 已编码历史：`~/Library/Application Support/WallpaperConverter/壁纸/已编码/`；
- 原生画布记录：`~/Library/Application Support/WallpaperConverter/native-canvases.json`；
- 日志：`~/Library/Logs/WallpaperConverter.log`。

目标 Apple 动态壁纸位于：

```text
~/Library/Application Support/com.apple.wallpaper/aerials/videos/
```

## 常见问题

### 为什么没有动态壁纸可选？

先在“系统设置 → 壁纸”下载并应用至少一个 Apple 动态壁纸，再点击“重新检测”。

### 为什么提示内置编码器损坏？

发行包中的 encoder、架构或 SHA-256 manifest 校验失败。重新从 Releases 下载与设备匹配的 Apple Silicon 包；不要为普通使用安装 Xcode、Git 或 Python。

### 为什么环境检查显示 Git、Python 或 Swift 警告？

这些是开发工具提示，不会阻止普通运行。只有从源码构建或进行上游高级恢复时才需要它们。

### 为什么桌面不动或锁屏黑屏？

请在系统设置中重新点击对应动态壁纸并连续测试 5 次锁屏→解锁。若仍异常，先在应用中恢复备份；不要运行常驻杀进程脚本。

### 为什么首次打开被 macOS 拦截？

当前本地发行构建使用 ad-hoc 签名，尚未配置 Developer ID 和公证。按系统提示打开“系统设置 → 隐私与安全性 → 仍要打开”。不要把关闭 SIP 或 `xattr -dr com.apple.quarantine` 作为默认步骤。

## 从源码构建（仅开发者）

源码构建需要 macOS 13+、Apple Silicon、Xcode Command Line Tools 和 Swift。Git 只用于取得源码；Python 3 不参与普通构建或运行。

```bash
git clone https://github.com/efjuemie/macos-aerial-wallpaper-converter.git
cd macos-aerial-wallpaper-converter
./build_app.sh
open dist/WallpaperConverter.app
```

`build_app.sh` 会在构建期编译 arm64 temporal encoder、复制第三方许可证和可选源码、生成带版本/架构/SHA-256 的 manifest，并对 App 和内置 encoder 做 ad-hoc 签名与严格验证。发行包使用：

```bash
Scripts/package_release.sh
```

输出到 `dist/releases/` 的 ZIP 和 DMG 文件名会从 App 的 `Info.plist` 版本字段生成。DMG 包含 `WallpaperConverter.app` 和指向 `/Applications` 的快捷方式。当前项目没有 Developer ID 证书，因此本地包不公证。

Debug 构建可使用 `WALLPAPER_CONVERTER_FAKE_MISSING=encoder,aerial,diskSpace,git,python3,swiftc,clt,architecture,macos` 模拟缺失环境；Release 构建忽略该变量。

如需检查视频画布元数据，可执行：

```bash
swift Scripts/verify_video_geometry.swift /path/to/output.mov <宽度> <高度>
```

## Wallpaper Engine 视频准备

macOS 版 Wallpaper Engine 通常不能直接运行，可在 Windows 或 Windows 虚拟机中导出视频：订阅壁纸 → 发送至移动设备 → 导出 `.mpkg` → 选择“预渲染：高性能”、保持原始宽高比、60 FPS。若得到 `.pkg` / `.mpkg`，可使用 Windows 版 RePKG-GUI 提取 `.mp4`，再用本地视频工具转换为 `.mov`。上传私人视频到在线转换服务前请先确认隐私政策。

## 第三方许可证

内置 temporal encoder 来自 [macos-custom-video-wallpaper-fix](https://github.com/AlexisBCD/macos-custom-video-wallpaper-fix)，其 MIT License 和源码随 App 一起放在 `Contents/Resources/Encoder/` 中；上游 `groups.py` 仅作为参考实现保留。发行包不依赖在线 clone，也不会从未固定的第三方 `main` 分支下载后执行。

## 版本

当前源码版本为 **0.8.0**，完整记录见 [CHANGELOG.md](CHANGELOG.md)。
