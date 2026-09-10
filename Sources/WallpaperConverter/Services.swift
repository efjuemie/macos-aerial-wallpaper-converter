import CryptoKit
@preconcurrency import AVFoundation
import AppKit
import Foundation
import ImageIO

private final class ExportSessionBox: @unchecked Sendable {
    let session: AVAssetExportSession

    init(_ session: AVAssetExportSession) {
        self.session = session
    }
}

enum EncoderService {
    static func prepare() async throws -> URL {
        let encoder = try await validatedBundledEncoder()
        return encoder.url
    }

    static func describeBundledEncoder() async throws -> String {
        try await validatedBundledEncoder().detail
    }

    private static func validatedBundledEncoder() async throws -> (url: URL, detail: String) {
        guard let binary = AppPaths.bundledEncoderBinary,
              let manifest = AppPaths.bundledEncoderManifest else {
            throw AppError("应用内置编码器资源缺失，请重新下载应用。")
        }
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw AppError("应用内置编码器缺失或不可执行，请重新下载应用。")
        }
        let architecture: String
        do {
            architecture = try EncoderArchitectureDetector.architecture(of: binary)
        } catch let error as AppError {
            throw error
        } catch {
            throw AppError("应用内置编码器无法读取，请重新下载应用。")
        }
        let detail = try EncoderAssetValidator.validate(
            binaryURL: binary,
            manifestURL: manifest,
            actualArchitecture: architecture
        )
        return (binary, detail)
    }

    static func encode(
        input: URL,
        output: URL,
        loopCount: Int,
        bitrateMbps: Int,
        executable: URL,
        cropSelection: WallpaperCropSelection
    ) async throws -> String {
        try AppPaths.ensureDirectory(output.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: output)
        let croppedInput = output.deletingLastPathComponent().appendingPathComponent(
            ".wallpaper-converter-crop-\(UUID().uuidString).mov"
        )
        try await VideoAspectService.renderCrop(
            input: input,
            output: croppedInput,
            crop: cropSelection
        )
        defer {
            try? FileManager.default.removeItem(at: croppedInput)
        }
        let result = try await CommandRunner.run(
            executable,
            arguments: [croppedInput.path, output.path, String(loopCount), String(bitrateMbps)],
            currentDirectory: executable.deletingLastPathComponent()
        )
        guard result.status == 0 else {
            throw AppError("视频编码失败：\n\(result.output)")
        }
        guard FileManager.default.isReadableFile(atPath: output.path),
              (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.int64Value ?? 0 > 0 else {
            throw AppError("编码器没有生成有效输出文件。")
        }
        return try await VideoGeometryService.validateFixedCanvas(
            at: output,
            expected: AerialCanvas(width: cropSelection.outputWidth, height: cropSelection.outputHeight)
        )
    }

    static func validate(output: URL) async throws -> String {
        try Task.checkCancellation()
        return try TemporalSampleGroupValidator.validate(at: output)
    }
}

struct VideoGeometrySnapshot: Sendable {
    let naturalSize: CGSize
    let preferredTransform: CGAffineTransform
    let encodedSize: CMVideoDimensions
    let cleanAperture: CGRect
    let presentationSize: CGSize
    let pixelAspectRatio: (horizontal: Int, vertical: Int)?
    let hasExplicitCleanAperture: Bool

    var hasIdentityTransform: Bool {
        approximatelyEqual(preferredTransform.a, 1)
            && approximatelyEqual(preferredTransform.b, 0)
            && approximatelyEqual(preferredTransform.c, 0)
            && approximatelyEqual(preferredTransform.d, 1)
            && approximatelyEqual(preferredTransform.tx, 0)
            && approximatelyEqual(preferredTransform.ty, 0)
    }

    var hasSquarePixels: Bool {
        pixelAspectRatio.map { $0.horizontal == $0.vertical } ?? true
    }

    var hasExplicitSquarePixels: Bool {
        pixelAspectRatio.map { $0.horizontal == 1 && $0.vertical == 1 } ?? false
    }

    var fixedCanvasEvidence: AerialCanvas? {
        let width = Int(encodedSize.width)
        let height = Int(encodedSize.height)
        guard width > 1,
              height > 1,
              width.isMultiple(of: 2),
              height.isMultiple(of: 2),
              approximatelyEqual(naturalSize.width, CGFloat(width)),
              approximatelyEqual(naturalSize.height, CGFloat(height)),
              approximatelyEqual(cleanAperture.width, CGFloat(width)),
              approximatelyEqual(cleanAperture.height, CGFloat(height)),
              approximatelyEqual(presentationSize.width, CGFloat(width)),
              approximatelyEqual(presentationSize.height, CGFloat(height)),
              hasIdentityTransform,
              hasSquarePixels else {
            return nil
        }
        return AerialCanvas(width: width, height: height)
    }

    private func approximatelyEqual(_ left: CGFloat, _ right: CGFloat) -> Bool {
        abs(left - right) < 0.01
    }
}

enum VideoGeometryService {
    static func inspect(_ url: URL) async throws -> VideoGeometrySnapshot {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw AppError("视频中没有可用于画布验证的视频轨道。")
        }
        let naturalSize = try await track.load(.naturalSize)
        let preferredTransform = try await track.load(.preferredTransform)
        guard let description = try await track.load(.formatDescriptions).first else {
            throw AppError("视频轨道缺少格式描述，无法验证显示尺寸。")
        }
        let extensions = CMFormatDescriptionGetExtensions(description) as NSDictionary? ?? [:]
        let hasExplicitCleanAperture = extensions[kCMFormatDescriptionExtension_CleanAperture] != nil
        let pixelAspectRatio: (horizontal: Int, vertical: Int)?
        if let values = extensions[kCMFormatDescriptionExtension_PixelAspectRatio] as? NSDictionary,
           let horizontal = values[kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing] as? NSNumber,
           let vertical = values[kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing] as? NSNumber {
            pixelAspectRatio = (horizontal.intValue, vertical.intValue)
        } else {
            pixelAspectRatio = nil
        }
        return VideoGeometrySnapshot(
            naturalSize: naturalSize,
            preferredTransform: preferredTransform,
            encodedSize: CMVideoFormatDescriptionGetDimensions(description),
            cleanAperture: CMVideoFormatDescriptionGetCleanAperture(
                description,
                originIsAtTopLeft: true
            ),
            presentationSize: CMVideoFormatDescriptionGetPresentationDimensions(
                description,
                usePixelAspectRatio: true,
                useCleanAperture: true
            ),
            pixelAspectRatio: pixelAspectRatio,
            hasExplicitCleanAperture: hasExplicitCleanAperture
        )
    }

    static func validateFixedCanvas(
        at url: URL,
        expected: AerialCanvas,
        requireExplicitMetadata: Bool = true
    ) async throws -> String {
        let geometry = try await inspect(url)
        let width = CGFloat(expected.width)
        let height = CGFloat(expected.height)
        let matches = approximatelyEqual(geometry.naturalSize.width, width)
            && approximatelyEqual(geometry.naturalSize.height, height)
            && geometry.encodedSize.width == Int32(expected.width)
            && geometry.encodedSize.height == Int32(expected.height)
            && approximatelyEqual(geometry.cleanAperture.width, width)
            && approximatelyEqual(geometry.cleanAperture.height, height)
            && approximatelyEqual(geometry.presentationSize.width, width)
            && approximatelyEqual(geometry.presentationSize.height, height)
            && geometry.hasIdentityTransform
            && geometry.hasSquarePixels
            && (!requireExplicitMetadata || geometry.hasExplicitCleanAperture)
            && (!requireExplicitMetadata || geometry.hasExplicitSquarePixels)
        guard matches else {
            throw AppError(
                "输出画布验证失败：要求 \(expected.width)×\(expected.height)、方形像素和恒等显示变换；" +
                "实际 encoded=\(geometry.encodedSize.width)×\(geometry.encodedSize.height)，" +
                "presentation=\(Int(geometry.presentationSize.width))×\(Int(geometry.presentationSize.height))，" +
                "explicitCleanAperture=\(geometry.hasExplicitCleanAperture)，" +
                "explicitPAR=\(geometry.pixelAspectRatio != nil)。"
            )
        }
        let metadata = requireExplicitMetadata ? "explicit clean aperture/PAR" : "semantic clean aperture/PAR"
        return "encoded/natural/clean/presentation=\(expected.width)x\(expected.height), pixelAspect=1:1, transform=identity, \(metadata)"
    }

    private static func approximatelyEqual(_ left: CGFloat, _ right: CGFloat) -> Bool {
        abs(left - right) < 0.01
    }
}

enum VideoAspectService {
    static func renderCrop(input: URL, output: URL, crop: WallpaperCropSelection) async throws {
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
        guard crop.sourceWidth <= sourceWidth + 1,
              crop.sourceHeight <= sourceHeight + 1,
              crop.cropWidth > 1,
              crop.cropHeight > 1,
              crop.outputWidth > 1,
              crop.outputHeight > 1,
              crop.originX >= 0,
              crop.originY >= 0,
              crop.originX + crop.cropWidth <= sourceWidth + 1,
              crop.originY + crop.cropHeight <= sourceHeight + 1 else {
            throw AppError("视频裁剪范围无效，无法生成动态壁纸。")
        }

        let normalizedTransform = CGAffineTransform(
            a: preferredTransform.a,
            b: preferredTransform.b,
            c: preferredTransform.c,
            d: preferredTransform.d,
            tx: preferredTransform.tx - transformedBounds.minX,
            ty: preferredTransform.ty - transformedBounds.minY
        )
        let placement = WallpaperGeometry.renderPlacement(for: crop)
        let transform = CGAffineTransform(
            a: normalizedTransform.a * placement.scale,
            b: normalizedTransform.b * placement.scale,
            c: normalizedTransform.c * placement.scale,
            d: normalizedTransform.d * placement.scale,
            tx: normalizedTransform.tx * placement.scale + placement.translationX,
            ty: normalizedTransform.ty * placement.scale + placement.translationY
        )

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = CGSize(width: crop.outputWidth, height: crop.outputHeight)
        let frameRate = try await track.load(.nominalFrameRate)
        let timescale = Int32(max(1, Int(frameRate.rounded())))
        videoComposition.frameDuration = CMTime(value: 1, timescale: timescale)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layerInstruction.setTransform(transform, at: .zero)
        instruction.layerInstructions = [layerInstruction]
        videoComposition.instructions = [instruction]

        let presetName: String
        if crop.outputWidth <= 3840 && crop.outputHeight <= 2160
            && (crop.outputWidth > 1920 || crop.outputHeight > 1080) {
            presetName = AVAssetExportPresetHEVC3840x2160
        } else if crop.outputWidth <= 1920 && crop.outputHeight <= 1080 {
            presetName = AVAssetExportPresetHEVC1920x1080
        } else {
            presetName = AVAssetExportPresetHEVCHighestQuality
        }
        guard let exporter = AVAssetExportSession(asset: asset, presetName: presetName) else {
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
                    let detail = exporterBox.session.error.map {
                        let error = $0 as NSError
                        return "\(error.localizedDescription) [\(error.domain) \(error.code)] \(error.userInfo)"
                    } ?? "未知错误"
                    continuation.resume(throwing: AppError("视频比例处理失败：\(detail)"))
                }
            }
        }
        guard FileManager.default.isReadableFile(atPath: output.path) else {
            throw AppError("视频比例处理没有生成有效文件。")
        }
        _ = try await VideoGeometryService.validateFixedCanvas(
            at: output,
            expected: AerialCanvas(width: crop.outputWidth, height: crop.outputHeight),
            requireExplicitMetadata: false
        )
    }
}

enum PreviewService {
    static func generateFirstFrame(from video: URL, to destination: URL) async throws {
        let data = try await firstFrameJPEG(from: video)
        try AppPaths.ensureDirectory(destination.deletingLastPathComponent())
        try data.write(to: destination, options: [.atomic])
    }

    static func firstFrameJPEG(from video: URL) async throws -> Data {
        let asset = AVURLAsset(url: video)
        guard try await asset.loadTracks(withMediaType: .video).first != nil else {
            throw AppError("视频中没有可生成预览的视频轨道。")
        }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else {
            throw AppError("视频时长无效，无法生成预览。")
        }
        let safeEnd = max(0, duration - 1.0 / 60.0)
        let seconds = [
            min(0.10, safeEnd),
            min(max(0.25, duration * 0.05), safeEnd),
            min(max(0.50, duration * 0.10), safeEnd),
            0
        ].reduce(into: [Double]()) { values, value in
            if !values.contains(where: { abs($0 - value) < 0.001 }) {
                values.append(value)
            }
        }
        var failures: [String] = []
        for second in seconds {
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 1920, height: 1080)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.50, preferredTimescale: 600)
            do {
                let result = try await generator.image(
                    at: CMTime(seconds: second, preferredTimescale: 600)
                )
                let bitmap = NSBitmapImageRep(cgImage: result.image)
                if let data = bitmap.representation(
                    using: .jpeg,
                    properties: [.compressionFactor: 0.88]
                ), !data.isEmpty {
                    return data
                }
                failures.append(String(format: "%.2fs: JPEG 编码失败", second))
            } catch {
                failures.append(String(format: "%.2fs: %@", second, error.localizedDescription))
            }
        }
        throw AppError("多个安全取帧时刻均失败：\(failures.joined(separator: "；"))")
    }

    static func isValidPreview(at url: URL) -> Bool {
        validPreviewData(at: url) != nil
    }

    static func validPreviewData(at url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              let image = CGImageSourceCreateImageAtIndex(
                  source,
                  0,
                  [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
              ),
              image.width > 0,
              image.height > 0,
              let context = CGContext(
                  data: nil,
                  width: 1,
                  height: 1,
                  bitsPerComponent: 8,
                  bytesPerRow: 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return context.data == nil ? nil : data
    }
}

enum NativeCanvasStore {
    static func load(from url: URL) throws -> [String: AerialCanvas] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([String: AerialCanvas].self, from: data)
        } catch {
            throw AppError("原生画布记录无法读取，请检查或移走该文件后重试：\(url.path)")
        }
    }

    static func save(
        _ canvas: AerialCanvas,
        uuid: String,
        to url: URL
    ) throws {
        var records = try load(from: url)
        records[uuid] = canvas
        try AppPaths.ensureDirectory(url.deletingLastPathComponent())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(records).write(to: url, options: [.atomic])
    }
}

enum AerialService {
    private static let uuidPattern = #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"#

    private struct Manifest: Decodable {
        let assets: [ManifestAsset]
    }

    private struct ManifestAsset: Decodable {
        let id: String
        let url4K: String?

        enum CodingKeys: String, CodingKey {
            case id
            case url4K = "url-4K-SDR-240FPS"
        }
    }

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

    static func outputCanvas(
        for target: URL,
        uuid: String,
        recordsURL: URL = AppPaths.nativeCanvasRecordsURL
    ) async throws -> AerialCanvas {
        let normalizedUUID = normalizeUUID(uuid) ?? uuid.uppercased()
        let records = try NativeCanvasStore.load(from: recordsURL)
        let persistedCanvas = records[normalizedUUID]
        let manifestCanvas = explicitManifestCanvas(uuid: normalizedUUID)
        let matchingArchives = archiveEntries().filter { entry in
            let filenameUUID = normalizeUUID(entry.url.deletingPathExtension().lastPathComponent)
            return entry.uuid == normalizedUUID || filenameUUID == normalizedUUID
        }
        let originalArchives = matchingArchives.filter { $0.kind == .original }
        let backupEntries = backups(for: normalizedUUID)
        let hasAnyHistoricalRecords = !matchingArchives.isEmpty || !backupEntries.isEmpty

        var resolution = NativeCanvasResolver.resolve(
            persistedCanvas: persistedCanvas,
            manifestCanvas: manifestCanvas,
            targetCanvas: nil,
            hasAnyHistoricalRecords: hasAnyHistoricalRecords,
            earliestOriginalCanvas: nil,
            earliestBackupCanvas: nil
        )
        if resolution == nil, !hasAnyHistoricalRecords {
            resolution = NativeCanvasResolver.resolve(
                persistedCanvas: nil,
                manifestCanvas: nil,
                targetCanvas: try? await fixedCanvas(at: target),
                hasAnyHistoricalRecords: false,
                earliestOriginalCanvas: nil,
                earliestBackupCanvas: nil
            )
        }
        if resolution == nil, hasAnyHistoricalRecords {
            let earliestOriginal = originalArchives.min(by: isEarlierOriginalArchive)
            let earliestBackup = backupEntries.min {
                backupChronology($0) < backupChronology($1)
            }
            let earliestOriginalCanvas: AerialCanvas?
            if let earliestOriginal {
                earliestOriginalCanvas = try? await fixedCanvas(at: earliestOriginal.url)
            } else {
                earliestOriginalCanvas = nil
            }
            let earliestBackupCanvas: AerialCanvas?
            if let earliestBackup {
                earliestBackupCanvas = try? await fixedCanvas(at: earliestBackup.url)
            } else {
                earliestBackupCanvas = nil
            }
            resolution = NativeCanvasResolver.resolve(
                persistedCanvas: nil,
                manifestCanvas: nil,
                targetCanvas: nil,
                hasAnyHistoricalRecords: true,
                earliestOriginalCanvas: earliestOriginalCanvas,
                earliestBackupCanvas: earliestBackupCanvas
            )
        }
        guard let resolution else {
            throw AppError(
                "无法可靠判定该系统动态壁纸的原生编码画布。请先在系统设置中重新下载该动态壁纸，" +
                "或确认同 UUID 最早的原壁纸归档与最早备份完整且画布一致后重试。"
            )
        }
        if resolution.shouldPersist {
            try NativeCanvasStore.save(resolution.canvas, uuid: normalizedUUID, to: recordsURL)
        }
        return resolution.canvas
    }

    private static func fixedCanvas(at url: URL) async throws -> AerialCanvas? {
        try await VideoGeometryService.inspect(url).fixedCanvasEvidence
    }

    private static func isEarlierOriginalArchive(
        _ left: WallpaperArchiveEntry,
        _ right: WallpaperArchiveEntry
    ) -> Bool {
        if left.number != right.number { return left.number < right.number }
        let leftDate = (try? left.url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantFuture
        let rightDate = (try? right.url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantFuture
        return leftDate < rightDate
    }

    private static func backupChronology(_ entry: BackupEntry) -> Date {
        let stem = entry.url.deletingPathExtension().lastPathComponent
        if let range = stem.range(
            of: #"[0-9]{8}-[0-9]{6}"#,
            options: [.regularExpression, .backwards]
        ), let date = DateFormatter.fileTimestamp.date(from: String(stem[range])) {
            return date
        }
        return entry.date
    }

    private static func explicitManifestCanvas(uuid: String) -> AerialCanvas? {
        guard let data = try? Data(contentsOf: AppPaths.aerialManifestURL),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              let asset = manifest.assets.first(where: {
                  $0.id.caseInsensitiveCompare(uuid) == .orderedSame
              }),
              let url = asset.url4K else {
            return nil
        }
        if let match = url.range(
            of: #"(?i)([1-9][0-9]{2,4})x([1-9][0-9]{2,4})"#,
            options: .regularExpression
        ) {
            let dimensions = url[match].lowercased().split(separator: "x")
            if dimensions.count == 2,
               let width = Int(dimensions[0]),
               let height = Int(dimensions[1]) {
                return AerialCanvas(width: width & ~1, height: height & ~1)
            }
        }
        if let match = url.range(
            of: #"(?i)(?:^|[_-])t(2160|1080)(?:[_\.-]|$)"#,
            options: .regularExpression
        ) {
            let marker = url[match]
            let height = marker.contains("2160") ? 2160 : 1080
            return AerialCanvas(width: height * 16 / 9, height: height)
        }
        return nil
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
                displayName: destination.deletingPathExtension().lastPathComponent,
                kind: .original
            )
            try saveArchiveMetadata(metadata)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        return destination
    }

    static func archiveEncodedOutput(_ output: URL, uuid: String) throws -> URL {
        try AppPaths.ensureDirectory(AppPaths.archiveDirectory)
        try AppPaths.ensureDirectory(AppPaths.previewDirectory)
        try AppPaths.ensureDirectory(AppPaths.encodedArchiveDirectory)

        let destination = uniqueURL(
            directory: AppPaths.encodedArchiveDirectory,
            filename: output.lastPathComponent
        )
        do {
            try FileManager.default.moveItem(at: output, to: destination)
            try verifyNonEmpty(destination)
            var metadata = loadArchiveMetadata()
            metadata[archiveMetadataKey(for: destination)] = WallpaperArchiveMetadata(
                uuid: normalizeUUID(uuid),
                displayName: destination.deletingPathExtension().lastPathComponent,
                kind: .encoded
            )
            try saveArchiveMetadata(metadata)
        } catch {
            if FileManager.default.fileExists(atPath: destination.path),
               !FileManager.default.fileExists(atPath: output.path) {
                try? FileManager.default.moveItem(at: destination, to: output)
            }
            throw error
        }
        return destination
    }

    static func archiveEntries() -> [WallpaperArchiveEntry] {
        let metadata = loadArchiveMetadata()
        let locations: [(directory: URL, kind: WallpaperArchiveKind)] = [
            (AppPaths.archiveDirectory, .original),
            (AppPaths.encodedArchiveDirectory, .encoded)
        ]
        let entries = locations.flatMap { location in
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: location.directory,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            return urls.compactMap { url -> WallpaperArchiveEntry? in
                guard url.pathExtension.lowercased() == "mov",
                      (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                    return nil
                }
                let stem = url.deletingPathExtension().lastPathComponent
                let record = metadata[archiveMetadataKey(for: url)] ?? metadata[url.lastPathComponent]
                let kind = record?.kind ?? location.kind
                let number = kind == .original
                    ? stem.split(separator: "-", maxSplits: 1).first.flatMap { Int($0) } ?? 0
                    : 0
                let uuid = record?.uuid ?? (
                    kind == .encoded
                        ? uuidFromProcessedFilename(url)
                        : uuidFromArchiveFilename(url)
                )
                return WallpaperArchiveEntry(
                    url: url,
                    previewURL: previewURL(for: url),
                    number: number,
                    uuid: uuid,
                    displayName: record?.displayName ?? stem,
                    kind: kind
                )
            }
        }
        return entries.sorted {
            if $0.kind != $1.kind { return $0.kind == .encoded }
            if $0.kind == .original, $0.number != $1.number {
                return $0.number > $1.number
            }
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
        if entry.kind == .original {
            let numberPrefix = "\(entry.number)-"
            if stem.hasPrefix(numberPrefix) {
                stem.removeFirst(numberPrefix.count)
            }
        }
        guard !stem.isEmpty else {
            throw AppError("自定义归档名称无效。")
        }
        let destinationDirectory = entry.kind == .encoded
            ? AppPaths.encodedArchiveDirectory
            : AppPaths.archiveDirectory
        let filename = entry.kind == .encoded ? "\(stem).mov" : "\(entry.number)-\(stem).mov"
        try AppPaths.ensureDirectory(destinationDirectory)
        let destination = destinationDirectory.appendingPathComponent(filename)
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
        let oldRecord = metadata.removeValue(forKey: archiveMetadataKey(for: entry.url))
        metadata.removeValue(forKey: entry.url.lastPathComponent)
        metadata[archiveMetadataKey(for: destination)] = WallpaperArchiveMetadata(
            uuid: entry.uuid ?? oldRecord?.uuid,
            displayName: destination.deletingPathExtension().lastPathComponent,
            kind: entry.kind
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
        metadata.removeValue(forKey: archiveMetadataKey(for: entry.url))
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
        if let uuid = normalizeUUID(stem) { return uuid }
        guard let separator = stem.firstIndex(of: "-") else { return nil }
        let candidate = String(stem[stem.index(after: separator)...])
        return normalizeUUID(candidate)
    }

    private static func uuidFromProcessedFilename(_ url: URL) -> String? {
        let stem = url.deletingPathExtension().lastPathComponent
        guard let separator = stem.range(of: "-fixed-") else { return nil }
        return normalizeUUID(String(stem[..<separator.lowerBound]))
    }

    private static func archiveMetadataKey(for url: URL) -> String {
        if url.deletingLastPathComponent().standardizedFileURL
            == AppPaths.archiveDirectory.standardizedFileURL {
            return url.lastPathComponent
        }
        return "\(AppPaths.encodedArchiveDirectory.lastPathComponent)/\(url.lastPathComponent)"
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

    static func migrateProcessedOutputs() {
        guard (try? AppPaths.ensureDirectory(AppPaths.archiveDirectory)) != nil,
              (try? AppPaths.ensureDirectory(AppPaths.previewDirectory)) != nil,
              (try? AppPaths.ensureDirectory(AppPaths.encodedArchiveDirectory)) != nil else {
            return
        }
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: AppPaths.processedDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        var metadata = loadArchiveMetadata()
        var didChange = false
        for url in urls where url.pathExtension.lowercased() == "mov" {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                continue
            }
            let destination = AppPaths.encodedArchiveDirectory.appendingPathComponent(url.lastPathComponent)
            guard !FileManager.default.fileExists(atPath: destination.path) else { continue }
            do {
                try FileManager.default.moveItem(at: url, to: destination)
                try verifyNonEmpty(destination)
                metadata[archiveMetadataKey(for: destination)] = WallpaperArchiveMetadata(
                    uuid: uuidFromProcessedFilename(destination),
                    displayName: destination.deletingPathExtension().lastPathComponent,
                    kind: .encoded
                )
                didChange = true
            } catch {
                try? FileManager.default.removeItem(at: destination)
            }
        }
        if didChange {
            try? saveArchiveMetadata(metadata)
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
