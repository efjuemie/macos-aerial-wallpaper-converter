# Aerial Wallpaper Converter

一个原生 SwiftUI macOS 应用，将短视频转换成带有 HEVC temporal sample groups 的 Aerial 兼容视频，并安全替换当前用户的 macOS 航拍动态壁纸文件。

当前版本：**0.1.0**

## 功能

- 拖拽视频、文件选择器或路径输入；支持 `.mov`、`.mp4`、`.m4v`。
- 默认目标 UUID：`00BA71CD-2C54-415A-A68A-8358E677D750`，也可选择已安装 Aerial 或手动输入 UUID。
- 自动读取时长并计算循环次数，默认生成约 300 秒的视频。
- 默认 12 Mbps、HEVC Main 10 编码。
- 强制验证 `sgpd 'tscl'`、`sgpd 'tsas'`、`csgm 'tscl'`、`csgm 'tsas'` 四项标记。
- 替换前同时保存应用备份和桌面 `壁纸` 文件夹中的连续编号归档。
- 使用 SHA-256 校验和临时文件原子替换，失败时不安装；安装失败会尝试恢复备份。
- 支持恢复历史备份、打开日志、检查旧的自动 LaunchAgent。
- 不常驻后台，不使用 `killall WallpaperAerialsExtension`，不需要 root 或关闭 SIP。

## 系统要求

- macOS 13 或更高版本；编码器使用 Apple VideoToolbox，推荐 Apple Silicon。
- Xcode Command Line Tools（提供 `swiftc`）。
- Git 和 Python 3（Python 3 仅用于 `groups.py` 验证）。
- 目标航拍壁纸必须已经在“系统设置 → 壁纸”中下载并应用过，目标 `.mov` 才会存在。

首次点击“处理并替换”时，应用会将上游编码器仓库缓存到：

```text
~/Library/Application Support/WallpaperConverter/Encoder/macos-custom-video-wallpaper-fix
```

应用不会删除已有编码器目录，也不会自动执行 `git pull`。上游项目接口和原理见 [macos-custom-video-wallpaper-fix](https://github.com/AlexisBCD/macos-custom-video-wallpaper-fix)。该项目采用 MIT License。

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

## 处理结果位置

- 编码输出：`~/Library/Application Support/WallpaperConverter/Processed/`
- 应用备份：`~/Library/Application Support/WallpaperConverter/Backups/`
- 被替换的原文件：`~/Desktop/壁纸/数字-UUID.mov`
- 日志：`~/Library/Logs/WallpaperConverter.log`

完成后请在系统设置中重新点击对应航拍壁纸，并连续测试 5 次“锁屏 → 解锁”。桌面保持静态是正常现象；如果出现黑屏、冻结或第二次不播放，可在应用中恢复备份。

## 安全流程

1. 检查 Command Line Tools、Swift、Git、Python 3 和 Aerial 目录。
2. 检查至少 1.5 GB 可用磁盘空间。
3. 准备或编译上游 temporal encoder。
4. 编码并验证四项 temporal sample groups。
5. 确认目标 UUID 文件存在。
6. 备份原文件并保存桌面编号归档。
7. 复制到目标目录中的临时文件，校验后原子替换。
8. 校验目标 SHA-256，并只重载一次 `WallpaperAgent`。

任一关键步骤失败都会停止安装，并保留原始目标文件。

## 版本更新

版本历史记录在 [CHANGELOG.md](CHANGELOG.md)。
