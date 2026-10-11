import Darwin
import Foundation

@main
enum LockBehaviorLogicTests {
    static func main() async {
        testSymptomModel()
        testAllowedCommands()
        testLaunchAgentConfiguration()
        await testBoundedCommands()
        testReportAndExport()
        print("PASS: lock behavior diagnostics")
    }

    private static func testSymptomModel() {
        require(LockSymptom.allCases.count == 6, "all six lock symptom categories must exist")
        require(LockSymptom.actualSessionLock.displayName.contains("身份"), "actual lock needs a clear label")
        require(LockSymptom.unknown.displayName.contains("无法"), "unknown needs a clear label")
        let data = try! JSONEncoder().encode(LockSymptom.wallpaperTransition)
        let roundTrip = try! JSONDecoder().decode(LockSymptom.self, from: data)
        require(roundTrip == .wallpaperTransition, "lock symptom must be Codable")
    }

    private static func testAllowedCommands() {
        require(
            SystemEventProbe.allowedInvocation(name: "pmset", arguments: ["-g", "custom"]),
            "pmset custom must be allowed"
        )
        require(
            SystemEventProbe.allowedInvocation(name: "pmset", arguments: ["-g", "batt"]),
            "pmset batt must be allowed"
        )
        require(
            SystemEventProbe.allowedInvocation(
                name: "log",
                arguments: SystemEventProbe.logArguments(around: nil)
            ),
            "bounded log show must be allowed"
        )
        require(
            !SystemEventProbe.allowedInvocation(name: "sh", arguments: ["-c", "pkill WallpaperAgent"]),
            "arbitrary shell commands must be rejected"
        )
        require(
            !SystemEventProbe.allowedInvocation(name: "log", arguments: ["show"]),
            "unbounded log show must be rejected"
        )
        var alteredLog = SystemEventProbe.logArguments(around: nil)
        alteredLog[6] = "process == \"untrusted\""
        require(
            !SystemEventProbe.allowedInvocation(name: "log", arguments: alteredLog),
            "log predicate must remain fixed"
        )
    }

    private static func testLaunchAgentConfiguration() {
        let legacyMissing = NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)
        let modernMissing = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)
        let permissionDenied = NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        require(
            SystemEventProbe.launchAgentConfiguration(for: legacyMissing) == false,
            "legacy missing-file error must mean unconfigured"
        )
        require(
            SystemEventProbe.launchAgentConfiguration(for: modernMissing) == false,
            "modern missing-file error must mean unconfigured"
        )
        require(
            SystemEventProbe.launchAgentConfiguration(for: permissionDenied) == nil,
            "permission errors must remain unavailable"
        )
    }

    private static func testBoundedCommands() async {
        let shell = URL(fileURLWithPath: "/bin/sh")
        let success = await BoundedDiagnosticCommand.run(
            executable: shell,
            arguments: ["-c", "printf 'ok'"]
        )
        require(success.succeeded && success.output == "ok", "successful command must be captured")

        let failure = await BoundedDiagnosticCommand.run(
            executable: shell,
            arguments: ["-c", "printf 'failure' >&2; exit 7"]
        )
        require(failure.status == 7 && failure.output.contains("failure"), "failed command must preserve exit code/output")
        require(!failure.succeeded, "non-zero exit must never be successful")

        let fastOutput = await BoundedDiagnosticCommand.run(
            executable: shell,
            arguments: [
                "-c",
                "i=0; while [ $i -lt 20000 ]; do printf 0123456789; i=$((i+1)); done; printf SENTINEL"
            ],
            timeout: 3,
            outputLimit: 262_144
        )
        require(fastOutput.succeeded, "fast output command must finish successfully")
        require(!fastOutput.truncated, "fast output within the limit must not be truncated")
        require(fastOutput.output.hasSuffix("SENTINEL"), "final output sentinel must survive process completion")

        let truncated = await BoundedDiagnosticCommand.run(
            executable: shell,
            arguments: ["-c", "while :; do printf '0123456789'; done"],
            timeout: 2,
            outputLimit: 4096
        )
        require(truncated.truncated, "large output must be explicitly truncated")
        require(truncated.output.utf8.count <= 4096, "large output must respect the byte limit")
        require(!truncated.succeeded, "truncated output must not be reported as available")

        let timedOut = await BoundedDiagnosticCommand.run(
            executable: shell,
            arguments: ["-c", "while :; do :; done"],
            timeout: 0.1,
            outputLimit: 512
        )
        require(timedOut.timedOut, "timeout must be reported")
        require(!timedOut.succeeded, "timeout must never be reported as success")
        require(timedOut.terminated, "timed out child must terminate before result")
        assertProcessExited(timedOut.processIdentifier, "timed out child")

        let cancellationTask = Task {
            await BoundedDiagnosticCommand.run(
                executable: shell,
                arguments: ["-c", "while :; do :; done"],
                timeout: 5,
                outputLimit: 512
            )
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        cancellationTask.cancel()
        let cancelled = await cancellationTask.value
        require(cancelled.cancelled, "cancelled command must be reported")
        require(!cancelled.succeeded, "cancelled command must never be reported as success")
        require(cancelled.terminated, "cancelled child must terminate before result")
        assertProcessExited(cancelled.processIdentifier, "cancelled child")

        let preCancelledTask = Task {
            withUnsafeCurrentTask { currentTask in
                currentTask?.cancel()
            }
            return await BoundedDiagnosticCommand.run(
                executable: shell,
                arguments: ["-c", "sleep 10"],
                timeout: 5,
                outputLimit: 512
            )
        }
        let preCancelled = await preCancelledTask.value
        require(preCancelled.cancelled, "pre-cancelled command must be reported as cancelled")
        require(preCancelled.processIdentifier == nil, "pre-cancelled command must not spawn a process")

        let ignoredTermChild = await BoundedDiagnosticCommand.run(
            executable: shell,
            arguments: [
                "-c",
                "( trap '' TERM; while :; do printf child; done ) & child=$!; trap 'exit 0' TERM; printf 'child=%s\\n' \"$child\"; wait"
            ],
            timeout: 0.1,
            outputLimit: 4096
        )
        require(ignoredTermChild.timedOut, "ignored TERM process group must time out")
        require(ignoredTermChild.terminated, "ignored TERM parent must be reaped")
        guard let childPID = childPID(in: ignoredTermChild.output) else {
            require(false, "ignored TERM test must expose its child PID")
            return
        }
        assertProcessExited(ignoredTermChild.processIdentifier, "ignored TERM parent")
        assertProcessExited(childPID, "ignored TERM descendant")

        let missing = await BoundedDiagnosticCommand.run(
            executable: URL(fileURLWithPath: "/definitely/missing/wallpaper-diagnostic-command"),
            arguments: []
        )
        require(missing.unavailableReason != nil && !missing.succeeded, "missing command must be unavailable")
    }

    private static func testReportAndExport() {
        let record = WallpaperOperationRecord(
            id: UUID(),
            kind: .conversion,
            startTime: Date(timeIntervalSince1970: 1_760_000_000),
            endTime: Date(timeIntervalSince1970: 1_760_000_002),
            targetUUID: "00BA71CD-2C54-415A-A68A-8358E677D750",
            backupCreated: true,
            backupSHA256: String(repeating: "a", count: 64),
            backupVerified: true,
            installationSucceeded: true,
            installedSHA256: String(repeating: "b", count: 64),
            installationVerified: true,
            installationCompletedAt: Date(timeIntervalSince1970: 1_760_000_001),
            rollbackAttempted: false,
            rollbackSucceeded: nil,
            rollbackSHA256: nil,
            rollbackVerified: nil,
            reloadStartedAt: Date(timeIntervalSince1970: 1_760_000_003),
            reloadEndedAt: Date(timeIntervalSince1970: 1_760_000_004),
            reloadExecutableAvailable: true,
            reloadExitCode: 0,
            reloadSucceeded: true,
            reloadSkipped: false,
            reloadErrorMessage: "reload path /Users/private-user/Library/Logs/reload.log",
            errorMessage: "video at /Users/private-user/Library/Secrets/video.mov; contact email@example.com; ssid=HomeWifi",
            errorIsRedacted: false
        )
        let failedRecord = WallpaperOperationRecord(
            id: UUID(),
            kind: .historyReplacement,
            startTime: Date(timeIntervalSince1970: 1_760_000_005),
            endTime: Date(timeIntervalSince1970: 1_760_000_006),
            targetUUID: "00BA71CD-2C54-415A-A68A-8358E677D750",
            installationSucceeded: false,
            installationCompletedAt: nil,
            reloadExecutableAvailable: false,
            reloadSkipped: true,
            reloadErrorMessage: "reload failed at /Users/private-user/Library/Logs/reload.log",
            errorMessage: "failed input /Users/private-user/Library/Secrets/video.mov",
            errorIsRedacted: false
        )
        let failedCommand = BoundedCommandResult(
            command: "log",
            arguments: ["show", "--last", "10m"],
            status: 1,
            output: "path=/Users/private-user/Library/Logs/app.log email=email@example.com ssid=HomeWifi 192.168.1.4",
            outputBytes: 100,
            truncated: false,
            timedOut: false,
            cancelled: false,
            unavailableReason: "命令退出码为 1",
            processIdentifier: nil,
            terminated: true
        )
        let probe = SystemEventProbeSnapshot(
            capturedAt: Date(timeIntervalSince1970: 1_760_000_010),
            macOSVersion: "macOS 26.6.2 (Build 25G83)",
            machineModel: "MacBookPro18,3",
            deviceClass: nil,
            architecture: "arm64",
            powerSource: nil,
            displayCount: 1,
            externalDisplayCount: 0,
            displayIdleOnBattery: nil,
            displayIdleOnAC: 10,
            commands: [failedCommand],
            logWindow: "最近 10 分钟",
            logTimeZone: "Asia/Shanghai",
            oldLaunchAgentConfigured: nil,
            oldLaunchAgentLoaded: nil,
            warnings: ["系统日志不可用"]
        )
        let settings = [
            "screenSaverDelay": "unknown",
            "triggerCorners": "top-right locks screen",
            "privatePath": "/Users/private-user/Documents/video.mov",
            "email": "email@example.com"
        ]
        let successfulReport = LockBehaviorDiagnostics.buildReport(
            reportedSymptom: .wallpaperTransition,
            incidentTime: nil,
            userSettings: settings,
            operations: [record],
            probe: probe
        )
        require(
            successfulReport.wallpaperOperation.replacementAt.value?.timeIntervalSince1970 == 1_760_000_001,
            "replacement timestamp must use installationCompletedAt"
        )
        let report = LockBehaviorDiagnostics.buildReport(
            reportedSymptom: .unknown,
            incidentTime: nil,
            userSettings: settings,
            operations: [record, failedRecord],
            probe: probe
        )
        require(report.classification == .unknown, "unknown observation must remain unknown")
        require(report.confidence == .insufficient, "unknown observation must remain insufficient")
        require(report.evidence.first?.status == .failed, "non-zero diagnostic command must be failed")
        require(report.settings.screenSaverDelay.source == .userReported, "manual settings must be userReported")
        require(report.deviceClass.availability == .unavailable, "portable/desktop classification must stay unavailable when unreadable")
        require(report.wallpaperOperation.replacementAt.availability == .unavailable, "failed operation must not become a replacement timestamp")
        require(report.wallpaperOperation.reloadAttempted.availability == .unavailable, "skipped or unavailable reload must stay unavailable")
        require(report.wallpaperOperation.operations.last?.reloadSkipped == true, "reloadSkipped must survive report sanitization")
        require(report.wallpaperOperation.operations.last?.reloadErrorMessage?.contains("<user-home>") == true, "reload error must be sanitized")

        let first = try! LockBehaviorDiagnostics.export(report)
        let second = try! LockBehaviorDiagnostics.export(report)
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        require(first.lastPathComponent.contains("unexpected-lock"), "export name must identify unexpected lock")
        require(first != second, "exports must use unique filenames")
        let data = try! Data(contentsOf: first)
        let json = String(decoding: data, as: UTF8.self)
        require(json.contains("schemaVersion"), "export must contain schema version")
        require(json.contains("unexpectedLock"), "export must contain diagnostic type")
        require(!json.contains("/Users/private-user"), "export must not contain full user paths")
        require(!json.contains("email@example.com"), "export must not contain email addresses")
        require(!json.contains("HomeWifi"), "export must not contain Wi-Fi identifiers")
        require(json.contains("unavailable"), "missing values must remain explicitly unavailable")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    private static func assertProcessExited(_ pid: Int32?, _ label: String) {
        guard let pid else {
            require(false, "\(label) must expose a child PID")
            return
        }
        for _ in 0..<20 {
            if kill(pid, 0) != 0 { return }
            usleep(50_000)
        }
        require(false, "\(label) must not remain running")
    }

    private static func childPID(in output: String) -> Int32? {
        guard let expression = try? NSRegularExpression(pattern: #"child=(\d+)"#),
              let match = expression.firstMatch(in: output, range: NSRange(output.startIndex..<output.endIndex, in: output)),
              let range = Range(match.range(at: 1), in: output) else {
            return nil
        }
        return Int32(output[range])
    }
}
