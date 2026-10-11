import AppKit
import Darwin
import Foundation

@main
enum SeparationSnapshotTests {
    static func main() {
        testStrictUUID()
        testPlistSanitizationAndPrivacy()
        testUnknownSubtreeChangesAreVisible()
        testMalformedAndMissingIndex()
        testStableRaceGuard()
        testNoOverwriteAndPermissions()
        testDesktopURLSanitization()
        print("PASS: P0 separation snapshot UUID, plist privacy, missing/malformed/race, output safety, and desktop URL sanitization")
    }

    private static func testStrictUUID() {
        require(
            StrictUUID.normalize("00ba71cd-2c54-415a-a68a-8358e677d750") == "00BA71CD-2C54-415A-A68A-8358E677D750",
            "strict UUID normalization changed"
        )
        require(StrictUUID.normalize("not-a-uuid") == nil, "malformed UUID must be rejected")
        require(StrictUUID.normalize("00BA71CD-2C54-415A-A68A-8358E677D750.mov") == nil, "UUID suffix must not be guessed")
    }

    private static func testPlistSanitizationAndPrivacy() {
        let secretKey = "PrivatePathKey"
        let secretValue = "/Users/private-user/secret-wallpaper.mov"
        let source: [String: Any] = [
            "Type": "individual",
            "Desktop": ["Provider": ["Configuration": ["secret": secretValue]]],
            secretKey: ["Linked": true],
            "UnknownValue": "do-not-export"
        ]
        let sanitizer = PlistSanitizer()
        let sanitized = sanitizer.sanitize(source)
        guard let data = try? SeparationSnapshotCapture.jsonData([
            "tree": sanitized,
            "counts": sanitizer.counts,
            "unknown": sanitizer.unknownKeyHashes.sorted()
        ]), let text = String(data: data, encoding: .utf8) else {
            fail("sanitized plist JSON was not serializable")
        }
        require(text.contains("\"Type\""), "recognized Type key missing")
        require(text.contains("\"Desktop\""), "recognized Desktop key missing")
        require(text.contains("\"Provider\""), "recognized Provider key missing")
        require(text.contains("\"Configuration\""), "recognized Configuration key missing")
        require(!text.contains(secretKey), "unknown key leaked into sanitized JSON")
        require(!text.contains(secretValue), "unknown string value leaked into sanitized JSON")
        require(!text.contains("do-not-export"), "unknown value leaked into sanitized JSON")
    }

    private static func testUnknownSubtreeChangesAreVisible() {
        let before: [String: Any] = [
            "PerDisplayState": [
                "NestedConfiguration": [
                    "Type": "individual",
                    "PrivateValue": "before-secret"
                ]
            ]
        ]
        let after: [String: Any] = [
            "PerDisplayState": [
                "NestedConfiguration": [
                    "Type": "linked",
                    "PrivateValue": "after-secret"
                ]
            ]
        ]
        let beforeSanitizer = PlistSanitizer()
        let afterSanitizer = PlistSanitizer()
        let beforeTree = beforeSanitizer.sanitize(before)
        let afterTree = afterSanitizer.sanitize(after)
        let beforeData = try? SeparationSnapshotCapture.jsonData([
            "root": beforeTree,
            "recognizedKeyCounts": beforeSanitizer.counts
        ])
        let afterData = try? SeparationSnapshotCapture.jsonData([
            "root": afterTree,
            "recognizedKeyCounts": afterSanitizer.counts
        ])
        require(beforeData != afterData, "nested unknown subtree changes must affect structural evidence")
        guard let beforeText = beforeData.flatMap({ String(data: $0, encoding: .utf8) }),
              let afterText = afterData.flatMap({ String(data: $0, encoding: .utf8) }) else {
            fail("nested unknown subtree JSON was not serializable")
        }
        require(!beforeText.contains("PerDisplayState"), "unknown parent key leaked")
        require(!beforeText.contains("NestedConfiguration"), "unknown child key leaked")
        require(!beforeText.contains("before-secret"), "unknown nested value leaked")
        require(!afterText.contains("after-secret"), "changed unknown nested value leaked")
        require(beforeText.contains("\"Type\""), "recognized nested key was discarded")
        require(afterText.contains("\"Type\""), "recognized nested key was discarded after change")
    }

    private static func testMalformedAndMissingIndex() {
        let directory = tryTemporaryDirectory()
        let missingURL = directory.appendingPathComponent("missing.plist")
        let missing = IndexSnapshotReader.read(url: missingURL)
        require(missing.status == "unavailable", "missing plist must be unavailable")
        require(missing.rawData == nil, "missing plist must not create raw data")
        let missingIndex2 = IndexSnapshotReader.read(url: missingURL, label: "Index2.plist")
        require(missingIndex2.status == "unavailable", "missing Index2 plist must be unavailable")
        require(missingIndex2.reason == "Index2.plist缺失", "Index2 absence must be explicit")

        let malformedURL = directory.appendingPathComponent("malformed.plist")
        tryWrite(Data([0x00, 0xff, 0x11, 0x22, 0x33]), to: malformedURL)
        let malformed = IndexSnapshotReader.read(url: malformedURL)
        require(malformed.status == "unavailable", "malformed plist must be unavailable")
        require(malformed.rawData != nil, "stable malformed bytes should remain available for local evidence")
        require(malformed.structural == nil, "malformed plist must not get guessed structure")
        let malformedIndex2 = IndexSnapshotReader.read(url: malformedURL, label: "Index2.plist")
        require(malformedIndex2.reason == "Index2.plist格式损坏", "Index2 corruption must be explicit")
    }

    private static func testStableRaceGuard() {
        let before = StableFileMetadata(byteCount: 2, modificationNanoseconds: 1, inode: 3, device: 4)
        let same = StableFileMetadata(byteCount: 2, modificationNanoseconds: 1, inode: 3, device: 4)
        let changed = StableFileMetadata(byteCount: 2, modificationNanoseconds: 2, inode: 3, device: 4)
        require(before == same, "equal stable metadata changed")
        require(before != changed, "metadata race was not observable")
        require(StableFileReader.isStable(before: before, after: same), "stable metadata was rejected")
        require(!StableFileReader.isStable(before: before, after: changed), "metadata race was accepted")

        let directory = tryTemporaryDirectory()
        let url = directory.appendingPathComponent("stable.plist")
        tryWrite(Data("stable".utf8), to: url)
        let result = try? StableFileReader.readData(at: url, maxBytes: 1024)
        require(result?.data == Data("stable".utf8), "stable file read failed")
        require(result?.before == result?.after, "stable read incorrectly reported a race")
    }

    private static func testNoOverwriteAndPermissions() {
        let parent = tryTemporaryDirectory()
        let output = parent.appendingPathComponent("snapshot")
        guard let writer = try? SnapshotWriter(outputPath: output.path) else {
            fail("new output directory was not created")
        }
        let mode = permissions(output.path)
        require(mode == 0o700, "output directory must be private 0700")
        try? writer.write(Data("first".utf8), named: "snapshot.json")
        let existing = output.appendingPathComponent("snapshot.json")
        require(permissions(existing.path) == 0o600, "snapshot file must be private 0600")
        let secondAttempt: Void? = try? writer.write(Data("second".utf8), named: "snapshot.json")
        require(secondAttempt == nil, "writer must reject overwriting an existing file")
        require((try? Data(contentsOf: existing)) == Data("first".utf8), "existing output was overwritten")
        require((try? SnapshotWriter(outputPath: output.path)) == nil, "existing output directory must be rejected")
    }

    private static func testDesktopURLSanitization() {
        let url = URL(fileURLWithPath: "/Users/private-user/Pictures/secret.png")
        let hash = PlistSanitizer.hash("desktop-url:" + url.absoluteString)
        require(hash.count == 64, "desktop URL hash is not SHA-256")
        require(!hash.contains("private-user"), "desktop URL hash leaked path")
    }

    private static func tryTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("p0-separation-test-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            return url
        } catch {
            fail("temporary directory unavailable")
        }
    }

    private static func tryWrite(_ data: Data, to url: URL) {
        do {
            try data.write(to: url, options: .atomic)
            _ = chmod(url.path, 0o600)
        } catch {
            fail("temporary fixture write failed")
        }
    }

    private static func permissions(_ path: String) -> UInt16 {
        var info = stat()
        guard lstat(path, &info) == 0 else { return 0 }
        return UInt16(info.st_mode & 0o777)
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fail(message) }
    }

    private static func fail(_ message: String) -> Never {
        fputs("FAIL: \(message)\n", stderr)
        Foundation.exit(1)
    }
}
