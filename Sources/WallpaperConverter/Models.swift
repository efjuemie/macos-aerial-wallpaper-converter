import AVFoundation
import Foundation

struct InputVideoInfo: Equatable, Sendable {
    let url: URL
    let duration: Double
    let width: Int
    let height: Int
    let fileSize: Int64

    var suggestedLoopCount: Int {
        max(1, Int(ceil(300.0 / duration)))
    }

    var durationText: String {
        let totalSeconds = Int(duration.rounded())
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    var fileSizeText: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }
}

struct AerialTarget: Identifiable, Hashable, Sendable {
    let uuid: String
    let url: URL

    var id: String { uuid }
}

struct AerialCanvas: Codable, Equatable, Hashable, Sendable {
    let width: Int
    let height: Int

    var aspect: Double {
        Double(width) / Double(height)
    }
}

struct NativeCanvasResolution: Equatable, Sendable {
    let canvas: AerialCanvas
    let shouldPersist: Bool
}

enum NativeCanvasResolver {
    static func resolve(
        persistedCanvas: AerialCanvas?,
        manifestCanvas: AerialCanvas?,
        targetCanvas: AerialCanvas?,
        hasAnyHistoricalRecords: Bool,
        earliestOriginalCanvas: AerialCanvas?,
        earliestBackupCanvas: AerialCanvas?
    ) -> NativeCanvasResolution? {
        if let manifestCanvas, isValid(manifestCanvas) {
            return NativeCanvasResolution(
                canvas: manifestCanvas,
                shouldPersist: persistedCanvas != manifestCanvas
            )
        }
        if let persistedCanvas, isValid(persistedCanvas) {
            return NativeCanvasResolution(canvas: persistedCanvas, shouldPersist: false)
        }
        if !hasAnyHistoricalRecords,
           let targetCanvas,
           isValid(targetCanvas) {
            return NativeCanvasResolution(canvas: targetCanvas, shouldPersist: true)
        }
        if hasAnyHistoricalRecords,
           let earliestOriginalCanvas,
           let earliestBackupCanvas,
           earliestOriginalCanvas == earliestBackupCanvas,
           isValid(earliestOriginalCanvas) {
            return NativeCanvasResolution(
                canvas: earliestOriginalCanvas,
                shouldPersist: true
            )
        }
        return nil
    }

    private static func isValid(_ canvas: AerialCanvas) -> Bool {
        canvas.width > 1 && canvas.height > 1 && canvas.width.isMultiple(of: 2) && canvas.height.isMultiple(of: 2)
    }
}

struct BackupEntry: Identifiable, Hashable, Sendable {
    let url: URL
    let date: Date
    let size: Int64

    var id: URL { url }

    var displayName: String {
        "\(url.deletingPathExtension().lastPathComponent) · " +
        DateFormatter.backupDisplay.string(from: date)
    }
}

enum WallpaperArchiveKind: String, Codable, Sendable {
    case original
    case encoded
}

struct WallpaperArchiveMetadata: Codable, Sendable {
    let uuid: String?
    var displayName: String
    let kind: WallpaperArchiveKind?
}

struct WallpaperArchiveEntry: Identifiable, Hashable, Sendable {
    let url: URL
    let previewURL: URL
    let number: Int
    let uuid: String?
    let displayName: String
    let kind: WallpaperArchiveKind

    var id: URL { url }

    var defaultDisplayName: String {
        url.deletingPathExtension().lastPathComponent
    }

    var editableName: String {
        guard kind == .original else { return displayName }
        let prefix = "\(number)-"
        guard displayName.hasPrefix(prefix) else { return displayName }
        return String(displayName.dropFirst(prefix.count))
    }

    var kindLabel: String {
        kind == .encoded ? "已编码" : "原壁纸"
    }
}

struct WallpaperCropSelection: Equatable, Sendable {
    let sourceWidth: Double
    let sourceHeight: Double
    let cropWidth: Double
    let cropHeight: Double
    let outputWidth: Int
    let outputHeight: Int
    let visibleAspect: Double
    var originX: Double
    var originY: Double

    mutating func clamp() {
        guard let range = WallpaperGeometry.achievableOriginRange(for: self) else {
            originX = max(0, (sourceWidth - cropWidth) / 2)
            originY = max(0, (sourceHeight - cropHeight) / 2)
            return
        }
        originX = min(max(range.minX, originX), range.maxX)
        originY = min(max(range.minY, originY), range.maxY)
    }
}

struct WallpaperCropOriginRange: Equatable, Sendable {
    let minX: Double
    let maxX: Double
    let minY: Double
    let maxY: Double
}

struct WallpaperRenderPlacement: Equatable, Sendable {
    let scale: Double
    let translationX: Double
    let translationY: Double
}

enum WallpaperGeometry {
    static func cropSelection(
        sourceWidth: Double,
        sourceHeight: Double,
        screenAspect: Double,
        outputCanvas: AerialCanvas
    ) -> WallpaperCropSelection? {
        guard sourceWidth > 1,
              sourceHeight > 1,
              screenAspect > 0,
              outputCanvas.width > 1,
              outputCanvas.height > 1 else {
            return nil
        }
        let sourceAspect = sourceWidth / sourceHeight
        let outputAspect = Double(outputCanvas.width) / Double(outputCanvas.height)
        let cropWidth: Double
        let cropHeight: Double
        if outputAspect > screenAspect {
            cropHeight = evenFloor(min(sourceHeight, sourceWidth / outputAspect))
            cropWidth = min(sourceWidth, cropHeight * screenAspect)
        } else if outputAspect < screenAspect {
            cropWidth = evenFloor(min(sourceWidth, sourceHeight * outputAspect))
            cropHeight = min(sourceHeight, cropWidth / screenAspect)
        } else if sourceAspect > screenAspect {
            cropHeight = evenFloor(sourceHeight)
            cropWidth = min(sourceWidth, cropHeight * screenAspect)
        } else {
            cropWidth = evenFloor(sourceWidth)
            cropHeight = min(sourceHeight, cropWidth / screenAspect)
        }
        var selection = WallpaperCropSelection(
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            cropWidth: cropWidth,
            cropHeight: cropHeight,
            outputWidth: outputCanvas.width,
            outputHeight: outputCanvas.height,
            visibleAspect: screenAspect,
            originX: (sourceWidth - cropWidth) / 2,
            originY: (sourceHeight - cropHeight) / 2
        )
        guard achievableOriginRange(for: selection) != nil else { return nil }
        selection.clamp()
        return selection
    }

    static func achievableOriginRange(
        for selection: WallpaperCropSelection
    ) -> WallpaperCropOriginRange? {
        let outputWidth = Double(selection.outputWidth)
        let outputHeight = Double(selection.outputHeight)
        guard selection.sourceWidth > 1,
              selection.sourceHeight > 1,
              selection.cropWidth > 1,
              selection.cropHeight > 1,
              outputWidth > 1,
              outputHeight > 1,
              selection.visibleAspect > 0 else {
            return nil
        }
        let scale = min(
            outputWidth / selection.cropWidth,
            outputHeight / selection.cropHeight
        )
        guard scale > 0,
              selection.sourceWidth * scale >= outputWidth - 0.01,
              selection.sourceHeight * scale >= outputHeight - 0.01 else {
            return nil
        }
        let horizontalMargin = max(0, (outputWidth / scale - selection.cropWidth) / 2)
        let verticalMargin = max(0, (outputHeight / scale - selection.cropHeight) / 2)
        let minX = horizontalMargin
        let maxX = selection.sourceWidth - selection.cropWidth - horizontalMargin
        let minY = verticalMargin
        let maxY = selection.sourceHeight - selection.cropHeight - verticalMargin
        guard minX <= maxX + 0.01, minY <= maxY + 0.01 else { return nil }
        return WallpaperCropOriginRange(
            minX: minX,
            maxX: max(minX, maxX),
            minY: minY,
            maxY: max(minY, maxY)
        )
    }

    static func renderPlacement(for selection: WallpaperCropSelection) -> WallpaperRenderPlacement {
        let outputWidth = Double(selection.outputWidth)
        let outputHeight = Double(selection.outputHeight)
        let selectedScale = min(
            outputWidth / selection.cropWidth,
            outputHeight / selection.cropHeight
        )
        let fillScale = max(
            outputWidth / selection.sourceWidth,
            outputHeight / selection.sourceHeight
        )
        let scale = max(selectedScale, fillScale)
        let centerX = selection.originX + selection.cropWidth / 2
        let centerY = selection.originY + selection.cropHeight / 2
        let desiredX = outputWidth / 2 - centerX * scale
        let desiredY = outputHeight / 2 - centerY * scale
        return WallpaperRenderPlacement(
            scale: scale,
            translationX: min(0, max(outputWidth - selection.sourceWidth * scale, desiredX)),
            translationY: min(0, max(outputHeight - selection.sourceHeight * scale, desiredY))
        )
    }

    static func visibleSourceRectAfterSystemCrop(
        selection: WallpaperCropSelection,
        screenAspect: Double? = nil
    ) -> CGRect {
        let screenAspect = screenAspect ?? selection.visibleAspect
        let outputWidth = Double(selection.outputWidth)
        let outputHeight = Double(selection.outputHeight)
        let outputAspect = outputWidth / outputHeight
        let visibleWidth: Double
        let visibleHeight: Double
        if outputAspect > screenAspect {
            visibleWidth = outputHeight * screenAspect
            visibleHeight = outputHeight
        } else {
            visibleWidth = outputWidth
            visibleHeight = outputWidth / screenAspect
        }
        let outputOriginX = (outputWidth - visibleWidth) / 2
        let outputOriginY = (outputHeight - visibleHeight) / 2
        let placement = renderPlacement(for: selection)
        return CGRect(
            x: (outputOriginX - placement.translationX) / placement.scale,
            y: (outputOriginY - placement.translationY) / placement.scale,
            width: visibleWidth / placement.scale,
            height: visibleHeight / placement.scale
        )
    }

    private static func evenFloor(_ value: Double) -> Double {
        Double(max(2, Int(value.rounded(.down)) & ~1))
    }
}

enum EnvironmentStatus: Equatable, Sendable {
    case checking
    case ok
    case warning
    case error
}

enum EnvironmentRequirement: Equatable, Sendable {
    case required
    case optional
}

enum EnvironmentAction: Equatable, Sendable {
    case none
    case refresh
    case openSoftwareUpdate
    case installCommandLineTools
    case openWallpaperSettings
    case openStorageSettings
    case disableOldLaunchAgent
    case reinstallApplication
    case showHelp(String)

    var requiresConfirmation: Bool {
        switch self {
        case .installCommandLineTools, .disableOldLaunchAgent:
            return true
        default:
            return false
        }
    }
}

struct EnvironmentCheck: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let status: EnvironmentStatus
    let requirement: EnvironmentRequirement
    let detail: String
    let action: EnvironmentAction

    var isOK: Bool { status == .ok }

    var blocksProcessing: Bool {
        requirement == .required && status == .error
    }
}

struct EnvironmentProbe: Sendable {
    var macOSSupported: Bool
    var macOSDetail: String
    var architecture: String
    var encoderDetail: String?
    var aerialCount: Int
    var freeBytes: Int64
    var oldLaunchAgentRunning: Bool
    var oldLaunchAgentDetail: String
    var commandLineToolsDetail: String?
    var swiftDetail: String?
    var gitDetail: String?
    var pythonDetail: String?

    static var allAvailable: EnvironmentProbe {
        EnvironmentProbe(
            macOSSupported: true,
            macOSDetail: "macOS 13 或更高版本",
            architecture: "arm64",
            encoderDetail: "已准备内置 VideoToolbox 编码器",
            aerialCount: 1,
            freeBytes: 100_000_000_000,
            oldLaunchAgentRunning: false,
            oldLaunchAgentDetail: "未发现旧自动修复脚本",
            commandLineToolsDetail: "已安装",
            swiftDetail: "Swift 已安装",
            gitDetail: "Git 已安装",
            pythonDetail: "Python 3 已安装"
        )
    }
}

enum EnvironmentSimulation {
    static func missing(from value: String?) -> Set<String> {
        #if DEBUG
        guard let value else { return [] }
        return Set(value.split { $0 == "," || $0 == ";" || $0 == " " || $0 == "\n" }
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty })
        #else
        return []
        #endif
    }

    static func applying(_ missing: Set<String>, to probe: EnvironmentProbe) -> EnvironmentProbe {
        var result = probe
        if missing.contains("macos") {
            result.macOSSupported = false
            result.macOSDetail = "当前 macOS 版本低于 13"
        }
        if missing.contains("architecture") {
            result.architecture = "x86_64"
        }
        if missing.contains("encoder") {
            result.encoderDetail = nil
        }
        if missing.contains("aerial") {
            result.aerialCount = 0
        }
        if missing.contains("diskspace") || missing.contains("disk") {
            result.freeBytes = 0
        }
        if missing.contains("clt") || missing.contains("commandlinetools") {
            result.commandLineToolsDetail = nil
        }
        if missing.contains("swiftc") || missing.contains("swift") {
            result.swiftDetail = nil
        }
        if missing.contains("git") {
            result.gitDetail = nil
        }
        if missing.contains("python3") || missing.contains("python") {
            result.pythonDetail = nil
        }
        return result
    }
}

enum EnvironmentCheckBuilder {
    static let minimumFreeBytes: Int64 = 1_500_000_000

    static func checking() -> [EnvironmentCheck] {
        [
            check(id: "macos", name: "macOS", status: .checking, requirement: .required, detail: "正在检查…", action: .none),
            check(id: "architecture", name: "处理器架构", status: .checking, requirement: .required, detail: "正在检查…", action: .none),
            check(id: "encoder", name: "内置编码器", status: .checking, requirement: .required, detail: "正在验证…", action: .none),
            check(id: "aerial", name: "Apple 动态壁纸", status: .checking, requirement: .required, detail: "正在检查已下载的动态壁纸…", action: .none),
            check(id: "diskSpace", name: "磁盘空间", status: .checking, requirement: .required, detail: "正在检查…", action: .none),
            check(id: "oldLaunchAgent", name: "旧自动脚本", status: .checking, requirement: .optional, detail: "正在检查…", action: .none),
            check(id: "commandLineTools", name: "Command Line Tools", status: .checking, requirement: .optional, detail: "正在检查…", action: .none),
            check(id: "swift", name: "Swift / swiftc", status: .checking, requirement: .optional, detail: "正在检查…", action: .none),
            check(id: "git", name: "Git", status: .checking, requirement: .optional, detail: "正在检查…", action: .none),
            check(id: "python", name: "Python 3", status: .checking, requirement: .optional, detail: "正在检查…", action: .none)
        ]
    }

    static func build(_ probe: EnvironmentProbe) -> [EnvironmentCheck] {
        let oldStatus: EnvironmentStatus = probe.oldLaunchAgentRunning ? .warning : .ok
        let commandLineAction: EnvironmentAction = probe.commandLineToolsDetail == nil
            ? .installCommandLineTools
            : .none
        let swiftAction: EnvironmentAction
        if probe.swiftDetail != nil {
            swiftAction = .none
        } else if probe.commandLineToolsDetail == nil {
            swiftAction = .installCommandLineTools
        } else {
            swiftAction = .showHelp("Command Line Tools 已存在但未找到 swiftc，请重新安装或检查 Xcode 工具链。")
        }

        let diskDetail = probe.freeBytes >= minimumFreeBytes
            ? "可用 " + ByteCountFormatter.string(fromByteCount: probe.freeBytes, countStyle: .file)
            : "可用空间少于 1.5 GB"

        return [
            check(
                id: "macos",
                name: "macOS",
                status: probe.macOSSupported ? .ok : .error,
                requirement: .required,
                detail: probe.macOSDetail,
                action: probe.macOSSupported ? .none : .openSoftwareUpdate
            ),
            check(
                id: "architecture",
                name: "处理器架构",
                status: probe.architecture == "arm64" ? .ok : .error,
                requirement: .required,
                detail: probe.architecture == "arm64"
                    ? "Apple Silicon (arm64)"
                    : "当前为 \(probe.architecture)，发行版仅支持 Apple Silicon",
                action: probe.architecture == "arm64"
                    ? .none
                    : .showHelp("请使用 Apple Silicon Mac；当前发行版不支持 Intel。")
            ),
            check(
                id: "encoder",
                name: "内置编码器",
                status: probe.encoderDetail == nil ? .error : .ok,
                requirement: .required,
                detail: probe.encoderDetail ?? "内置编码器缺失或损坏，请重新下载应用。",
                action: probe.encoderDetail == nil ? .reinstallApplication : .none
            ),
            check(
                id: "aerial",
                name: "Apple 动态壁纸",
                status: probe.aerialCount > 0 ? .ok : .error,
                requirement: .required,
                detail: probe.aerialCount > 0
                    ? "已找到 \(probe.aerialCount) 个已下载的动态壁纸"
                    : "尚未下载动态壁纸",
                action: probe.aerialCount > 0 ? .none : .openWallpaperSettings
            ),
            check(
                id: "diskSpace",
                name: "磁盘空间",
                status: probe.freeBytes >= minimumFreeBytes ? .ok : .error,
                requirement: .required,
                detail: diskDetail,
                action: probe.freeBytes >= minimumFreeBytes ? .none : .openStorageSettings
            ),
            check(
                id: "oldLaunchAgent",
                name: "旧自动脚本",
                status: oldStatus,
                requirement: .optional,
                detail: probe.oldLaunchAgentRunning
                    ? probe.oldLaunchAgentDetail
                    : "未发现旧自动修复脚本",
                action: probe.oldLaunchAgentRunning ? .disableOldLaunchAgent : .none
            ),
            check(
                id: "commandLineTools",
                name: "Command Line Tools",
                status: probe.commandLineToolsDetail == nil ? .warning : .ok,
                requirement: .optional,
                detail: probe.commandLineToolsDetail ?? "未安装（仅源码构建或高级恢复需要）",
                action: commandLineAction
            ),
            check(
                id: "swift",
                name: "Swift / swiftc",
                status: probe.swiftDetail == nil ? .warning : .ok,
                requirement: .optional,
                detail: probe.swiftDetail ?? "未找到（普通运行不需要）",
                action: swiftAction
            ),
            check(
                id: "git",
                name: "Git",
                status: probe.gitDetail == nil ? .warning : .ok,
                requirement: .optional,
                detail: probe.gitDetail ?? "未安装（普通运行不需要）",
                action: probe.gitDetail == nil
                    ? .showHelp("Git 仅用于开发者从源码构建；普通运行不需要。")
                    : .none
            ),
            check(
                id: "python",
                name: "Python 3",
                status: probe.pythonDetail == nil ? .warning : .ok,
                requirement: .optional,
                detail: probe.pythonDetail ?? "未安装（应用已使用原生 Swift 验证器）",
                action: probe.pythonDetail == nil
                    ? .showHelp("Python 3 仅保留给上游源码调试；普通运行不需要。")
                    : .none
            )
        ]
    }

    static func canProcess(_ checks: [EnvironmentCheck]) -> Bool {
        !checks.contains(where: \.blocksProcessing)
    }

    private static func check(
        id: String,
        name: String,
        status: EnvironmentStatus,
        requirement: EnvironmentRequirement,
        detail: String,
        action: EnvironmentAction
    ) -> EnvironmentCheck {
        EnvironmentCheck(
            id: id,
            name: name,
            status: status,
            requirement: requirement,
            detail: detail,
            action: action
        )
    }
}

enum ArchiveRefreshPolicy {
    static func shouldRefreshArchives(isProcessing: Bool) -> Bool {
        !isProcessing
    }
}

enum LaunchAgentPathPolicy {
    static func nextAvailableDestination(
        preferred: URL,
        fileManager: FileManager = .default
    ) -> URL {
        guard fileManager.fileExists(atPath: preferred.path) else {
            return preferred
        }

        let directory = preferred.deletingLastPathComponent()
        let stem = preferred.deletingPathExtension().lastPathComponent
        let pathExtension = preferred.pathExtension
        var index = 2
        while true {
            let filename = pathExtension.isEmpty
                ? stem + "-" + String(index)
                : stem + "-" + String(index) + "." + pathExtension
            let candidate = directory.appendingPathComponent(filename)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            index += 1
        }
    }
}

enum ProcessingPhase: Equatable {
    case idle
    case running(number: Int, title: String, detail: String)
    case success
    case failed(String)

    var title: String {
        switch self {
        case .idle: return "等待处理"
        case let .running(_, title, _): return title
        case .success: return "替换完成"
        case .failed: return "处理失败"
        }
    }

    var detail: String {
        switch self {
        case .idle: return "拖入一个视频开始。"
        case let .running(_, _, detail): return detail
        case .success: return "请在系统设置中重新选择对应的动态壁纸。"
        case let .failed(message): return message
        }
    }
}

struct OperationReport: Sendable {
    let uuid: String
    let archiveURL: URL
    let backupURL: URL
    let outputURL: URL
    let reloadWarning: String?
    let isRestore: Bool
    let isArchiveReplacement: Bool
}

extension DateFormatter {
    static var fileTimestamp: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }

    static var backupDisplay: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }
}

enum VideoInspector {
    static func inspect(_ url: URL) async throws -> InputVideoInfo {
        let allowedExtensions = Set(["mov", "mp4", "m4v"])
        guard allowedExtensions.contains(url.pathExtension.lowercased()) else {
            throw AppError("仅支持 .mov、.mp4 和 .m4v 视频文件。")
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw AppError("无法读取视频文件，请检查文件是否存在及权限。")
        }

        let asset = AVAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else {
            throw AppError("无法读取视频时长，或视频没有有效的视频轨道。")
        }
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw AppError("文件中没有可用的视频轨道。")
        }

        let naturalSize = try await track.load(.naturalSize)
        let preferredTransform = try await track.load(.preferredTransform)
        let transformedSize = naturalSize.applying(preferredTransform)
        let width = max(1, Int(abs(transformedSize.width).rounded()))
        let height = max(1, Int(abs(transformedSize.height).rounded()))
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0

        return InputVideoInfo(
            url: url,
            duration: duration,
            width: width,
            height: height,
            fileSize: fileSize
        )
    }
}

struct AppError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
