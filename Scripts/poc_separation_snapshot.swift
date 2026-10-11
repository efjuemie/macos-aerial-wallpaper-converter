import AppKit
import CryptoKit
import Darwin
import Foundation

// This file is intentionally a standalone, read-only P0 probe.  It does not
// link the application target and must never be changed into an installer or
// wallpaper writer.  Build it with:
//
// swiftc -parse-as-library Scripts/poc_separation_snapshot.swift \
//   -o /tmp/poc-separation-snapshot -framework AppKit -framework CryptoKit
//
// The test helper compiles this file with -DSEPARATION_SNAPSHOT_TESTING so the
// command-line entry point is omitted.

enum SeparationSnapshotError: Error, CustomStringConvertible {
    case usage(String)
    case outputUnavailable
    case outputAlreadyExists
    case fileUnavailable(String)
    case fileChangedDuringRead
    case fileTooLarge
    case malformedPlist
    case invalidSnapshot

    var description: String {
        switch self {
        case .usage(let message): return message
        case .outputUnavailable: return "无法创建快照输出目录。"
        case .outputAlreadyExists: return "快照输出目录已存在；为避免覆盖，请指定新的目录。"
        case .fileUnavailable(let kind): return "\(kind)不可读取。"
        case .fileChangedDuringRead: return "读取期间文件发生变化，快照标记为不可用。"
        case .fileTooLarge: return "文件超过只读快照大小上限。"
        case .malformedPlist: return "壁纸配置不是可解析的Property List。"
        case .invalidSnapshot: return "对比快照格式无效。"
        }
    }
}

struct StableFileMetadata: Equatable {
    let byteCount: Int64
    let modificationNanoseconds: Int64
    let inode: UInt64
    let device: UInt64

    var dictionary: [String: Any] {
        [
            "byteCount": byteCount,
            "modificationNanoseconds": modificationNanoseconds,
            "inode": inode,
            "device": device
        ]
    }
}

struct StableFileData {
    let data: Data
    let before: StableFileMetadata
    let after: StableFileMetadata
}

enum StableFileReader {
    static let indexByteLimit = 16 * 1024 * 1024
    static let hashByteLimit: Int64 = 8 * 1024 * 1024 * 1024
    static let chunkSize = 1024 * 1024

    static func isStable(before: StableFileMetadata, after: StableFileMetadata) -> Bool {
        before == after
    }

    static func metadata(at url: URL) throws -> StableFileMetadata {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw SeparationSnapshotError.fileUnavailable("文件")
        }
        let mode = info.st_mode & S_IFMT
        guard mode == S_IFREG else {
            throw SeparationSnapshotError.fileUnavailable("非普通文件")
        }
        return StableFileMetadata(
            byteCount: Int64(info.st_size),
            modificationNanoseconds: Int64(info.st_mtimespec.tv_sec) * 1_000_000_000
                + Int64(info.st_mtimespec.tv_nsec),
            inode: UInt64(info.st_ino),
            device: UInt64(info.st_dev)
        )
    }

    static func readData(at url: URL, maxBytes: Int = indexByteLimit) throws -> StableFileData {
        let before = try metadata(at: url)
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw SeparationSnapshotError.fileUnavailable("文件")
        }
        defer { try? handle.close() }

        var data = Data()
        data.reserveCapacity(min(maxBytes, Int(before.byteCount)))
        while true {
            let remaining = maxBytes - data.count
            let count = min(chunkSize, max(1, remaining + 1))
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: count) ?? Data()
            } catch {
                throw SeparationSnapshotError.fileUnavailable("文件")
            }
            if chunk.isEmpty { break }
            data.append(chunk)
            if data.count > maxBytes {
                throw SeparationSnapshotError.fileTooLarge
            }
        }
        let after = try metadata(at: url)
        guard isStable(before: before, after: after) else {
            throw SeparationSnapshotError.fileChangedDuringRead
        }
        return StableFileData(data: data, before: before, after: after)
    }

    static func sha256(at url: URL) throws -> (hash: String, metadata: StableFileMetadata) {
        let before = try metadata(at: url)
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw SeparationSnapshotError.fileUnavailable("视频")
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        var total: Int64 = 0
        while true {
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: chunkSize) ?? Data()
            } catch {
                throw SeparationSnapshotError.fileUnavailable("视频")
            }
            if chunk.isEmpty { break }
            total += Int64(chunk.count)
            guard total <= hashByteLimit else {
                throw SeparationSnapshotError.fileTooLarge
            }
            hasher.update(data: chunk)
        }
        let after = try metadata(at: url)
        guard isStable(before: before, after: after), before.byteCount == total else {
            throw SeparationSnapshotError.fileChangedDuringRead
        }
        return (hex(hasher.finalize()), after)
    }

    static func sha256(data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

struct SnapshotWriter {
    let root: URL

    init(outputPath: String) throws {
        let candidate = URL(fileURLWithPath: outputPath, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: candidate.path) else {
            throw SeparationSnapshotError.outputAlreadyExists
        }
        guard mkdir(candidate.path, 0o700) == 0 else {
            throw SeparationSnapshotError.outputUnavailable
        }
        _ = chmod(candidate.path, 0o700)
        root = candidate
    }

    @discardableResult
    func makeDirectory(_ name: String) throws -> URL {
        guard !name.isEmpty, !name.contains("/") else {
            throw SeparationSnapshotError.outputUnavailable
        }
        let directory = root.appendingPathComponent(name, isDirectory: true)
        guard mkdir(directory.path, 0o700) == 0 else {
            throw SeparationSnapshotError.outputUnavailable
        }
        _ = chmod(directory.path, 0o700)
        return directory
    }

    func write(_ data: Data, named name: String, mode: mode_t = 0o600) throws {
        guard !name.isEmpty, !name.contains("/") else {
            throw SeparationSnapshotError.outputUnavailable
        }
        try write(data, to: root.appendingPathComponent(name), mode: mode)
    }

    func write(_ data: Data, to url: URL, mode: mode_t = 0o600) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL, mode)
        guard descriptor >= 0 else {
            throw SeparationSnapshotError.outputUnavailable
        }
        do {
            try data.withUnsafeBytes { bytes in
                guard let baseAddress = bytes.baseAddress else { return }
                var offset = 0
                while offset < bytes.count {
                    let written = Darwin.write(
                        descriptor,
                        baseAddress.advanced(by: offset),
                        bytes.count - offset
                    )
                    guard written > 0 else {
                        throw SeparationSnapshotError.outputUnavailable
                    }
                    offset += written
                }
            }
            guard fsync(descriptor) == 0 else {
                throw SeparationSnapshotError.outputUnavailable
            }
            guard fchmod(descriptor, mode) == 0 else {
                throw SeparationSnapshotError.outputUnavailable
            }
            close(descriptor)
        } catch {
            close(descriptor)
            _ = unlink(url.path)
            throw error
        }
    }
}

enum StrictUUID {
    private static let pattern = #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"#

    static func normalize(_ value: String) -> String? {
        let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard candidate.range(of: pattern, options: .regularExpression) != nil else {
            return nil
        }
        return candidate.uppercased()
    }
}

final class PlistSanitizer {
    static let recognizedKeys: Set<String> = [
        "Type", "Linked", "Desktop", "Idle", "AllSpacesAndDisplays",
        "Displays", "Spaces", "SystemDefault", "Provider", "Configuration"
    ]

    private(set) var counts: [String: Int] = [:]
    private(set) var unknownKeyHashes: Set<String> = []

    func sanitize(_ object: Any) -> Any {
        let value = sanitizeValue(object)
        for key in Self.recognizedKeys {
            counts[key] = counts[key, default: 0]
        }
        return value
    }

    private func sanitizeValue(_ object: Any) -> Any {
        if let dictionary = dictionary(from: object) {
            var output: [String: Any] = [:]
            var localUnknownKeyHashes: Set<String> = []
            for key in dictionary.keys.sorted() {
                let value = dictionary[key]!
                if Self.recognizedKeys.contains(key) {
                    counts[key, default: 0] += 1
                    output[key] = sanitizeValue(value)
                } else {
                    let keyHash = Self.hash("plist-key:" + key)
                    unknownKeyHashes.insert(keyHash)
                    localUnknownKeyHashes.insert(keyHash)
                    output["_unknownKey_\(keyHash)"] = sanitizeValue(value)
                }
            }
            if !localUnknownKeyHashes.isEmpty {
                output["_unknownKeyHashes"] = localUnknownKeyHashes.sorted()
            }
            return output
        }
        if let array = object as? [Any] {
            return array.map(sanitizeValue)
        }
        if let array = object as? NSArray {
            return array.map { sanitizeValue($0) }
        }
        if let data = object as? Data {
            return ["kind": "data", "byteCount": data.count, "sha256": Self.hash(data)]
        }
        if let date = object as? Date {
            return ["kind": "date", "sha256": Self.hash("date:\(date.timeIntervalSince1970)")]
        }
        if let string = object as? String {
            return ["kind": "string", "length": string.utf8.count, "sha256": Self.hash("string:" + string)]
        }
        if let number = object as? NSNumber {
            let type: String
            switch String(cString: number.objCType) {
            case "c": type = "bool-or-int8"
            case "s", "i", "l", "q": type = "integer"
            case "f", "d": type = "real"
            default: type = "number"
            }
            return ["kind": type, "sha256": Self.hash("number:\(number)")]
        }
        if object is NSNull {
            return ["kind": "null"]
        }
        return ["kind": "redacted", "type": String(describing: type(of: object))]
    }

    private func dictionary(from object: Any) -> [String: Any]? {
        if let dictionary = object as? [String: Any] {
            return dictionary
        }
        if let dictionary = object as? NSDictionary {
            var result: [String: Any] = [:]
            for (key, value) in dictionary {
                guard let key = key as? String else { continue }
                result[key] = value
            }
            return result
        }
        return nil
    }

    static func hash(_ value: String) -> String {
        StableFileReader.sha256(data: Data(value.utf8))
    }

    static func hash(_ value: Data) -> String {
        StableFileReader.sha256(data: value)
    }
}

struct IndexCaptureResult {
    let status: String
    let reason: String?
    let byteCount: Int?
    let sha256: String?
    let format: String?
    let structural: [String: Any]?
    let rawData: Data?
    let metadata: StableFileMetadata?
}

enum IndexSnapshotReader {
    static func read(url: URL, label: String = "Index.plist") -> IndexCaptureResult {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return IndexCaptureResult(
                status: "unavailable", reason: "\(label)缺失", byteCount: nil,
                sha256: nil, format: nil, structural: nil, rawData: nil, metadata: nil
            )
        }
        let stable: StableFileData
        do {
            stable = try StableFileReader.readData(at: url)
        } catch let error as SeparationSnapshotError {
            return IndexCaptureResult(
                status: "unavailable", reason: reason(for: error, label: label), byteCount: nil,
                sha256: nil, format: nil, structural: nil, rawData: nil, metadata: nil
            )
        } catch {
            return IndexCaptureResult(
                status: "unavailable", reason: "\(label)读取失败", byteCount: nil,
                sha256: nil, format: nil, structural: nil, rawData: nil, metadata: nil
            )
        }

        let digest = StableFileReader.sha256(data: stable.data)
        var format = PropertyListSerialization.PropertyListFormat.xml
        do {
            let object = try PropertyListSerialization.propertyList(
                from: stable.data,
                options: [],
                format: &format
            )
            let sanitizer = PlistSanitizer()
            let tree = sanitizer.sanitize(object)
            return IndexCaptureResult(
                status: "available",
                reason: nil,
                byteCount: stable.data.count,
                sha256: digest,
                format: formatName(format),
                structural: [
                    "root": tree,
                    "recognizedKeyCounts": sanitizer.counts,
                    "unknownKeyHashes": sanitizer.unknownKeyHashes.sorted()
                ],
                rawData: stable.data,
                metadata: stable.after
            )
        } catch {
            return IndexCaptureResult(
                status: "unavailable",
                reason: "\(label)格式损坏",
                byteCount: stable.data.count,
                sha256: digest,
                format: nil,
                structural: nil,
                rawData: stable.data,
                metadata: stable.after
            )
        }
    }

    private static func formatName(_ format: PropertyListSerialization.PropertyListFormat) -> String {
        switch format {
        case .binary: return "binary"
        case .xml: return "xml"
        case .openStep: return "openStep"
        @unknown default: return "unknown"
        }
    }

    private static func reason(for error: SeparationSnapshotError, label: String) -> String {
        switch error {
        case .fileChangedDuringRead: return "\(label)读取竞态"
        case .fileTooLarge: return "\(label)超过大小上限"
        case .fileUnavailable: return "\(label)不可读取"
        default: return "\(label)读取失败"
        }
    }
}

struct DesktopScreenCapture {
    let sanitized: [String: Any]
    let privateState: [String: Any]
}

enum DesktopStateReader {
    static func capture() -> [DesktopScreenCapture] {
        NSScreen.screens.map { screen in
            let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
                .map { UInt32(truncating: $0) }
            let url = NSWorkspace.shared.desktopImageURL(for: screen)
            let options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
            let sanitizedOptions = options.keys.sorted { $0.rawValue < $1.rawValue }.reduce(into: [String: Any]()) { result, key in
                result["keyHash_\(PlistSanitizer.hash(key.rawValue))"] = sanitizeOption(options[key]!)
            }
            let privateOptions = options.keys.sorted { $0.rawValue < $1.rawValue }.reduce(into: [String: Any]()) { result, key in
                result[key.rawValue] = privateOption(options[key]!)
            }
            var sanitized: [String: Any] = [
                "displayID": displayID as Any,
                "isMain": screen === NSScreen.main,
                "isBuiltIn": displayID.map { CGDisplayIsBuiltin(CGDirectDisplayID($0)) != 0 } as Any,
                "framePoints": [
                    "width": screen.frame.width,
                    "height": screen.frame.height,
                    "originX": screen.frame.origin.x,
                    "originY": screen.frame.origin.y
                ],
                "backingScaleFactor": screen.backingScaleFactor,
                "pixelWidth": Int((screen.frame.width * screen.backingScaleFactor).rounded()),
                "pixelHeight": Int((screen.frame.height * screen.backingScaleFactor).rounded()),
                "desktopImage": [
                    "present": url != nil,
                    "urlSha256": url.map { PlistSanitizer.hash("desktop-url:" + $0.absoluteString) } as Any,
                    "options": sanitizedOptions
                ],
                "spaceCount": NSNull(),
                "spaceStatus": "unavailable: public read-only API not available"
            ]
            // Avoid JSON nulls being represented through an Optional<Any>.
            if displayID == nil { sanitized["displayID"] = NSNull() }
            if let displayID {
                sanitized["isBuiltIn"] = CGDisplayIsBuiltin(CGDirectDisplayID(displayID)) != 0
            } else {
                sanitized["isBuiltIn"] = NSNull()
            }
            if url == nil { sanitized["desktopImage"] = ["present": false, "options": sanitizedOptions] }
            var privateValues: [String: Any] = [
                "displayID": displayID as Any,
                "desktopImageURL": url?.absoluteString as Any,
                "desktopImageOptions": privateOptions
            ]
            if displayID == nil { privateValues["displayID"] = NSNull() }
            if url == nil { privateValues["desktopImageURL"] = NSNull() }
            return DesktopScreenCapture(sanitized: sanitized, privateState: privateValues)
        }
    }

    private static func sanitizeOption(_ value: Any) -> Any {
        if let url = value as? URL {
            return ["kind": "url", "sha256": PlistSanitizer.hash("desktop-option-url:" + url.absoluteString)]
        }
        if value is NSColor {
            return ["kind": "color", "redacted": true]
        }
        if let string = value as? String {
            return ["kind": "string", "length": string.utf8.count, "sha256": PlistSanitizer.hash("desktop-option:" + string)]
        }
        if let number = value as? NSNumber {
            return ["kind": "number", "sha256": PlistSanitizer.hash("desktop-option-number:\(number)")]
        }
        return ["kind": "redacted", "type": String(describing: type(of: value))]
    }

    private static func privateOption(_ value: Any) -> Any {
        if let color = value as? NSColor {
            let sRGB = color.usingColorSpace(.sRGB)
            var result: [String: Any] = [
                "kind": "NSColor",
                "red": sRGB?.redComponent as Any,
                "green": sRGB?.greenComponent as Any,
                "blue": sRGB?.blueComponent as Any,
                "alpha": sRGB?.alphaComponent as Any
            ]
            if let archived = try? NSKeyedArchiver.archivedData(
                withRootObject: color,
                requiringSecureCoding: true
            ) {
                result["secureArchiveBase64"] = archived.base64EncodedString()
            } else {
                result["secureArchiveBase64"] = NSNull()
            }
            return result
        }
        if let url = value as? URL { return url.absoluteString }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number }
        return "<redacted \(String(describing: type(of: value)))>"
    }
}

enum SystemSnapshotReader {
    static let indexURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
    static let index2URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index2.plist")
    static let aerialDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.apple.wallpaper/aerials/videos")

    static func systemInfo() -> [String: Any] {
        var version = ProcessInfo.processInfo.operatingSystemVersionString
        var build: String?
        let systemVersionURL = URL(fileURLWithPath: "/System/Library/CoreServices/SystemVersion.plist")
        if let data = try? Data(contentsOf: systemVersionURL),
           let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
            if let productVersion = object["ProductVersion"] as? String { version = productVersion }
            build = object["ProductBuildVersion"] as? String
        }
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unknown"
        #endif
        var result: [String: Any] = [
            "macOSVersion": version,
            "architecture": architecture,
            "machineModel": machineModel() as Any,
            "screens": screenInfo(),
            "spaceCount": NSNull(),
            "spaceStatus": "unavailable: public read-only API not available"
        ]
        if let build { result["build"] = build } else { result["build"] = NSNull() }
        if machineModel() == nil { result["machineModel"] = NSNull() }
        return result
    }

    static func screenInfo() -> [[String: Any]] {
        NSScreen.screens.map { screen in
            let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
                .map { UInt32(truncating: $0) }
            var result: [String: Any] = [
                "displayID": displayID as Any,
                "isMain": screen === NSScreen.main,
                "isBuiltIn": displayID.map { CGDisplayIsBuiltin(CGDirectDisplayID($0)) != 0 } as Any,
                "framePoints": ["width": screen.frame.width, "height": screen.frame.height],
                "backingScaleFactor": screen.backingScaleFactor
            ]
            if displayID == nil { result["displayID"] = NSNull() }
            if let displayID {
                result["isBuiltIn"] = CGDisplayIsBuiltin(CGDirectDisplayID(displayID)) != 0
            } else {
                result["isBuiltIn"] = NSNull()
            }
            return result
        }
    }

    static func targetCapture(uuid: String?) -> (report: [String: Any], privateState: [String: Any]) {
        guard let uuid else {
            let candidates = aerialCandidates().map { ["uuid": $0] }
            return (
                [
                    "status": "notSelected",
                    "reason": "未提供目标UUID；文件名不是当前生效目标的证据。",
                    "candidateUUIDs": candidates
                ],
                ["targetVideoSourcePath": NSNull()]
            )
        }
        let url = aerialDirectory.appendingPathComponent("\(uuid).mov")
        do {
            let result = try StableFileReader.sha256(at: url)
            return (
                [
                    "status": "available",
                    "uuid": uuid,
                    "sha256": result.hash,
                    "byteCount": result.metadata.byteCount
                ],
                ["targetVideoSourcePath": url.path, "targetUUID": uuid]
            )
        } catch let error as SeparationSnapshotError {
            return (
                ["status": "unavailable", "uuid": uuid, "reason": targetReason(error)],
                ["targetVideoSourcePath": url.path, "targetUUID": uuid]
            )
        } catch {
            return (
                ["status": "unavailable", "uuid": uuid, "reason": "目标视频不可读取"],
                ["targetVideoSourcePath": url.path, "targetUUID": uuid]
            )
        }
    }

    private static func aerialCandidates() -> [String] {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: aerialDirectory, includingPropertiesForKeys: nil) else {
            return []
        }
        return urls.compactMap { url in
            guard url.pathExtension.lowercased() == "mov",
                  let uuid = StrictUUID.normalize(url.deletingPathExtension().lastPathComponent),
                  (try? StableFileReader.metadata(at: url)) != nil else {
                return nil
            }
            return uuid
        }.sorted()
    }

    private static func targetReason(_ error: SeparationSnapshotError) -> String {
        switch error {
        case .fileChangedDuringRead: return "目标视频读取竞态"
        case .fileTooLarge: return "目标视频超过大小上限"
        case .fileUnavailable: return "目标视频缺失或不可读取"
        default: return "目标视频不可读取"
        }
    }

    private static func machineModel() -> String? {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return nil }
        return String(bytes: bytes.prefix { $0 != 0 }, encoding: .utf8)
    }
}

enum SeparationSnapshotCapture {
    static let schemaVersion = 1

    static func run(
        writer: SnapshotWriter,
        targetUUID: String?,
        compareURL: URL?
    ) throws {
        let rawDirectory = try writer.makeDirectory("raw")
        let index = IndexSnapshotReader.read(url: SystemSnapshotReader.indexURL)
        let index2 = IndexSnapshotReader.read(url: SystemSnapshotReader.index2URL, label: "Index2.plist")
        try saveRaw(index, fileName: "Index.plist", in: rawDirectory, writer: writer)
        try saveRaw(index2, fileName: "Index2.plist", in: rawDirectory, writer: writer)

        let target = SystemSnapshotReader.targetCapture(uuid: targetUUID)
        let desktop = DesktopStateReader.capture()
        let desktopSanitized = desktop.map(\.sanitized)
        let privateState: [String: Any] = [
            "privacy": "LOCAL_ONLY_DO_NOT_SHARE",
            "indexSourcePath": SystemSnapshotReader.indexURL.path,
            "index2SourcePath": SystemSnapshotReader.index2URL.path,
            "target": target.privateState,
            "desktop": desktop.map(\.privateState)
        ]
        try writer.write(try jsonData(privateState), named: "private-state.json")

        var rawFiles = ["private-state.json"]
        if index.rawData != nil { rawFiles.append("raw/Index.plist") }
        if index2.rawData != nil { rawFiles.append("raw/Index2.plist") }
        var report: [String: Any] = [
            "schemaVersion": schemaVersion,
            "capturedAt": ISO8601DateFormatter().string(from: Date()),
            "system": SystemSnapshotReader.systemInfo(),
            "target": target.report,
            "index": indexReport(index, rawFile: index.rawData == nil ? nil : "raw/Index.plist"),
            "index2": indexReport(index2, rawFile: index2.rawData == nil ? nil : "raw/Index2.plist"),
            "desktop": [
                "status": "readOnly",
                "screens": desktopSanitized
            ],
            "privacy": [
                "sanitizedReport": true,
                "rawFiles": rawFiles,
                "warning": "private-state.json和raw/Index*.plist仅供本机核对，分享前请删除。"
            ]
        ]
        if let compareURL {
            report["comparison"] = comparison(current: report, compareURL: compareURL, indexKey: "index")
            report["index2Comparison"] = comparison(current: report, compareURL: compareURL, indexKey: "index2")
        }
        try writer.write(try jsonData(report), named: "snapshot.json")
        print("P0只读快照已生成；未修改系统壁纸、Store、锁屏、电源或进程状态。")
    }

    private static func saveRaw(
        _ capture: IndexCaptureResult,
        fileName: String,
        in rawDirectory: URL,
        writer: SnapshotWriter
    ) throws {
        guard let rawData = capture.rawData else { return }
        let rawURL = rawDirectory.appendingPathComponent(fileName)
        try writer.write(rawData, to: rawURL)
        let saved = try StableFileReader.readData(at: rawURL)
        guard saved.data == rawData,
              let expectedHash = capture.sha256,
              StableFileReader.sha256(data: saved.data) == expectedHash else {
            throw SeparationSnapshotError.outputUnavailable
        }
    }

    private static func indexReport(
        _ capture: IndexCaptureResult,
        rawFile: String?
    ) -> [String: Any] {
        var result: [String: Any] = [
            "status": capture.status,
            "byteCount": capture.byteCount as Any,
            "sha256": capture.sha256 as Any,
            "format": capture.format as Any,
            "rawFile": rawFile as Any,
            "structural": capture.structural as Any
        ]
        if let reason = capture.reason {
            result["reason"] = reason
        }
        return result
    }

    private static func comparison(
        current: [String: Any],
        compareURL: URL,
        indexKey: String
    ) -> [String: Any] {
        guard let stable = try? StableFileReader.readData(
            at: compareURL,
            maxBytes: StableFileReader.indexByteLimit
        ),
              let object = try? JSONSerialization.jsonObject(with: stable.data),
              let previous = object as? [String: Any],
              let previousSchema = previous["schemaVersion"] as? NSNumber,
              previousSchema.intValue == schemaVersion,
              let previousIndex = previous[indexKey] as? [String: Any],
              let currentIndex = current[indexKey] as? [String: Any],
              (previousIndex["status"] as? String) == "available",
              (currentIndex["status"] as? String) == "available" else {
            return ["status": "unavailable", "reason": "\(indexKey)对比快照不可解析"]
        }
        let oldStructural = previousIndex["structural"] as? [String: Any]
        let newStructural = currentIndex["structural"] as? [String: Any]
        guard let oldStructural, let newStructural,
              oldStructural["root"] != nil,
              oldStructural["recognizedKeyCounts"] is [String: Any],
              oldStructural["unknownKeyHashes"] is [Any],
              newStructural["root"] != nil,
              newStructural["recognizedKeyCounts"] is [String: Any],
              newStructural["unknownKeyHashes"] is [Any],
              let oldData = try? jsonData(oldStructural),
              let newData = try? jsonData(newStructural) else {
            return ["status": "unavailable", "reason": "\(indexKey)对比快照缺少结构化数据"]
        }
        let oldCounts = oldStructural["recognizedKeyCounts"] as? [String: Any] ?? [:]
        let newCounts = newStructural["recognizedKeyCounts"] as? [String: Any] ?? [:]
        let allKeys = Set(oldCounts.keys).union(newCounts.keys).sorted()
        var keyChanges: [String: Any] = [:]
        for key in allKeys {
            let before = oldCounts[key] as? NSNumber
            let after = newCounts[key] as? NSNumber
            if before?.intValue != after?.intValue {
                keyChanges[key] = [
                    "beforeCount": before?.intValue as Any,
                    "afterCount": after?.intValue as Any
                ]
            }
        }
        return [
            "status": "available",
            "structuralChanged": oldData != newData,
            "beforeStructuralSha256": PlistSanitizer.hash(oldData),
            "afterStructuralSha256": PlistSanitizer.hash(newData),
            "recognizedKeyCountChanges": keyChanges
        ]
    }

    static func jsonData(_ object: Any) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw SeparationSnapshotError.outputUnavailable
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }
}

struct SeparationSnapshotCLI {
    struct Options {
        let outputPath: String
        let targetUUID: String?
        let compareURL: URL?
    }

    static func parse(_ arguments: [String]) throws -> Options {
        var outputPath: String?
        var targetUUID: String?
        var compareURL: URL?
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--output":
                index += 1
                guard index < arguments.count else { throw SeparationSnapshotError.usage("--output需要目录") }
                outputPath = arguments[index]
            case "--target-uuid":
                index += 1
                guard index < arguments.count,
                      let normalized = StrictUUID.normalize(arguments[index]) else {
                    throw SeparationSnapshotError.usage("--target-uuid必须是标准UUID")
                }
                targetUUID = normalized
            case "--compare":
                index += 1
                guard index < arguments.count else { throw SeparationSnapshotError.usage("--compare需要快照JSON") }
                compareURL = URL(fileURLWithPath: arguments[index])
            case "--help", "-h":
                throw SeparationSnapshotError.usage("用法：poc_separation_snapshot --output 新目录 [--target-uuid UUID] [--compare 旧snapshot.json]")
            default:
                throw SeparationSnapshotError.usage("存在未识别参数")
            }
            index += 1
        }
        guard let outputPath, !outputPath.isEmpty else {
            throw SeparationSnapshotError.usage("必须提供--output新目录")
        }
        return Options(outputPath: outputPath, targetUUID: targetUUID, compareURL: compareURL)
    }

    static func run(arguments: [String]) -> Int32 {
        do {
            let options = try parse(arguments)
            let writer = try SnapshotWriter(outputPath: options.outputPath)
            try SeparationSnapshotCapture.run(
                writer: writer,
                targetUUID: options.targetUUID,
                compareURL: options.compareURL
            )
            return 0
        } catch {
            fputs("P0只读快照未完成：\(error)\n", stderr)
            return 64
        }
    }
}

#if !SEPARATION_SNAPSHOT_TESTING
@main
enum SeparationSnapshotMain {
    static func main() {
        Foundation.exit(SeparationSnapshotCLI.run(arguments: Array(CommandLine.arguments.dropFirst())))
    }
}
#endif
