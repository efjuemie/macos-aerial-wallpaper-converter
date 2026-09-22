import Foundation

@main
enum GeometryLogicSmoke {
    static func main() {
        testNativeCanvasResolution()
        testOrientationAssessment()
        testFixedAspectZoomAndReset()
        testInvalidZoomGeometry()
        testUltrawideInputZoom()
        testHorizontalBoundaries(screenAspect: 3.0 / 2.0, label: "3:2")
        testHorizontalBoundaries(screenAspect: 16.0 / 10.0, label: "16:10")
        testVerticalBoundariesForUltrawideScreen()
        print("PASS: native canvas resolution, fixed-aspect zoom, and achievable two-stage crop boundaries")
    }

    private static func testFixedAspectZoomAndReset() {
        let sourceWidth = 720.0
        let sourceHeight = 410.0
        let screenAspect = 1.60

        guard let portrait = WallpaperGeometry.cropSelection(
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            screenAspect: screenAspect,
            outputCanvas: AerialCanvas(width: 720, height: 1280)
        ) else {
            fail("portrait crop was not achievable")
        }
        require(close(portrait.cropWidth, 230), "portrait maximal crop width changed")
        require(close(portrait.cropHeight, 143.75), "portrait maximal crop height changed")
        require(close(portrait.originX, 245), "portrait maximal crop is not centered on X")
        require(close(portrait.originY, 133.125), "portrait maximal crop is not centered on Y")
        guard let portraitRange = WallpaperGeometry.achievableOriginRange(for: portrait) else {
            fail("portrait crop range was not achievable")
        }
        require(close(portraitRange.minX, 0), "portrait X range minimum changed")
        require(close(portraitRange.maxX, 490), "portrait X range maximum changed")
        require(close(portraitRange.minY, 132.57), "portrait Y range minimum changed")
        require(close(portraitRange.maxY, 133.68), "portrait Y range maximum changed")
        require(portraitRange.maxX - portraitRange.minX > 100, "portrait crop should remain movable on X")
        require(portraitRange.maxY - portraitRange.minY < 2, "portrait crop Y movement should be effectively locked")
        assertVisibleSelection(portrait, label: "portrait maximal")

        guard let reset = WallpaperGeometry.maximumSelection(for: portrait) else {
            fail("portrait maximal reset was not achievable")
        }
        require(close(reset.cropWidth, portrait.cropWidth), "reset changed maximal crop width")
        require(close(reset.cropHeight, portrait.cropHeight), "reset changed maximal crop height")
        require(close(reset.originX, portrait.originX), "reset did not center maximal crop on X")
        require(close(reset.originY, portrait.originY), "reset did not center maximal crop on Y")
        assertVisibleSelection(reset, label: "portrait reset")

        var offCenter = portrait
        offCenter.originX = portraitRange.maxX
        offCenter.originY = portraitRange.maxY
        guard let resetFromOffCenter = WallpaperGeometry.maximumSelection(for: offCenter) else {
            fail("off-center maximal reset was not achievable")
        }
        require(close(resetFromOffCenter.originX, reset.originX), "reset did not recenter an off-center crop on X")
        require(close(resetFromOffCenter.originY, reset.originY), "reset did not recenter an off-center crop on Y")

        guard let zoomed = WallpaperGeometry.zoomedSelection(from: portrait, zoomFactor: 2) else {
            fail("portrait 2x zoom was not achievable")
        }
        require(close(zoomed.cropWidth, 115), "portrait 2x zoom width is not relative to maximal crop")
        require(close(zoomed.cropHeight, 71.875), "portrait 2x zoom height is not relative to maximal crop")
        require(close(zoomed.cropWidth / zoomed.cropHeight, screenAspect), "portrait zoom changed fixed aspect")
        require(close(zoomed.originX + zoomed.cropWidth / 2, portrait.originX + portrait.cropWidth / 2), "portrait zoom did not preserve X center")
        require(close(zoomed.originY + zoomed.cropHeight / 2, portrait.originY + portrait.cropHeight / 2), "portrait zoom did not preserve Y center")
        assertVisibleSelection(zoomed, label: "portrait 2x zoom")

        guard let absoluteZoom = WallpaperGeometry.zoomedSelection(from: zoomed, zoomFactor: 2) else {
            fail("portrait absolute 2x zoom was not repeatable")
        }
        require(close(absoluteZoom.cropWidth, zoomed.cropWidth), "zoom factor was applied cumulatively")
        require(close(absoluteZoom.cropHeight, zoomed.cropHeight), "zoom factor was not absolute")
        require(close(absoluteZoom.originX, zoomed.originX), "absolute zoom changed preserved X center")
        require(close(absoluteZoom.originY, zoomed.originY), "absolute zoom changed preserved Y center")

        var moved = zoomed
        moved.originX = -10_000
        moved.originY = 10_000
        guard let clampedZoom = WallpaperGeometry.zoomedSelection(from: moved, zoomFactor: 2) else {
            fail("out-of-range zoomed crop was not clamped")
        }
        guard let movedRange = WallpaperGeometry.achievableOriginRange(for: clampedZoom) else {
            fail("portrait zoomed crop range was not achievable")
        }
        require(close(clampedZoom.originX, movedRange.minX), "zoomed crop did not clamp to X range")
        require(close(clampedZoom.originY, movedRange.maxY), "zoomed crop did not clamp to Y range")
        assertVisibleSelection(clampedZoom, label: "portrait 2x zoom boundary")

        for canvas in [
            AerialCanvas(width: 1280, height: 720),
            AerialCanvas(width: 1920, height: 1080),
            AerialCanvas(width: 3840, height: 2160)
        ] {
            guard let landscape = WallpaperGeometry.cropSelection(
                sourceWidth: sourceWidth,
                sourceHeight: sourceHeight,
                screenAspect: screenAspect,
                outputCanvas: canvas
            ) else {
                fail("landscape crop \(canvas.width)x\(canvas.height) was not achievable")
            }
            require(close(landscape.cropWidth, 646.4), "landscape maximal crop width changed for \(canvas.width)x\(canvas.height)")
            require(close(landscape.cropHeight, 404), "landscape maximal crop height changed for \(canvas.width)x\(canvas.height)")
            require(close(landscape.cropWidth / landscape.cropHeight, screenAspect), "landscape crop changed fixed aspect")
            assertVisibleSelection(landscape, label: "landscape \(canvas.width)x\(canvas.height)")
            guard let range = WallpaperGeometry.achievableOriginRange(for: landscape) else {
                fail("landscape crop range was not achievable for \(canvas.width)x\(canvas.height)")
            }
            require(range.maxX - range.minX > 0, "landscape crop should retain horizontal movement")
            require(range.maxY - range.minY > 0, "landscape crop should retain vertical movement")
        }
    }

    private static func testInvalidZoomGeometry() {
        guard let valid = WallpaperGeometry.cropSelection(
            sourceWidth: 720,
            sourceHeight: 410,
            screenAspect: 1.60,
            outputCanvas: AerialCanvas(width: 720, height: 1280)
        ) else {
            fail("valid crop was not achievable for invalid-input tests")
        }
        for factor in [0.99, 0, -1, 3.01, .nan, .infinity] {
            require(
                WallpaperGeometry.zoomedSelection(from: valid, zoomFactor: factor) == nil,
                "invalid zoom factor \(factor) must be rejected"
            )
        }

        var invalid = valid
        invalid.originX = .nan
        require(WallpaperGeometry.maximumSelection(for: invalid) == nil, "non-finite origin must be rejected by reset")
        require(WallpaperGeometry.zoomedSelection(from: invalid, zoomFactor: 2) == nil, "non-finite origin must be rejected by zoom")

        invalid = WallpaperCropSelection(
            sourceWidth: valid.sourceWidth,
            sourceHeight: valid.sourceHeight,
            cropWidth: valid.cropWidth,
            cropHeight: .infinity,
            outputWidth: valid.outputWidth,
            outputHeight: valid.outputHeight,
            visibleAspect: valid.visibleAspect,
            originX: valid.originX,
            originY: valid.originY
        )
        require(WallpaperGeometry.maximumSelection(for: invalid) == nil, "non-finite crop size must be rejected by reset")
        require(WallpaperGeometry.zoomedSelection(from: invalid, zoomFactor: 2) == nil, "non-finite crop size must be rejected by zoom")
    }

    private static func testUltrawideInputZoom() {
        guard let ultrawide = WallpaperGeometry.cropSelection(
            sourceWidth: 2520,
            sourceHeight: 1080,
            screenAspect: 1.60,
            outputCanvas: AerialCanvas(width: 1920, height: 1080)
        ) else {
            fail("21:9 crop was not achievable")
        }
        require(close(ultrawide.cropWidth, 1728), "21:9 maximal crop width changed")
        require(close(ultrawide.cropHeight, 1080), "21:9 maximal crop height changed")
        guard let range = WallpaperGeometry.achievableOriginRange(for: ultrawide) else {
            fail("21:9 crop range was not achievable")
        }
        require(close(range.minX, 96), "21:9 crop X range minimum changed")
        require(close(range.maxX, 696), "21:9 crop X range maximum changed")
        require(close(range.minY, 0), "21:9 crop Y range minimum changed")
        require(close(range.maxY, 0), "21:9 crop Y range maximum changed")
        assertVisibleSelection(ultrawide, label: "21:9 maximal")

        guard let zoomed = WallpaperGeometry.zoomedSelection(from: ultrawide, zoomFactor: 3) else {
            fail("21:9 3x zoom was not achievable")
        }
        require(close(zoomed.cropWidth, 576), "21:9 zoom width is not relative to maximal crop")
        require(close(zoomed.cropHeight, 360), "21:9 zoom height is not relative to maximal crop")
        require(close(zoomed.cropWidth / zoomed.cropHeight, 1.60), "21:9 zoom changed fixed aspect")
        assertVisibleSelection(zoomed, label: "21:9 3x zoom")
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

    private static func testOrientationAssessment() {
        let mainLandscape = GeometryScreenSnapshot(
            isMain: true,
            frameWidthPoints: 1920,
            frameHeightPoints: 1080,
            backingScaleFactor: 1,
            pixelWidth: 1920,
            pixelHeight: 1080
        )
        let secondaryPortrait = GeometryScreenSnapshot(
            isMain: false,
            frameWidthPoints: 1200,
            frameHeightPoints: 1920,
            backingScaleFactor: 1,
            pixelWidth: 1200,
            pixelHeight: 1920
        )
        let rotatedProfile = AerialGeometryProfile(
            encodedSize: GeometrySize(width: 1080, height: 1920),
            naturalSize: GeometrySize(width: 1080, height: 1920),
            cleanAperture: GeometryRect(x: 0, y: 0, width: 1080, height: 1920),
            presentationSize: GeometrySize(width: 1920, height: 1080),
            pixelAspectRatio: PixelAspectRatio(horizontal: 1, vertical: 1),
            preferredTransform: GeometryTransform(a: 0, b: 1, c: -1, d: 0, tx: 1920, ty: 0),
            hasExplicitCleanAperture: true,
            hasExplicitPixelAspectRatio: true
        )
        let rotatedAssessment = GeometryDiagnostics.orientationAssessment(
            sourceSize: GeometrySize(width: 720, height: 410),
            screens: [mainLandscape],
            targetProfile: rotatedProfile,
            referenceOriginalProfile: rotatedProfile,
            chosenCanvas: AerialCanvas(width: 1920, height: 1080),
            chosenSource: .persisted,
            manifestCanvas: AerialCanvas(width: 1080, height: 1920)
        )
        require(rotatedAssessment.targetEncodedOrientation == .portrait, "encoded orientation was not retained")
        require(rotatedAssessment.targetPresentationOrientation == .landscape, "presentation orientation was not retained")
        require(rotatedAssessment.targetEffectiveOrientation == .landscape, "90-degree transform did not determine effective orientation")
        require(!rotatedAssessment.trustedOriginalPresentationConflict, "90-degree transform falsely blocked a matching landscape canvas")
        require(rotatedAssessment.manifestTargetConflict, "manifest/target orientation conflict was not reported")

        let mainPortraitAssessment = GeometryDiagnostics.orientationAssessment(
            sourceSize: GeometrySize(width: 1080, height: 1920),
            screens: [secondaryPortrait, mainLandscape],
            targetProfile: nil,
            referenceOriginalProfile: nil,
            chosenCanvas: AerialCanvas(width: 1080, height: 1920),
            chosenSource: .manifest,
            manifestCanvas: nil
        )
        require(mainPortraitAssessment.screenOrientation == .landscape, "main screen was not selected by provenance")
        require(mainPortraitAssessment.canvasScreenConflict, "portrait canvas/landscape main screen conflict was not reported")

        let currentCanvas = AerialCanvas(width: 1920, height: 1080)
        let archiveCanvas = AerialCanvas(width: 1080, height: 1920)
        let currentProfile = profile(for: currentCanvas)
        let archiveProfile = profile(for: archiveCanvas)
        let originalHash = String(repeating: "d", count: 64)
        let reidentifiedRecord = NativeCanvasRecord(
            canvas: currentCanvas,
            source: .reidentified,
            originalTargetSHA256: originalHash,
            capturedAt: Date(timeIntervalSince1970: 4),
            geometry: currentProfile
        )
        let report = GeometryDiagnosticReport(
            schemaVersion: GeometryDiagnosticReport.schemaVersion,
            appVersion: "test",
            createdAt: Date(timeIntervalSince1970: 5),
            macOS: "test",
            architecture: "test",
            screens: [mainLandscape],
            targetUUID: "TEST",
            input: nil,
            targetBefore: GeometryVideoSnapshot(
                basename: "current.mov",
                fileSize: nil,
                duration: nil,
                profile: currentProfile
            ),
            targetBeforeSHA256: originalHash,
            referenceOriginal: GeometryVideoSnapshot(
                basename: "old-archive.mov",
                fileSize: nil,
                duration: nil,
                profile: archiveProfile
            ),
            manifestCanvas: nil,
            persistedRecord: reidentifiedRecord,
            historyEvidence: [],
            chosenCanvas: currentCanvas,
            chosenSource: .persisted,
            chosenEvidence: "reidentified",
            crop: nil,
            intermediate: nil,
            finalOutput: nil,
            finalOutputSHA256: nil,
            installedTarget: nil,
            installedTargetSHA256: nil,
            outputMatchesInstalledTarget: nil,
            diffs: [],
            conflicts: [],
            phenomenon: nil,
            notes: []
        )
        require(report.orientationAssessment?.trustedOriginalPresentationConflict == false, "matching reidentified SHA preferred stale archive orientation")
        require(report.orientationAssessment?.blockingReason == nil, "matching reidentified SHA produced a false orientation block")
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
