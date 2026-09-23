import Foundation

@inline(__always)
func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
enum InputReadinessSmoke {
    static func main() {

        let availableTarget = TargetAvailability.available
        let baseReadiness = ProcessingReadinessInput(
            inputLoaded: true,
            isInspectingVideo: false,
            uuidValid: true,
            targetAvailability: availableTarget,
            environmentChecking: false,
            environmentFailures: [],
            isProcessing: false,
            isPreparingLayout: false,
            isReidentifying: false
        )

        require(
            ProcessingReadiness.evaluate(baseReadiness) == .ready
                && ProcessingReadiness.evaluate(baseReadiness).canStart,
            "all ready conditions must enable processing"
        )
        require(
            ProcessingReadiness.evaluate(baseReadiness.with(inputLoaded: false)).blockReason == .noInput,
            "missing input must block with noInput"
        )
        require(
            ProcessingReadiness.evaluate(baseReadiness.with(isInspectingVideo: true)).blockReason == .inspectingVideo,
            "inspection must block with inspectingVideo"
        )
        require(
            ProcessingReadiness.evaluate(baseReadiness.with(uuidValid: false)).blockReason == .invalidUUID,
            "invalid UUID must block with invalidUUID"
        )
        require(
            ProcessingReadiness.evaluate(baseReadiness.with(targetAvailability: .missing)).blockReason
                == .targetUnavailable(.missing),
            "missing target must block with targetUnavailable"
        )
        require(
            ProcessingReadiness.evaluate(baseReadiness.with(environmentChecking: true)).blockReason
                == .environmentChecking,
            "environment checking must block with environmentChecking"
        )
        require(
            ProcessingReadiness.evaluate(baseReadiness.with(environmentFailures: ["编码器"])).blockReason
                == .environmentFailure(["编码器"]),
            "required environment failure must block with environmentFailure"
        )
        require(
            ProcessingReadiness.evaluate(baseReadiness.with(isPreparingLayout: true)).blockReason
                == .preparingLayout,
            "layout preparation must block with preparingLayout"
        )
        require(
            ProcessingReadiness.evaluate(baseReadiness.with(isReidentifying: true)).blockReason
                == .reidentifying,
            "reidentification must block with reidentifying"
        )
        require(
            ProcessingReadiness.evaluate(baseReadiness.with(isProcessing: true)).blockReason == .processing,
            "processing must block with processing"
        )

        var loadState = VideoLoadStateMachine()
        let generationA = loadState.begin()
        require(loadState.isBusy && loadState.isCurrent(generationA), "A begin must set busy")
        let generationB = loadState.begin()
        require(
            !loadState.finish(generationA) && loadState.isBusy && loadState.isCurrent(generationB),
            "stale A finish must not clear current B"
        )
        require(loadState.finish(generationB) && !loadState.isBusy, "B finish must clear busy")
        let generationC = loadState.begin()
        require(loadState.cancelCurrent() && !loadState.isBusy, "current cancellation must clear busy")
        require(!loadState.finish(generationC), "cancelled generation must not finish twice")
        let generationD = loadState.begin()
        require(loadState.finish(generationD) && !loadState.isBusy, "failure finish must clear busy")

        require(
            EnvironmentRefreshPolicy.shouldResetToChecking(checkCount: 0, hasCheckingStatus: false),
            "first environment refresh must show checking"
        )
        require(
            !EnvironmentRefreshPolicy.shouldResetToChecking(checkCount: 4, hasCheckingStatus: false),
            "completed environment snapshot must remain visible during refresh"
        )
        require(
            EnvironmentRefreshPolicy.shouldResetToChecking(checkCount: 4, hasCheckingStatus: true),
            "incomplete environment snapshot must remain checking"
        )

        let testHome = URL(fileURLWithPath: "/Users/test")
        func parsedPath(_ value: String) -> URL? {
            guard case let .success(url) = VideoInputParser.parse(value, homeDirectory: testHome) else {
                return nil
            }
            return url
        }
        require(
            parsedPath("/Users/test/Downloads/a.mov")?.path == "/Users/test/Downloads/a.mov",
            "absolute path must parse"
        )
        require(
            parsedPath("~/Downloads/a.mov")?.path == "/Users/test/Downloads/a.mov",
            "tilde path must expand"
        )
        require(
            parsedPath("file:///Users/test/Downloads/a.mov")?.path == "/Users/test/Downloads/a.mov",
            "file URL must parse with URL semantics"
        )
        require(
            parsedPath("\"/Users/test/Downloads/a.mov\"")?.path == "/Users/test/Downloads/a.mov",
            "double quoted path must parse"
        )
        require(
            parsedPath("'/Users/test/Downloads/a.mov'")?.path == "/Users/test/Downloads/a.mov",
            "single quoted path must parse"
        )
        require(
            VideoInputParser.parse("https://example.com/a.mov", homeDirectory: testHome)
                == .failure(.unsupportedRemoteURL),
            "remote URL must be rejected explicitly"
        )
        require(
            VideoInputParser.parse("", homeDirectory: testHome) == .failure(.empty),
            "empty input must be rejected"
        )
        require(
            VideoInputParser.parse("/Users/test/Downloads/a.mkv", homeDirectory: testHome)
                == .failure(.unsupportedFileType("mkv")),
            "unsupported extension must be rejected"
        )

        let dropURL = URL(fileURLWithPath: "/Users/test/Downloads/drop.mp4")
        require(
            DroppedVideoURLResolver.resolve(dropURL) == .success(dropURL.standardizedFileURL),
            "drop resolver must accept URL"
        )
        require(
            DroppedVideoURLResolver.resolve(dropURL as NSURL) == .success(dropURL.standardizedFileURL),
            "drop resolver must accept NSURL"
        )
        require(
            DroppedVideoURLResolver.resolve(dropURL.dataRepresentation) == .success(dropURL.standardizedFileURL),
            "drop resolver must accept URL data"
        )
        require(
            DroppedVideoURLResolver.resolve(NSData(data: dropURL.dataRepresentation))
                == .success(dropURL.standardizedFileURL),
            "drop resolver must accept NSData URL data"
        )
        require(
            DroppedVideoURLResolver.resolve(dropURL.path) == .success(dropURL.standardizedFileURL),
            "drop resolver must accept path string"
        )
        require(
            DroppedVideoURLResolver.resolve(NSString(string: dropURL.path))
                == .success(dropURL.standardizedFileURL),
            "drop resolver must accept NSString paths"
        )
        require(
            DroppedVideoURLResolver.resolve(NSNumber(value: 1)) == .failure(.invalidLocalURL),
            "drop resolver must report unrecognized objects"
        )
        require(
            DroppedVideoURLResolver.resolve(URL(string: "https://example.com/drop.mov")!)
                == .failure(.unsupportedRemoteURL),
            "drop resolver must reject remote URL objects explicitly"
        )

        let targetTestDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wallpaper-converter-readiness-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: targetTestDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: targetTestDirectory) }
        let targetFile = targetTestDirectory.appendingPathComponent("target.mov")
        try! Data("target".utf8).write(to: targetFile)
        require(
            TargetAvailability.evaluate(targetFile) == .available,
            "non-empty regular target must be available"
        )
        let emptyTarget = targetTestDirectory.appendingPathComponent("empty.mov")
        FileManager.default.createFile(atPath: emptyTarget.path, contents: nil)
        require(
            TargetAvailability.evaluate(emptyTarget) == .empty,
            "empty target must be unavailable"
        )
        let directoryTarget = targetTestDirectory.appendingPathComponent("directory.mov", isDirectory: true)
        try! FileManager.default.createDirectory(at: directoryTarget, withIntermediateDirectories: false)
        require(
            TargetAvailability.evaluate(directoryTarget) == .notRegularFile,
            "directory target must be unavailable"
        )
        require(
            TargetAvailability.evaluate(targetTestDirectory.appendingPathComponent("missing.mov")) == .missing,
            "missing target must be unavailable"
        )

        let firstUUID = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
        let secondUUID = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
        require(
            TargetSelectionPolicy.select(
                uuidText: firstUUID,
                selectedUUID: secondUUID,
                availableUUIDs: [firstUUID, secondUUID]
            ) == firstUUID,
            "existing UUID text must be preserved"
        )
        require(
            TargetSelectionPolicy.normalizeUUID("\(firstUUID).mov") == firstUUID,
            "UUID filename suffix must normalize"
        )
        require(
            TargetSelectionPolicy.select(
                uuidText: "invalid",
                selectedUUID: secondUUID,
                availableUUIDs: [firstUUID, secondUUID]
            ) == secondUUID,
            "existing selected UUID must be used when text is unavailable"
        )
        require(
            TargetSelectionPolicy.select(
                uuidText: "invalid",
                selectedUUID: "also invalid",
                availableUUIDs: [firstUUID, secondUUID]
            ) == firstUUID,
            "first installed target must be selected as fallback"
        )
        require(
            TargetSelectionPolicy.select(
                uuidText: firstUUID,
                selectedUUID: firstUUID,
                availableUUIDs: [secondUUID]
            ) == secondUUID,
            "deleted current target must switch to remaining installed target"
        )
        require(
            TargetSelectionPolicy.select(
                uuidText: "invalid",
                selectedUUID: "also invalid",
                availableUUIDs: []
            ) == nil,
            "empty installed target list must have no selection"
        )

        print("input/readiness tests passed")
    }
}

extension ProcessingReadinessInput {
    func with(inputLoaded: Bool? = nil, isInspectingVideo: Bool? = nil,
              uuidValid: Bool? = nil, targetAvailability: TargetAvailability? = nil,
              environmentChecking: Bool? = nil, environmentFailures: [String]? = nil,
              isProcessing: Bool? = nil, isPreparingLayout: Bool? = nil,
              isReidentifying: Bool? = nil) -> ProcessingReadinessInput {
        ProcessingReadinessInput(
            inputLoaded: inputLoaded ?? self.inputLoaded,
            isInspectingVideo: isInspectingVideo ?? self.isInspectingVideo,
            uuidValid: uuidValid ?? self.uuidValid,
            targetAvailability: targetAvailability ?? self.targetAvailability,
            environmentChecking: environmentChecking ?? self.environmentChecking,
            environmentFailures: environmentFailures ?? self.environmentFailures,
            isProcessing: isProcessing ?? self.isProcessing,
            isPreparingLayout: isPreparingLayout ?? self.isPreparingLayout,
            isReidentifying: isReidentifying ?? self.isReidentifying
        )
    }
}
