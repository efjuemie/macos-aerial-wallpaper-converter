import Foundation

enum LockSymptom: String, CaseIterable, Codable, Sendable {
    case actualSessionLock
    case screenSaverOnly
    case displayOffOrSleep
    case wallpaperTransition
    case manualOrPolicyLock
    case unknown

    var displayName: String {
        switch self {
        case .actualSessionLock: return "需要身份验证的会话锁定"
        case .screenSaverOnly: return "仅启动屏幕保护程序"
        case .displayOffOrSleep: return "显示器关闭或系统休眠"
        case .wallpaperTransition: return "壁纸切换、静止或黑屏"
        case .manualOrPolicyLock: return "手动或策略触发的锁定"
        case .unknown: return "暂时无法判断"
        }
    }
}

enum LockBehaviorConfidence: String, Codable, Sendable {
    case userReported
    case insufficient
}

struct LockSettingsSnapshot: Codable, Sendable {
    let screenSaverDelay: LockDiagnosticValue<String>
    let displayIdleOnBattery: LockDiagnosticValue<String>
    let displayIdleOnAC: LockDiagnosticValue<String>
    let passwordDelay: LockDiagnosticValue<String>
    let triggerCorners: LockDiagnosticValue<String>
    let lidClosed: LockDiagnosticValue<String>
}

struct LockWallpaperOperationSnapshot: Codable, Sendable {
    let targetUUID: LockDiagnosticValue<String>
    let replacementAt: LockDiagnosticValue<Date>
    let reloadAttempted: LockDiagnosticValue<Bool>
    let reloadExitCode: LockDiagnosticValue<Int32>
    let operations: [WallpaperOperationRecord]
}

struct LockLaunchAgentSnapshot: Codable, Sendable {
    let configured: LockDiagnosticValue<Bool>
    let loaded: LockDiagnosticValue<Bool>
}

struct LockBehaviorEvidence: Codable, Sendable {
    let source: String
    let status: LockDiagnosticAvailability
    let command: String
    let arguments: [String]
    let exitCode: Int32?
    let window: String?
    let text: String
    let truncated: Bool
    let possibleRelevance: String
}

struct LockBehaviorReport: Codable, Sendable {
    let schemaVersion: Int
    let diagnosticType: String
    let appVersion: String
    let capturedAt: Date
    let incidentTime: Date?
    let incidentTimeSource: LockDiagnosticSource
    let reportedSymptom: LockSymptom
    let macOSVersion: LockDiagnosticValue<String>
    let machineModel: LockDiagnosticValue<String>
    let deviceClass: LockDiagnosticValue<String>
    let architecture: LockDiagnosticValue<String>
    let powerSource: LockDiagnosticValue<String>
    let displayCount: LockDiagnosticValue<Int>
    let externalDisplayCount: LockDiagnosticValue<Int>
    let settings: LockSettingsSnapshot
    let wallpaperOperation: LockWallpaperOperationSnapshot
    let oldLaunchAgent: LockLaunchAgentSnapshot
    let evidence: [LockBehaviorEvidence]
    let classification: LockSymptom
    let confidence: LockBehaviorConfidence
    var warnings: [String]
}

enum LockBehaviorDiagnostics {
    static let schemaVersion = 1
    static let diagnosticType = "unexpectedLock"

    static func capture(
        reportedSymptom: LockSymptom,
        incidentTime: Date?,
        userSettings: [String: String],
        operations: [WallpaperOperationRecord]
    ) async -> LockBehaviorReport {
        let probe = await SystemEventProbe.capture(incidentTime: incidentTime)
        return buildReport(
            reportedSymptom: reportedSymptom,
            incidentTime: incidentTime,
            userSettings: userSettings,
            operations: operations,
            probe: probe
        )
    }

    static func buildReport(
        reportedSymptom: LockSymptom,
        incidentTime: Date?,
        userSettings: [String: String],
        operations: [WallpaperOperationRecord],
        probe: SystemEventProbeSnapshot
    ) -> LockBehaviorReport {
        let sanitizedSettings = userSettings.mapValues { sanitize($0) }
        let settings = LockSettingsSnapshot(
            screenSaverDelay: userSetting("screenSaverDelay", from: sanitizedSettings),
            displayIdleOnBattery: settingValue(
                key: "displayIdleOnBattery",
                userSettings: sanitizedSettings,
                systemValue: probe.displayIdleOnBattery.map { "\($0) 分钟" }
            ),
            displayIdleOnAC: settingValue(
                key: "displayIdleOnAC",
                userSettings: sanitizedSettings,
                systemValue: probe.displayIdleOnAC.map { "\($0) 分钟" }
            ),
            passwordDelay: userSetting("passwordDelay", from: sanitizedSettings),
            triggerCorners: userSetting("triggerCorners", from: sanitizedSettings),
            lidClosed: userSetting("lidClosed", from: sanitizedSettings)
        )

        let operationSnapshot = makeOperationSnapshot(operations)
        var warnings = probe.warnings
        warnings.append("系统日志和 pmset 只提供可能相关的辅助证据，不能单独证明锁屏由本应用导致。")
        if incidentTime == nil {
            warnings.append("未提供事件时间，日志范围为最近 10 分钟；更早事件可能无法判断。")
        }
        if reportedSymptom == .unknown {
            warnings.append("用户未能确定事件类型，报告不会将其归类为会话锁定。")
        }
        if !operations.isEmpty {
            warnings.append("操作时间线来自应用本地记录，路径等私人字段已脱敏。")
        }

        let evidence = probe.commands.map {
            commandEvidence($0, window: "\(probe.logWindow)，时区 \(probe.logTimeZone)")
        }
        // The selected symptom is an observation supplied by the user.  A
        // successful pmset or log command is only auxiliary evidence and must
        // never upgrade that observation to a confirmed causal finding.
        let confidence: LockBehaviorConfidence = reportedSymptom == .unknown
            ? .insufficient
            : .userReported
        return LockBehaviorReport(
            schemaVersion: schemaVersion,
            diagnosticType: diagnosticType,
            appVersion: appVersion,
            capturedAt: probe.capturedAt,
            incidentTime: incidentTime,
            incidentTimeSource: incidentTime == nil ? .unavailable : .userReported,
            reportedSymptom: reportedSymptom,
            macOSVersion: probe.macOSVersion.map { LockDiagnosticValue.available($0) } ?? .unavailable("系统版本无法读取"),
            machineModel: probe.machineModel.map { LockDiagnosticValue.available($0) } ?? .unavailable("机型无法读取"),
            deviceClass: probe.deviceClass.map { LockDiagnosticValue.available($0) } ?? .unavailable("便携/台式类型没有稳定的公开读取接口"),
            architecture: probe.architecture.map { LockDiagnosticValue.available($0) } ?? .unavailable("架构无法读取"),
            powerSource: probe.powerSource.map { LockDiagnosticValue.available($0) } ?? .unavailable("电源状态无法读取"),
            displayCount: probe.displayCount.map { LockDiagnosticValue.available($0) } ?? .unavailable("显示器数量无法读取"),
            externalDisplayCount: probe.externalDisplayCount.map { LockDiagnosticValue.available($0) } ?? .unavailable("外接显示器状态无法读取"),
            settings: settings,
            wallpaperOperation: operationSnapshot,
            oldLaunchAgent: LockLaunchAgentSnapshot(
                configured: probe.oldLaunchAgentConfigured.map { LockDiagnosticValue.available($0) } ?? .unavailable("旧 LaunchAgent 配置无法读取"),
                loaded: probe.oldLaunchAgentLoaded.map { LockDiagnosticValue.available($0) } ?? .unavailable("旧 LaunchAgent 加载状态无法读取")
            ),
            evidence: evidence,
            classification: reportedSymptom,
            confidence: confidence,
            warnings: warnings
        )
    }

    static func export(_ report: LockBehaviorReport) throws -> URL {
        try AppPaths.ensureDirectory(GeometryDiagnostics.directory)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = formatter.string(from: report.capturedAt)
        let filename = "\(timestamp)-unexpected-lock-\(UUID().uuidString).json"
        let destination = GeometryDiagnostics.directory.appendingPathComponent(filename)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        try data.write(to: destination, options: .atomic)
        return destination
    }

    private static var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.8.5"
    }

    private static func userSetting(
        _ key: String,
        from values: [String: String]
    ) -> LockDiagnosticValue<String> {
        guard let value = values[key], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .unavailable("该设置没有稳定的公开读取接口")
        }
        return .userReported(value)
    }

    private static func settingValue(
        key: String,
        userSettings: [String: String],
        systemValue: String?
    ) -> LockDiagnosticValue<String> {
        if let userValue = userSettings[key], !userValue.isEmpty {
            return .userReported(userValue)
        }
        if let systemValue {
            return .available(systemValue, detail: "仅表示显示器闲置关闭计时器，不等同于锁屏或密码策略")
        }
        return .unavailable("无法读取")
    }

    private static func makeOperationSnapshot(
        _ operations: [WallpaperOperationRecord]
    ) -> LockWallpaperOperationSnapshot {
        let sanitizedOperations = operations.map(sanitizedOperation)
        let latest = sanitizedOperations.last
        let target = latest?.targetUUID.map { LockDiagnosticValue.available($0) }
            ?? .unavailable("没有可用的壁纸操作记录")
        let replacement: LockDiagnosticValue<Date>
        if let latest,
           latest.installationSucceeded == true,
           let installationCompletedAt = latest.installationCompletedAt {
            replacement = .available(installationCompletedAt)
        } else {
            replacement = .unavailable("没有可用的安装完成时间")
        }

        let reload: LockDiagnosticValue<Bool>
        if let latest {
            if latest.reloadSkipped {
                reload = .unavailable("重载步骤已跳过")
            } else if latest.reloadExecutableAvailable == false {
                reload = .unavailable("重载可执行文件不可用")
            } else if latest.reloadStartedAt != nil {
                reload = .available(true)
            } else {
                reload = .unavailable("重载是否尝试未知")
            }
        } else {
            reload = .unavailable("没有可用的重载记录")
        }
        let exitCode: LockDiagnosticValue<Int32>
        if reload.value == true, let reloadExitCode = latest?.reloadExitCode {
            exitCode = .available(reloadExitCode)
        } else {
            exitCode = .unavailable("没有可用的重载退出码")
        }
        return LockWallpaperOperationSnapshot(
            targetUUID: target,
            replacementAt: replacement,
            reloadAttempted: reload,
            reloadExitCode: exitCode,
            operations: sanitizedOperations
        )
    }

    private static func sanitizedOperation(_ record: WallpaperOperationRecord) -> WallpaperOperationRecord {
        WallpaperOperationRecord(
            id: record.id,
            kind: record.kind,
            startTime: record.startTime,
            endTime: record.endTime,
            timezone: record.timezone,
            targetUUID: record.targetUUID,
            backupCreated: record.backupCreated,
            backupSHA256: record.backupSHA256,
            backupVerified: record.backupVerified,
            installationSucceeded: record.installationSucceeded,
            installedSHA256: record.installedSHA256,
            installationVerified: record.installationVerified,
            installationCompletedAt: record.installationCompletedAt,
            rollbackAttempted: record.rollbackAttempted,
            rollbackSucceeded: record.rollbackSucceeded,
            rollbackSHA256: record.rollbackSHA256,
            rollbackVerified: record.rollbackVerified,
            reloadStartedAt: record.reloadStartedAt,
            reloadEndedAt: record.reloadEndedAt,
            reloadExecutableAvailable: record.reloadExecutableAvailable,
            reloadExitCode: record.reloadExitCode,
            reloadSucceeded: record.reloadSucceeded,
            reloadSkipped: record.reloadSkipped,
            reloadErrorMessage: record.reloadErrorMessage.map { sanitize($0) },
            errorMessage: record.errorMessage.map { sanitize($0) },
            errorIsRedacted: record.errorIsRedacted || record.errorMessage != nil || record.reloadErrorMessage != nil
        )
    }

    private static func commandEvidence(
        _ result: BoundedCommandResult,
        window: String
    ) -> LockBehaviorEvidence {
        let status: LockDiagnosticAvailability
        if result.cancelled {
            status = .cancelled
        } else if result.timedOut {
            status = .timedOut
        } else if result.truncated {
            status = .truncated
        } else if result.unavailableReason != nil || result.status == nil || result.status != 0 {
            status = .failed
        } else {
            status = .available
        }
        return LockBehaviorEvidence(
            source: result.command == "log" ? "systemLog" : "systemCommand",
            status: status,
            command: result.command,
            arguments: result.arguments,
            exitCode: result.status,
            window: result.command == "log" ? window : nil,
            text: sanitize(result.output),
            truncated: result.truncated,
            possibleRelevance: "可能与电源、会话、壁纸服务或屏保状态相关；不能据此确认因果。"
        )
    }

    /// Shared redaction for operation timeline and exported diagnostic text.
    /// It never changes the source log file; it only affects report data.
    static func sanitize(_ value: String) -> String {
        var result = value
        result = result.replacingOccurrences(of: AppPaths.home.path, with: "<home>")
        let username = NSUserName()
        if !username.isEmpty {
            result = result.replacingOccurrences(of: username, with: "<user>")
        }
        result = replacing(result, pattern: #"(?i)(?:/private)?/Users/[^/\s]+"#, with: "<user-home>")
        result = replacing(result, pattern: #"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#, with: "<email>")
        result = replacing(result, pattern: #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#, with: "<network-address>")
        result = replacing(result, pattern: #"(?i)\b(?:ssid|bssid|wifi|network(?:name)?)[=:]\s*[^\s,;]+"#, with: "<network-id>")
        return result
    }

    private static func replacing(_ value: String, pattern: String, with replacement: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return value }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.stringByReplacingMatches(in: value, options: [], range: range, withTemplate: replacement)
    }
}
