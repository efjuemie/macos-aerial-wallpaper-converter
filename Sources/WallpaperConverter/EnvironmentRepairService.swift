import AppKit
import Foundation

enum EnvironmentRepairService {
    static let releasesURL = URL(string: "https://github.com/efjuemie/macos-aerial-wallpaper-converter/releases")!

    static func perform(_ action: EnvironmentAction) async -> String? {
        switch action {
        case .none, .refresh:
            return nil
        case .openSoftwareUpdate:
            openSystemSettings("x-apple.systempreferences:com.apple.Software-Update-Settings.extension")
            return nil
        case .installCommandLineTools:
            return await installCommandLineTools()
        case .openWallpaperSettings:
            openSystemSettings("x-apple.systempreferences:com.apple.Wallpaper-Settings.extension")
            return nil
        case .openStorageSettings:
            openSystemSettings("x-apple.systempreferences:com.apple.Storage-Settings.extension")
            return nil
        case .disableOldLaunchAgent:
            return nil
        case .reinstallApplication:
            NSWorkspace.shared.open(releasesURL)
            return nil
        case let .showHelp(message):
            return message
        }
    }

    private static func openSystemSettings(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }

    private static func installCommandLineTools() async -> String? {
        let executable = URL(fileURLWithPath: "/usr/bin/xcode-select")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            return "未找到 macOS 官方开发工具安装器，请通过系统设置→通用→软件更新安装。"
        }
        do {
            let result = try await CommandRunner.run(executable, arguments: ["--install"])
            if result.status == 0 {
                return "已唤起 macOS 官方 Command Line Tools 安装器；完成后点击“重新检测”。"
            }
            let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            return output.isEmpty
                ? "无法唤起 Command Line Tools 安装器，请打开系统设置→通用→软件更新。"
                : "无法唤起 Command Line Tools 安装器：\n\(output)"
        } catch {
            return "无法唤起 Command Line Tools 安装器：\(error.localizedDescription)"
        }
    }
}
