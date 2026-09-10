import Foundation

@main
enum EnvironmentLogicTests {
    static func main() {
        let allAvailable = EnvironmentProbe.allAvailable
        let expectedIDs = [
            "macos", "architecture", "encoder", "aerial", "diskSpace",
            "oldLaunchAgent", "commandLineTools", "swift", "git", "python"
        ]
        let initial = EnvironmentCheckBuilder.build(allAvailable)
        require(initial.map(\.id) == expectedIDs, "environment ids must be stable and ordered")
        require(initial.allSatisfy { $0.status == .ok }, "all available environment checks should pass")
        require(EnvironmentCheckBuilder.canProcess(initial), "all required checks should allow processing")

        var requiredFailure = allAvailable
        requiredFailure.aerialCount = 0
        let requiredChecks = EnvironmentCheckBuilder.build(requiredFailure)
        require(requiredChecks.first(where: { $0.id == "aerial" })?.blocksProcessing == true, "missing Aerial must block")
        require(!EnvironmentCheckBuilder.canProcess(requiredChecks), "required failure must block processing")

        var optionalFailure = allAvailable
        optionalFailure.gitDetail = nil
        let optionalChecks = EnvironmentCheckBuilder.build(optionalFailure)
        require(optionalChecks.first(where: { $0.id == "git" })?.status == .warning, "missing Git should be a warning")
        require(EnvironmentCheckBuilder.canProcess(optionalChecks), "optional failure must not block processing")

        var oldAgent = allAvailable
        oldAgent.oldLaunchAgentRunning = true
        let warningChecks = EnvironmentCheckBuilder.build(oldAgent)
        let oldCheck = warningChecks.first(where: { $0.id == "oldLaunchAgent" })
        require(oldCheck?.status == .warning, "old LaunchAgent should be a warning")
        require(oldCheck?.action == .disableOldLaunchAgent, "old LaunchAgent warning should offer disable action")
        require(EnvironmentCheckBuilder.canProcess(warningChecks), "warnings must not block processing")

        require(
            ArchiveRefreshPolicy.shouldRefreshArchives(isProcessing: false),
            "archives should refresh while idle"
        )
        require(
            !ArchiveRefreshPolicy.shouldRefreshArchives(isProcessing: true),
            "archives must not refresh during processing"
        )

        let launchAgentDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wallpaper-converter-launch-agent-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: launchAgentDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: launchAgentDirectory) }
        let preferredDisabled = launchAgentDirectory
            .appendingPathComponent("com.local.wallpaper-aerial-fix.plist.disabled")
        FileManager.default.createFile(atPath: preferredDisabled.path, contents: Data("existing".utf8))
        let safeDisabled = LaunchAgentPathPolicy.nextAvailableDestination(preferred: preferredDisabled)
        require(
            safeDisabled != preferredDisabled && safeDisabled.lastPathComponent == "com.local.wallpaper-aerial-fix.plist-2.disabled",
            "existing disabled LaunchAgent config must not be overwritten"
        )

        #if DEBUG
        let missing = EnvironmentSimulation.missing(from: "encoder,aerial,diskSpace,git,python3,swiftc,clt,architecture,macos")
        require(missing.contains("encoder") && missing.contains("python3"), "debug fake list must parse")
        let simulated = EnvironmentSimulation.applying(missing, to: allAvailable)
        let simulatedChecks = EnvironmentCheckBuilder.build(simulated)
        require(simulatedChecks.first(where: { $0.id == "encoder" })?.status == .error, "fake encoder must fail")
        require(simulatedChecks.first(where: { $0.id == "git" })?.status == .warning, "fake Git must remain optional")
        require(simulatedChecks.first(where: { $0.id == "commandLineTools" })?.action == .installCommandLineTools, "fake CLT must offer installer")
        require(simulatedChecks.first(where: { $0.id == "swift" })?.status == .warning, "fake swiftc must remain optional")
        require(!EnvironmentCheckBuilder.canProcess(simulatedChecks), "fake required failures must block")
        for name in ["macos", "architecture", "encoder", "aerial", "diskSpace"] {
            let one = EnvironmentCheckBuilder.build(
                EnvironmentSimulation.applying([name.lowercased()], to: allAvailable)
            )
            require(one.first(where: { $0.id == name })?.blocksProcessing == true, "fake \(name) must block")
        }
        #endif

        print("PASS: environment check semantics")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            FileHandle.standardError.write("FAIL: \(message)\n".data(using: .utf8)!)
            exit(1)
        }
    }
}
