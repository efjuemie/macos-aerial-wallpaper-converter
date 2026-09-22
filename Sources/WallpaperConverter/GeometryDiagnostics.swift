import AppKit
import Foundation

struct GeometryScreenSnapshot: Codable, Equatable, Sendable {
    let isMain: Bool
    let frameWidthPoints: Double
    let frameHeightPoints: Double
    let backingScaleFactor: Double
    let pixelWidth: Int
    let pixelHeight: Int

    var aspect: Double {
        guard pixelHeight > 0 else { return 0 }
        return Double(pixelWidth) / Double(pixelHeight)
    }
}

struct GeometryVideoSnapshot: Codable, Equatable, Sendable {
    let basename: String
    let fileSize: Int64?
    let duration: Double?
    let profile: AerialGeometryProfile?
}

struct GeometryCropDiagnostic: Codable, Equatable, Sendable {
    let screenAspect: Double
    let sourceWidth: Double
    let sourceHeight: Double
    let sourceAspect: Double
    let outputCanvas: AerialCanvas
    let outputAspect: Double
    let cropWidth: Double
    let cropHeight: Double
    let originX: Double
    let originY: Double
    let placementScale: Double
    let placementTranslationX: Double
    let placementTranslationY: Double
    let visibleSourceRect: GeometryRect

    init(selection: WallpaperCropSelection, screenAspect: Double) {
        let placement = WallpaperGeometry.renderPlacement(for: selection)
        let visible = WallpaperGeometry.visibleSourceRectAfterSystemCrop(
            selection: selection,
            screenAspect: screenAspect
        )
        self.screenAspect = screenAspect
        self.sourceWidth = selection.sourceWidth
        self.sourceHeight = selection.sourceHeight
        self.sourceAspect = selection.sourceWidth / selection.sourceHeight
        self.outputCanvas = AerialCanvas(width: selection.outputWidth, height: selection.outputHeight)
        self.outputAspect = Double(selection.outputWidth) / Double(selection.outputHeight)
        self.cropWidth = selection.cropWidth
        self.cropHeight = selection.cropHeight
        self.originX = selection.originX
        self.originY = selection.originY
        self.placementScale = placement.scale
        self.placementTranslationX = placement.translationX
        self.placementTranslationY = placement.translationY
        self.visibleSourceRect = GeometryRect(
            x: visible.origin.x,
            y: visible.origin.y,
            width: visible.width,
            height: visible.height
        )
    }
}

struct GeometryDiagnosticReport: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let appVersion: String
    let createdAt: Date
    let macOS: String
    let architecture: String
    let screens: [GeometryScreenSnapshot]
    let targetUUID: String
    let input: GeometryVideoSnapshot?
    let targetBefore: GeometryVideoSnapshot?
    let targetBeforeSHA256: String?
    let referenceOriginal: GeometryVideoSnapshot?
    let manifestCanvas: AerialCanvas?
    let persistedRecord: NativeCanvasRecord?
    let historyEvidence: [String]
    let chosenCanvas: AerialCanvas?
    let chosenSource: NativeCanvasSource?
    let chosenEvidence: String?
    let crop: GeometryCropDiagnostic?
    var intermediate: GeometryVideoSnapshot?
    var finalOutput: GeometryVideoSnapshot?
    var finalOutputSHA256: String?
    var installedTarget: GeometryVideoSnapshot?
    var installedTargetSHA256: String?
    var outputMatchesInstalledTarget: Bool?
    var diffs: [String]
    let conflicts: [String]
    var phenomenon: String?
    var notes: [String]

    static let schemaVersion = 2

    var summary: String {
        let canvas = chosenCanvas.map { "\($0.width)x\($0.height)" } ?? "unknown"
        let source = chosenSource?.rawValue ?? "unknown"
        return "canvas=\(canvas), source=\(source), conflicts=\(conflicts.count), screens=\(screens.count)"
    }

    var warningSummary: String? {
        var warnings: [String] = []
        if chosenSource?.isFallback == true {
            warnings.append("原生画布仅由低可信来源提供：\(chosenSource?.displayName ?? "未知")。")
        }
        if !conflicts.isEmpty {
            warnings.append("原生画布证据存在冲突，请核对诊断报告后再继续替换。")
        }
        if !diffs.isEmpty {
            warnings.append("目标、输出或安装后文件的几何 profile 存在差异。")
        }
        if outputMatchesInstalledTarget == false {
            warnings.append("最终输出与安装后的目标文件 SHA-256 不一致。")
        }
        return warnings.isEmpty ? nil : warnings.joined(separator: " ")
    }

    var geometryLogSummary: String {
        let target = targetBefore?.profile?.compactDescription ?? "unavailable"
        let original = referenceOriginal?.profile?.compactDescription ?? "unavailable"
        let intermediate = intermediate?.profile?.compactDescription ?? "unavailable"
        let final = finalOutput?.profile?.compactDescription ?? "unavailable"
        let installed = installedTarget?.profile?.compactDescription ?? "unavailable"
        let canvas = chosenCanvas.map { "\($0.width)x\($0.height)" } ?? "unknown"
        let source = chosenSource?.rawValue ?? "unknown"
        let conflictText = conflicts.isEmpty ? "none" : conflicts.joined(separator: " | ")
        return "[Geometry] uuid=\(targetUUID) chosenCanvas=\(canvas) source=\(source) " +
            "target-before=\(target) original-reference=\(original) intermediate=\(intermediate) final-output=\(final) " +
            "installed-target=\(installed) conflicts=\(conflictText) " +
            "outputMatchesInstalled=\(outputMatchesInstalledTarget.map(String.init) ?? "unknown")"
    }
}

enum GeometryDiagnostics {
    static let directory = AppPaths.appSupport.appendingPathComponent("Diagnostics", isDirectory: true)

    static func currentScreens() -> [GeometryScreenSnapshot] {
        let main = NSScreen.main
        return NSScreen.screens.map { screen in
            let frame = screen.frame
            let scale = screen.backingScaleFactor
            return GeometryScreenSnapshot(
                isMain: screen == main,
                frameWidthPoints: frame.width,
                frameHeightPoints: frame.height,
                backingScaleFactor: scale,
                pixelWidth: Int((frame.width * scale).rounded()),
                pixelHeight: Int((frame.height * scale).rounded())
            )
        }
    }

    static func mainAspect(from screens: [GeometryScreenSnapshot] = currentScreens()) -> Double? {
        guard let main = screens.first(where: \.isMain), main.aspect > 0 else { return nil }
        return main.aspect
    }

    static func displayAspectWarning(from screens: [GeometryScreenSnapshot] = currentScreens()) -> String? {
        guard screens.count > 1 else { return nil }
        let aspects = Set(screens.map { Int(($0.aspect * 10_000).rounded()) })
        guard aspects.count > 1 else { return nil }
        return "检测到不同宽高比的多台显示器：裁剪以主显示器为基准，其他显示器上的效果可能不同。"
    }

    static func profileDifferences(
        _ label: String,
        left: AerialGeometryProfile?,
        right: AerialGeometryProfile?
    ) -> [String] {
        guard let left, let right else { return [] }
        return left.differences(from: right).map { "\(label): \($0)" }
    }

    static func originalReferenceProfile(
        chosenSource: NativeCanvasSource?,
        targetHash: String?,
        targetProfile: AerialGeometryProfile?,
        persistedRecord: NativeCanvasRecord?,
        archiveProfile: AerialGeometryProfile?
    ) -> AerialGeometryProfile? {
        if chosenSource == .currentTarget || (
            persistedRecord?.source == .reidentified
                && targetHash != nil
                && targetHash == persistedRecord?.originalTargetSHA256
        ) {
            return targetProfile
        }
        return persistedRecord?.geometry ?? archiveProfile
    }

    static func export(_ report: GeometryDiagnosticReport) throws -> URL {
        try AppPaths.ensureDirectory(directory)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "\(formatter.string(from: report.createdAt))-geometry.json"
        let destination = directory.appendingPathComponent(name)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(report).write(to: destination, options: [.atomic])
        return destination
    }
}
