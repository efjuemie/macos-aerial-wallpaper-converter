import AppKit
import Foundation

enum GeometryOrientation: String, Codable, Equatable, Sendable {
    case portrait
    case landscape
    case square
    case unknown

    init(width: Double, height: Double) {
        guard width > 0, height > 0 else {
            self = .unknown
            return
        }
        let difference = abs(width - height)
        let tolerance = max(width, height) * 0.01
        if difference <= tolerance {
            self = .square
        } else if width > height {
            self = .landscape
        } else {
            self = .portrait
        }
    }

    var displayName: String {
        switch self {
        case .portrait: return "纵向"
        case .landscape: return "横向"
        case .square: return "方形"
        case .unknown: return "未知"
        }
    }

    var isKnown: Bool { self != .unknown }
}

struct GeometryOriginRange: Codable, Equatable, Sendable {
    let minX: Double
    let maxX: Double
    let minY: Double
    let maxY: Double

    var movementWidth: Double { max(0, maxX - minX) }
    var movementHeight: Double { max(0, maxY - minY) }
}

struct GeometryOrientationAssessment: Codable, Equatable, Sendable {
    let sourceOrientation: GeometryOrientation
    let screenOrientation: GeometryOrientation
    let targetEncodedOrientation: GeometryOrientation
    let targetPresentationOrientation: GeometryOrientation
    let targetEffectiveOrientation: GeometryOrientation
    let chosenCanvasOrientation: GeometryOrientation
    let manifestOrientation: GeometryOrientation
    let chosenSource: NativeCanvasSource?
    let canvasScreenConflict: Bool
    let manifestTargetConflict: Bool
    let trustedOriginalPresentationConflict: Bool
    let warningMessage: String?
    let blockingReason: String?

    var shouldBlockProcessing: Bool { blockingReason != nil }
    var requiresReview: Bool {
        canvasScreenConflict || manifestTargetConflict || trustedOriginalPresentationConflict
    }
}

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
    let originRange: GeometryOriginRange?
    let movementWidth: Double?
    let movementHeight: Double?
    let movementEffectivelyLocked: Bool
    let canvasOrientation: GeometryOrientation
    let screenOrientation: GeometryOrientation
    let sourceOrientation: GeometryOrientation
    let maxAchievableCropWidth: Double?
    let maxAchievableCropHeight: Double?

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
        let range = WallpaperGeometry.achievableOriginRange(for: selection)
        self.originRange = range.map {
            GeometryOriginRange(
                minX: $0.minX,
                maxX: $0.maxX,
                minY: $0.minY,
                maxY: $0.maxY
            )
        }
        self.movementWidth = originRange?.movementWidth
        self.movementHeight = originRange?.movementHeight
        self.movementEffectivelyLocked = (movementWidth ?? 0) <= 2 || (movementHeight ?? 0) <= 2
        self.canvasOrientation = GeometryOrientation(
            width: Double(selection.outputWidth),
            height: Double(selection.outputHeight)
        )
        self.screenOrientation = GeometryOrientation(width: screenAspect, height: 1)
        self.sourceOrientation = GeometryOrientation(
            width: selection.sourceWidth,
            height: selection.sourceHeight
        )
        let maximum = WallpaperGeometry.maximumSelection(for: selection)
        self.maxAchievableCropWidth = maximum?.cropWidth
        self.maxAchievableCropHeight = maximum?.cropHeight
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
    let orientationAssessment: GeometryOrientationAssessment?
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

    static let schemaVersion = 3

    init(
        schemaVersion: Int,
        appVersion: String,
        createdAt: Date,
        macOS: String,
        architecture: String,
        screens: [GeometryScreenSnapshot],
        targetUUID: String,
        input: GeometryVideoSnapshot?,
        targetBefore: GeometryVideoSnapshot?,
        targetBeforeSHA256: String?,
        referenceOriginal: GeometryVideoSnapshot?,
        manifestCanvas: AerialCanvas?,
        persistedRecord: NativeCanvasRecord?,
        historyEvidence: [String],
        chosenCanvas: AerialCanvas?,
        chosenSource: NativeCanvasSource?,
        chosenEvidence: String?,
        crop: GeometryCropDiagnostic?,
        intermediate: GeometryVideoSnapshot?,
        finalOutput: GeometryVideoSnapshot?,
        finalOutputSHA256: String?,
        installedTarget: GeometryVideoSnapshot?,
        installedTargetSHA256: String?,
        outputMatchesInstalledTarget: Bool?,
        diffs: [String],
        conflicts: [String],
        phenomenon: String?,
        notes: [String]
    ) {
        let originalProfile = GeometryDiagnostics.originalReferenceProfile(
            chosenSource: chosenSource,
            targetHash: targetBeforeSHA256,
            targetProfile: targetBefore?.profile,
            persistedRecord: persistedRecord,
            archiveProfile: referenceOriginal?.profile
        )
        let assessment = GeometryDiagnostics.orientationAssessment(
            sourceSize: crop.map {
                GeometrySize(width: $0.sourceWidth, height: $0.sourceHeight)
            } ?? input?.profile.map(GeometryDiagnostics.displaySize),
            screens: screens,
            targetProfile: targetBefore?.profile,
            referenceOriginalProfile: originalProfile,
            chosenCanvas: chosenCanvas,
            chosenSource: chosenSource,
            manifestCanvas: manifestCanvas
        )
        var reportConflicts = conflicts
        var reportNotes = notes
        if let blockingReason = assessment.blockingReason {
            reportConflicts.append("orientation: \(blockingReason)")
        }
        if let warning = assessment.warningMessage,
           !reportNotes.contains(where: { $0 == warning }) {
            reportNotes.append("orientation: \(warning)")
        }
        self.schemaVersion = schemaVersion
        self.appVersion = appVersion
        self.createdAt = createdAt
        self.macOS = macOS
        self.architecture = architecture
        self.screens = screens
        self.targetUUID = targetUUID
        self.input = input
        self.targetBefore = targetBefore
        self.targetBeforeSHA256 = targetBeforeSHA256
        self.referenceOriginal = referenceOriginal
        self.manifestCanvas = manifestCanvas
        self.persistedRecord = persistedRecord
        self.historyEvidence = historyEvidence
        self.chosenCanvas = chosenCanvas
        self.chosenSource = chosenSource
        self.chosenEvidence = chosenEvidence
        self.crop = crop
        self.orientationAssessment = assessment
        self.intermediate = intermediate
        self.finalOutput = finalOutput
        self.finalOutputSHA256 = finalOutputSHA256
        self.installedTarget = installedTarget
        self.installedTargetSHA256 = installedTargetSHA256
        self.outputMatchesInstalledTarget = outputMatchesInstalledTarget
        self.diffs = diffs
        self.conflicts = reportConflicts
        self.phenomenon = phenomenon
        self.notes = reportNotes
    }

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
        if let orientationAssessment,
           let warning = orientationAssessment.warningMessage {
            warnings.append(warning)
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
        let orientation = orientationAssessment.map {
            "source=\($0.sourceOrientation.rawValue), screen=\($0.screenOrientation.rawValue), " +
            "target=\($0.targetEncodedOrientation.rawValue)/\($0.targetPresentationOrientation.rawValue)/\($0.targetEffectiveOrientation.rawValue), " +
            "chosen=\($0.chosenCanvasOrientation.rawValue), manifest=\($0.manifestOrientation.rawValue)"
        } ?? "unavailable"
        return "[Geometry] uuid=\(targetUUID) chosenCanvas=\(canvas) source=\(source) " +
            "target-before=\(target) original-reference=\(original) intermediate=\(intermediate) final-output=\(final) " +
            "installed-target=\(installed) conflicts=\(conflictText) " +
            "orientation=\(orientation) " +
            "outputMatchesInstalled=\(outputMatchesInstalledTarget.map(String.init) ?? "unknown")"
    }
}

enum GeometryDiagnostics {
    static let directory = AppPaths.appSupport.appendingPathComponent("Diagnostics", isDirectory: true)

    static func orientationAssessment(
        sourceSize: GeometrySize?,
        screens: [GeometryScreenSnapshot] = currentScreens(),
        targetProfile: AerialGeometryProfile?,
        referenceOriginalProfile: AerialGeometryProfile?,
        chosenCanvas: AerialCanvas?,
        chosenSource: NativeCanvasSource?,
        manifestCanvas: AerialCanvas?
    ) -> GeometryOrientationAssessment {
        let sourceOrientation = sourceSize.map {
            GeometryOrientation(width: $0.width, height: $0.height)
        } ?? .unknown
        let screenOrientation = screens.first(where: \.isMain).map {
            GeometryOrientation(width: Double($0.pixelWidth), height: Double($0.pixelHeight))
        } ?? .unknown
        let targetEncodedOrientation = targetProfile.map {
            GeometryOrientation(width: $0.encodedSize.width, height: $0.encodedSize.height)
        } ?? .unknown
        let targetPresentationOrientation = targetProfile.map {
            GeometryOrientation(width: $0.presentationSize.width, height: $0.presentationSize.height)
        } ?? .unknown
        let targetEffectiveOrientation = targetProfile.map(effectiveOrientation(for:)) ?? .unknown
        let chosenCanvasOrientation = chosenCanvas.map {
            GeometryOrientation(width: Double($0.width), height: Double($0.height))
        } ?? .unknown
        let manifestOrientation = manifestCanvas.map {
            GeometryOrientation(width: Double($0.width), height: Double($0.height))
        } ?? .unknown

        let canvasScreenConflict = orientationsConflict(chosenCanvasOrientation, screenOrientation)
        let manifestTargetConflict = orientationsConflict(manifestOrientation, targetEffectiveOrientation)
        let originalProfile = referenceOriginalProfile ?? (
            isTrustedSource(chosenSource) ? targetProfile : nil
        )
        let trustedOriginalOrientation = originalProfile.map(effectiveOrientation(for:)) ?? .unknown
        let trustedOriginalPresentationConflict = isTrustedSource(chosenSource)
            && orientationsConflict(trustedOriginalOrientation, chosenCanvasOrientation)

        var messages: [String] = []
        if canvasScreenConflict {
            messages.append(
                "目标编码画布为\(chosenCanvasOrientation.displayName)，主显示器为\(screenOrientation.displayName)；" +
                "请确认目标原生画布方向，裁剪范围将严格受几何约束。"
            )
        }
        if manifestTargetConflict {
            messages.append(
                "系统清单推断方向（\(manifestOrientation.displayName)）与目标展示几何（\(targetEffectiveOrientation.displayName)）不一致。"
            )
        }

        let blockingReason: String?
        if trustedOriginalPresentationConflict {
            blockingReason =
                "可信原壁纸的实际展示方向（\(trustedOriginalOrientation.displayName)）与选用编码画布（" +
                "\(chosenCanvasOrientation.displayName)）冲突，已停止处理；请重新识别目标原壁纸后再试。"
            messages.append(blockingReason!)
        } else {
            blockingReason = nil
        }

        return GeometryOrientationAssessment(
            sourceOrientation: sourceOrientation,
            screenOrientation: screenOrientation,
            targetEncodedOrientation: targetEncodedOrientation,
            targetPresentationOrientation: targetPresentationOrientation,
            targetEffectiveOrientation: targetEffectiveOrientation,
            chosenCanvasOrientation: chosenCanvasOrientation,
            manifestOrientation: manifestOrientation,
            chosenSource: chosenSource,
            canvasScreenConflict: canvasScreenConflict,
            manifestTargetConflict: manifestTargetConflict,
            trustedOriginalPresentationConflict: trustedOriginalPresentationConflict,
            warningMessage: messages.isEmpty ? nil : messages.joined(separator: " "),
            blockingReason: blockingReason
        )
    }

    static func displaySize(_ profile: AerialGeometryProfile) -> GeometrySize {
        let transformed = transformedBoundsSize(
            width: profile.naturalSize.width,
            height: profile.naturalSize.height,
            transform: profile.preferredTransform
        )
        guard transformed.width > 0, transformed.height > 0 else {
            return profile.presentationSize
        }
        return GeometrySize(width: transformed.width, height: transformed.height)
    }

    static func effectiveOrientation(for profile: AerialGeometryProfile) -> GeometryOrientation {
        let display = displaySize(profile)
        let transformedOrientation = GeometryOrientation(width: display.width, height: display.height)
        if profile.preferredTransform.isIdentity {
            return GeometryOrientation(
                width: profile.presentationSize.width,
                height: profile.presentationSize.height
            )
        }
        return transformedOrientation.isKnown
            ? transformedOrientation
            : GeometryOrientation(width: profile.presentationSize.width, height: profile.presentationSize.height)
    }

    private static func transformedBoundsSize(
        width: Double,
        height: Double,
        transform: GeometryTransform
    ) -> (width: Double, height: Double) {
        let points = [
            (x: 0.0, y: 0.0),
            (x: width, y: 0.0),
            (x: 0.0, y: height),
            (x: width, y: height)
        ].map { point in
            (
                x: transform.a * point.x + transform.c * point.y + transform.tx,
                y: transform.b * point.x + transform.d * point.y + transform.ty
            )
        }
        guard let minX = points.map(\.x).min(),
              let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(),
              let maxY = points.map(\.y).max() else {
            return (0, 0)
        }
        return (abs(maxX - minX), abs(maxY - minY))
    }

    private static func orientationsConflict(
        _ left: GeometryOrientation,
        _ right: GeometryOrientation
    ) -> Bool {
        left.isKnown && right.isKnown && left != right
    }

    private static func isTrustedSource(_ source: NativeCanvasSource?) -> Bool {
        switch source {
        case .currentTarget, .reidentified, .persisted, .historyConsensus:
            return true
        case .manifest, .legacy, .none:
            return false
        }
    }

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
