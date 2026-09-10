import Foundation

@main
enum TemporalSampleGroupValidatorTests {
    private enum BoxSizeMode {
        case normal
        case extended
        case zero
    }

    private struct GroupSpec {
        let type: String
        let groupingType: String
        let mode: BoxSizeMode
    }

    static func main() {
        testAllRequiredGroups()
        testExtendedAndZeroSizedBoxes()
        for missing in [
            ("sgpd", "tscl"),
            ("sgpd", "tsas"),
            ("csgm", "tscl"),
            ("csgm", "tsas")
        ] {
            testMissingGroup(type: missing.0, groupingType: missing.1)
        }
        testMalformedSize()
        testMultipleTracks()
        testEmptyFile()
        testMissingPath()
        print("PASS: temporal sample group validator")
    }

    private static func testAllRequiredGroups() {
        let url = writeFixture(stblPayload: requiredGroups())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do {
            _ = try TemporalSampleGroupValidator.validate(at: url)
        } catch {
            fail("all four groups must pass: \(error.localizedDescription)")
        }
    }

    private static func testExtendedAndZeroSizedBoxes() {
        let groups = requiredGroups(
            modes: [
                ("sgpd", "tscl", .extended),
                ("sgpd", "tsas", .normal),
                ("csgm", "tscl", .normal),
                ("csgm", "tsas", .zero)
            ]
        )
        let url = writeFixture(stblPayload: groups)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        require((try? TemporalSampleGroupValidator.validate(at: url)) != nil, "extended and zero-sized boxes must pass")
    }

    private static func testMissingGroup(type: String, groupingType: String) {
        let groups = requiredGroups().filter {
            !($0.type == type && $0.groupingType == groupingType)
        }
        let url = writeFixture(stblPayload: groups)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        require(throws: { try TemporalSampleGroupValidator.validate(at: url) }, "missing \(type) \(groupingType) must fail")
    }

    private static func testMalformedSize() {
        var stbl = makeBox(type: "stbl", payload: requiredGroups().map {
            makeGroupingBox(type: $0.type, groupingType: $0.groupingType, mode: $0.mode)
        }.reduce(into: Data(), { $0.append($1) }))
        stbl[0] = 0
        stbl[1] = 0
        stbl[2] = 0
        stbl[3] = 5
        let url = writeFixture(stblPayload: [], stblOverride: stbl)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        require(throws: { try TemporalSampleGroupValidator.validate(at: url) }, "box size smaller than header must fail")
    }

    private static func testMultipleTracks() {
        let firstTrack = [GroupSpec(type: "sgpd", groupingType: "other", mode: .normal)]
        let url = writeMovieFixture(tracks: [firstTrack, requiredGroups()])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        require(
            (try? TemporalSampleGroupValidator.validate(at: url)) != nil,
            "a complete second track must pass when the first track is not a target track"
        )

        let allMissingURL = writeMovieFixture(
            tracks: [
                Array(requiredGroups().dropLast()),
                Array(requiredGroups().dropFirst())
            ]
        )
        defer { try? FileManager.default.removeItem(at: allMissingURL.deletingLastPathComponent()) }
        require(
            throws: { try TemporalSampleGroupValidator.validate(at: allMissingURL) },
            "all incomplete tracks must fail"
        )
    }

    private static func testEmptyFile() {
        let directory = temporaryDirectory()
        let url = directory.appendingPathComponent("empty.mov")
        FileManager.default.createFile(atPath: url.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: directory) }
        require(throws: { try TemporalSampleGroupValidator.validate(at: url) }, "empty file must fail")
    }

    private static func testMissingPath() {
        let url = temporaryDirectory().appendingPathComponent("does-not-exist.mov")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        require(throws: { try TemporalSampleGroupValidator.validate(at: url) }, "missing path must fail")
    }

    private static func requiredGroups(
        modes: [(String, String, BoxSizeMode)]? = nil
    ) -> [GroupSpec] {
        let values = [
            ("sgpd", "tscl"),
            ("sgpd", "tsas"),
            ("csgm", "tscl"),
            ("csgm", "tsas")
        ]
        if let modes {
            return modes.map { GroupSpec(type: $0.0, groupingType: $0.1, mode: $0.2) }
        }
        return values.map { GroupSpec(type: $0.0, groupingType: $0.1, mode: .normal) }
    }

    private static func writeFixture(
        stblPayload groups: [GroupSpec],
        stblOverride: Data? = nil
    ) -> URL {
        let directory = temporaryDirectory()
        let url = directory.appendingPathComponent("fixture.mov")
        let payload = groups.reduce(into: Data()) { data, item in
            data.append(makeGroupingBox(type: item.type, groupingType: item.groupingType, mode: item.mode))
        }
        let stbl = stblOverride ?? makeBox(type: "stbl", payload: payload)
        let path = ["minf", "mdia", "trak", "moov"].reduce(stbl) { payload, type in
            makeBox(type: type, payload: payload)
        }
        try! path.write(to: url)
        return url
    }

    private static func writeMovieFixture(tracks: [[GroupSpec]]) -> URL {
        let directory = temporaryDirectory()
        let url = directory.appendingPathComponent("multi-track.mov")
        let moviePayload = tracks
            .map(makeTrack)
            .reduce(into: Data()) { $0.append($1) }
        try! makeBox(type: "moov", payload: moviePayload).write(to: url)
        return url
    }

    private static func makeTrack(groups: [GroupSpec]) -> Data {
        let payload = groups.reduce(into: Data()) { data, item in
            data.append(makeGroupingBox(type: item.type, groupingType: item.groupingType, mode: item.mode))
        }
        let stbl = makeBox(type: "stbl", payload: payload)
        return ["minf", "mdia", "trak"].reduce(stbl) { payload, type in
            makeBox(type: type, payload: payload)
        }
    }

    private static func makeGroupingBox(
        type: String,
        groupingType: String,
        mode: BoxSizeMode = .normal
    ) -> Data {
        var payload = Data([0, 0, 0, 0])
        payload.append(contentsOf: groupingType.utf8)
        payload.append(contentsOf: [0, 0, 0, 1])
        return makeBox(type: type, payload: payload, mode: mode)
    }

    private static func makeBox(type: String, payload: Data, mode: BoxSizeMode = .normal) -> Data {
        var data = Data()
        switch mode {
        case .normal:
            appendUInt32(UInt32(8 + payload.count), to: &data)
            data.append(contentsOf: type.utf8)
        case .extended:
            appendUInt32(1, to: &data)
            data.append(contentsOf: type.utf8)
            appendUInt64(UInt64(16 + payload.count), to: &data)
        case .zero:
            appendUInt32(0, to: &data)
            data.append(contentsOf: type.utf8)
        }
        data.append(payload)
        return data
    }

    private static func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wallpaper-converter-validator-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8(value & 0xff))
    }

    private static func appendUInt64(_ value: UInt64, to data: inout Data) {
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8((value >> UInt64(shift)) & 0xff))
        }
    }

    private static func require(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        if !condition() { fail(message) }
    }

    private static func require(
        throws operation: () throws -> Any,
        _ message: String
    ) {
        do {
            _ = try operation()
            fail(message)
        } catch {
            // Expected failure.
        }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write("FAIL: \(message)\n".data(using: .utf8)!)
        exit(1)
    }
}
