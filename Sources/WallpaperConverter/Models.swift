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

struct EnvironmentCheck: Identifiable, Sendable {
    let id = UUID()
    let name: String
    let isOK: Bool
    let detail: String
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
