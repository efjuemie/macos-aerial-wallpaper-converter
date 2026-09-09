import AppKit
import Foundation

@MainActor
final class AppModel: ObservableObject {
    static let defaultUUID = "00BA71CD-2C54-415A-A68A-8358E677D750"

    @Published var inputPath = ""
    @Published var inputInfo: InputVideoInfo?
    @Published var uuidText = AppModel.defaultUUID
    @Published var selectedUUID = AppModel.defaultUUID
    @Published var targets: [AerialTarget] = []
    @Published var bitrateText = "12"
    @Published var targetDurationText = "300"
    @Published var environmentChecks: [EnvironmentCheck] = []
    @Published var oldAgentWarning: String?
    @Published var phase: ProcessingPhase = .idle
    @Published var progress = 0
    @Published var lastReport: OperationReport?
    @Published var backups: [BackupEntry] = []
    @Published var selectedBackup: BackupEntry?
    @Published var showProcessConfirmation = false
    @Published var showRestoreConfirmation = false
    @Published var alertMessage: String?
    @Published var isProcessing = false

    private let logger = AppLogger()

    init() {
        refresh()
        if let path = CommandLine.arguments.dropFirst().first, !path.isEmpty {
            loadVideo(at: URL(fileURLWithPath: path))
        }
    }

    var hasEnvironmentFailure: Bool {
        environmentChecks.contains { !$0.isOK }
    }

    var canStart: Bool {
        inputInfo != nil && AerialService.normalizeUUID(uuidText) != nil && !isProcessing
    }

    var selectedTargetExists: Bool {
        guard let uuid = AerialService.normalizeUUID(uuidText) else { return false }
        return FileManager.default.fileExists(atPath: AppPaths.aerialDirectory.appendingPathComponent("\(uuid).mov").path)
    }

    func refresh() {
        Task {
            targets = AerialService.targets()
            backups = AerialService.backups(for: AerialService.normalizeUUID(uuidText) ?? Self.defaultUUID)
            environmentChecks = await EnvironmentChecker.check()
            let status = await EnvironmentChecker.oldLaunchAgentStatus()
            oldAgentWarning = status.isRunning ? status.detail : nil
        }
    }

    func chooseVideo() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.movie, .mpeg4Movie]
        panel.prompt = "选择"
        if panel.runModal() == .OK, let url = panel.url {
            loadVideo(at: url)
        }
    }

    func loadVideoFromPathField() {
        let path = inputPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }
        loadVideo(at: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
    }

    func loadVideo(at url: URL) {
        guard !isProcessing else { return }
        inputPath = url.path
        inputInfo = nil
        alertMessage = nil

        Task {
            do {
                let info = try await Task.detached(priority: .userInitiated) {
                    try await VideoInspector.inspect(url)
                }.value
                inputInfo = info
                if let detectedUUID = AerialService.uuidFromFilename(url) {
                    uuidText = detectedUUID
                    selectedUUID = detectedUUID
                    backups = AerialService.backups(for: detectedUUID)
                }
                logger.write("Loaded input=\(url.path) duration=\(info.duration) size=\(info.width)x\(info.height)")
            } catch {
                alertMessage = error.localizedDescription
            }
        }
    }

    func selectTarget(_ uuid: String) {
        guard !uuid.isEmpty else { return }
        uuidText = uuid
        selectedUUID = uuid
        backups = AerialService.backups(for: uuid)
    }

    func uuidFieldChanged() {
        if let uuid = AerialService.normalizeUUID(uuidText) {
            selectedUUID = uuid
            backups = AerialService.backups(for: uuid)
        }
    }

    func startProcessing() {
        guard let inputInfo,
              let uuid = AerialService.normalizeUUID(uuidText) else {
            alertMessage = "请先选择视频，并输入有效的 Aerial UUID。"
            return
        }
        guard let bitrate = Int(bitrateText), (1...100).contains(bitrate) else {
            alertMessage = "输出码率必须是 1–100 Mbps 之间的整数。"
            return
        }
        guard let targetDuration = Double(targetDurationText), targetDuration >= 1 else {
            alertMessage = "目标时长必须是大于 0 的数字。"
            return
        }
        guard targetDuration <= 3600 else {
            alertMessage = "目标时长不能超过 3600 秒。"
            return
        }
        let loopCount = max(1, Int(ceil(targetDuration / inputInfo.duration)))
        showProcessConfirmation = false
        runConversion(input: inputInfo, uuid: uuid, loopCount: loopCount, bitrate: bitrate)
    }

    func openWallpaperSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    func openArchiveFolder() {
        try? AppPaths.ensureDirectory(AppPaths.desktopArchiveDirectory)
        NSWorkspace.shared.open(AppPaths.desktopArchiveDirectory)
    }

    func openLog() {
        NSWorkspace.shared.open(AppPaths.logURL)
    }

    func disableOldAgent() {
        guard !isProcessing else { return }
        Task {
            var messages: [String] = []
            let uid = String(getuid())
            if let launchctl = CommandRunner.executable(named: "launchctl") {
                let result = try? await CommandRunner.run(
                    launchctl,
                    arguments: ["bootout", "gui/\(uid)", AppPaths.oldLaunchAgent.path]
                )
                if result?.status != 0, let output = result?.output, !output.isEmpty {
                    messages.append(output.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
            if FileManager.default.fileExists(atPath: AppPaths.oldLaunchAgent.path) {
                do {
                    if FileManager.default.fileExists(atPath: AppPaths.oldLaunchAgentDisabled.path) {
                        try FileManager.default.removeItem(at: AppPaths.oldLaunchAgentDisabled)
                    }
                    try FileManager.default.moveItem(at: AppPaths.oldLaunchAgent, to: AppPaths.oldLaunchAgentDisabled)
                } catch {
                    messages.append("无法将旧 LaunchAgent 改名为 .disabled：\(error.localizedDescription)")
                }
            }
            if let pgrep = CommandRunner.executable(named: "pgrep"),
               let running = try? await CommandRunner.run(pgrep, arguments: ["-fl", "wallpaper-aerial-fix"]),
               running.status == 0,
               let pkill = CommandRunner.executable(named: "pkill") {
                _ = try? await CommandRunner.run(pkill, arguments: ["-f", "wallpaper-aerial-fix"])
            }
            oldAgentWarning = messages.isEmpty ? nil : messages.joined(separator: "\n")
            logger.write("Disabled old LaunchAgent; result=\(messages.joined(separator: " | "))")
        }
    }

    func restoreSelectedBackup() {
        guard let backup = selectedBackup,
              let uuid = AerialService.normalizeUUID(uuidText) else {
            alertMessage = "请选择一个备份文件。"
            return
        }
        showRestoreConfirmation = false
        isProcessing = true
        phase = .running(number: 1, title: "恢复备份", detail: "正在备份当前壁纸并恢复所选版本…")
        Task {
            do {
                let target = try AerialService.targetURL(uuid: uuid)
                guard FileManager.default.fileExists(atPath: target.path) else {
                    throw AppError("目标 Aerial 文件不存在，无法恢复。")
                }
                let currentBackup = try AerialService.createBackup(of: target, uuid: uuid, suffix: "before-restore")
                try AerialService.replaceAtomically(source: backup.url, target: target)
                guard try AerialService.sha256(backup.url) == AerialService.sha256(target) else {
                    try? AerialService.replaceAtomically(source: currentBackup, target: target)
                    throw AppError("恢复后的文件校验失败，已尝试恢复恢复前的文件。")
                }
                let warning = await reloadWallpaperAgent()
                backups = AerialService.backups(for: uuid)
                selectedBackup = nil
                lastReport = OperationReport(
                    uuid: uuid,
                    archiveURL: currentBackup,
                    backupURL: currentBackup,
                    outputURL: backup.url,
                    reloadWarning: warning,
                    isRestore: true
                )
                phase = .success
                logger.write("Restored backup=\(backup.url.path) target=\(target.path)")
            } catch {
                phase = .failed(error.localizedDescription)
                alertMessage = error.localizedDescription
            }
            isProcessing = false
        }
    }

    private func runConversion(input: InputVideoInfo, uuid: String, loopCount: Int, bitrate: Int) {
        isProcessing = true
        progress = 0
        phase = .running(number: 1, title: "检查开发环境", detail: "正在检查 Swift、Git、Python 3 和 Aerial 目录…")
        lastReport = nil

        Task {
            do {
                environmentChecks = await EnvironmentChecker.check()
                guard !environmentChecks.contains(where: { !$0.isOK }) else {
                    throw AppError(environmentChecks.filter { !$0.isOK }.map { "\($0.name)：\($0.detail)" }.joined(separator: "\n"))
                }
                progress = 1

                try checkFreeSpace()
                phase = .running(number: 2, title: "准备编码器", detail: "首次使用会下载并编译 VideoToolbox 编码器；以后会复用本地版本。")
                let encoder = try await EncoderService.prepare()
                progress = 2

                phase = .running(number: 3, title: "读取视频信息", detail: "\(input.durationText)，\(input.width) × \(input.height)，循环 \(loopCount) 次。")
                logger.write("Start input=\(input.url.path) uuid=\(uuid) duration=\(input.duration) loopCount=\(loopCount) bitrate=\(bitrate)")
                progress = 3

                phase = .running(number: 4, title: "编码 Aerial 兼容视频", detail: "正在生成 HEVC Main 10 输出，预计需要一些时间…")
                let output = try processedOutputURL(uuid: uuid)
                try await EncoderService.encode(
                    input: input.url,
                    output: output,
                    loopCount: loopCount,
                    bitrateMbps: bitrate,
                    executable: encoder
                )
                progress = 4

                phase = .running(number: 5, title: "验证 temporal sample groups", detail: "必须同时包含 tscl 和 tsas 的四项标记。")
                let validation = try await EncoderService.validate(output: output, repository: AppPaths.encoderRepository)
                logger.write("Validation output=\(validation.replacingOccurrences(of: "\n", with: " | "))")
                progress = 5

                let target = try AerialService.targetURL(uuid: uuid)
                guard FileManager.default.isReadableFile(atPath: target.path) else {
                    throw AppError("目标 Aerial 不存在：\(target.path)\n请先在系统设置→壁纸中下载并应用对应航拍壁纸。")
                }

                phase = .running(number: 6, title: "备份原 Aerial", detail: "正在备份到应用备份目录和桌面“壁纸”文件夹…")
                let backup = try AerialService.createBackup(of: target, uuid: uuid)
                let archive = try AerialService.archiveOriginalOnDesktop(of: target)
                progress = 6

                phase = .running(number: 7, title: "安装新视频", detail: "正在校验并安全替换目标文件…")
                let sourceHash = try AerialService.sha256(output)
                do {
                    try AerialService.replaceAtomically(source: output, target: target)
                    guard sourceHash == (try AerialService.sha256(target)) else {
                        throw AppError("安装后的文件 SHA-256 校验不一致。")
                    }
                } catch {
                    try? AerialService.replaceAtomically(source: backup, target: target)
                    throw error
                }
                progress = 7

                phase = .running(number: 8, title: "重载 WallpaperAgent", detail: "仅重载一次系统壁纸服务…")
                let reloadWarning = await reloadWallpaperAgent()
                progress = 8
                lastReport = OperationReport(
                    uuid: uuid,
                    archiveURL: archive,
                    backupURL: backup,
                    outputURL: output,
                    reloadWarning: reloadWarning,
                    isRestore: false
                )
                phase = .success
                backups = AerialService.backups(for: uuid)
                targets = AerialService.targets()
                logger.write("Success uuid=\(uuid) archive=\(archive.path) backup=\(backup.path) output=\(output.path) reloadWarning=\(reloadWarning ?? "none")")
            } catch {
                phase = .failed(error.localizedDescription)
                alertMessage = error.localizedDescription
                logger.write("Failure: \(error.localizedDescription)")
            }
            isProcessing = false
        }
    }

    private func checkFreeSpace() throws {
        let values = try FileManager.default.attributesOfFileSystem(forPath: AppPaths.appSupport.deletingLastPathComponent().path)
        let freeBytes = (values[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        guard freeBytes >= 1_500_000_000 else {
            throw AppError("可用磁盘空间不足 1.5 GB，已停止处理。")
        }
    }

    private func processedOutputURL(uuid: String) throws -> URL {
        try AppPaths.ensureDirectory(AppPaths.processedDirectory)
        let timestamp = DateFormatter.fileTimestamp.string(from: Date())
        return AppPaths.processedDirectory.appendingPathComponent("\(uuid)-fixed-\(timestamp).mov")
    }

    private func reloadWallpaperAgent() async -> String? {
        guard let pkill = CommandRunner.executable(named: "pkill") else {
            return "未找到 pkill，请在系统设置中重新选择壁纸。"
        }
        do {
            let result = try await CommandRunner.run(pkill, arguments: ["-x", "WallpaperAgent"])
            if result.status == 0 { return nil }
            if result.status == 1 { return "WallpaperAgent 当前未运行；请在系统设置中重新选择壁纸。" }
            return "WallpaperAgent 重载命令返回状态 \(result.status)，请手动重新选择壁纸。"
        } catch {
            return "WallpaperAgent 重载失败：\(error.localizedDescription)"
        }
    }
}
