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
    static let aerialManifestURL = home.appendingPathComponent(
        "Library/Application Support/com.apple.wallpaper/aerials/manifest/entries.json"
    )
    static let archiveMetadataURL = archiveDirectory.appendingPathComponent("metadata.json")
    static let nativeCanvasRecordsURL = appSupport.appendingPathComponent("native-canvases.json")
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

    static var bundledEncoderDirectory: URL? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent(
                "Encoder",
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
            fileManager.fileExists(atPath: $0.path)
        }
    }

    static var bundledEncoderBinary: URL? {
        bundledEncoderDirectory.map {
            $0.appendingPathComponent(EncoderAssetSelector.binaryRelativePath)
        }
    }

    static var bundledEncoderManifest: URL? {
        bundledEncoderDirectory.map {
            $0.appendingPathComponent(EncoderAssetSelector.manifestRelativePath)
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
        var probe = await liveProbe()
        #if DEBUG
        let fakeMissing = EnvironmentSimulation.missing(
            from: ProcessInfo.processInfo.environment["WALLPAPER_CONVERTER_FAKE_MISSING"]
        )
        probe = EnvironmentSimulation.applying(fakeMissing, to: probe)
        #endif
        return EnvironmentCheckBuilder.build(probe)
    }

    private static func liveProbe() async -> EnvironmentProbe {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let versionDetail = "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unknown"
        #endif

        let encoderDetail: String?
        if let detail = try? await EncoderService.describeBundledEncoder() {
            encoderDetail = detail
        } else {
            encoderDetail = nil
        }

        let aerialCount = AerialService.targets().count
        let freeBytes: Int64
        if let values = try? FileManager.default.attributesOfFileSystem(
            forPath: AppPaths.appSupport.deletingLastPathComponent().path
        ) {
            freeBytes = (values[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        } else {
            freeBytes = 0
        }

        let oldAgent = await oldLaunchAgentStatus()
        let commandLineToolsDetail = await commandDetail(
            named: "xcode-select",
            arguments: ["-p"]
        )
        let swiftDetail = commandLineToolsDetail == nil
            ? nil
            : await commandDetail(named: "swiftc", arguments: ["--version"])
        let gitDetail = commandLineToolsDetail == nil
            ? nil
            : await commandDetail(named: "git", arguments: ["--version"])
        let pythonDetail = await commandDetail(named: "python3", arguments: ["--version"])
        return EnvironmentProbe(
            macOSSupported: version.majorVersion >= 13,
            macOSDetail: versionDetail,
            architecture: architecture,
            encoderDetail: encoderDetail,
            aerialCount: aerialCount,
            freeBytes: freeBytes,
            oldLaunchAgentRunning: oldAgent.isRunning,
            oldLaunchAgentDetail: oldAgent.detail,
            commandLineToolsDetail: commandLineToolsDetail,
            swiftDetail: swiftDetail,
            gitDetail: gitDetail,
            pythonDetail: pythonDetail
        )
    }

    private static func commandDetail(named name: String, arguments: [String]) async -> String? {
        guard let executable = CommandRunner.executable(named: name),
              let result = try? await CommandRunner.run(executable, arguments: arguments),
              result.status == 0 else {
            return nil
        }
        return result.output
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .first
            .map(String.init)
            .flatMap { $0.isEmpty ? nil : $0 }
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
        if FileManager.default.fileExists(atPath: AppPaths.oldLaunchAgent.path) {
            let wasLoaded = running
            running = true
            reasons.append(
                wasLoaded
                    ? "发现旧 LaunchAgent 配置"
                    : "发现旧 LaunchAgent 配置（尚未加载）"
            )
        }

        return (running, reasons.isEmpty ? "未发现旧自动修复脚本" : reasons.joined(separator: "；"))
    }
}
