import Foundation

struct VideoLoadStateMachine: Equatable, Sendable {
    private(set) var activeGeneration: UUID?
    private(set) var isBusy = false

    mutating func begin() -> UUID {
        let generation = UUID()
        activeGeneration = generation
        isBusy = true
        return generation
    }

    func isCurrent(_ generation: UUID) -> Bool {
        isBusy && activeGeneration == generation
    }

    @discardableResult
    mutating func finish(_ generation: UUID) -> Bool {
        guard isCurrent(generation) else { return false }
        activeGeneration = nil
        isBusy = false
        return true
    }

    @discardableResult
    mutating func cancelCurrent() -> Bool {
        guard isBusy else { return false }
        activeGeneration = nil
        isBusy = false
        return true
    }
}

enum EnvironmentRefreshPolicy {
    static func shouldResetToChecking(checkCount: Int, hasCheckingStatus: Bool) -> Bool {
        checkCount == 0 || hasCheckingStatus
    }
}

enum VideoInputParserError: Error, Equatable, LocalizedError {
    case empty
    case invalidLocalURL
    case unsupportedRemoteURL
    case unsupportedFileType(String)

    var errorDescription: String? {
        switch self {
        case .empty:
            return "请先输入视频路径。"
        case .invalidLocalURL:
            return "无法识别本地视频路径，请输入绝对路径、~/ 路径或 file:// 本地 URL。"
        case .unsupportedRemoteURL:
            return "当前版本不直接下载网络视频链接，请先将视频下载到本地后再拖入或选择文件。"
        case let .unsupportedFileType(extensionName):
            return "仅支持 .mov、.mp4 和 .m4v 视频文件（当前为 .\(extensionName)）。"
        }
    }
}

enum VideoInputParser {
    static let supportedExtensions: Set<String> = ["mov", "mp4", "m4v"]

    static func parse(
        _ rawValue: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Result<URL, VideoInputParserError> {
        let rawValue = removingWrappingQuotes(
            rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard !rawValue.isEmpty else { return .failure(.empty) }

        if let parsedURL = URL(string: rawValue), let scheme = parsedURL.scheme?.lowercased() {
            if scheme == "file" {
                return parse(parsedURL)
            }
            if scheme == "http" || scheme == "https" {
                return .failure(.unsupportedRemoteURL)
            }
        }

        let expandedPath: String
        if rawValue == "~" {
            expandedPath = homeDirectory.path
        } else if rawValue.hasPrefix("~/") {
            expandedPath = homeDirectory.appendingPathComponent(
                String(rawValue.dropFirst(2))
            ).path
        } else if rawValue.hasPrefix("/") {
            expandedPath = rawValue
        } else {
            return .failure(.invalidLocalURL)
        }
        return parse(URL(fileURLWithPath: expandedPath))
    }

    static func parse(_ url: URL) -> Result<URL, VideoInputParserError> {
        if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            return .failure(.unsupportedRemoteURL)
        }
        guard url.isFileURL, !url.path.isEmpty else {
            return .failure(.invalidLocalURL)
        }
        let extensionName = url.pathExtension.lowercased()
        guard supportedExtensions.contains(extensionName) else {
            return .failure(.unsupportedFileType(extensionName.isEmpty ? "未知" : extensionName))
        }
        return .success(url.standardizedFileURL)
    }

    private static func removingWrappingQuotes(_ value: String) -> String {
        guard value.count >= 2,
              let first = value.first,
              let last = value.last,
              (first == "\"" && last == "\"") || (first == "'" && last == "'") else {
            return value
        }
        return String(value.dropFirst().dropLast())
    }
}

enum DroppedVideoURLResolver {
    static func resolve(_ item: Any?) -> Result<URL, VideoInputParserError> {
        if let url = item as? URL {
            return VideoInputParser.parse(url)
        }
        if let url = item as? NSURL {
            return VideoInputParser.parse(url as URL)
        }
        if let data = item as? Data {
            return resolveData(data)
        }
        if let data = item as? NSData {
            return resolveData(Data(referencing: data))
        }
        if let string = item as? String {
            return VideoInputParser.parse(string)
        }
        if let string = item as? NSString {
            return VideoInputParser.parse(string as String)
        }
        return .failure(.invalidLocalURL)
    }

    private static func resolveData(_ data: Data) -> Result<URL, VideoInputParserError> {
        if let url = URL(dataRepresentation: data, relativeTo: nil) {
            return VideoInputParser.parse(url)
        }
        if let string = String(data: data, encoding: .utf8) {
            return VideoInputParser.parse(string)
        }
        return .failure(.invalidLocalURL)
    }
}

enum TargetAvailability: Equatable, Sendable {
    case available
    case missing
    case unreadable
    case notRegularFile
    case empty
    case invalidUUID

    var isAvailable: Bool {
        self == .available
    }

    var message: String {
        switch self {
        case .available:
            return "目标文件已就绪。"
        case .missing:
            return "当前 UUID 对应的动态壁纸文件不存在，请先从系统设置→壁纸中下载并选择目标。"
        case .unreadable:
            return "当前 UUID 对应的动态壁纸文件不可读，请检查文件权限或重新下载。"
        case .notRegularFile:
            return "当前 UUID 对应的路径不是可用的动态壁纸文件。"
        case .empty:
            return "当前 UUID 对应的动态壁纸文件为空，请重新下载。"
        case .invalidUUID:
            return "当前 Aerial UUID 格式无效。"
        }
    }

    static func evaluate(_ url: URL, fileManager: FileManager = .default) -> TargetAvailability {
        guard fileManager.fileExists(atPath: url.path) else { return .missing }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return .notRegularFile
        }
        guard fileManager.isReadableFile(atPath: url.path) else { return .unreadable }
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true else {
            return .notRegularFile
        }
        guard (values.fileSize ?? 0) > 0 else { return .empty }
        return .available
    }
}

enum TargetSelectionPolicy {
    private static let uuidPattern = #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"#

    static func normalizeUUID(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate: String
        if trimmed.lowercased().hasSuffix(".mov") {
            candidate = String(trimmed.dropLast(4))
        } else {
            candidate = trimmed
        }
        guard candidate.range(of: uuidPattern, options: .regularExpression) != nil else {
            return nil
        }
        return candidate.uppercased()
    }

    static func select(
        uuidText: String,
        selectedUUID: String,
        availableUUIDs: [String]
    ) -> String? {
        let available = availableUUIDs.compactMap(normalizeUUID)
        if let uuid = normalizeUUID(uuidText), available.contains(uuid) {
            return uuid
        }
        if let uuid = normalizeUUID(selectedUUID), available.contains(uuid) {
            return uuid
        }
        return available.first
    }
}

enum ProcessingBlockReason: Equatable, Sendable {
    case noInput
    case inspectingVideo
    case invalidUUID
    case targetUnavailable(TargetAvailability)
    case environmentChecking
    case environmentFailure([String])
    case processing
    case preparingLayout
    case reidentifying

    var message: String {
        switch self {
        case .noInput:
            return "请先拖入或选择一个本地视频。"
        case .inspectingVideo:
            return "正在读取视频信息…"
        case .invalidUUID:
            return "当前 Aerial UUID 格式无效。"
        case let .targetUnavailable(availability):
            return availability.message
        case .environmentChecking:
            return "正在检查运行环境…"
        case let .environmentFailure(names):
            return names.isEmpty ? "运行环境未就绪，请先完成环境检查。" : "请先处理：" + names.joined(separator: "、")
        case .processing:
            return "正在处理视频，请稍候…"
        case .preparingLayout:
            return "正在读取目标动态壁纸画布…"
        case .reidentifying:
            return "正在重新识别系统原壁纸…"
        }
    }
}

struct ProcessingReadinessInput: Equatable, Sendable {
    let inputLoaded: Bool
    let isInspectingVideo: Bool
    let uuidValid: Bool
    let targetAvailability: TargetAvailability
    let environmentChecking: Bool
    let environmentFailures: [String]
    let isProcessing: Bool
    let isPreparingLayout: Bool
    let isReidentifying: Bool
}

enum ProcessingReadiness: Equatable, Sendable {
    case ready
    case blocked(ProcessingBlockReason)

    var canStart: Bool {
        if case .ready = self { return true }
        return false
    }

    var blockReason: ProcessingBlockReason? {
        if case let .blocked(reason) = self { return reason }
        return nil
    }

    static func evaluate(_ input: ProcessingReadinessInput) -> ProcessingReadiness {
        if input.isProcessing {
            return .blocked(.processing)
        }
        if input.isPreparingLayout {
            return .blocked(.preparingLayout)
        }
        if input.isReidentifying {
            return .blocked(.reidentifying)
        }
        if input.isInspectingVideo {
            return .blocked(.inspectingVideo)
        }
        if !input.inputLoaded {
            return .blocked(.noInput)
        }
        if !input.uuidValid {
            return .blocked(.invalidUUID)
        }
        if !input.targetAvailability.isAvailable {
            return .blocked(.targetUnavailable(input.targetAvailability))
        }
        if input.environmentChecking {
            return .blocked(.environmentChecking)
        }
        if !input.environmentFailures.isEmpty {
            return .blocked(.environmentFailure(input.environmentFailures))
        }
        return .ready
    }
}
