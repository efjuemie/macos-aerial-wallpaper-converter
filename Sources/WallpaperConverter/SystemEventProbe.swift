import AppKit
import Darwin
import Foundation

/// The diagnostic collector deliberately has a smaller command surface than
/// the conversion code.  Every invocation is fixed in this file so a report
/// can never turn a user supplied string into a shell command.
enum LockDiagnosticAvailability: String, Codable, Sendable {
    case available
    case unavailable
    case failed
    case timedOut
    case cancelled
    case truncated
}

enum LockDiagnosticSource: String, Codable, Sendable {
    case system
    case userReported
    case unavailable
}

struct LockDiagnosticValue<Value: Codable & Sendable>: Codable, Sendable {
    let value: Value?
    let source: LockDiagnosticSource
    let availability: LockDiagnosticAvailability
    let detail: String?

    static func available(_ value: Value, detail: String? = nil) -> Self {
        Self(value: value, source: .system, availability: .available, detail: detail)
    }

    static func userReported(_ value: Value) -> Self {
        Self(value: value, source: .userReported, availability: .available, detail: nil)
    }

    static func unavailable(_ detail: String? = nil) -> Self {
        Self(value: nil, source: .unavailable, availability: .unavailable, detail: detail)
    }

}

struct BoundedCommandResult: Codable, Equatable, Sendable {
    let command: String
    let arguments: [String]
    let status: Int32?
    let output: String
    let outputBytes: Int
    let truncated: Bool
    let timedOut: Bool
    let cancelled: Bool
    let unavailableReason: String?
    let processIdentifier: Int32?
    let terminated: Bool

    var succeeded: Bool {
        status == 0 && !timedOut && !cancelled && !truncated && unavailableReason == nil
    }
}

/// A small POSIX process wrapper used only by diagnostics.  It drains the pipe
/// while the process is running, retains at most `outputLimit` bytes, and
/// terminates the child on timeout or task cancellation.
enum BoundedDiagnosticCommand {
    static let defaultTimeout: TimeInterval = 3
    static let defaultOutputLimit = 96 * 1024

    static func run(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval = defaultTimeout,
        outputLimit: Int = defaultOutputLimit
    ) async -> BoundedCommandResult {
        let cancellation = CancellationBox()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                let worker = BoundedProcessWorker(
                    executable: executable,
                    arguments: arguments,
                    timeout: timeout,
                    outputLimit: max(1, outputLimit)
                ) { result in
                    continuation.resume(returning: result)
                }
                cancellation.install {
                    worker.cancel()
                }
                worker.start()
            }
        }, onCancel: {
            cancellation.cancel()
        })
    }
}

private final class CancellationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellation: (() -> Void)?
    private var wasCancelled = false

    func install(_ cancellation: @escaping () -> Void) {
        lock.lock()
        if wasCancelled {
            lock.unlock()
            cancellation()
            return
        }
        self.cancellation = cancellation
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        wasCancelled = true
        let action = cancellation
        lock.unlock()
        action?()
    }
}

private final class BoundedProcessWorker: @unchecked Sendable {
    private let executable: URL
    private let arguments: [String]
    private let timeout: TimeInterval
    private let outputLimit: Int
    private let completion: (BoundedCommandResult) -> Void
    private let stateLock = NSLock()
    private let queue = DispatchQueue(label: "WallpaperConverter.diagnostic-process")
    private var output = Data()
    private var didTruncate = false
    private var timedOut = false
    private var cancelled = false
    private var cancellationRequested = false
    private var completed = false
    private var processIdentifier: pid_t = 0
    private var processRunning = false
    private var childWaitCompleted = false
    private var childExitStatus: Int32?
    private var terminationRequested = false
    private var forceKillSent = false
    private var readDescriptor: Int32 = -1
    private var readSource: DispatchSourceRead?

    init(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval,
        outputLimit: Int,
        completion: @escaping (BoundedCommandResult) -> Void
    ) {
        self.executable = executable
        self.arguments = arguments
        self.timeout = max(0.05, timeout)
        self.outputLimit = outputLimit
        self.completion = completion
    }

    func start() {
        queue.async { [self] in
            guard !isCancellationRequested() else {
                cancelled = true
                finish(status: nil, unavailableReason: "任务在启动前已取消", terminated: false)
                return
            }
            launch()
        }
    }

    func cancel() {
        stateLock.lock()
        cancellationRequested = true
        stateLock.unlock()
        queue.async { [self] in
            guard !completed else { return }
            cancelled = true
            if processIdentifier > 0 {
                requestTermination()
            } else {
                finish(status: nil, unavailableReason: "任务已取消", terminated: false)
            }
        }
    }

    private func isCancellationRequested() -> Bool {
        stateLock.lock()
        let requested = cancellationRequested
        stateLock.unlock()
        return requested
    }

    private func launch() {
        var pipeDescriptors = [Int32](repeating: 0, count: 2)
        guard Darwin.pipe(&pipeDescriptors) == 0 else {
            finish(status: nil, unavailableReason: "无法创建诊断输出管道", terminated: false)
            return
        }
        readDescriptor = pipeDescriptors[0]
        let writeDescriptor = pipeDescriptors[1]
        let flags = fcntl(readDescriptor, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(readDescriptor, F_SETFL, flags | O_NONBLOCK)
        }

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            close(readDescriptor)
            close(writeDescriptor)
            readDescriptor = -1
            finish(status: nil, unavailableReason: "无法初始化诊断子进程", terminated: false)
            return
        }
        guard posix_spawnattr_init(&attributes) == 0 else {
            posix_spawn_file_actions_destroy(&actions)
            close(readDescriptor)
            close(writeDescriptor)
            readDescriptor = -1
            finish(status: nil, unavailableReason: "无法初始化诊断子进程", terminated: false)
            return
        }
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }

        guard posix_spawn_file_actions_adddup2(&actions, writeDescriptor, STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, writeDescriptor, STDERR_FILENO) == 0,
              posix_spawn_file_actions_addclose(&actions, readDescriptor) == 0,
              posix_spawn_file_actions_addclose(&actions, writeDescriptor) == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0 else {
            close(readDescriptor)
            close(writeDescriptor)
            readDescriptor = -1
            finish(status: nil, unavailableReason: "无法初始化诊断子进程", terminated: false)
            return
        }

        var argv = [UnsafeMutablePointer<CChar>?]()
        argv.append(strdup(executable.path))
        argv.append(contentsOf: arguments.map { strdup($0) })
        argv.append(nil)
        defer {
            for pointer in argv {
                if let pointer { free(pointer) }
            }
        }

        var childPID: pid_t = 0
        let spawnResult = argv.withUnsafeMutableBufferPointer { buffer in
            executable.path.withCString { path in
                posix_spawn(
                    &childPID,
                    path,
                    &actions,
                    &attributes,
                    buffer.baseAddress,
                    environ
                )
            }
        }
        close(writeDescriptor)
        guard spawnResult == 0 else {
            close(readDescriptor)
            readDescriptor = -1
            finish(
                status: nil,
                unavailableReason: "无法启动命令：\(String(cString: strerror(spawnResult)))",
                terminated: false
            )
            return
        }
        processIdentifier = childPID
        processRunning = true
        installReadSource()
        waitForChild(childPID)
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.timeoutIfNeeded()
        }
    }

    private func installReadSource() {
        let source = DispatchSource.makeReadSource(fileDescriptor: readDescriptor, queue: queue)
        source.setEventHandler { [weak self] in
            self?.drainAvailableOutput(maxChunks: 64)
        }
        source.setCancelHandler { [descriptor = readDescriptor] in
            close(descriptor)
        }
        readSource = source
        source.resume()
    }

    private func waitForChild(_ pid: pid_t) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var status: Int32 = 0
            var result: pid_t = -1
            repeat {
                result = waitpid(pid, &status, 0)
            } while result < 0 && errno == EINTR
            guard let self else { return }
            self.queue.async {
                self.processRunning = false
                self.childWaitCompleted = result == pid
                self.childExitStatus = result == pid ? Self.decodeWaitStatus(status) : nil
                if self.terminationRequested {
                    self.finishAfterTerminationIfReady()
                } else {
                    self.finish(status: self.childExitStatus, unavailableReason: nil, terminated: result == pid)
                }
            }
        }
    }

    private func timeoutIfNeeded() {
        guard !completed, processRunning else { return }
        timedOut = true
        requestTermination()
    }

    private func requestTermination() {
        guard processIdentifier > 0 else { return }
        guard !terminationRequested else { return }
        terminationRequested = true
        // POSIX_SPAWN_SETPGROUP creates a private group whose ID equals the
        // owned child PID.  Signals are never sent to the app's process group.
        _ = kill(-processIdentifier, SIGTERM)
        queue.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, !self.completed else { return }
            self.forceKillSent = true
            _ = kill(-self.processIdentifier, SIGKILL)
            self.finishAfterTerminationIfReady()
        }
    }

    private func finishAfterTerminationIfReady() {
        guard terminationRequested, forceKillSent, childWaitCompleted else { return }
        finish(status: childExitStatus, unavailableReason: nil, terminated: true)
    }

    private func drainAvailableOutput(maxChunks: Int) {
        guard readDescriptor >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        var chunks = 0
        while chunks < maxChunks {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(readDescriptor, bytes.baseAddress, bytes.count)
            }
            if count > 0 {
                chunks += 1
                consume(Data(buffer[0..<count]))
                continue
            }
            if count < 0, errno == EINTR {
                continue
            }
            return
        }
    }

    private func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !completed else { return }
        let remaining = outputLimit - output.count
        if remaining > 0 {
            output.append(data.prefix(remaining))
        }
        if data.count > max(remaining, 0) {
            didTruncate = true
        }
    }

    private func finish(status: Int32?, unavailableReason: String?, terminated: Bool) {
        guard !completed else { return }
        // The child has already been reaped here.  The pipe is non-blocking,
        // so this final drain captures bytes queued after the last read event
        // without waiting for an orphaned descendant to close the pipe.
        drainAvailableOutput(maxChunks: 1024)
        completed = true
        let source = readSource
        readSource = nil
        readDescriptor = -1
        source?.cancel()

        let outputText = String(decoding: output, as: UTF8.self)
        let outputByteCount = output.count
        let wasTruncated = didTruncate
        let wasTimedOut = timedOut
        let wasCancelled = cancelled
        let pid = processIdentifier > 0 ? processIdentifier : nil

        let availability: LockDiagnosticAvailability
        if wasCancelled {
            availability = .cancelled
        } else if wasTimedOut {
            availability = .timedOut
        } else if wasTruncated {
            availability = .truncated
        } else {
            availability = unavailableReason == nil && status == 0 ? .available : .failed
        }

        let detail: String?
        if let unavailableReason {
            detail = unavailableReason
        } else if availability == .timedOut {
            detail = "命令超过 \(timeout)s 限制，已终止"
        } else if availability == .cancelled {
            detail = "命令已取消并终止"
        } else if let status, status != 0 {
            detail = "命令退出码为 \(status)"
        } else {
            detail = nil
        }

        completion(
            BoundedCommandResult(
                command: executable.lastPathComponent,
                arguments: arguments,
                status: status,
                output: outputText,
                outputBytes: outputByteCount,
                truncated: wasTruncated,
                timedOut: wasTimedOut,
                cancelled: wasCancelled,
                unavailableReason: detail,
                processIdentifier: pid,
                terminated: terminated
            )
        )
    }

    private static func decodeWaitStatus(_ status: Int32) -> Int32? {
        let signal = status & 0x7f
        if signal == 0 {
            return (status >> 8) & 0xff
        }
        if signal != 0x7f {
            return -signal
        }
        return nil
    }
}

struct SystemEventProbeSnapshot: Codable, Sendable {
    let capturedAt: Date
    let macOSVersion: String?
    let machineModel: String?
    let deviceClass: String?
    let architecture: String?
    let powerSource: String?
    let displayCount: Int?
    let externalDisplayCount: Int?
    let displayIdleOnBattery: Int?
    let displayIdleOnAC: Int?
    let commands: [BoundedCommandResult]
    let logWindow: String
    let logTimeZone: String
    let oldLaunchAgentConfigured: Bool?
    let oldLaunchAgentLoaded: Bool?
    let warnings: [String]
}

enum SystemEventProbe {
    private static let logPredicate =
        "(process == \"powerd\" OR process == \"loginwindow\" OR process == \"WallpaperAgent\" OR process == \"screensaver\" OR process == \"ScreenSaverEngine\")"
    private static let oldLaunchAgentLabel = "com.local.wallpaper-aerial-fix"

    static func capture(incidentTime: Date? = nil) async -> SystemEventProbeSnapshot {
        let capturedAt = Date()
        var warnings: [String] = []
        var results: [BoundedCommandResult] = []

        let pmsetCustom = Task.isCancelled
            ? cancelledResult(command: "pmset", arguments: ["-g", "custom"])
            : await runAllowed(named: "pmset", arguments: ["-g", "custom"])
        results.append(pmsetCustom)

        let pmsetBattery = Task.isCancelled
            ? cancelledResult(command: "pmset", arguments: ["-g", "batt"])
            : await runAllowed(named: "pmset", arguments: ["-g", "batt"])
        results.append(pmsetBattery)

        let logArguments = logArguments(around: incidentTime)
        let systemLog = Task.isCancelled
            ? cancelledResult(command: "log", arguments: logArguments)
            : await runAllowed(named: "log", arguments: logArguments)
        results.append(systemLog)

        let custom = pmsetCustom.succeeded ? pmsetCustom.output : nil
        let batt = pmsetBattery.succeeded ? pmsetBattery.output : nil
        if custom == nil {
            warnings.append("无法读取 pmset -g custom，显示器闲置计时器标为 unavailable。")
        }
        if batt == nil {
            warnings.append("无法读取 pmset -g batt，电源状态标为 unavailable。")
        }
        if !systemLog.succeeded {
            warnings.append("系统日志不可用或被截断；日志证据不足以判断锁屏原因。")
        } else if systemLog.truncated {
            warnings.append("系统日志达到输出上限，报告仅保留截断前内容。")
        }

        let oldAgent = Task.isCancelled
            ? (configured: Optional<Bool>.none, loaded: Optional<Bool>.none, warnings: ["诊断任务已取消，旧 LaunchAgent 状态未读取。"])
            : await oldLaunchAgentStatus()
        warnings.append(contentsOf: oldAgent.warnings)

        let versionText = ProcessInfo.processInfo.operatingSystemVersionString
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unknown"
        #endif

        let screens = NSScreen.screens
        var builtInCount = 0
        var displayClassificationAvailable = true
        for screen in screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                displayClassificationAvailable = false
                continue
            }
            if CGDisplayIsBuiltin(CGDirectDisplayID(number.uint32Value)) != 0 {
                builtInCount += 1
            }
        }
        return SystemEventProbeSnapshot(
            capturedAt: capturedAt,
            macOSVersion: versionText,
            machineModel: machineModel(),
            deviceClass: nil,
            architecture: architecture,
            powerSource: parsePowerSource(batt),
            displayCount: screens.count,
            externalDisplayCount: displayClassificationAvailable ? max(0, screens.count - builtInCount) : nil,
            displayIdleOnBattery: parseDisplaySleep(custom, section: "Battery Power"),
            displayIdleOnAC: parseDisplaySleep(custom, section: "AC Power"),
            commands: results,
            logWindow: logWindowDescription(around: incidentTime),
            logTimeZone: TimeZone.current.identifier,
            oldLaunchAgentConfigured: oldAgent.configured,
            oldLaunchAgentLoaded: oldAgent.loaded,
            warnings: warnings
        )
    }

    static func logArguments(around incidentTime: Date?) -> [String] {
        if let incidentTime {
            let start = logDateFormatter.string(from: incidentTime.addingTimeInterval(-5 * 60))
            let end = logDateFormatter.string(from: incidentTime.addingTimeInterval(5 * 60))
            return [
                "show", "--style", "compact", "--start", start, "--end", end,
                "--predicate", logPredicate
            ]
        }
        return [
            "show", "--style", "compact", "--last", "10m",
            "--predicate", logPredicate
        ]
    }

    private static func logWindowDescription(around incidentTime: Date?) -> String {
        if incidentTime != nil {
            return "事件时间前后各 5 分钟"
        }
        return "最近 10 分钟"
    }

    private static let logDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private static func runAllowed(named name: String, arguments: [String]) async -> BoundedCommandResult {
        guard let executable = commandURL(named: name), allowedInvocation(name: name, arguments: arguments) else {
            return BoundedCommandResult(
                command: name,
                arguments: arguments,
                status: nil,
                output: "",
                outputBytes: 0,
                truncated: false,
                timedOut: false,
                cancelled: false,
                unavailableReason: "未找到命令或调用不在诊断允许范围内",
                processIdentifier: nil,
                terminated: false
            )
        }
        return await BoundedDiagnosticCommand.run(
            executable: executable,
            arguments: arguments,
            timeout: name == "log" ? 5 : 3,
            outputLimit: BoundedDiagnosticCommand.defaultOutputLimit
        )
    }

    private static func commandURL(named name: String) -> URL? {
        let systemPath = name == "launchctl" ? "/bin/launchctl" : "/usr/bin/\(name)"
        let candidate = URL(fileURLWithPath: systemPath)
        return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
    }

    private static func cancelledResult(command: String, arguments: [String]) -> BoundedCommandResult {
        BoundedCommandResult(
            command: command,
            arguments: arguments,
            status: nil,
            output: "",
            outputBytes: 0,
            truncated: false,
            timedOut: false,
            cancelled: true,
            unavailableReason: "诊断任务已取消",
            processIdentifier: nil,
            terminated: false
        )
    }

    private static func machineModel() -> String? {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return nil }
        return String(bytes: bytes.prefix { $0 != 0 }, encoding: .utf8)
    }

    static func allowedInvocation(name: String, arguments: [String]) -> Bool {
        switch name {
        case "pmset":
            return arguments == ["-g", "custom"] || arguments == ["-g", "batt"]
        case "log":
            if arguments.count == 7,
               arguments.prefix(3).elementsEqual(["show", "--style", "compact"]),
               arguments[3] == "--last",
               arguments[4] == "10m",
               arguments[5] == "--predicate",
               arguments[6] == logPredicate {
                return true
            }
            return arguments.count == 9
                && arguments.prefix(3).elementsEqual(["show", "--style", "compact"])
                && arguments[3] == "--start"
                && !arguments[4].isEmpty
                && arguments[5] == "--end"
                && !arguments[6].isEmpty
                && arguments[7] == "--predicate"
                && arguments[8] == logPredicate
        default:
            return false
        }
    }

    private static func parsePowerSource(_ output: String?) -> String? {
        guard let output else { return nil }
        let lower = output.lowercased()
        if lower.contains("ac power") || lower.contains("adapter") {
            return "AC Power"
        }
        if lower.contains("battery") {
            return "Battery Power"
        }
        return nil
    }

    private static func parseDisplaySleep(_ output: String?, section: String) -> Int? {
        guard let output else { return nil }
        var inSection = false
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            if line.localizedCaseInsensitiveContains(section) {
                inSection = true
                continue
            }
            if inSection,
               line.contains(":"),
               line.localizedCaseInsensitiveContains("Power") {
                inSection = line.localizedCaseInsensitiveContains(section)
            }
            guard inSection,
                  line.trimmingCharacters(in: .whitespaces).hasPrefix("displaysleep") else {
                continue
            }
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if let value = tokens.dropFirst().first.flatMap({ Int($0) }) {
                return value
            }
        }
        return nil
    }

    private static func oldLaunchAgentStatus() async -> (
        configured: Bool?,
        loaded: Bool?,
        warnings: [String]
    ) {
        let configured: Bool?
        do {
            configured = !(try FileManager.default.attributesOfItem(atPath: AppPaths.oldLaunchAgent.path).isEmpty)
        } catch {
            configured = launchAgentConfiguration(for: error as NSError)
        }
        guard let launchctl = commandURL(named: "launchctl") else {
            return (configured, nil, ["无法找到 launchctl，旧 LaunchAgent 加载状态标为 unavailable。"])
        }
        let uid = String(getuid())
        let result = await BoundedDiagnosticCommand.run(
            executable: launchctl,
            arguments: ["print", "gui/\(uid)/\(oldLaunchAgentLabel)"],
            timeout: 2,
            outputLimit: 16 * 1024
        )
        if result.succeeded {
            return (configured, true, [])
        }
        if result.status == 113 || result.status == 112 {
            return (configured, false, [])
        }
        return (configured, nil, ["无法可靠读取旧 LaunchAgent 加载状态，已标为 unavailable。"])
    }

    /// Returns false only for errors that unambiguously mean the plist is
    /// absent. Permission and other read failures remain unavailable.
    static func launchAgentConfiguration(for error: NSError) -> Bool? {
        guard error.domain == NSCocoaErrorDomain else { return nil }
        switch error.code {
        case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
            return false
        default:
            return nil
        }
    }
}
