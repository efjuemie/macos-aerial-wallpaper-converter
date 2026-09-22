import Foundation

@main
enum GeometryLogicSmoke {
    static func main() {
        testNativeCanvasResolution()
        testHorizontalBoundaries(screenAspect: 3.0 / 2.0, label: "3:2")
        testHorizontalBoundaries(screenAspect: 16.0 / 10.0, label: "16:10")
        testVerticalBoundariesForUltrawideScreen()
        print("PASS: native canvas resolution and achievable two-stage crop boundaries")
    }

    private static func testNativeCanvasResolution() {
        let native = AerialCanvas(width: 3840, height: 2152)
        let custom = AerialCanvas(width: 2940, height: 1912)
        let manifest = AerialCanvas(width: 1920, height: 1080)
        let nativeProfile = profile(for: native)
        let customProfile = profile(for: custom)

        let freshConflict = NativeCanvasResolver.resolve(
            persistedRecord: nil,
            manifestCanvas: manifest,
            targetProfile: nativeProfile,
            hasAnyHistoricalRecords: false,
            earliestOriginalProfile: nil,
            earliestBackupProfile: nil
        )
        require(freshConflict?.canvas == native, "fresh target must win over manifest")
        require(freshConflict?.source == .currentTarget, "fresh target provenance must be recorded")
        require(freshConflict?.conflicts.isEmpty == false, "manifest mismatch must be visible")

        let persisted = NativeCanvasRecord(
            canvas: native,
            source: .currentTarget,
            originalTargetSHA256: String(repeating: "a", count: 64),
            capturedAt: Date(timeIntervalSince1970: 1),
            geometry: nativeProfile
        )
        let persistedResolution = NativeCanvasResolver.resolve(
            persistedRecord: persisted,
            manifestCanvas: manifest,
            targetProfile: profile(for: custom),
            hasAnyHistoricalRecords: true,
            earliestOriginalProfile: nil,
            earliestBackupProfile: nil
        )
        require(persistedResolution?.canvas == native, "trusted persisted record must win over current replacement")
        require(persistedResolution?.source == .persisted, "persisted provenance must be recorded")

        let legacyFresh = NativeCanvasResolver.resolve(
            persistedRecord: .legacy(canvas: native),
            manifestCanvas: manifest,
            targetProfile: nativeProfile,
            hasAnyHistoricalRecords: false,
            earliestOriginalProfile: nil,
            earliestBackupProfile: nil
        )
        require(legacyFresh?.source == .manifest, "a v1 record proves prior use and must not relabel the current target as an Apple original")

        let legacyManifestFallback = NativeCanvasResolver.resolve(
            persistedRecord: .legacy(canvas: native),
            manifestCanvas: manifest,
            targetProfile: customProfile,
            hasAnyHistoricalRecords: true,
            earliestOriginalProfile: nil,
            earliestBackupProfile: nil
        )
        require(legacyManifestFallback?.source == .manifest, "history without trusted evidence may use a labelled manifest fallback")

        let falseSHA = NativeCanvasResolver.resolve(
            persistedRecord: persisted,
            manifestCanvas: manifest,
            targetProfile: customProfile,
            hasAnyHistoricalRecords: true,
            earliestOriginalProfile: nativeProfile,
            earliestBackupProfile: nativeProfile,
            earliestOriginalSHA256: String(repeating: "b", count: 64)
        )
        require(falseSHA?.source == .historyConsensus, "a persisted SHA conflicting with the archived original must not win")

        let reidentified = NativeCanvasResolver.resolve(
            persistedRecord: NativeCanvasRecord(
                canvas: native,
                source: .reidentified,
                originalTargetSHA256: String(repeating: "c", count: 64),
                capturedAt: Date(timeIntervalSince1970: 3),
                geometry: nativeProfile
            ),
            manifestCanvas: manifest,
            targetProfile: nativeProfile,
            hasAnyHistoricalRecords: true,
            earliestOriginalProfile: customProfile,
            earliestBackupProfile: customProfile,
            earliestOriginalSHA256: String(repeating: "a", count: 64)
        )
        require(reidentified?.source == .persisted, "explicitly re-identified downloaded original must supersede older archived evidence")
        let reidentifiedRecord = NativeCanvasRecord(
            canvas: native,
            source: .reidentified,
            originalTargetSHA256: String(repeating: "c", count: 64),
            capturedAt: Date(timeIntervalSince1970: 3),
            geometry: nativeProfile
        )
        let activeOriginal = GeometryDiagnostics.originalReferenceProfile(
            chosenSource: .persisted,
            targetHash: String(repeating: "c", count: 64),
            targetProfile: nativeProfile,
            persistedRecord: reidentifiedRecord,
            archiveProfile: customProfile
        )
        require(activeOriginal == nativeProfile, "reidentified current target may serve as original only while its SHA still matches")
        let replacedTarget = GeometryDiagnostics.originalReferenceProfile(
            chosenSource: .persisted,
            targetHash: String(repeating: "d", count: 64),
            targetProfile: customProfile,
            persistedRecord: reidentifiedRecord,
            archiveProfile: customProfile
        )
        require(replacedTarget == nativeProfile, "after replacement, parity must use saved original geometry rather than custom target")

        let persistedConflict = NativeCanvasResolver.resolve(
            persistedRecord: persisted,
            manifestCanvas: manifest,
            targetProfile: customProfile,
            hasAnyHistoricalRecords: true,
            earliestOriginalProfile: customProfile,
            earliestBackupProfile: nativeProfile
        )
        require(persistedConflict == nil, "trusted persisted dimensions conflicting with original archive must fail closed")

        let consensus = NativeCanvasResolver.resolve(
            persistedRecord: nil,
            manifestCanvas: manifest,
            targetProfile: customProfile,
            hasAnyHistoricalRecords: true,
            earliestOriginalProfile: nativeProfile,
            earliestBackupProfile: nativeProfile
        )
        require(consensus?.canvas == native, "matching original and backup must recover baseline")
        require(consensus?.source == .historyConsensus, "history consensus provenance must be recorded")

        let conflict = NativeCanvasResolver.resolve(
            persistedRecord: nil,
            manifestCanvas: manifest,
            targetProfile: customProfile,
            hasAnyHistoricalRecords: true,
            earliestOriginalProfile: nativeProfile,
            earliestBackupProfile: customProfile
        )
        require(conflict == nil, "conflicting history evidence must fail closed")

        let historyWithoutEvidence = NativeCanvasResolver.resolve(
            persistedRecord: nil,
            manifestCanvas: manifest,
            targetProfile: customProfile,
            hasAnyHistoricalRecords: true,
            earliestOriginalProfile: nil,
            earliestBackupProfile: nil
        )
        require(historyWithoutEvidence?.source == .manifest, "historical replacement must not trust current target; manifest is a labelled fallback")
        let historyWithoutAnyEvidence = NativeCanvasResolver.resolve(
            persistedRecord: nil,
            manifestCanvas: nil,
            targetProfile: customProfile,
            hasAnyHistoricalRecords: true,
            earliestOriginalProfile: nil,
            earliestBackupProfile: nil
        )
        require(historyWithoutAnyEvidence == nil, "historical replacement without trusted evidence or manifest must fail closed")

        let manifestFallback = NativeCanvasResolver.resolve(
            persistedRecord: nil,
            manifestCanvas: manifest,
            targetProfile: nil,
            hasAnyHistoricalRecords: false,
            earliestOriginalProfile: nil,
            earliestBackupProfile: nil
        )
        require(manifestFallback?.source == .manifest, "manifest should remain an explicit fallback")

        let implicitSquare = AerialGeometryProfile(
            encodedSize: GeometrySize(width: native.width, height: native.height),
            naturalSize: GeometrySize(width: native.width, height: native.height),
            cleanAperture: GeometryRect(x: 0, y: 0, width: native.width, height: native.height),
            presentationSize: GeometrySize(width: native.width, height: native.height),
            pixelAspectRatio: nil,
            preferredTransform: GeometryTransform(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0),
            hasExplicitCleanAperture: false,
            hasExplicitPixelAspectRatio: false
        )
        require(implicitSquare.isCompatibleWithFixedEncoder, "implicit square PAR and full aperture are semantically compatible")
        let rotated = AerialGeometryProfile(
            encodedSize: GeometrySize(width: native.width, height: native.height),
            naturalSize: GeometrySize(width: native.width, height: native.height),
            cleanAperture: GeometryRect(x: 0, y: 0, width: native.width, height: native.height),
            presentationSize: GeometrySize(width: native.width, height: native.height),
            pixelAspectRatio: PixelAspectRatio(horizontal: 1, vertical: 1),
            preferredTransform: GeometryTransform(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: 0),
            hasExplicitCleanAperture: true,
            hasExplicitPixelAspectRatio: true
        )
        require(!rotated.isCompatibleWithFixedEncoder, "rotated original geometry must fail closed")
        let parityDifferences = GeometryDiagnostics.profileDifferences(
            "final-vs-original", left: customProfile, right: nativeProfile
        )
        require(parityDifferences.contains(where: { $0.contains("encodedSize") }), "profile parity must identify the differing field")

        testNativeCanvasStoreMigration(native: native, profile: nativeProfile)
    }

    private static func profile(for canvas: AerialCanvas) -> AerialGeometryProfile {
        AerialGeometryProfile(
            encodedSize: GeometrySize(width: canvas.width, height: canvas.height),
            naturalSize: GeometrySize(width: canvas.width, height: canvas.height),
            cleanAperture: GeometryRect(x: 0, y: 0, width: canvas.width, height: canvas.height),
            presentationSize: GeometrySize(width: canvas.width, height: canvas.height),
            pixelAspectRatio: PixelAspectRatio(horizontal: 1, vertical: 1),
            preferredTransform: GeometryTransform(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0),
            hasExplicitCleanAperture: true,
            hasExplicitPixelAspectRatio: true
        )
    }

    private static func testNativeCanvasStoreMigration(native: AerialCanvas, profile: AerialGeometryProfile) {
        let directory = temporaryDirectory()
        let url = directory.appendingPathComponent("native-canvases.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let legacyJSON = "{\"A\":{\"width\":3840,\"height\":2152}}"
        try! Data(legacyJSON.utf8).write(to: url)
        let loaded = try! NativeCanvasStore.load(from: url)
        require(loaded["A"]?.source == NativeCanvasSource.legacy, "v1 records must migrate as legacy")
        require(loaded["A"]?.canvas == native, "v1 canvas dimensions must be retained")

        try! NativeCanvasStore.save(
            NativeCanvasRecord(
                canvas: native,
                source: .currentTarget,
                originalTargetSHA256: String(repeating: "a", count: 64),
                capturedAt: Date(timeIntervalSince1970: 2),
                geometry: profile
            ),
            uuid: "A",
            to: url
        )
        let migratedData = try! Data(contentsOf: url)
        let migratedObject = try! JSONSerialization.jsonObject(with: migratedData) as! [String: Any]
        require(migratedObject["version"] as? Int == 2, "saved records must use v2 envelope")
        require((migratedObject["records"] as? [String: Any])?["A"] != nil, "saved v2 record must be retained")
    }

    private static func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wallpaper-converter-geometry-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func testHorizontalBoundaries(screenAspect: Double, label: String) {
        let canvas = AerialCanvas(width: 3840, height: 2152)
        guard let centered = WallpaperGeometry.cropSelection(
            sourceWidth: 2208,
            sourceHeight: 1048,
            screenAspect: screenAspect,
            outputCanvas: canvas
        ), let range = WallpaperGeometry.achievableOriginRange(for: centered) else {
            fail("\(label) horizontal crop was not achievable")
        }
        require(close(centered.originX, (centered.sourceWidth - centered.cropWidth) / 2), "\(label) initial crop is not centered")
        require(close(centered.originY, (centered.sourceHeight - centered.cropHeight) / 2), "\(label) initial crop Y is not centered")
        require(range.minX > 0 && range.maxX < centered.sourceWidth - centered.cropWidth, "\(label) did not reserve native-canvas side margins")

        var left = centered
        left.originX = -10_000
        left.clamp()
        require(close(left.originX, range.minX), "\(label) left boundary clamp failed")
        assertVisibleSelection(left, label: "\(label) left")

        var right = centered
        right.originX = 10_000
        right.clamp()
        require(close(right.originX, range.maxX), "\(label) right boundary clamp failed")
        assertVisibleSelection(right, label: "\(label) right")
    }

    private static func testVerticalBoundariesForUltrawideScreen() {
        let screenAspect = 21.0 / 9.0
        guard let centered = WallpaperGeometry.cropSelection(
            sourceWidth: 3000,
            sourceHeight: 1800,
            screenAspect: screenAspect,
            outputCanvas: AerialCanvas(width: 3840, height: 2152)
        ), let range = WallpaperGeometry.achievableOriginRange(for: centered) else {
            fail("ultrawide vertical crop was not achievable")
        }
        require(close(centered.originX, 0), "ultrawide initial crop X is not centered")
        require(close(centered.originY, (centered.sourceHeight - centered.cropHeight) / 2), "ultrawide initial crop is not centered")
        require(range.minY > 0 && range.maxY < centered.sourceHeight - centered.cropHeight, "ultrawide did not reserve native-canvas top/bottom margins")

        var top = centered
        top.originY = -10_000
        top.clamp()
        require(close(top.originY, range.minY), "ultrawide top boundary clamp failed")
        assertVisibleSelection(top, label: "ultrawide top")

        var bottom = centered
        bottom.originY = 10_000
        bottom.clamp()
        require(close(bottom.originY, range.maxY), "ultrawide bottom boundary clamp failed")
        assertVisibleSelection(bottom, label: "ultrawide bottom")
    }

    private static func assertVisibleSelection(
        _ selection: WallpaperCropSelection,
        label: String
    ) {
        let visible = WallpaperGeometry.visibleSourceRectAfterSystemCrop(selection: selection)
        require(close(visible.origin.x, selection.originX), "\(label) visible X differs from preview")
        require(close(visible.origin.y, selection.originY), "\(label) visible Y differs from preview")
        require(close(visible.width, selection.cropWidth), "\(label) visible width differs from preview")
        require(close(visible.height, selection.cropHeight), "\(label) visible height differs from preview")

        let placement = WallpaperGeometry.renderPlacement(for: selection)
        let outputWidth = Double(selection.outputWidth)
        let outputHeight = Double(selection.outputHeight)
        require(placement.translationX <= 0.01, "\(label) exposed the left canvas edge")
        require(placement.translationY <= 0.01, "\(label) exposed the top canvas edge")
        require(placement.translationX + selection.sourceWidth * placement.scale >= outputWidth - 0.01, "\(label) exposed the right canvas edge")
        require(placement.translationY + selection.sourceHeight * placement.scale >= outputHeight - 0.01, "\(label) exposed the bottom canvas edge")
    }

    private static func close(_ left: Double, _ right: Double) -> Bool {
        abs(left - right) < 0.02
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fail(message) }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write("FAIL: \(message)\n".data(using: .utf8)!)
        exit(1)
    }
}
