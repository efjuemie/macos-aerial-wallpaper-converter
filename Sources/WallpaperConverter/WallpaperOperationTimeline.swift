import Foundation

/// The three workflows that can replace the installed Aerial video.
enum WallpaperOperationKind: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case conversion
    case historyReplacement
    case backupRestore

    var displayName: String {
        switch self {
        case .conversion:
            return "新视频替换"
        case .historyReplacement:
            return "历史壁纸替换"
        case .backupRestore:
            return "备份恢复"
        }
    }
}

/// A privacy-safe record of one file replacement workflow.
///
/// The record intentionally stores no source, target, backup, or output paths.
/// UUIDs, hashes, command status, and redacted error text are enough for the
/// lock-behavior diagnostics without persisting a user's home directory.
struct WallpaperOperationRecord: Codable, Equatable, Sendable {
    let id: UUID
    let kind: WallpaperOperationKind
    let startTime: Date
    var endTime: Date?
    let timezone: String
    let targetUUID: String?

    var backupCreated: Bool
    var backupSHA256: String?
    var backupVerified: Bool?

    var installationSucceeded: Bool?
    var installedSHA256: String?
    var installationVerified: Bool?
    var installationCompletedAt: Date?

    var rollbackAttempted: Bool
    var rollbackSucceeded: Bool?
    var rollbackSHA256: String?
    var rollbackVerified: Bool?

    var reloadStartedAt: Date?
    var reloadEndedAt: Date?
    var reloadExecutableAvailable: Bool?
    var reloadExitCode: Int32?
    var reloadSucceeded: Bool?
    var reloadSkipped: Bool
    var reloadErrorMessage: String?

    var errorMessage: String?
    var errorIsRedacted: Bool

    init(
        id: UUID = UUID(),
        kind: WallpaperOperationKind,
        startTime: Date = Date(),
        endTime: Date? = nil,
        timezone: String = TimeZone.current.identifier,
        targetUUID: String? = nil,
        backupCreated: Bool = false,
        backupSHA256: String? = nil,
        backupVerified: Bool? = nil,
        installationSucceeded: Bool? = nil,
        installedSHA256: String? = nil,
        installationVerified: Bool? = nil,
        installationCompletedAt: Date? = nil,
        rollbackAttempted: Bool = false,
        rollbackSucceeded: Bool? = nil,
        rollbackSHA256: String? = nil,
        rollbackVerified: Bool? = nil,
        reloadStartedAt: Date? = nil,
        reloadEndedAt: Date? = nil,
        reloadExecutableAvailable: Bool? = nil,
        reloadExitCode: Int32? = nil,
        reloadSucceeded: Bool? = nil,
        reloadSkipped: Bool = false,
        reloadErrorMessage: String? = nil,
        errorMessage: String? = nil,
        errorIsRedacted: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.startTime = startTime
        self.endTime = endTime
        self.timezone = timezone
        self.targetUUID = targetUUID
        self.backupCreated = backupCreated
        self.backupSHA256 = backupSHA256
        self.backupVerified = backupVerified
        self.installationSucceeded = installationSucceeded
        self.installedSHA256 = installedSHA256
        self.installationVerified = installationVerified
        self.installationCompletedAt = installationCompletedAt
        self.rollbackAttempted = rollbackAttempted
        self.rollbackSucceeded = rollbackSucceeded
        self.rollbackSHA256 = rollbackSHA256
        self.rollbackVerified = rollbackVerified
        self.reloadStartedAt = reloadStartedAt
        self.reloadEndedAt = reloadEndedAt
        self.reloadExecutableAvailable = reloadExecutableAvailable
        self.reloadExitCode = reloadExitCode
        self.reloadSucceeded = reloadSucceeded
        self.reloadSkipped = reloadSkipped
        self.reloadErrorMessage = reloadErrorMessage
        self.errorMessage = errorMessage
        self.errorIsRedacted = errorIsRedacted
    }
}

struct WallpaperAgentReloadResult: Equatable, Sendable {
    let warning: String?
    let startedAt: Date
    let endedAt: Date
    let executableAvailable: Bool
    let exitCode: Int32?
    let succeeded: Bool?
    let skipped: Bool
    let errorMessage: String?
}

struct WallpaperOperationReloadGate: Equatable, Sendable {
    private(set) var attempts = 0

    mutating func beginAttempt() -> Bool {
        guard attempts == 0 else { return false }
        attempts = 1
        return true
    }
}

/// Shared verification and rollback boundary for all three replacement flows.
/// The closures keep the failure paths deterministic in tests without changing
/// the production AerialService implementation.
enum WallpaperOperationSafety {
    typealias HashFunction = (URL) throws -> String
    typealias ReplaceFunction = (URL, URL) throws -> Void

    static func install(
        record: inout WallpaperOperationRecord,
        source: URL,
        target: URL,
        backup: URL,
        originalTargetSHA256: String,
        hash: @escaping HashFunction = { try AerialService.sha256($0) },
        replace: @escaping ReplaceFunction = { source, target in
            try AerialService.replaceAtomically(source: source, target: target)
        }
    ) throws {
        guard record.backupCreated,
              record.backupVerified == true,
              record.backupSHA256 == originalTargetSHA256 else {
            record.installationSucceeded = false
            record.installationVerified = false
            throw AppError("备份校验未通过，已停止安装，原壁纸未被覆盖。")
        }

        let sourceSHA256: String
        do {
            sourceSHA256 = try hash(source)
        } catch {
            record.installationSucceeded = false
            record.installationVerified = false
            throw AppError("新壁纸源文件无法校验，已停止安装。")
        }

        do {
            try replace(source, target)
            let installedSHA256 = try hash(target)
            guard installedSHA256 == sourceSHA256 else {
                throw AppError("安装后的壁纸校验不一致。")
            }
            record.installationSucceeded = true
            record.installedSHA256 = installedSHA256
            record.installationVerified = true
            record.installationCompletedAt = Date()
            return
        } catch {
            record.installationSucceeded = false
            record.installationVerified = false
            record.rollbackAttempted = true
            do {
                try replace(backup, target)
                let rollbackSHA256 = try hash(target)
                record.rollbackSHA256 = rollbackSHA256
                let rollbackVerified = rollbackSHA256 == originalTargetSHA256
                record.rollbackVerified = rollbackVerified
                record.rollbackSucceeded = rollbackVerified
                guard rollbackVerified else {
                    throw AppError("回滚后的原壁纸校验不一致。")
                }
            } catch {
                record.rollbackSucceeded = false
                record.rollbackVerified = false
                throw AppError("壁纸安装失败，且回滚校验未通过，请立即检查备份。")
            }
            throw error
        }
    }
}

/// A small JSON-backed store for the most recent operation records.
/// The store is intentionally synchronous and used from AppModel's main actor.
final class WallpaperOperationTimeline {
    static let schemaVersion = 1
    static let defaultMaximumRecords = 40

    private struct Store: Codable {
        let schemaVersion: Int
        let records: [WallpaperOperationRecord]
    }

    let fileURL: URL
    let maximumRecords: Int
    private(set) var records: [WallpaperOperationRecord]
    private(set) var persistenceWarning: String?

    init(
        fileURL: URL = AppPaths.appSupport.appendingPathComponent("wallpaper-operation-timeline.json"),
        maximumRecords: Int = WallpaperOperationTimeline.defaultMaximumRecords
    ) {
        self.fileURL = fileURL
        self.maximumRecords = max(1, maximumRecords)
        let loaded = Self.load(from: fileURL)
        self.records = loaded.records
        self.persistenceWarning = loaded.warning
    }

    @discardableResult
    func begin(kind: WallpaperOperationKind, targetUUID: String?) -> WallpaperOperationRecord {
        let record = WallpaperOperationRecord(kind: kind, targetUUID: targetUUID)
        upsert(record)
        return record
    }

    func update(_ record: WallpaperOperationRecord) {
        upsert(record)
    }

    func append(_ record: WallpaperOperationRecord) {
        upsert(record)
    }

    private func upsert(_ record: WallpaperOperationRecord) {
        records.removeAll { $0.id == record.id }
        records.append(record)
        if records.count > maximumRecords {
            records.removeFirst(records.count - maximumRecords)
        }
        persist()
    }

    private func persist() {
        do {
            try AppPaths.ensureDirectory(fileURL.deletingLastPathComponent())
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(Store(schemaVersion: Self.schemaVersion, records: records))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            persistenceWarning = "操作时间线无法保存，后续诊断可能缺少本地记录。"
        }
    }

    private static func load(from url: URL) -> (records: [WallpaperOperationRecord], warning: String?) {
        guard FileManager.default.fileExists(atPath: url.path) else { return ([], nil) }
        guard let data = try? Data(contentsOf: url) else {
            return ([], "历史操作时间线文件无法读取，已标记为不可用。")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let timestamp = try? container.decode(Double.self) {
                return Date(timeIntervalSince1970: timestamp)
            }
            let text = try container.decode(String.self)
            guard let date = ISO8601DateFormatter().date(from: text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid timeline date")
            }
            return date
        }
        if let store = try? decoder.decode(Store.self, from: data),
           store.schemaVersion == schemaVersion {
            return (store.records, nil)
        }
        return ([], "历史操作时间线文件无法读取，已标记为不可用。")
    }

    static func redactedError(_ error: Error) -> String {
        let sanitized = LockBehaviorDiagnostics.sanitize(error.localizedDescription)
        return sanitized.isEmpty ? "未知错误" : sanitized
    }
}
