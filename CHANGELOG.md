# 更新记录

## 0.3.0 — 2026-09-09

- 修复选择或拖入视频后“处理并替换”按钮一直灰置的问题，增加视频读取状态提示，并统一拖拽文件 URL 解析路径。
- 在目标动态壁纸区域增加“打开动态壁纸文件夹”快捷入口。
- 被替换文件继续使用自动编号归档，同时支持填写自定义名称，例如 `1-我的夜景.mov`。
- 将界面、README 和处理提示中的壁纸称谓统一为“动态壁纸”。

## 0.2.0 — 2026-09-09

- 修复首次使用时强制从 GitHub 下载编码器导致的网络失败：将编码器源文件、验证脚本和许可证随应用打包，离线环境可正常准备编码器。
- 增加新的 Aerial Wallpaper Converter Logo 和 macOS AppIcon。
- README 增加 Wallpaper Engine 获取、`.pkg/.mpkg` 提取、RePKG-GUI（Windows）和 `.mp4` 转 `.mov` 的完整准备流程。

## 0.1.0 — 2026-09-09

- 初始 SwiftUI macOS 应用。
- 支持拖拽、文件选择和路径输入。
- 集成上游 VideoToolbox temporal encoder 的自动下载、编译和缓存。
- 支持时长读取、循环次数计算、12 Mbps 默认码率和四项 sample group 验证。
- 增加备份、桌面连续编号归档、SHA-256 校验、原子替换和恢复功能。
- 增加 WallpaperAgent 重载、旧 LaunchAgent 检测、日志及系统设置引导。
