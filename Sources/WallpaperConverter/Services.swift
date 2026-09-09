import CryptoKit
@preconcurrency import AVFoundation
import AppKit
import Foundation

private final class ExportSessionBox: @unchecked Sendable {
    let session: AVAssetExportSession

    init(_ session: AVAssetExportSession) {
        self.session = session
    }
}

enum EncoderService {
    static let repositoryURL = "https://github.com/AlexisBCD/macos-custom-video-wallpaper-fix.git"

    static func prepare() async throws -> URL {
        if let bundledRepository = AppPaths.bundledEncoderRepository {
            return try await prepareBundled(repository: bundledRepository)
        }
        return try await prepareFromNetwork()
    }

    private static func prepareBundled(repository: URL) async throws -> URL {
        let fileManager = FileManager.default
        try AppPaths.ensureDirectory(AppPaths.bundledEncoderCache)
        for filename in ["encode_temporal.swift", "groups.py", "build.sh", "LICENSE"] {
            let source = repository.appendingPathComponent(filename)
            let destination = AppPaths.bundledEncoderCache.appendingPathComponent(filename)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            if !fileManager.fileExists(atPath: destination.path) {
                try fileManager.copyItem(at: source, to: destination)
            }
        }

        let executable = AppPaths.bundledEncoderCache.appendingPathComponent("encode_temporal")
        if !fileManager.isExecutableFile(atPath: executable.path) {
            let buildScript = AppPaths.bundledEncoderCache.appendingPathComponent("build.sh")
            guard fileManager.fileExists(atPath: buildScript.path) else {
                throw AppError("应用内置编码器缺少 build.sh，无法继续。")
            }
            let result = try await CommandRunner.run(
                URL(fileURLWithPath: "/bin/bash"),
                arguments: [buildScript.path],
                currentDirectory: AppPaths.bundledEncoderCache
            )
            guard result.status == 0 else {
                throw AppError("内置编码器编译失败：\n\(result.output)")
            }
        }
        guard fileManager.isExecutableFile(atPath: executable.path) else {
            throw AppError("内置编码器编译完成后没有生成 encode_temporal。")
        }
        return executable
    }

    private static func prepareFromNetwork() async throws -> URL {
        let fileManager = FileManager.default
        try AppPaths.ensureDirectory(AppPaths.encoderRepository.deletingLastPathComponent())

        if !fileManager.fileExists(atPath: AppPaths.encoderRepository.path) {
            guard let git = CommandRunner.executable(named: "git") else {
                throw AppError("未找到 Git，无法准备编码器。")
            }
            let result = try await CommandRunner.run(
                git,
                arguments: ["clone", repositoryURL, AppPaths.encoderRepository.path]
            )
            guard result.status == 0 else {
                throw AppError("应用内置编码器不可用，且在线备用下载失败：\n\(result.output)")
            }
        }

        let executable = AppPaths.encoderRepository.appendingPathComponent("encode_temporal")
        if !fileManager.isExecutableFile(atPath: executable.path) {
            let buildScript = AppPaths.encoderRepository.appendingPathComponent("build.sh")
            guard fileManager.fileExists(atPath: buildScript.path) else {
                throw AppError("编码器目录缺少 build.sh，未自动删除现有目录。")
            }
            let bash = URL(fileURLWithPath: "/bin/bash")
            let result = try await CommandRunner.run(bash, arguments: [buildScript.path], currentDirectory: AppPaths.encoderRepository)
            guard result.status == 0 else {
                throw AppError("编码器编译失败：\n\(result.output)")
            }
        }

        guard fileManager.isExecutableFile(atPath: executable.path) else {
            throw AppError("编码器编译完成后没有生成 encode_temporal。")
        }
        return executable
    }

    static func encode(
        input: URL,
        output: URL,
        loopCount: Int,
        bitrateMbps: Int,
        executable: URL,
        canvasSize: VideoCanvasSize? = nil
    ) async throws {
        try AppPaths.ensureDirectory(output.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: output)
        let aspectFitInput: URL?
        if let canvasSize {
            let temporaryInput = output.deletingLastPathComponent().appendingPathComponent(
                ".wallpaper-converter-aspect-\(UUID().uuidString).mov"
            )
            try await VideoAspectService.renderAspectFit(
                input: input,
                output: temporaryInput,
                canvasSize: canvasSize
            )
            aspectFitInput = temporaryInput
        } else {
            aspectFitInput = nil
        }
        defer {
            if let aspectFitInput {
                try? FileManager.default.removeItem(at: aspectFitInput)
            }
        }
        let result = try await CommandRunner.run(
            executable,
            arguments: [aspectFitInput?.path ?? input.path, output.path, String(loopCount), String(bitrateMbps)],
            currentDirectory: executable.deletingLastPathComponent()
        )
        guard result.status == 0 else {
            throw AppError("视频编码失败：\n\(result.output)")
        }
        guard FileManager.default.isReadableFile(atPath: output.path),
              (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.int64Value ?? 0 > 0 else {
            throw AppError("编码器没有生成有效输出文件。")
        }
    }

    static func validate(output: URL, repository: URL) async throws -> String {
        guard let python = CommandRunner.executable(named: "python3") else {
            throw AppError("未找到 Python 3，无法验证 temporal sample groups。")
        }
        let groups = repository.appendingPathComponent("groups.py")
        guard FileManager.default.fileExists(atPath: groups.path) else {
            throw AppError("编码器仓库缺少 groups.py，无法进行安全验证。")
        }
        let result = try await CommandRunner.run(python, arguments: [groups.path, output.path])
        guard result.status == 0 else {
            throw AppError("sample group 验证程序失败：\n\(result.output)")
        }

        let required = [
            "[sgpd] grouping_type='tscl'",
            "[sgpd] grouping_type='tsas'",
            "[csgm] grouping_type='tscl'",
            "[csgm] grouping_type='tsas'"
        ]
        let missing = required.filter { !result.output.contains($0) }
        guard missing.isEmpty else {
            throw AppError("视频未通过 Aerial 兼容性验证，缺少：\n\(missing.joined(separator: "\n"))\n\n原始验证输出：\n\(result.output)")
        }
        return result.output
    }
}

enum VideoAspectService {
    static func renderAspectFit(input: URL, output: URL, canvasSize: VideoCanvasSize) async throws {
        let asset = AVURLAsset(url: input)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw AppError("视频中没有可用于比例处理的视频轨道。")
        }
        let duration = try await asset.load(.duration)
        let naturalSize = try await track.load(.naturalSize)
        let preferredTransform = try await track.load(.preferredTransform)
        let transformedBounds = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let sourceWidth = max(1, abs(transformedBounds.width))
        let sourceHeight = max(1, abs(transformedBounds.height))
        let scale = min(
            CGFloat(canvasSize.width) / sourceWidth,
            CGFloat(canvasSize.height) / sourceHeight
        )
        let fittedWidth = sourceWidth * scale
        let fittedHeight = sourceHeight * scale
        let paddingX = (CGFloat(canvasSize.width) - fittedWidth) / 2
        let paddingY = (CGFloat(canvasSize.height) - fittedHeight) / 2
        let transform = CGAffineTransform(
            a: preferredTransform.a * scale,
            b: preferredTransform.b * scale,
            c: preferredTransform.c * scale,
            d: preferredTransform.d * scale,
            tx: preferredTransform.tx * scale - transformedBounds.minX * scale + paddingX,
            ty: preferredTransform.ty * scale - transformedBounds.minY * scale + paddingY
        )

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = CGSize(width: canvasSize.width, height: canvasSize.height)
        let frameRate = try await track.load(.nominalFrameRate)
        let timescale = Int32(max(1, Int(frameRate.rounded())))
        videoComposition.frameDuration = CMTime(value: 1, timescale: timescale)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.backgroundColor = CGColor(gray: 0, alpha: 1)
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layerInstruction.setTransform(transform, at: .zero)
        instruction.layerInstructions = [layerInstruction]
        videoComposition.instructions = [instruction]

        guard let exporter = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw AppError("无法创建视频比例处理任务。")
        }
        try? FileManager.default.removeItem(at: output)
        exporter.outputURL = output
        exporter.outputFileType = .mov
        exporter.videoComposition = videoComposition
        exporter.shouldOptimizeForNetworkUse = false

        let exporterBox = ExportSessionBox(exporter)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            exporterBox.session.exportAsynchronously {
                if exporterBox.session.status == .completed {
                    continuation.resume()
                } else {
                    let detail = exporterBox.session.error?.localizedDescription ?? "未知错误"
                    continuation.resume(throwing: AppError("视频比例处理失败：\(detail)"))
                }
            }
        }
        guard FileManager.default.isReadableFile(atPath: output.path) else {
            throw AppError("视频比例处理没有生成有效文件。")
        }
    }
}

enum PreviewService {
    static func generateFirstFrame(from video: URL, to destination: URL) async throws {
        let asset = AVAsset(url: video)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1920, height: 1080)
        let result = try await generator.image(at: .zero)
        let bitmap = NSBitmapImageRep(cgImage: result.image)
        guard let data = bitmap.representation(
            using: .jpeg,
            properties: [.compressionFactor: 0.88]
        ) else {
            throw AppError("无法生成动态壁纸首帧预览。")
        }
        try AppPaths.ensureDirectory(destination.deletingLastPathComponent())
        try data.write(to: destination, options: [.atomic])
    }
}

enum AerialService {
    private static let uuidPattern = #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"#

    static func normalizeUUID(_ value: String) -> String? {
        let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ".mov", with: "", options: [.caseInsensitive, .anchored])
        guard candidate.range(of: uuidPattern, options: .regularExpression) != nil else { return nil }
        return candidate.uppercased()
    }

    static func uuidFromFilename(_ url: URL) -> String? {
        normalizeUUID(url.deletingPathExtension().lastPathComponent)
    }

    static func targets() -> [AerialTarget] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: AppPaths.aerialDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return urls.compactMap { url in
            guard url.pathExtension.lowercased() == "mov",
                  let uuid = uuidFromFilename(url),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                return nil
            }
            return AerialTarget(uuid: uuid, url: url)
        }.sorted { $0.uuid < $1.uuid }
    }

    static func targetURL(uuid: String) throws -> URL {
        guard let normalized = normalizeUUID(uuid) else {
            throw AppError("UUID 格式不正确。")
        }
        return AppPaths.aerialDirectory.appendingPathComponent("\(normalized).mov")
    }

    static func createBackup(of target: URL, uuid: String, suffix: String? = nil) throws -> URL {
        try AppPaths.ensureDirectory(AppPaths.backupsDirectory)
        let timestamp = DateFormatter.fileTimestamp.string(from: Date())
        let middle = suffix.map { "-\($0)" } ?? ""
        let destination = uniqueURL(
            directory: AppPaths.backupsDirectory,
            filename: "\(uuid)\(middle)-\(timestamp).mov"
        )
        try FileManager.default.copyItem(at: target, to: destination)
        try verifyNonEmpty(destination)
        return destination
    }

    static func archiveOriginal(of target: URL, uuid: String, customName: String? = nil) throws -> URL {
        try AppPaths.ensureDirectory(AppPaths.archiveDirectory)
        try AppPaths.ensureDirectory(AppPaths.previewDirectory)
        let number = nextArchiveNumber()
        let filename = try archiveFilename(for: target, customName: customName)
        let destination = AppPaths.archiveDirectory.appendingPathComponent(
            "\(number)-\(filename)"
        )
        try FileManager.default.copyItem(at: target, to: destination)
        do {
            try verifyNonEmpty(destination)
            var metadata = loadArchiveMetadata()
            metadata[destination.lastPathComponent] = WallpaperArchiveMetadata(
                uuid: normalizeUUID(uuid),
                displayName: destination.deletingPathExtension().lastPathComponent
            )
            try saveArchiveMetadata(metadata)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        return destination
    }

    static func archiveEntries() -> [WallpaperArchiveEntry] {
        let metadata = loadArchiveMetadata()
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: AppPaths.archiveDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return urls.compactMap { url in
            guard url.pathExtension.lowercased() == "mov",
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                return nil
            }
            let stem = url.deletingPathExtension().lastPathComponent
            let number = stem.split(separator: "-", maxSplits: 1).first.flatMap { Int($0) } ?? 0
            let record = metadata[url.lastPathComponent]
            return WallpaperArchiveEntry(
                url: url,
                previewURL: previewURL(for: url),
                number: number,
                uuid: record?.uuid ?? uuidFromArchiveFilename(url),
                displayName: record?.displayName ?? stem
            )
        }.sorted {
            if $0.number != $1.number { return $0.number > $1.number }
            return $0.url.lastPathComponent > $1.url.lastPathComponent
        }
    }

    static func previewURL(for archiveURL: URL) -> URL {
        AppPaths.previewDirectory.appendingPathComponent(
            "\(archiveURL.deletingPathExtension().lastPathComponent).jpg"
        )
    }

    static func renameArchive(_ entry: WallpaperArchiveEntry, to name: String) throws {
        var stem = try normalizedArchiveStem(name)
        let numberPrefix = "\(entry.number)-"
        if stem.hasPrefix(numberPrefix) {
            stem.removeFirst(numberPrefix.count)
        }
        guard !stem.isEmpty else {
            throw AppError("自定义归档名称无效。")
        }
        let destination = AppPaths.archiveDirectory.appendingPathComponent(
            "\(entry.number)-\(stem).mov"
        )
        guard destination != entry.url else { return }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw AppError("该归档名称已存在，请换一个名称。")
        }

        let oldPreview = entry.previewURL
        let newPreview = previewURL(for: destination)
        guard !FileManager.default.fileExists(atPath: newPreview.path) else {
            throw AppError("该归档名称对应的预览已存在，请换一个名称。")
        }

        var metadata = loadArchiveMetadata()
        let oldRecord = metadata.removeValue(forKey: entry.url.lastPathComponent)
        metadata[destination.lastPathComponent] = WallpaperArchiveMetadata(
            uuid: entry.uuid ?? oldRecord?.uuid,
            displayName: destination.deletingPathExtension().lastPathComponent
        )

        do {
            try FileManager.default.moveItem(at: entry.url, to: destination)
            if FileManager.default.fileExists(atPath: oldPreview.path) {
                try FileManager.default.moveItem(at: oldPreview, to: newPreview)
            }
            try saveArchiveMetadata(metadata)
        } catch {
            if FileManager.default.fileExists(atPath: newPreview.path),
               !FileManager.default.fileExists(atPath: oldPreview.path) {
                try? FileManager.default.moveItem(at: newPreview, to: oldPreview)
            }
            if FileManager.default.fileExists(atPath: destination.path),
               !FileManager.default.fileExists(atPath: entry.url.path) {
                try? FileManager.default.moveItem(at: destination, to: entry.url)
            }
            throw error
        }
    }

    static func deleteArchive(_ entry: WallpaperArchiveEntry) throws {
        if FileManager.default.fileExists(atPath: entry.url.path) {
            try FileManager.default.removeItem(at: entry.url)
        }
        if FileManager.default.fileExists(atPath: entry.previewURL.path) {
            try FileManager.default.removeItem(at: entry.previewURL)
        }
        var metadata = loadArchiveMetadata()
        metadata.removeValue(forKey: entry.url.lastPathComponent)
        try saveArchiveMetadata(metadata)
    }

    private static func archiveFilename(for target: URL, customName: String?) throws -> String {
        guard let customName else { return target.lastPathComponent }
        return "\(try normalizedArchiveStem(customName)).mov"
    }

    private static func normalizedArchiveStem(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != ".",
              trimmed != "..",
              !trimmed.contains("/"),
              !trimmed.contains("\\"),
              !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw AppError("自定义归档名称无效，不能包含路径分隔符。")
        }

        var stem = trimmed
        if stem.lowercased().hasSuffix(".mov") {
            stem.removeLast(4)
        }
        guard !stem.isEmpty, stem != ".", stem != ".." else {
            throw AppError("自定义归档名称无效。")
        }
        return stem
    }

    private static func uuidFromArchiveFilename(_ url: URL) -> String? {
        let stem = url.deletingPathExtension().lastPathComponent
        guard let separator = stem.firstIndex(of: "-") else { return nil }
        let candidate = String(stem[stem.index(after: separator)...])
        return normalizeUUID(candidate)
    }

    private static func loadArchiveMetadata() -> [String: WallpaperArchiveMetadata] {
        guard let data = try? Data(contentsOf: AppPaths.archiveMetadataURL),
              let metadata = try? JSONDecoder().decode(
                  [String: WallpaperArchiveMetadata].self,
                  from: data
              ) else {
            return [:]
        }
        return metadata
    }

    private static func saveArchiveMetadata(_ metadata: [String: WallpaperArchiveMetadata]) throws {
        try AppPaths.ensureDirectory(AppPaths.archiveDirectory)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(metadata)
        try data.write(to: AppPaths.archiveMetadataURL, options: [.atomic])
    }

    static func migrateLegacyDesktopArchives() {
        guard FileManager.default.fileExists(atPath: AppPaths.legacyDesktopArchiveDirectory.path),
              (try? AppPaths.ensureDirectory(AppPaths.archiveDirectory)) != nil else { return }
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: AppPaths.legacyDesktopArchiveDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for url in urls where url.pathExtension.lowercased() == "mov" {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let destination = AppPaths.archiveDirectory.appendingPathComponent(url.lastPathComponent)
            guard !FileManager.default.fileExists(atPath: destination.path) else { continue }
            do {
                try FileManager.default.copyItem(at: url, to: destination)
                try verifyNonEmpty(destination)
                try FileManager.default.removeItem(at: url)
            } catch {
                try? FileManager.default.removeItem(at: destination)
            }
        }
    }

    static func backups(for uuid: String) -> [BackupEntry] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: AppPaths.backupsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return urls.compactMap { url in
            guard url.pathExtension.lowercased() == "mov", url.lastPathComponent.hasPrefix(uuid) else { return nil }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return BackupEntry(
                url: url,
                date: values?.contentModificationDate ?? .distantPast,
                size: Int64(values?.fileSize ?? 0)
            )
        }.sorted { $0.date > $1.date }
    }

    static func replaceAtomically(source: URL, target: URL) throws {
        let staging = target.deletingLastPathComponent().appendingPathComponent(
            ".wallpaper-converter-\(UUID().uuidString).mov"
        )
        defer { try? FileManager.default.removeItem(at: staging) }

        try FileManager.default.copyItem(at: source, to: staging)
        guard try sha256(source) == sha256(staging) else {
            throw AppError("安装前临时文件校验不一致，已停止替换。")
        }
        _ = try FileManager.default.replaceItemAt(
            target,
            withItemAt: staging,
            backupItemName: nil,
            options: [.usingNewMetadataOnly]
        )
    }

    static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func verifyNonEmpty(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, (values.fileSize ?? 0) > 0 else {
            throw AppError("文件备份失败或为空：\(url.path)")
        }
    }

    private static func uniqueURL(directory: URL, filename: String) -> URL {
        let base = directory.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: base.path) else { return base }
        let stem = base.deletingPathExtension().lastPathComponent
        var index = 2
        while true {
            let candidate = directory.appendingPathComponent("\(stem)-\(index).mov")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }

    private static func nextArchiveNumber() -> Int {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: AppPaths.archiveDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        let numbers = urls.compactMap { url -> Int? in
            let first = url.lastPathComponent.split(separator: "-", maxSplits: 1).first
            return first.flatMap { Int($0) }
        }
        return (numbers.max() ?? 0) + 1
    }
}
