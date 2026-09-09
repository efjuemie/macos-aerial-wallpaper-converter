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

        require(
            NativeCanvasResolver.resolve(
                persistedCanvas: native,
                manifestCanvas: nil,
                targetCanvas: custom,
                hasAnyHistoricalRecords: true,
                earliestOriginalCanvas: custom,
                earliestBackupCanvas: custom
            ) == NativeCanvasResolution(canvas: native, shouldPersist: false),
            "persisted native canvas must be reused without inspecting new output"
        )
        require(
            NativeCanvasResolver.resolve(
                persistedCanvas: native,
                manifestCanvas: manifest,
                targetCanvas: nil,
                hasAnyHistoricalRecords: true,
                earliestOriginalCanvas: nil,
                earliestBackupCanvas: nil
            ) == NativeCanvasResolution(canvas: manifest, shouldPersist: true),
            "explicit manifest canvas must be persisted"
        )
        require(
            NativeCanvasResolver.resolve(
                persistedCanvas: nil,
                manifestCanvas: nil,
                targetCanvas: native,
                hasAnyHistoricalRecords: false,
                earliestOriginalCanvas: nil,
                earliestBackupCanvas: nil
            ) == NativeCanvasResolution(canvas: native, shouldPersist: true),
            "fresh install may persist a valid downloaded target"
        )
        require(
            NativeCanvasResolver.resolve(
                persistedCanvas: nil,
                manifestCanvas: nil,
                targetCanvas: native,
                hasAnyHistoricalRecords: true,
                earliestOriginalCanvas: nil,
                earliestBackupCanvas: nil
            ) == nil,
            "encoded or other history must prevent fresh-target trust"
        )
        require(
            NativeCanvasResolver.resolve(
                persistedCanvas: nil,
                manifestCanvas: nil,
                targetCanvas: custom,
                hasAnyHistoricalRecords: true,
                earliestOriginalCanvas: native,
                earliestBackupCanvas: native
            ) == NativeCanvasResolution(canvas: native, shouldPersist: true),
            "matching earliest original and backup must recover an upgrade baseline"
        )
        require(
            NativeCanvasResolver.resolve(
                persistedCanvas: nil,
                manifestCanvas: nil,
                targetCanvas: nil,
                hasAnyHistoricalRecords: true,
                earliestOriginalCanvas: native,
                earliestBackupCanvas: custom
            ) == nil,
            "conflicting upgrade evidence must fail closed"
        )
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
