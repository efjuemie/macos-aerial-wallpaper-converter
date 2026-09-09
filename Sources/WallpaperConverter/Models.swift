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
