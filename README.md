# Aerial Wallpaper Converter

一个原生 SwiftUI macOS 应用，将短视频转换成带有 HEVC temporal sample groups 的 Aerial 兼容视频，并安全替换当前用户的 macOS 动态壁纸文件。

当前版本：**0.4.0**

## 功能

- 拖拽视频、文件选择器或路径输入；支持 `.mov`、`.mp4`、`.m4v`。
- 默认目标 UUID：`00BA71CD-2C54-415A-A68A-8358E677D750`，也可选择已安装 Aerial 或手动输入 UUID。
- 自动读取时长并计算循环次数，默认生成约 300 秒的视频。
- 默认 12 Mbps、HEVC Main 10 编码。
- 强制验证 `sgpd 'tscl'`、`sgpd 'tsas'`、`csgm 'tscl'`、`csgm 'tsas'` 四项标记。
- 替换前同时保存应用备份和应用文件夹中 `壁纸` 目录的连续编号归档。
- 如果输入视频比例与主显示器不同，编码时会按主显示器比例补边，原画面保持比例且不被拉伸或裁剪。
- 使用 SHA-256 校验和临时文件原子替换，失败时不安装；安装失败会尝试恢复备份。
- 支持恢复历史备份、打开日志、检查旧的自动 LaunchAgent。
- 支持快速打开系统动态壁纸文件夹，并可为应用归档填写自定义名称。
- 第二个“历史壁纸”选项卡提供首帧缩略图、放大预览、重命名、删除和快速替换。
- 不常驻后台，不使用 `killall WallpaperAerialsExtension`，不需要 root 或关闭 SIP。
- 编码器源文件随应用打包，正常使用无需连接 GitHub；应用内置简约 Logo 和 macOS AppIcon。

## 系统要求

- macOS 13 或更高版本；编码器使用 Apple VideoToolbox，推荐 Apple Silicon。
- Xcode Command Line Tools（提供 `swiftc`）。
- Git 和 Python 3（Python 3 仅用于 `groups.py` 验证）。
- 目标动态壁纸必须已经在“系统设置 → 壁纸”中下载并应用过，目标 `.mov` 才会存在。

首次点击“处理并替换”时，应用会优先使用随应用打包的编码器源文件，并缓存编译结果到：

```text
~/Library/Application Support/WallpaperConverter/Encoder/macos-custom-video-wallpaper-fix-bundled-v2
```

因此，即使 GitHub 无法连接，已打包的应用仍可准备并编译编码器。只有在应用资源缺失时，才会使用网络下载作为后备路径。应用不会删除已有的旧编码器目录，也不会自动执行 `git pull`。上游项目接口和原理见 [macos-custom-video-wallpaper-fix](https://github.com/AlexisBCD/macos-custom-video-wallpaper-fix)，对应源文件和 MIT License 位于本仓库的 `ThirdParty/` 目录。

## 从 Wallpaper Engine 获取并准备壁纸

macOS 版 Wallpaper Engine 目前不能直接运行，因此通常需要在 Windows 环境中导出视频；也可以使用其他支持导出视频的壁纸网站或应用。

以 Steam 版 Wallpaper Engine 为例：

1. 订阅一个壁纸。
2. 右键壁纸，选择“发送至移动设备”。
3. 在移动设备页面点击“导出 `.mpkg` 文件”。
4. 在弹窗中选择“预渲染：高性能”。
5. 视频裁剪选择“保持原始宽高比”。
6. 帧率选择 `60`，然后导出。

如果导出的壁纸包含场景或是 `.pkg` / `.mpkg` 格式，可以使用 Windows 版 `RePKG-GUI_v1.0.1` 将其提取为 `.mp4`。该工具疑似不支持 macOS，请在 Windows 电脑或 Windows 虚拟机中完成这一步；不要在 macOS 上直接运行 ZIP 中的 `.exe` 文件。操作参考：[1分钟教会你提取 Wallpaper Engine 动态壁纸 pkg 格式 RePKG-GUI 软件使用教程](https://www.bilibili.com/video/BV1fKkuBtEtQ/?share_source=copy_web&vd_source=bd22f6255144a26beb7e590998543f34)。

得到 `.mp4` 后，可以使用其他视频工具转换为 `.mov`。一个在线参考工具是 [SubHero 视频转换器](https://subhero.io/zh-Hans/tools/video-converter)。上传私人或敏感视频到第三方网站前，请先确认其隐私政策；也可以使用本地视频转换工具。

## 壁纸处理全流程

1. 准备一个 `.mov` 文件。应用也接受 `.mp4` 和 `.m4v`，会统一交给内置编码器处理。
2. 打开应用，将视频拖入窗口，或点击“选择文件”，也可以在路径输入框中粘贴完整路径。
3. 确认目标动态壁纸 UUID。默认目标为 `00BA71CD-2C54-415A-A68A-8358E677D750`；也可以从当前动态壁纸目录选择其他已安装壁纸或手动输入 UUID。需要定位目录时，可点击应用中的“打开动态壁纸文件夹”。
4. 确认目标时长和码率。默认目标时长为 300 秒，码率为 12 Mbps，应用会根据原视频时长自动计算循环次数。
5. 点击“处理并替换”并确认。应用会检查开发环境和磁盘空间，使用 HEVC Main 10 编码，然后验证 `sgpd/csgm` 中的 `tscl` 与 `tsas` 四项标记。
6. 验证通过后，应用确认目标文件存在，备份原动态壁纸，并将原文件复制到应用文件夹的 `壁纸` 目录，按 `1-UUID.mov`、`2-UUID.mov` 的顺序编号；也可以在“归档名称（可选）”中填写自定义名称，例如 `1-我的夜景.mov`。
7. 如果输入视频比例与主显示器不同，应用会生成匹配显示器比例的画布并居中补边，原画面不拉伸、不裁剪；随后新视频会先复制到目标目录中的临时文件，完成 SHA-256 校验后再原子替换目标文件。
8. 应用只重载一次 `WallpaperAgent`。完成后打开“系统设置 → 壁纸”，重新点击对应动态壁纸。
9. 使用 `Control + Command + Q` 锁屏，连续测试至少 5 次“锁屏 → 解锁”。桌面保持静态是正常的；黑屏、冻结或第二次不播放时，请在应用中恢复备份。

应用不会通过常驻脚本在每次解锁后杀掉壁纸进程，也不会修改系统保护目录。

## 构建

```bash
./build_app.sh
open dist/WallpaperConverter.app
```

这是一个本地未签名应用。首次运行时 macOS 可能需要在“系统设置 → 隐私与安全性”中允许打开。

应用没有启用 App Sandbox，因为它需要访问当前用户的：

```text
~/Library/Application Support/com.apple.wallpaper/aerials/videos/
```

应用只操作用户目录，不修改 `/System`、`/System/Library`，也不要求 sudo。

## 历史壁纸

第二个“历史壁纸”选项卡读取应用归档目录中的视频，并为每个视频截取首帧 JPEG 预览（最大尺寸为 1920×1080，并按原比例缩放）。点击缩略图后，可以在下方查看放大预览、编辑名称、快速替换当前目标、打开视频或显示所在文件夹。删除操作会同时删除归档视频和对应预览。

归档名称默认是 `编号-UUID`，如果之前填写了自定义归档名则显示自定义文件名；重命名会同步更新视频文件名和预览文件名，并保留原编号及目标 UUID 元数据。

## 处理结果位置

- 编码输出：`~/Library/Application Support/WallpaperConverter/Processed/`
- 应用备份：`~/Library/Application Support/WallpaperConverter/Backups/`
- 被替换的原文件：`~/Library/Application Support/WallpaperConverter/壁纸/数字-UUID.mov`
- 首帧预览：`~/Library/Application Support/WallpaperConverter/壁纸/预览/数字-UUID.jpg`
- 历史壁纸名称与目标 UUID：`~/Library/Application Support/WallpaperConverter/壁纸/metadata.json`
- 日志：`~/Library/Logs/WallpaperConverter.log`

首次使用或点击“打开归档文件夹”时，如果 `壁纸` 目录不存在，应用会自动创建应用支持目录及其预览目录。旧版本桌面 `~/Desktop/壁纸` 中的 `.mov` 归档会在读取历史壁纸时安全迁移到新目录。

完成后请在系统设置中重新点击对应动态壁纸，并连续测试 5 次“锁屏 → 解锁”。桌面保持静态是正常现象；如果出现黑屏、冻结或第二次不播放，可在应用中恢复备份。

## 安全流程

1. 检查 Command Line Tools、Swift、Git、Python 3 和 Aerial 目录。
2. 检查至少 1.5 GB 可用磁盘空间。
3. 准备或编译上游 temporal encoder。
4. 编码并验证四项 temporal sample groups。
5. 确认目标 UUID 文件存在。
6. 备份原文件并保存应用目录中的编号归档及首帧预览。
7. 复制到目标目录中的临时文件，校验后原子替换。
8. 校验目标 SHA-256，并只重载一次 `WallpaperAgent`。

任一关键步骤失败都会停止安装，并保留原始目标文件。

## 版本更新

版本历史记录在 [CHANGELOG.md](CHANGELOG.md)。
