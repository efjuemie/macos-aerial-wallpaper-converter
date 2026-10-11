import Foundation

private struct TestError: Error {}

private final class FakeFileSystem {
    var values: [URL: String]
    var hashOverrides: [URL: [Result<String, Error>]] = [:]
    var throwingReplaceCalls: Set<Int> = []
    private(set) var replaceCount = 0

    init(source: URL, target: URL, backup: URL) {
        values = [source: "new", target: "old", backup: "old"]
    }

    func hash(_ url: URL) throws -> String {
        if var overrides = hashOverrides[url], !overrides.isEmpty {
            let result = overrides.removeFirst()
            hashOverrides[url] = overrides
            return try result.get()
        }
        guard let value = values[url] else { throw TestError() }
        return value
    }

    func replace(source: URL, target: URL) throws {
        replaceCount += 1
        if throwingReplaceCalls.contains(replaceCount) { throw TestError() }
        guard let value = values[source] else { throw TestError() }
        values[target] = value
    }
}

@inline(__always)
private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
enum WallpaperOperationTimelineTest {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WallpaperConverterTimeline-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("timeline.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let timeline = WallpaperOperationTimeline(fileURL: fileURL, maximumRecords: 4)
        var conversion = timeline.begin(kind: .conversion, targetUUID: "TARGET-1")
        conversion.backupCreated = true
        conversion.backupSHA256 = String(repeating: "a", count: 64)
        conversion.backupVerified = true
        conversion.installationSucceeded = true
        conversion.installationVerified = true
        conversion.installationCompletedAt = conversion.startTime.addingTimeInterval(0.5)
        conversion.reloadStartedAt = conversion.startTime
        conversion.reloadEndedAt = conversion.startTime.addingTimeInterval(1)
        conversion.reloadExecutableAvailable = true
        conversion.reloadExitCode = 0
        conversion.reloadSucceeded = true
        conversion.endTime = conversion.startTime.addingTimeInterval(2)
        timeline.update(conversion)

        var history = timeline.begin(kind: .historyReplacement, targetUUID: "TARGET-1")
        history.installationSucceeded = false
        history.installationVerified = false
        history.rollbackAttempted = true
        history.rollbackSucceeded = true
        history.rollbackVerified = true
        history.errorMessage = "安装失败，路径已脱敏"
        history.errorIsRedacted = true
        history.endTime = Date()
        timeline.update(history)

        var restore = timeline.begin(kind: .backupRestore, targetUUID: "TARGET-1")
        restore.installationSucceeded = false
        restore.rollbackAttempted = true
        restore.rollbackSucceeded = false
        restore.rollbackVerified = false
        restore.errorMessage = "恢复失败"
        restore.errorIsRedacted = true
        restore.endTime = Date()
        timeline.update(restore)

        require(Set(timeline.records.map(\.kind)) == Set(WallpaperOperationKind.allCases), "all three operation kinds must persist")
        require(timeline.records.first?.kind == .conversion, "updates must retain chronological order")
        require(history.rollbackVerified == true, "successful rollback must record verification")
        require(restore.rollbackSucceeded == false, "failed rollback must remain visible")

        var gate = WallpaperOperationReloadGate()
        require(gate.beginAttempt(), "the first reload attempt must be allowed")
        require(!gate.beginAttempt(), "the second reload attempt must be rejected")
        require(gate.attempts == 1, "one operation may attempt reload at most once")

        let reloaded = WallpaperOperationTimeline(fileURL: fileURL, maximumRecords: 4)
        require(
            reloaded.records.count == timeline.records.count
                && zip(timeline.records, reloaded.records).allSatisfy(recordsEquivalent),
            "timeline records must survive a new instance"
        )
        require(
            reloaded.records.allSatisfy { ($0.errorMessage?.contains(directory.path) ?? false) == false },
            "records must not contain local timeline paths"
        )
        let redacted = WallpaperOperationTimeline.redactedError(
            AppError("path=/Users/private-user/Library/Secrets/wallpaper.mov email=email@example.com ssid=HomeWifi")
        )
        require(!redacted.contains("/Users/private-user"), "timeline errors must redact absolute user paths")
        require(!redacted.contains("email@example.com"), "timeline errors must redact email addresses")
        require(!redacted.contains("HomeWifi"), "timeline errors must redact Wi-Fi identifiers")
        try testReplacementSafety()
        print("Wallpaper operation timeline tests passed")
    }

    private static func testReplacementSafety() throws {
        let source = URL(fileURLWithPath: "/tmp/timeline-source.mov")
        let target = URL(fileURLWithPath: "/tmp/timeline-target.mov")
        let backup = URL(fileURLWithPath: "/tmp/timeline-backup.mov")
        let hash: WallpaperOperationSafety.HashFunction
        let replace: WallpaperOperationSafety.ReplaceFunction

        do {
            let fileSystem = FakeFileSystem(source: source, target: target, backup: backup)
            hash = { try fileSystem.hash($0) }
            replace = { try fileSystem.replace(source: $0, target: $1) }
            var record = validRecord()
            record.backupVerified = false
            do {
                try WallpaperOperationSafety.install(
                    record: &record,
                    source: source,
                    target: target,
                    backup: backup,
                    originalTargetSHA256: "old",
                    hash: hash,
                    replace: replace
                )
                require(false, "an unverified backup must prevent installation")
            } catch {}
            require(fileSystem.replaceCount == 0, "backup failure must not reach replacement")
            require(record.installationSucceeded == false, "backup failure must be recorded")
        }

        do {
            let fileSystem = FakeFileSystem(source: source, target: target, backup: backup)
            fileSystem.hashOverrides[target] = [.success("wrong"), .success("old")]
            var record = validRecord()
            do {
                try WallpaperOperationSafety.install(
                    record: &record,
                    source: source,
                    target: target,
                    backup: backup,
                    originalTargetSHA256: "old",
                    hash: { try fileSystem.hash($0) },
                    replace: { try fileSystem.replace(source: $0, target: $1) }
                )
                require(false, "post-install hash mismatch must fail")
            } catch {}
            require(fileSystem.replaceCount == 2, "hash mismatch must attempt one rollback")
            require(record.rollbackSucceeded == true && record.rollbackVerified == true, "verified rollback must be recorded")
            require(record.installationSucceeded == false, "failed installation must remain visible")
        }

        do {
            let fileSystem = FakeFileSystem(source: source, target: target, backup: backup)
            fileSystem.throwingReplaceCalls = [1]
            var record = validRecord()
            do {
                try WallpaperOperationSafety.install(
                    record: &record,
                    source: source,
                    target: target,
                    backup: backup,
                    originalTargetSHA256: "old",
                    hash: { try fileSystem.hash($0) },
                    replace: { try fileSystem.replace(source: $0, target: $1) }
                )
                require(false, "replacement error must fail")
            } catch {}
            require(fileSystem.replaceCount == 2, "replacement error must attempt one rollback")
            require(record.rollbackSucceeded == true, "replacement error must preserve a verified rollback")
        }

        do {
            let fileSystem = FakeFileSystem(source: source, target: target, backup: backup)
            fileSystem.hashOverrides[target] = [.success("wrong"), .success("wrong-rollback")]
            var record = validRecord()
            do {
                try WallpaperOperationSafety.install(
                    record: &record,
                    source: source,
                    target: target,
                    backup: backup,
                    originalTargetSHA256: "old",
                    hash: { try fileSystem.hash($0) },
                    replace: { try fileSystem.replace(source: $0, target: $1) }
                )
                require(false, "rollback hash mismatch must fail")
            } catch {}
            require(record.rollbackSucceeded == false && record.rollbackVerified == false, "unverified rollback must not be successful")
        }

        do {
            let fileSystem = FakeFileSystem(source: source, target: target, backup: backup)
            fileSystem.hashOverrides[target] = [.success("wrong")]
            fileSystem.throwingReplaceCalls = [2]
            var record = validRecord()
            do {
                try WallpaperOperationSafety.install(
                    record: &record,
                    source: source,
                    target: target,
                    backup: backup,
                    originalTargetSHA256: "old",
                    hash: { try fileSystem.hash($0) },
                    replace: { try fileSystem.replace(source: $0, target: $1) }
                )
                require(false, "rollback error must fail")
            } catch {}
            require(record.rollbackSucceeded == false, "rollback error must remain visible")
        }

        do {
            let fileSystem = FakeFileSystem(source: source, target: target, backup: backup)
            var record = validRecord()
            try WallpaperOperationSafety.install(
                record: &record,
                source: source,
                target: target,
                backup: backup,
                originalTargetSHA256: "old",
                hash: { try fileSystem.hash($0) },
                replace: { try fileSystem.replace(source: $0, target: $1) }
            )
            require(record.installationSucceeded == true && record.installationVerified == true, "successful installation must be verified")
            guard let installationCompletedAt = record.installationCompletedAt else {
                require(false, "successful installation must record completion time")
                return
            }
            let reloadStartedAt = Date()
            require(installationCompletedAt <= reloadStartedAt, "installation must complete before reload begins")
            var reloadGate = WallpaperOperationReloadGate()
            require(reloadGate.beginAttempt(), "successful operation may reload once")
            require(!reloadGate.beginAttempt(), "successful operation must not reload twice")
        }
    }

    private static func validRecord() -> WallpaperOperationRecord {
        WallpaperOperationRecord(
            kind: .conversion,
            targetUUID: "TARGET-1",
            backupCreated: true,
            backupSHA256: "old",
            backupVerified: true
        )
    }

    private static func recordsEquivalent(
        _ expected: WallpaperOperationRecord,
        _ actual: WallpaperOperationRecord
    ) -> Bool {
        expected.id == actual.id
            && expected.kind == actual.kind
            && abs(expected.startTime.timeIntervalSince(actual.startTime)) <= 0.001
            && optionalDateClose(expected.endTime, actual.endTime)
            && expected.timezone == actual.timezone
            && expected.targetUUID == actual.targetUUID
            && expected.backupCreated == actual.backupCreated
            && expected.backupSHA256 == actual.backupSHA256
            && expected.backupVerified == actual.backupVerified
            && expected.installationSucceeded == actual.installationSucceeded
            && expected.installedSHA256 == actual.installedSHA256
            && expected.installationVerified == actual.installationVerified
            && optionalDateClose(expected.installationCompletedAt, actual.installationCompletedAt)
            && expected.rollbackAttempted == actual.rollbackAttempted
            && expected.rollbackSucceeded == actual.rollbackSucceeded
            && expected.rollbackSHA256 == actual.rollbackSHA256
            && expected.rollbackVerified == actual.rollbackVerified
            && optionalDateClose(expected.reloadStartedAt, actual.reloadStartedAt)
            && optionalDateClose(expected.reloadEndedAt, actual.reloadEndedAt)
            && expected.reloadExecutableAvailable == actual.reloadExecutableAvailable
            && expected.reloadExitCode == actual.reloadExitCode
            && expected.reloadSucceeded == actual.reloadSucceeded
            && expected.reloadSkipped == actual.reloadSkipped
            && expected.reloadErrorMessage == actual.reloadErrorMessage
            && expected.errorMessage == actual.errorMessage
            && expected.errorIsRedacted == actual.errorIsRedacted
    }

    private static func optionalDateClose(_ expected: Date?, _ actual: Date?) -> Bool {
        switch (expected, actual) {
        case (nil, nil):
            return true
        case let (expected?, actual?):
            return abs(expected.timeIntervalSince(actual)) <= 0.001
        default:
            return false
        }
    }
}
