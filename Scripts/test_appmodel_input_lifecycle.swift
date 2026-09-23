import Foundation

private enum StubInspectionError: Error, Sendable {
    case failed
}

@inline(__always)
private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
enum AppModelInputLifecycleSmoke {
    static func main() async {
        await run()
    }

    @MainActor
    private static func run() async {
        let infoA = InputVideoInfo(
            url: URL(fileURLWithPath: "/tmp/input-a.mov"),
            duration: 1,
            width: 1920,
            height: 1080,
            fileSize: 1
        )
        let infoB = InputVideoInfo(
            url: URL(fileURLWithPath: "/tmp/input-b.mov"),
            duration: 2,
            width: 1280,
            height: 720,
            fileSize: 2
        )
        let infoCancel = InputVideoInfo(
            url: URL(fileURLWithPath: "/tmp/input-cancel.mov"),
            duration: 3,
            width: 1280,
            height: 720,
            fileSize: 3
        )

        let inspector: @Sendable (URL) async throws -> InputVideoInfo = { url in
            switch url.lastPathComponent {
            case "input-a.mov":
                // Detached work ignores the parent task's cancellation so the
                // AppModel generation check is exercised when A returns late.
                return await Task.detached(priority: .utility) {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    return infoA
                }.value
            case "input-b.mov":
                return infoB
            case "input-failure.mov":
                throw StubInspectionError.failed
            case "input-cancel.mov":
                return await Task.detached(priority: .utility) {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    return infoCancel
                }.value
            default:
                throw StubInspectionError.failed
            }
        }

        let model = AppModel(autoRefresh: false, videoInspector: inspector)
        let inputA = URL(fileURLWithPath: "/tmp/input-a.mov")
        let inputB = URL(fileURLWithPath: "/tmp/input-b.mov")
        let inputFailure = URL(fileURLWithPath: "/tmp/input-failure.mov")
        let inputCancel = URL(fileURLWithPath: "/tmp/input-cancel.mov")

        model.loadVideo(at: inputA)
        await wait(milliseconds: 20)
        require(model.isInspectingVideo, "A must enter inspecting state")

        model.loadVideo(at: inputB)
        await wait(milliseconds: 100)
        require(!model.isInspectingVideo, "B success must clear inspecting state")
        require(model.inputInfo?.url.lastPathComponent == "input-b.mov", "B must become current input")

        await wait(milliseconds: 250)
        require(!model.isInspectingVideo, "late A must not clear B's completed state")
        require(model.inputInfo?.url.lastPathComponent == "input-b.mov", "late A must not overwrite B")

        model.loadVideo(at: inputFailure)
        await wait(milliseconds: 100)
        require(!model.isInspectingVideo, "inspection failure must clear inspecting state")
        require(model.inputInfo == nil && model.inputLoadError != nil, "inspection failure must be visible")

        model.loadVideo(at: inputCancel)
        await wait(milliseconds: 20)
        require(model.isInspectingVideo, "cancel case must enter inspecting state")
        model.cancelVideoInspection()
        require(!model.isInspectingVideo, "current cancellation must clear inspecting state")
        await wait(milliseconds: 100)
        require(!model.isInspectingVideo && model.inputInfo == nil, "cancelled task must not restore stale input")

        print("AppModel input lifecycle tests passed")
    }

    @MainActor
    private static func wait(milliseconds: UInt64) async {
        try? await Task.sleep(nanoseconds: milliseconds * 1_000_000)
    }
}
