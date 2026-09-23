import AppKit
import Foundation

private enum PreviewRefreshResult: Sendable {
    case valid
    case generated
    case failed(String)
}

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
    @Published var environmentChecks: [EnvironmentCheck] = EnvironmentCheckBuilder.checking()
    @Published var phase: ProcessingPhase = .idle
    @Published var progress = 0
    @Published var lastReport: OperationReport?
    @Published var backups: [BackupEntry] = []
    @Published var selectedBackup: BackupEntry?
    @Published var archiveEntries: [WallpaperArchiveEntry] = []
    @Published var selectedArchive: WallpaperArchiveEntry?
    @Published var archiveRenameText = ""
    @Published var isGeneratingPreviews = false
    @Published var previewFailures: Set<URL> = []
    @Published var previewRevision = 0
    @Published var archiveToDelete: WallpaperArchiveEntry?
    @Published var showArchiveDeleteConfirmation = false
    @Published var showArchiveReplaceConfirmation = false
    @Published var showProcessConfirmation = false
    @Published var showRestoreConfirmation = false
    @Published var alertMessage: String?
    @Published var inputLoadError: String?
    @Published var isProcessing = false
    @Published var isInspectingVideo = false
    @Published var isPreparingLayout = false
    @Published var archiveNameText = ""
    @Published var pendingCropSelection: WallpaperCropSelection?
    @Published var pendingCropOrientation: GeometryOrientationAssessment?
    @Published var pendingCropWarning: String?
    @Published var showCropSheet = false
    @Published var showEnvironmentActionConfirmation = false
    @Published var showReidentifyConfirmation = false
    @Published var isReidentifying = false
    @Published var lastGeometryDiagnostic: GeometryDiagnosticReport?
    @Published var geometryDiagnosticURL: URL?
    @Published var isGeneratingGeometryDiagnostic = false
    @Published var lastGeometrySummary: String?
    @Published var lastGeometrySource: String?
    @Published var geometryPhenomenonChoice = "未观察"

    static let geometryPhenomenonChoices = [
        "未观察",
        "A · 最终 MOV 在 QuickTime 已变形",
        "B · 进入桌面立即变形",
        "C · 桌面延迟数秒后变形",
        "D · 仅特定显示器或缩放设置变形"
    ]

    private let logger = AppLogger()
    private let videoInspector: @Sendable (URL) async throws -> InputVideoInfo
    private var previewTask: Task<Void, Never>?
    private var environmentRefreshTask: Task<Void, Never>?
    private var videoInspectionTask: Task<Void, Never>?
    private var videoLoadState = VideoLoadStateMachine()
    private var pendingEnvironmentAction: EnvironmentAction?

    init(
        autoRefresh: Bool = true,
        videoInspector: @escaping @Sendable (URL) async throws -> InputVideoInfo = { url in
            try await VideoInspector.inspect(url)
        }
    ) {
        self.videoInspector = videoInspector
        if autoRefresh {
            refresh()
        }
        if autoRefresh, let path = CommandLine.arguments.dropFirst().first, !path.isEmpty {
            inputPath = path
            loadVideoFromPathField()
        }
    }

    var hasBlockingEnvironmentFailure: Bool {
        environmentChecks.contains(where: \.blocksProcessing)
    }

    var hasEnvironmentFailure: Bool {
        hasBlockingEnvironmentFailure
    }

    var isEnvironmentChecking: Bool {
        environmentChecks.isEmpty || environmentChecks.contains { $0.status == .checking }
    }

    var selectedTargetAvailability: TargetAvailability {
        guard let uuid = TargetSelectionPolicy.normalizeUUID(uuidText) else {
            return .invalidUUID
        }
        let targetURL = AppPaths.aerialDirectory.appendingPathComponent("\(uuid).mov")
        return TargetAvailability.evaluate(targetURL)
    }

    var processingReadiness: ProcessingReadiness {
        ProcessingReadiness.evaluate(
            ProcessingReadinessInput(
                inputLoaded: inputInfo != nil,
                isInspectingVideo: isInspectingVideo,
                uuidValid: TargetSelectionPolicy.normalizeUUID(uuidText) != nil,
                targetAvailability: selectedTargetAvailability,
                environmentChecking: isEnvironmentChecking,
                environmentFailures: environmentChecks.filter(\.blocksProcessing).map(\.name),
                isProcessing: isProcessing,
                isPreparingLayout: isPreparingLayout,
                isReidentifying: isReidentifying
            )
        )
    }

    var processingBlockReason: ProcessingBlockReason? {
        processingReadiness.blockReason
    }

    var processingBlockMessage: String? {
        processingBlockReason?.message
    }

    var processingDetail: String {
        if case .idle = phase {
            return processingBlockMessage ?? "已就绪，可以处理。"
        }
        return phase.detail
    }

    var canStart: Bool {
        processingReadiness.canStart
    }

    var selectedTargetExists: Bool {
        selectedTargetAvailability.isAvailable
    }

    private func logReadiness(_ event: String) {
        let input = processingReadiness
        let reason = input.blockReason?.message ?? "ready"
        let blockingEnvironment = environmentChecks
            .filter { $0.blocksProcessing }
            .map { $0.name }
            .joined(separator: ",")
        logger.write(
            "[Readiness] event=\(event) canStart=\(input.canStart) reason=\(reason) " +
            "inputLoaded=\(inputInfo != nil) inspecting=\(isInspectingVideo) " +
            "uuid=\(uuidText) targetAvailability=\(selectedTargetAvailability) " +
            "environmentChecking=\(isEnvironmentChecking) " +
            "blockingEnvironment=\(blockingEnvironment) " +
            "processing=\(isProcessing) preparingLayout=\(isPreparingLayout) reidentifying=\(isReidentifying)"
        )
    }

    func refresh() {
        environmentRefreshTask?.cancel()
        let hasCheckingStatus = environmentChecks.contains { $0.status == .checking }
        if EnvironmentRefreshPolicy.shouldResetToChecking(
            checkCount: environmentChecks.count,
            hasCheckingStatus: hasCheckingStatus
        ) {
            environmentChecks = EnvironmentCheckBuilder.checking()
        }
        environmentRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let checks = await EnvironmentChecker.check()
            guard !Task.isCancelled else { return }
            self.environmentChecks = checks
            self.logReadiness("environment check completed")
        }
        refreshTargets()
        if ArchiveRefreshPolicy.shouldRefreshArchives(isProcessing: isProcessing) {
            refreshArchives()
        }
    }

    func refreshTargets() {
        let discoveredTargets = AerialService.targets()
        targets = discoveredTargets.filter {
            TargetAvailability.evaluate($0.url).isAvailable
        }
        let availableUUIDs = targets.map(\.uuid)
        if let selected = TargetSelectionPolicy.select(
            uuidText: uuidText,
            selectedUUID: selectedUUID,
            availableUUIDs: availableUUIDs
        ) {
            uuidText = selected
            selectedUUID = selected
            backups = AerialService.backups(for: selected)
        } else {
            selectedUUID = ""
            backups = []
        }
        logReadiness("refresh targets")
    }

    func refreshArchives() {
        guard ArchiveRefreshPolicy.shouldRefreshArchives(isProcessing: isProcessing) else {
            return
        }
        let previousTask = previewTask
        previousTask?.cancel()
        isGeneratingPreviews = true
        previewTask = Task { @MainActor [weak self] in
            await previousTask?.value
            guard !Task.isCancelled else { return }
            guard let self, !self.isProcessing else {
                self?.isGeneratingPreviews = false
                return
            }
            AerialService.migrateLegacyDesktopArchives()
            AerialService.migrateProcessedOutputs()
            guard !Task.isCancelled, !self.isProcessing else {
                if self.isProcessing { self.isGeneratingPreviews = false }
                return
            }
            let entries = await Task.detached(priority: .utility) {
                AerialService.archiveEntries()
            }.value
            guard !Task.isCancelled, !self.isProcessing else {
                if self.isProcessing { self.isGeneratingPreviews = false }
                return
            }
            self.archiveEntries = entries
            let currentPreviewURLs = Set(entries.map(\.previewURL))
            self.previewFailures.formIntersection(currentPreviewURLs)
            if let selectedArchive = self.selectedArchive {
                self.selectedArchive = entries.first { $0.url == selectedArchive.url }
            }
            guard !entries.isEmpty else {
                self.isGeneratingPreviews = false
                self.previewRevision += 1
                return
            }
            for entry in entries {
                guard !Task.isCancelled else { return }
                guard !self.isProcessing else {
                    self.isGeneratingPreviews = false
                    return
                }
                let result = await Task.detached(priority: .utility) {
                    () async -> PreviewRefreshResult in
                    if PreviewService.isValidPreview(at: entry.previewURL) {
                        return .valid
                    }
                    do {
                        try await PreviewService.generateFirstFrame(
                            from: entry.url,
                            to: entry.previewURL
                        )
                        return .generated
                    } catch {
                        return .failed(error.localizedDescription)
                    }
                }.value
                guard !Task.isCancelled else { return }
                guard !self.isProcessing else {
                    self.isGeneratingPreviews = false
                    return
                }
                switch result {
                case .valid:
                    self.previewFailures.remove(entry.previewURL)
                case .generated:
                    self.previewFailures.remove(entry.previewURL)
                    self.logger.write("Preview generated archive=\(entry.url.path) preview=\(entry.previewURL.path)")
                case let .failed(message):
                    self.previewFailures.insert(entry.previewURL)
                    self.logger.write("Preview generation failed archive=\(entry.url.path): \(message)")
                }
            }
            guard !Task.isCancelled else { return }
            guard !self.isProcessing else {
                self.isGeneratingPreviews = false
                return
            }
            self.archiveEntries = await Task.detached(priority: .utility) {
                AerialService.archiveEntries()
            }.value
            guard !Task.isCancelled, !self.isProcessing else {
                if self.isProcessing { self.isGeneratingPreviews = false }
                return
            }
            if let selectedArchive = self.selectedArchive {
                self.selectedArchive = self.archiveEntries.first { $0.url == selectedArchive.url }
            }
            self.isGeneratingPreviews = false
            self.previewRevision += 1
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
        switch VideoInputParser.parse(inputPath) {
        case let .success(url):
            loadVideo(at: url)
        case let .failure(error):
            recordInputLoadFailure(error.localizedDescription)
        }
    }

    func loadVideo(at url: URL) {
        guard !isProcessing else { return }
        switch VideoInputParser.parse(url) {
        case let .failure(error):
            recordInputLoadFailure(error.localizedDescription)
        case let .success(parsedURL):
            beginVideoInspection(parsedURL)
        }
    }

    private func beginVideoInspection(_ url: URL) {
        videoInspectionTask?.cancel()
        videoInspectionTask = nil
        let generation = videoLoadState.begin()
        inputPath = url.path
        inputInfo = nil
        inputLoadError = nil
        pendingCropSelection = nil
        pendingCropOrientation = nil
        pendingCropWarning = nil
        showCropSheet = false
        alertMessage = nil
        isInspectingVideo = true
        logReadiness("loadVideo start file=\(url.lastPathComponent)")

        videoInspectionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                _ = self.finishVideoInspection(generation)
            }
            do {
                let info = try await self.videoInspector(url)
                try Task.checkCancellation()
                guard self.videoLoadState.isCurrent(generation) else { return }
                self.inputInfo = info
                self.inputLoadError = nil
                if let detectedUUID = AerialService.uuidFromFilename(url) {
                    if self.targets.contains(where: { $0.uuid == detectedUUID }) {
                        self.uuidText = detectedUUID
                        self.selectedUUID = detectedUUID
                        self.backups = AerialService.backups(for: detectedUUID)
                    }
                }
                guard self.finishVideoInspection(generation) else { return }
                self.logger.write("Loaded input=\(url.lastPathComponent) duration=\(info.duration) size=\(info.width)x\(info.height)")
                self.logReadiness("inspect success")
            } catch is CancellationError {
                guard self.videoLoadState.isCurrent(generation) else { return }
                _ = self.finishVideoInspection(generation)
                self.logger.write("Input inspect cancelled file=\(url.lastPathComponent)")
                self.logReadiness("inspect cancelled")
            } catch {
                guard self.videoLoadState.isCurrent(generation) else { return }
                self.inputInfo = nil
                self.inputLoadError = error.localizedDescription
                _ = self.finishVideoInspection(generation)
                self.logger.write("Input inspect failed file=\(url.lastPathComponent): \(error.localizedDescription)")
                self.logReadiness("inspect failed")
            }
        }
    }

    private func finishVideoInspection(_ generation: UUID) -> Bool {
        guard videoLoadState.finish(generation) else { return false }
        isInspectingVideo = false
        videoInspectionTask = nil
        return true
    }

    func recordInputLoadFailure(_ message: String) {
        videoInspectionTask?.cancel()
        videoInspectionTask = nil
        _ = videoLoadState.cancelCurrent()
        inputInfo = nil
        inputLoadError = message
        alertMessage = nil
        isInspectingVideo = false
        pendingCropSelection = nil
        pendingCropOrientation = nil
        pendingCropWarning = nil
        showCropSheet = false
        logger.write("Input load failed (details shown in UI)")
        logReadiness("input failure")
    }

    func cancelVideoInspection() {
        guard videoLoadState.isBusy else { return }
        videoInspectionTask?.cancel()
        videoInspectionTask = nil
        _ = videoLoadState.cancelCurrent()
        isInspectingVideo = false
        logger.write("Input inspect cancelled by user")
        logReadiness("inspect cancelled")
    }

    func openDynamicWallpaperFolder() {
        do {
            try AppPaths.ensureDirectory(AppPaths.aerialDirectory)
            NSWorkspace.shared.open(AppPaths.aerialDirectory)
        } catch {
            alertMessage = "无法打开动态壁纸文件夹：\(error.localizedDescription)"
        }
    }

    func diagnoseCurrentTarget() {
        guard let uuid = TargetSelectionPolicy.normalizeUUID(uuidText) else {
            alertMessage = "请输入有效的 Aerial UUID。"
            return
        }
        guard selectedTargetExists else {
            alertMessage = "请先在系统设置→壁纸中下载动态壁纸。"
            return
        }
        let inputURL = inputInfo?.url
        isGeneratingGeometryDiagnostic = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isGeneratingGeometryDiagnostic = false }
            do {
                var report = try await AerialService.diagnoseCurrentTarget(
                    uuid: uuid,
                    inputURL: inputURL
                )
                guard TargetSelectionPolicy.normalizeUUID(self.uuidText) == uuid else { return }
                report.phenomenon = self.geometryPhenomenonChoice
                self.lastGeometryDiagnostic = report
                let url = try GeometryDiagnostics.export(report)
                self.geometryDiagnosticURL = url
                self.logger.write("Geometry diagnostic exported uuid=\(uuid) report=\(url.lastPathComponent) \(report.summary)")
                self.alertMessage = "诊断报告已导出：\n\(url.path)"
            } catch {
                self.alertMessage = "无法生成几何诊断：\(error.localizedDescription)"
            }
        }
    }

    func exportGeometryDiagnostic() {
        guard var report = lastGeometryDiagnostic else {
            diagnoseCurrentTarget()
            return
        }
        do {
            report.phenomenon = geometryPhenomenonChoice
            lastGeometryDiagnostic = report
            let url = try GeometryDiagnostics.export(report)
            geometryDiagnosticURL = url
            alertMessage = "诊断报告已导出：\n\(url.path)"
        } catch {
            alertMessage = "无法导出诊断报告：\(error.localizedDescription)"
        }
    }

    func openDiagnosticsFolder() {
        do {
            try AppPaths.ensureDirectory(GeometryDiagnostics.directory)
            NSWorkspace.shared.open(GeometryDiagnostics.directory)
        } catch {
            alertMessage = "无法打开诊断文件夹：\(error.localizedDescription)"
        }
    }

    func reidentifyDownloadedOriginal() {
        guard !isProcessing, !isPreparingLayout, !isGeneratingGeometryDiagnostic, !isReidentifying else { return }
        guard let uuid = TargetSelectionPolicy.normalizeUUID(uuidText) else {
            alertMessage = "请输入有效的动态壁纸 UUID。"
            return
        }
        isReidentifying = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isReidentifying = false }
            do {
                let canvas = try await AerialService.reidentifyDownloadedOriginal(uuid: uuid)
                guard TargetSelectionPolicy.normalizeUUID(self.uuidText) == uuid else { return }
                self.pendingCropSelection = nil
                self.showCropSheet = false
                self.showProcessConfirmation = false
                self.lastGeometryDiagnostic = nil
                self.geometryDiagnosticURL = nil
                self.lastGeometrySummary = "已重新识别原生画布：\(canvas.width) × \(canvas.height)"
                self.alertMessage = "原生画布记录已更新。旧记录已备份到诊断文件夹。"
                self.logger.write("Reidentified downloaded original uuid=\(uuid) canvas=\(canvas.width)x\(canvas.height)")
            } catch {
                self.alertMessage = "重新识别失败：\(error.localizedDescription)"
            }
        }
    }

    func selectTarget(_ uuid: String) {
        guard let normalizedUUID = TargetSelectionPolicy.normalizeUUID(uuid) else { return }
        if selectedUUID != normalizedUUID {
            lastGeometryDiagnostic = nil
            geometryDiagnosticURL = nil
            lastGeometrySummary = nil
        }
        uuidText = normalizedUUID
        selectedUUID = normalizedUUID
        backups = AerialService.backups(for: normalizedUUID)
        logReadiness("target selection changed")
    }

    func uuidFieldChanged() {
        if let uuid = TargetSelectionPolicy.normalizeUUID(uuidText) {
            if selectedUUID != uuid {
                lastGeometryDiagnostic = nil
                geometryDiagnosticURL = nil
                lastGeometrySummary = nil
            }
            selectedUUID = uuid
            backups = AerialService.backups(for: uuid)
        } else {
            selectedUUID = ""
            backups = []
        }
        logReadiness("UUID field changed")
    }

    func requestProcessing() {
        guard processingReadiness.canStart else {
            let message = processingBlockMessage ?? "当前尚未满足处理条件。"
            alertMessage = message
            logger.write("[Readiness] request blocked reason=\(message)")
            return
        }
        guard let values = validatedProcessingValues() else { return }
        let target: URL
        do {
            target = try AerialService.targetURL(uuid: values.uuid)
        } catch {
            alertMessage = error.localizedDescription
            return
        }
        guard FileManager.default.isReadableFile(atPath: target.path) else {
            alertMessage = "请先在系统设置→壁纸中下载动态壁纸。"
            return
        }
        isPreparingLayout = true
        Task {
            do {
                let resolution = try await AerialService.outputCanvasResolution(for: target, uuid: values.uuid)
                let canvas = resolution.canvas
                lastGeometrySummary = "目标画布 \(canvas.width) × \(canvas.height)；来源 \(resolution.source.displayName)"
                lastGeometrySource = resolution.source.rawValue

                let diagnostic = try? await AerialService.diagnoseCurrentTarget(
                    uuid: values.uuid,
                    inputURL: values.input.url
                )
                let orientation = diagnostic?.orientationAssessment ?? GeometryDiagnostics.orientationAssessment(
                    sourceSize: GeometrySize(width: values.input.width, height: values.input.height),
                    screens: GeometryDiagnostics.currentScreens(),
                    targetProfile: resolution.profile,
                    referenceOriginalProfile: resolution.profile,
                    chosenCanvas: canvas,
                    chosenSource: resolution.source,
                    manifestCanvas: nil
                )
                pendingCropOrientation = orientation
                pendingCropWarning = orientation.warningMessage
                if let blockingReason = orientation.blockingReason {
                    throw AppError(blockingReason)
                }

                guard let layout = wallpaperLayout(for: values.input, outputCanvas: canvas) else {
                    throw AppError("无法读取主显示器尺寸，不能安全生成壁纸画布。")
                }
                pendingCropSelection = layout
                logger.write(
                    "Prepared canvas uuid=\(values.uuid) output=\(canvas.width)x\(canvas.height) " +
                    "source=\(resolution.source.rawValue) evidence=\(resolution.evidence) " +
                    "conflicts=\(resolution.conflicts.joined(separator: ";")) " +
                    "visibleCrop=\(Int(layout.cropWidth))x\(Int(layout.cropHeight))"
                )
                if requiresCrop(for: values.input)
                    || layoutNeedsCropReview(layout, input: values.input)
                    || orientation.requiresReview {
                    showCropSheet = true
                } else {
                    showProcessConfirmation = true
                }
            } catch {
                pendingCropSelection = nil
                alertMessage = error.localizedDescription
                logger.write("Canvas preparation failed uuid=\(values.uuid): \(error.localizedDescription)")
            }
            isPreparingLayout = false
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
        pendingCropOrientation = nil
        pendingCropWarning = nil
        showCropSheet = false
    }

    func updatePendingCrop(originX: Double, originY: Double) {
        guard var selection = pendingCropSelection else { return }
        selection.originX = originX
        selection.originY = originY
        selection.clamp()
        pendingCropSelection = selection
    }

    func updatePendingCropZoom(zoomFactor: Double) {
        guard let selection = pendingCropSelection,
              let zoomed = WallpaperGeometry.zoomedSelection(
                  from: selection,
                  zoomFactor: min(3, max(1, zoomFactor))
              ) else {
            return
        }
        var updated = zoomed
        updated.clamp()
        pendingCropSelection = updated
    }

    func resetPendingCrop() {
        guard let selection = pendingCropSelection,
              var maximum = WallpaperGeometry.maximumSelection(for: selection) else {
            return
        }
        maximum.originX = (maximum.sourceWidth - maximum.cropWidth) / 2
        maximum.originY = (maximum.sourceHeight - maximum.cropHeight) / 2
        maximum.clamp()
        pendingCropSelection = maximum
    }

    func startProcessing() {
        guard processingReadiness.canStart else {
            showProcessConfirmation = false
            alertMessage = processingBlockMessage ?? "当前尚未满足处理条件。"
            logger.write("[Readiness] stale confirmation blocked")
            return
        }
        guard let values = validatedProcessingValues() else { return }
        guard let layout = pendingCropSelection else {
            alertMessage = "目标壁纸画布尚未准备完成，请重新点击“处理并替换”。"
            return
        }
        let loopCount = max(1, Int(ceil(values.targetDuration / values.input.duration)))
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
              let uuid = TargetSelectionPolicy.normalizeUUID(uuidText) else {
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

    func performEnvironmentAction(_ action: EnvironmentAction) {
        guard action != .none else { return }
        if action.requiresConfirmation {
            pendingEnvironmentAction = action
            showEnvironmentActionConfirmation = true
            return
        }
        executeEnvironmentAction(action)
    }

    func confirmEnvironmentAction() {
        showEnvironmentActionConfirmation = false
        guard let action = pendingEnvironmentAction else { return }
        pendingEnvironmentAction = nil
        executeEnvironmentAction(action)
    }

    func cancelEnvironmentAction() {
        pendingEnvironmentAction = nil
        showEnvironmentActionConfirmation = false
    }

    var environmentActionConfirmationMessage: String {
        switch pendingEnvironmentAction {
        case .installCommandLineTools:
            return "将调用 macOS 官方 Command Line Tools 安装器。应用不会获取管理员密码，也不会修改系统保护设置。"
        case .disableOldLaunchAgent:
            return "将卸载精确的旧 LaunchAgent 服务并安全保留其配置，不会删除动态壁纸或应用备份。"
        default:
            return ""
        }
    }

    private func executeEnvironmentAction(_ action: EnvironmentAction) {
        switch action {
        case .refresh:
            refresh()
        case .disableOldLaunchAgent:
            disableOldAgent()
        default:
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let message = await EnvironmentRepairService.perform(action) {
                    self.alertMessage = message
                }
                if action == .installCommandLineTools {
                    self.refresh()
                }
            }
        }
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
        lastGeometryDiagnostic = nil
        geometryDiagnosticURL = nil

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
            let launchAgentLabel = "gui/\(uid)/com.local.wallpaper-aerial-fix"
            if let launchctl = CommandRunner.executable(named: "launchctl") {
                let result = try? await CommandRunner.run(
                    launchctl,
                    arguments: ["bootout", launchAgentLabel]
                )
                if FileManager.default.fileExists(atPath: AppPaths.oldLaunchAgent.path),
                   result?.status != 0,
                   let output = result?.output.trimmingCharacters(in: .whitespacesAndNewlines),
                   !output.isEmpty {
                    messages.append("无法卸载旧 LaunchAgent：\(output)")
                }
            } else if FileManager.default.fileExists(atPath: AppPaths.oldLaunchAgent.path) {
                messages.append("未找到 launchctl，无法卸载旧 LaunchAgent 服务。")
            }
            if FileManager.default.fileExists(atPath: AppPaths.oldLaunchAgent.path) {
                do {
                    let destination = LaunchAgentPathPolicy.nextAvailableDestination(
                        preferred: AppPaths.oldLaunchAgentDisabled
                    )
                    try FileManager.default.moveItem(at: AppPaths.oldLaunchAgent, to: destination)
                    if destination != AppPaths.oldLaunchAgentDisabled {
                        messages.append(
                            "已保留现有 \(AppPaths.oldLaunchAgentDisabled.lastPathComponent)，旧配置已安全保存为 \(destination.lastPathComponent)。"
                        )
                    }
                } catch {
                    messages.append("无法安全保存旧 LaunchAgent 配置：\(error.localizedDescription)")
                }
            }
            logger.write("Disabled old LaunchAgent; result=\(messages.joined(separator: " | "))")
            refresh()
        }
    }

    func restoreSelectedBackup() {
        guard let backup = selectedBackup,
              let uuid = TargetSelectionPolicy.normalizeUUID(uuidText) else {
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
        cropSelection: WallpaperCropSelection
    ) {
        previewTask?.cancel()
        previewTask = nil
        isGeneratingPreviews = false
        environmentRefreshTask?.cancel()
        isProcessing = true
        progress = 0
        phase = .running(
            number: 1,
            title: "检查运行环境",
            detail: "正在检查系统版本、内置编码器、动态壁纸目录和磁盘空间…"
        )
        lastReport = nil
        lastGeometryDiagnostic = nil
        geometryDiagnosticURL = nil

        var didComplete = false
        Task {
            do {
                let checks = await EnvironmentChecker.check()
                guard !Task.isCancelled else {
                    isProcessing = false
                    return
                }
                environmentChecks = checks
                guard !checks.contains(where: \.blocksProcessing) else {
                    throw AppError(checks.filter(\.blocksProcessing).map { "\($0.name)：\($0.detail)" }.joined(separator: "\n"))
                }
                progress = 1

                try checkFreeSpace()
                phase = .running(number: 2, title: "准备内置编码器", detail: "正在验证并准备应用内置 VideoToolbox 编码器…")
                let encoder = try await EncoderService.prepare()
                progress = 2

                phase = .running(number: 3, title: "读取视频信息", detail: "\(input.durationText)，\(input.width) × \(input.height)，循环 \(loopCount) 次。")
                logger.write("Start input=\(input.url.path) uuid=\(uuid) duration=\(input.duration) loopCount=\(loopCount) bitrate=\(bitrate)")
                progress = 3

                var geometryReport: GeometryDiagnosticReport?
                do {
                    geometryReport = try await AerialService.diagnoseCurrentTarget(uuid: uuid, inputURL: input.url)
                } catch {
                    logger.write("Geometry diagnostic before encoding unavailable: \(error.localizedDescription)")
                }

                let aspectDetail = "按屏幕可见区域取景，并生成 \(cropSelection.outputWidth) × \(cropSelection.outputHeight) 的目标 Aerial 画布。"
                phase = .running(number: 4, title: "编码动态壁纸视频", detail: "正在生成 HEVC Main 10 输出，\(aspectDetail)")
                let output = try processedOutputURL(uuid: uuid)
                let geometryResult = try await EncoderService.encodeWithEvidence(
                    input: input.url,
                    output: output,
                    loopCount: loopCount,
                    bitrateMbps: bitrate,
                    executable: encoder,
                    cropSelection: cropSelection
                )
                logger.write("Geometry validation output=\(output.path): \(geometryResult.validation)")
                geometryReport?.intermediate = geometryResult.intermediate
                geometryReport?.finalOutput = geometryResult.finalOutput
                geometryReport?.finalOutputSHA256 = try? AerialService.sha256(output)
                progress = 4

                phase = .running(number: 5, title: "验证输出兼容性", detail: "画布几何已固定；继续检查 tscl 和 tsas 四项标记。")
                let validation = try await EncoderService.validate(output: output)
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
                geometryReport?.installedTarget = await VideoGeometryService.diagnosticSnapshot(at: target)
                let installedHash = try? AerialService.sha256(target)
                geometryReport?.installedTargetSHA256 = installedHash
                geometryReport?.outputMatchesInstalledTarget = installedHash == sourceHash
                if var report = geometryReport {
                    let originalProfile = GeometryDiagnostics.originalReferenceProfile(
                        chosenSource: report.chosenSource,
                        targetHash: report.targetBeforeSHA256,
                        targetProfile: report.targetBefore?.profile,
                        persistedRecord: report.persistedRecord,
                        archiveProfile: report.referenceOriginal?.profile
                    )
                    report.diffs += GeometryDiagnostics.profileDifferences(
                        "target-before-vs-original", left: report.targetBefore?.profile, right: originalProfile
                    )
                    report.diffs += GeometryDiagnostics.profileDifferences(
                        "final-vs-original", left: report.finalOutput?.profile, right: originalProfile
                    )
                    report.diffs += GeometryDiagnostics.profileDifferences(
                        "intermediate-vs-final", left: report.intermediate?.profile, right: report.finalOutput?.profile
                    )
                    report.diffs += GeometryDiagnostics.profileDifferences(
                        "final-vs-installed", left: report.finalOutput?.profile, right: report.installedTarget?.profile
                    )
                    if originalProfile == nil {
                        report.notes.append("未取得可比对的 Apple 原壁纸几何 profile。")
                    }
                    geometryReport = report
                }
                if var geometryReport {
                    geometryReport.phenomenon = geometryPhenomenonChoice
                    lastGeometryDiagnostic = geometryReport
                    do {
                        geometryDiagnosticURL = try GeometryDiagnostics.export(geometryReport)
                    } catch {
                        logger.write("Geometry diagnostic export failed: \(error.localizedDescription)")
                    }
                    logger.write(geometryReport.geometryLogSummary)
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
                didComplete = true
                logger.write("Success uuid=\(uuid) archive=\(archive.path) backup=\(backup.path) output=\(historyOutput.path) reloadWarning=\(reloadWarning ?? "none")")
            } catch {
                phase = .failed(error.localizedDescription)
                alertMessage = error.localizedDescription
                logger.write("Failure: \(error.localizedDescription)")
            }
            isProcessing = false
            if didComplete {
                refreshArchives()
            }
        }
    }

    private func checkFreeSpace() throws {
        let values = try FileManager.default.attributesOfFileSystem(forPath: AppPaths.appSupport.deletingLastPathComponent().path)
        let freeBytes = (values[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        guard freeBytes >= 1_500_000_000 else {
            throw AppError("可用磁盘空间不足 1.5 GB，已停止处理。")
        }
    }

    private func requiresCrop(for input: InputVideoInfo) -> Bool {
        guard let display = displayPixelSize() else { return false }
        return abs(Double(input.width) / Double(input.height) - display.aspect) > 0.005
    }

    private func wallpaperLayout(
        for input: InputVideoInfo,
        outputCanvas: AerialCanvas
    ) -> WallpaperCropSelection? {
        guard let display = displayPixelSize() else { return nil }
        return WallpaperGeometry.cropSelection(
            sourceWidth: Double(input.width),
            sourceHeight: Double(input.height),
            screenAspect: display.aspect,
            outputCanvas: outputCanvas
        )
    }

    private func layoutNeedsCropReview(
        _ selection: WallpaperCropSelection,
        input: InputVideoInfo
    ) -> Bool {
        let sourceWidth = Double(input.width)
        let sourceHeight = Double(input.height)
        guard sourceWidth > 1, sourceHeight > 1 else { return false }
        let widthReduction = 1 - selection.cropWidth / sourceWidth
        let heightReduction = 1 - selection.cropHeight / sourceHeight
        return widthReduction > 0.02 || heightReduction > 0.02
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
