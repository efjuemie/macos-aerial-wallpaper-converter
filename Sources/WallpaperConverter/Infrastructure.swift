import Foundation

enum AppPaths {
    static let fileManager = FileManager.default
    static let home = fileManager.homeDirectoryForCurrentUser
    static let aerialDirectory = home.appendingPathComponent(
        "Library/Application Support/com.apple.wallpaper/aerials/videos",
        isDirectory: true
    )
    static let appSupport = home.appendingPathComponent(
        "Library/Application Support/WallpaperConverter",
        isDirectory: true
    )
    static let encoderRepository = appSupport.appendingPathComponent(
        "Encoder/macos-custom-video-wallpaper-fix",
        isDirectory: true
    )
    static let bundledEncoderCache = appSupport.appendingPathComponent(
        "Encoder/macos-custom-video-wallpaper-fix-bundled-v2",
        isDirectory: true
    )
    static let processedDirectory = appSupport.appendingPathComponent(
        "Processed",
        isDirectory: true
    )
    static let backupsDirectory = appSupport.appendingPathComponent(
        "Backups",
        isDirectory: true
    )
    static let logURL = home.appendingPathComponent(
        "Library/Logs/WallpaperConverter.log"
    )
    static let archiveDirectory = appSupport.appendingPathComponent(
        "壁纸",
        isDirectory: true
    )
    static let previewDirectory = archiveDirectory.appendingPathComponent(
        "预览",
        isDirectory: true
    )
    static let encodedArchiveDirectory = archiveDirectory.appendingPathComponent(
        "已编码",
        isDirectory: true
    )
    static let archiveMetadataURL = archiveDirectory.appendingPathComponent("metadata.json")
    static let legacyDesktopArchiveDirectory = home.appendingPathComponent(
        "Desktop/壁纸",
        isDirectory: true
    )
    static let oldLaunchAgent = home.appendingPathComponent(
        "Library/LaunchAgents/com.local.wallpaper-aerial-fix.plist"
    )
    static let oldLaunchAgentDisabled = home.appendingPathComponent(
        "Library/LaunchAgents/com.local.wallpaper-aerial-fix.plist.disabled"
    )

    static var bundledEncoderRepository: URL? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent(
                "Encoder/macos-custom-video-wallpaper-fix",
                isDirectory: true
            ),
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(
                    "ThirdParty/macos-custom-video-wallpaper-fix",
                    isDirectory: true
                )
        ].compactMap { $0 }

        return candidates.first {
            fileManager.fileExists(atPath: $0.appendingPathComponent("encode_temporal.swift").path)
        }
    }

    static func ensureDirectory(_ url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

struct CommandResult: Sendable {
    let status: Int32
    let output: String
}

enum CommandRunner {
    static func executable(named name: String) -> URL? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        for directory in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    static func run(
        _ executable: URL,
        arguments: [String],
        currentDirectory: URL? = nil
    ) async throws -> CommandResult {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = pipe
            process.currentDirectoryURL = currentDirectory

            do {
                try process.run()
            } catch {
                throw AppError("无法启动命令 \(executable.lastPathComponent)：\(error.localizedDescription)")
            }

            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            return CommandResult(status: process.terminationStatus, output: output)
        }.value
    }
}

final class AppLogger {
    func write(_ message: String) {
        do {
            try AppPaths.ensureDirectory(AppPaths.logURL.deletingLastPathComponent())
            if !FileManager.default.fileExists(atPath: AppPaths.logURL.path) {
                FileManager.default.createFile(atPath: AppPaths.logURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: AppPaths.logURL)
            try handle.seekToEnd()
            let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
            try handle.write(contentsOf: Data(line.utf8))
            try handle.close()
        } catch {
            // Logging must never interrupt the conversion workflow.
        }
    }
}

enum EnvironmentChecker {
    static func check() async -> [EnvironmentCheck] {
        var checks: [EnvironmentCheck] = []

        let xcodeSelect = CommandRunner.executable(named: "xcode-select")
        if let xcodeSelect {
            do {
                let result = try await CommandRunner.run(xcodeSelect, arguments: ["-p"])
                let path = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                checks.append(EnvironmentCheck(
                    name: "Command Line Tools",
                    isOK: result.status == 0 && !path.isEmpty,
                    detail: result.status == 0 && !path.isEmpty ? path : "缺失，请执行 xcode-select --install"
                ))
            } catch {
                checks.append(EnvironmentCheck(name: "Command Line Tools", isOK: false, detail: error.localizedDescription))
            }
        } else {
            checks.append(EnvironmentCheck(name: "Command Line Tools", isOK: false, detail: "未找到 xcode-select"))
        }

        for (name, executableName) in [("Swift", "swiftc"), ("Git", "git"), ("Python 3", "python3")] {
            guard let executable = CommandRunner.executable(named: executableName) else {
                checks.append(EnvironmentCheck(name: name, isOK: false, detail: "未找到 \(executableName)"))
                continue
            }
            do {
                let result = try await CommandRunner.run(executable, arguments: ["--version"])
                let detail = result.output
                    .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
                    .first
                    .map(String.init) ?? executable.path
                checks.append(EnvironmentCheck(name: name, isOK: result.status == 0, detail: detail))
            } catch {
                checks.append(EnvironmentCheck(name: name, isOK: false, detail: error.localizedDescription))
            }
        }

        var isDirectory: ObjCBool = false
        let aerialAccessible = FileManager.default.fileExists(
            atPath: AppPaths.aerialDirectory.path,
            isDirectory: &isDirectory
        ) && isDirectory.boolValue
        checks.append(EnvironmentCheck(
            name: "Aerial 目录",
            isOK: aerialAccessible,
            detail: aerialAccessible ? AppPaths.aerialDirectory.path : "目录不存在，请先在系统设置中下载并应用动态壁纸"
        ))
        return checks
    }

    static func oldLaunchAgentStatus() async -> (isRunning: Bool, detail: String) {
        let uid = String(getuid())
        var running = false
        var reasons: [String] = []

        if let launchctl = CommandRunner.executable(named: "launchctl") {
            if let result = try? await CommandRunner.run(
                launchctl,
                arguments: ["print", "gui/\(uid)/com.local.wallpaper-aerial-fix"]
            ), result.status == 0 {
                running = true
                reasons.append("LaunchAgent 已加载")
            }
        }
        if let pgrep = CommandRunner.executable(named: "pgrep"),
           let result = try? await CommandRunner.run(pgrep, arguments: ["-fl", "wallpaper-aerial-fix"]),
           result.status == 0 {
            running = true
            reasons.append("旧修复脚本仍在运行")
        }

        return (running, reasons.isEmpty ? "未发现旧自动修复脚本" : reasons.joined(separator: "；"))
    }
}
