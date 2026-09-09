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
    @Published var archiveEntries: [WallpaperArchiveEntry] = []
    @Published var selectedArchive: WallpaperArchiveEntry?
    @Published var archiveRenameText = ""
    @Published var isGeneratingPreviews = false
    @Published var archiveToDelete: WallpaperArchiveEntry?
    @Published var showArchiveDeleteConfirmation = false
    @Published var showArchiveReplaceConfirmation = false
    @Published var showProcessConfirmation = false
    @Published var showRestoreConfirmation = false
    @Published var alertMessage: String?
    @Published var isProcessing = false
    @Published var isInspectingVideo = false
    @Published var archiveNameText = ""
    @Published var pendingCropSelection: WallpaperCropSelection?
    @Published var showCropSheet = false

    private let logger = AppLogger()
    private var previewTask: Task<Void, Never>?

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
        inputInfo != nil && AerialService.normalizeUUID(uuidText) != nil && !isProcessing && !isInspectingVideo
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
        refreshArchives()
    }

    func refreshArchives() {
        previewTask?.cancel()
        isGeneratingPreviews = true
        previewTask = Task { @MainActor [weak self] in
            await Task.detached(priority: .utility) {
                AerialService.migrateLegacyDesktopArchives()
                AerialService.migrateProcessedOutputs()
            }.value
            guard let self, !Task.isCancelled else { return }
            let entries = AerialService.archiveEntries()
            self.archiveEntries = entries
            if let selectedArchive = self.selectedArchive {
                self.selectedArchive = entries.first { $0.url == selectedArchive.url }
            }
            guard !entries.isEmpty else {
                self.isGeneratingPreviews = false
                return
            }
            for entry in entries {
                guard !Task.isCancelled else { return }
                guard !FileManager.default.fileExists(atPath: entry.previewURL.path) else { continue }
                try? await PreviewService.generateFirstFrame(from: entry.url, to: entry.previewURL)
            }
            guard !Task.isCancelled else { return }
            self.archiveEntries = AerialService.archiveEntries()
            if let selectedArchive = self.selectedArchive {
                self.selectedArchive = self.archiveEntries.first { $0.url == selectedArchive.url }
            }
            self.isGeneratingPreviews = false
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
        pendingCropSelection = nil
        showCropSheet = false
        alertMessage = nil
        isInspectingVideo = true

        Task { @MainActor in
            do {
                let info = try await VideoInspector.inspect(url)
                guard !Task.isCancelled else { return }
                inputInfo = info
                isInspectingVideo = false
                if let detectedUUID = AerialService.uuidFromFilename(url) {
                    uuidText = detectedUUID
                    selectedUUID = detectedUUID
                    backups = AerialService.backups(for: detectedUUID)
                }
                logger.write("Loaded input=\(url.path) duration=\(info.duration) size=\(info.width)x\(info.height)")
            } catch {
                isInspectingVideo = false
                alertMessage = error.localizedDescription
            }
        }
    }

    func openDynamicWallpaperFolder() {
        do {
            try AppPaths.ensureDirectory(AppPaths.aerialDirectory)
            NSWorkspace.shared.open(AppPaths.aerialDirectory)
        } catch {
            alertMessage = "无法打开动态壁纸文件夹：\(error.localizedDescription)"
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

    func requestProcessing() {
        guard let values = validatedProcessingValues() else { return }
        if let selection = cropSelection(for: values.input) {
            pendingCropSelection = selection
            showCropSheet = true
        } else {
            pendingCropSelection = nil
            showProcessConfirmation = true
        }
    }

    func continueWithCropSelection() {
        guard var selection = pendingCropSelection else {
            showCropSheet = false
            showProcessConfirmation = true
            return
        }
        selection.clamp()
        pendingCropSelection = selection
        showCropSheet = false
        showProcessConfirmation = true
    }

    func cancelCropSelection() {
        pendingCropSelection = nil
        showCropSheet = false
    }

    func updatePendingCrop(originX: Double, originY: Double) {
        guard var selection = pendingCropSelection else { return }
        selection.originX = originX
        selection.originY = originY
        selection.clamp()
        pendingCropSelection = selection
    }

    func startProcessing() {
        guard let values = validatedProcessingValues() else { return }
        let loopCount = max(1, Int(ceil(values.targetDuration / values.input.duration)))
        let layout = pendingCropSelection ?? wallpaperLayout(for: values.input)
        pendingCropSelection = nil
        showProcessConfirmation = false
        runConversion(
            input: values.input,
            uuid: values.uuid,
            loopCount: loopCount,
            bitrate: values.bitrate,
            archiveName: values.archiveName,
            cropSelection: layout
        )
    }

    private func validatedProcessingValues() -> (
        input: InputVideoInfo,
        uuid: String,
        bitrate: Int,
        targetDuration: Double,
        archiveName: String?
    )? {
        guard let inputInfo,
              let uuid = AerialService.normalizeUUID(uuidText) else {
            alertMessage = "请先选择视频，并输入有效的 Aerial UUID。"
            return nil
        }
        guard let bitrate = Int(bitrateText), (1...100).contains(bitrate) else {
            alertMessage = "输出码率必须是 1–100 Mbps 之间的整数。"
            return nil
        }
        guard let targetDuration = Double(targetDurationText), targetDuration >= 1 else {
            alertMessage = "目标时长必须是大于 0 的数字。"
            return nil
        }
        guard targetDuration <= 3600 else {
            alertMessage = "目标时长不能超过 3600 秒。"
            return nil
        }
        let archiveName = archiveNameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !archiveName.contains("/") && !archiveName.contains("\\") else {
            alertMessage = "自定义归档名称不能包含路径分隔符。"
            return nil
        }
        return (
            input: inputInfo,
            uuid: uuid,
            bitrate: bitrate,
            targetDuration: targetDuration,
            archiveName: archiveName.isEmpty ? nil : archiveName
        )
    }

    func openWallpaperSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    func openArchiveFolder() {
        do {
            try AppPaths.ensureDirectory(AppPaths.archiveDirectory)
            try AppPaths.ensureDirectory(AppPaths.previewDirectory)
            try AppPaths.ensureDirectory(AppPaths.encodedArchiveDirectory)
            NSWorkspace.shared.open(AppPaths.archiveDirectory)
        } catch {
            alertMessage = "无法打开壁纸归档文件夹：\(error.localizedDescription)"
        }
    }

    func selectArchive(_ entry: WallpaperArchiveEntry) {
        selectedArchive = entry
        archiveRenameText = entry.editableName
    }

    func renameSelectedArchive() {
        guard let selectedArchive else { return }
        do {
            try AerialService.renameArchive(selectedArchive, to: archiveRenameText)
            self.selectedArchive = nil
            archiveRenameText = ""
            refreshArchives()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func requestDeleteArchive(_ entry: WallpaperArchiveEntry) {
        archiveToDelete = entry
        showArchiveDeleteConfirmation = true
    }

    func deleteArchive() {
        guard let archiveToDelete else { return }
        showArchiveDeleteConfirmation = false
        do {
            try AerialService.deleteArchive(archiveToDelete)
            if selectedArchive?.url == archiveToDelete.url {
                selectedArchive = nil
                archiveRenameText = ""
            }
            self.archiveToDelete = nil
            refreshArchives()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func openArchiveVideo(_ entry: WallpaperArchiveEntry) {
        NSWorkspace.shared.open(entry.url)
    }

    func revealArchive(_ entry: WallpaperArchiveEntry) {
        NSWorkspace.shared.activateFileViewerSelecting([entry.url])
    }

    func requestArchiveReplacement() {
        guard selectedArchive?.uuid != nil else {
            alertMessage = "该历史归档缺少目标 UUID，无法自动替换。"
            return
        }
        showArchiveReplaceConfirmation = true
    }

    func quickReplaceSelectedArchive() {
        guard let archive = selectedArchive,
              let uuid = archive.uuid else {
            alertMessage = "请选择包含目标 UUID 的历史壁纸。"
            return
        }
        showArchiveReplaceConfirmation = false
        isProcessing = true
        phase = .running(number: 1, title: "替换历史动态壁纸", detail: "正在备份当前动态壁纸并安装历史版本…")
        lastReport = nil

        Task {
            do {
                let target = try AerialService.targetURL(uuid: uuid)
                guard FileManager.default.isReadableFile(atPath: target.path) else {
                    throw AppError("目标动态壁纸不存在：\(target.path)")
                }
                let currentBackup = try AerialService.createBackup(of: target, uuid: uuid, suffix: "before-history-restore")
                let sourceHash = try AerialService.sha256(archive.url)
                do {
                    try AerialService.replaceAtomically(source: archive.url, target: target)
                    guard sourceHash == (try AerialService.sha256(target)) else {
                        throw AppError("安装后的历史壁纸校验失败。")
                    }
                } catch {
                    try? AerialService.replaceAtomically(source: currentBackup, target: target)
                    throw error
                }
                let warning = await reloadWallpaperAgent()
                backups = AerialService.backups(for: uuid)
                lastReport = OperationReport(
                    uuid: uuid,
                    archiveURL: archive.url,
                    backupURL: currentBackup,
                    outputURL: archive.url,
                    reloadWarning: warning,
                    isRestore: true,
                    isArchiveReplacement: true
                )
                phase = .success
                logger.write("History replacement uuid=\(uuid) archive=\(archive.url.path) backup=\(currentBackup.path)")
            } catch {
                phase = .failed(error.localizedDescription)
                alertMessage = error.localizedDescription
                logger.write("History replacement failure: \(error.localizedDescription)")
            }
            isProcessing = false
        }
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
                    isRestore: true,
                    isArchiveReplacement: false
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

    private func runConversion(
        input: InputVideoInfo,
        uuid: String,
        loopCount: Int,
        bitrate: Int,
        archiveName: String?,
        cropSelection: WallpaperCropSelection?
    ) {
        isProcessing = true
        progress = 0
        phase = .running(number: 1, title: "检查开发环境", detail: "正在检查 Swift、Git、Python 3 和动态壁纸目录…")
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

                let aspectDetail = cropSelection == nil
                    ? "保持原始画幅比例。"
                    : "已按主显示器比例裁剪并铺满，不拉伸原画面。"
                phase = .running(number: 4, title: "编码动态壁纸视频", detail: "正在生成 HEVC Main 10 输出，\(aspectDetail)")
                let output = try processedOutputURL(uuid: uuid)
                try await EncoderService.encode(
                    input: input.url,
                    output: output,
                    loopCount: loopCount,
                    bitrateMbps: bitrate,
                    executable: encoder,
                    cropSelection: cropSelection
                )
                progress = 4

                phase = .running(number: 5, title: "验证 temporal sample groups", detail: "必须同时包含 tscl 和 tsas 的四项标记。")
                let validation = try await EncoderService.validate(
                    output: output,
                    repository: encoder.deletingLastPathComponent()
                )
                logger.write("Validation output=\(validation.replacingOccurrences(of: "\n", with: " | "))")
                progress = 5

                let target = try AerialService.targetURL(uuid: uuid)
                guard FileManager.default.isReadableFile(atPath: target.path) else {
                    throw AppError("目标动态壁纸不存在：\(target.path)\n请先在系统设置→壁纸中下载并应用对应动态壁纸。")
                }

                phase = .running(number: 6, title: "归档原动态壁纸", detail: "正在保存到应用文件夹中的“壁纸”目录…")
                let backup = try AerialService.createBackup(of: target, uuid: uuid)
                let archive = try AerialService.archiveOriginal(of: target, uuid: uuid, customName: archiveName)
                do {
                    try await PreviewService.generateFirstFrame(
                        from: archive,
                        to: AerialService.previewURL(for: archive)
                    )
                } catch {
                    logger.write("Preview generation failed archive=\(archive.path): \(error.localizedDescription)")
                }
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
                let encodedArchive: URL?
                do {
                    encodedArchive = try AerialService.archiveEncodedOutput(output, uuid: uuid)
                } catch {
                    encodedArchive = nil
                    logger.write("Encoded history archive failed output=\(output.path): \(error.localizedDescription)")
                }
                let historyOutput = encodedArchive ?? output
                progress = 7

                phase = .running(number: 8, title: "重载 WallpaperAgent", detail: "仅重载一次系统壁纸服务…")
                let reloadWarning = await reloadWallpaperAgent()
                progress = 8
                lastReport = OperationReport(
                    uuid: uuid,
                    archiveURL: archive,
                    backupURL: backup,
                    outputURL: historyOutput,
                    reloadWarning: reloadWarning,
                    isRestore: false,
                    isArchiveReplacement: false
                )
                phase = .success
                backups = AerialService.backups(for: uuid)
                targets = AerialService.targets()
                refreshArchives()
                logger.write("Success uuid=\(uuid) archive=\(archive.path) backup=\(backup.path) output=\(historyOutput.path) reloadWarning=\(reloadWarning ?? "none")")
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

    private func cropSelection(for input: InputVideoInfo) -> WallpaperCropSelection? {
        guard let display = displayPixelSize(),
              abs(Double(input.width) / Double(input.height) - display.aspect) > 0.005 else {
            return nil
        }
        return wallpaperLayout(for: input)
    }

    private func wallpaperLayout(for input: InputVideoInfo) -> WallpaperCropSelection? {
        guard let display = displayPixelSize() else { return nil }
        let sourceWidth = Double(input.width)
        let sourceHeight = Double(input.height)
        let sourceAspect = sourceWidth / sourceHeight
        let cropWidth: Double
        let cropHeight: Double
        let originX: Double
        let originY: Double

        if abs(sourceAspect - display.aspect) <= 0.005 {
            cropWidth = sourceWidth
            cropHeight = sourceHeight
            originX = 0
            originY = 0
        } else if sourceAspect > display.aspect {
            cropWidth = Double(max(2, Int((sourceHeight * display.aspect).rounded(.down)) & ~1))
            cropHeight = sourceHeight
            originX = (sourceWidth - cropWidth) / 2
            originY = 0
        } else if sourceAspect < display.aspect {
            cropWidth = sourceWidth
            cropHeight = Double(max(2, Int((sourceWidth / display.aspect).rounded(.down)) & ~1))
            originX = 0
            originY = (sourceHeight - cropHeight) / 2
        } else {
            cropWidth = sourceWidth
            cropHeight = sourceHeight
            originX = 0
            originY = 0
        }

        var selection = WallpaperCropSelection(
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            cropWidth: cropWidth,
            cropHeight: cropHeight,
            outputWidth: display.width,
            outputHeight: display.height,
            originX: originX,
            originY: originY
        )
        selection.clamp()
        return selection
    }

    private func displayPixelSize() -> (width: Int, height: Int, aspect: Double)? {
        guard let screen = NSScreen.main,
              screen.frame.width > 0,
              screen.frame.height > 0 else {
            return nil
        }
        let scale = max(1, screen.backingScaleFactor)
        let width = max(2, Int((screen.frame.width * scale).rounded()) & ~1)
        let height = max(2, Int((screen.frame.height * scale).rounded()) & ~1)
        return (
            width: width,
            height: height,
            aspect: screen.frame.width / screen.frame.height
        )
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
