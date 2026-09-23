import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ContentView: View {
    @ObservedObject var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            newWallpaperTab
                .tabItem {
                    Label("新壁纸替换", systemImage: "wand.and.stars")
                }
            HistoryView(model: model)
                .tabItem {
                    Label("历史壁纸", systemImage: "clock.arrow.circlepath")
                }
        }
        .frame(minWidth: 820, minHeight: 720)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $model.showCropSheet) {
            CropSheetView(model: model)
        }
        .alert("提示", isPresented: Binding(
            get: { model.alertMessage != nil },
            set: { if !$0 { model.alertMessage = nil } }
        )) {
            Button("好") { model.alertMessage = nil }
        } message: {
            Text(model.alertMessage ?? "")
        }
        .confirmationDialog(
            "确认处理并替换壁纸？",
            isPresented: $model.showProcessConfirmation,
            titleVisibility: .visible
        ) {
            Button("继续处理", role: .destructive) { model.startProcessing() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("应用会先验证视频，再备份当前动态壁纸，最后替换系统壁纸文件。原文件会保留在应用文件夹的“壁纸”目录中。")
        }
        .confirmationDialog(
            "确认恢复备份？",
            isPresented: $model.showRestoreConfirmation,
            titleVisibility: .visible
        ) {
            Button("恢复此版本", role: .destructive) { model.restoreSelectedBackup() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("恢复前会自动备份当前文件，并重载 WallpaperAgent。")
        }
        .confirmationDialog(
            "确认环境操作？",
            isPresented: $model.showEnvironmentActionConfirmation,
            titleVisibility: .visible
        ) {
            Button("继续") { model.confirmEnvironmentAction() }
            Button("取消", role: .cancel) { model.cancelEnvironmentAction() }
        } message: {
            Text(model.environmentActionConfirmationMessage)
        }
        .confirmationDialog(
            "确认重新识别系统原壁纸？",
            isPresented: $model.showReidentifyConfirmation,
            titleVisibility: .visible
        ) {
            Button("我已重新下载，重新识别") { model.reidentifyDownloadedOriginal() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("仅在你已从系统设置重新下载当前 UUID 对应的 Apple 动态壁纸后使用。应用会备份旧画布记录，再把当前文件识别为原件；不会替换壁纸。若当前仍是自定义视频，请取消。")
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                model.refresh()
            }
        }
    }

    private var newWallpaperTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                inputSection
                targetSection
                settingsSection
                environmentSection
                progressSection
                backupSection
                footer
            }
            .padding(28)
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            AppLogoView()
            VStack(alignment: .leading, spacing: 6) {
                Text("Aerial Wallpaper Converter")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Text("将视频转换为更稳定的 macOS 动态壁纸")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                model.refresh()
            } label: {
                Label("刷新环境", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(model.isProcessing)
        }
    }

    private var inputSection: some View {
        SectionCard(title: "1 · 选择视频", systemImage: "film") {
            HStack(spacing: 12) {
                Image(systemName: "doc.badge.plus")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                TextField("拖入视频，或输入 / 粘贴文件路径", text: $model.inputPath, onCommit: {
                    model.loadVideoFromPathField()
                })
                .textFieldStyle(.roundedBorder)
                Button("选择文件…") { model.chooseVideo() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(16)
            .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [6]))
            }
            .onDrop(
                of: [UTType.fileURL.identifier, UTType.url.identifier, UTType.text.identifier],
                isTargeted: nil
            ) { providers in
                loadDroppedVideo(from: providers)
                return true
            }

            if model.isInspectingVideo {
                Label("正在读取视频信息…", systemImage: "hourglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let inputLoadError = model.inputLoadError {
                Label("读取失败：\(inputLoadError)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }

            if let info = model.inputInfo {
                HStack(spacing: 20) {
                    InfoCell(label: "时长", value: info.durationText)
                    InfoCell(label: "分辨率", value: "\(info.width) × \(info.height)")
                    InfoCell(label: "大小", value: info.fileSizeText)
                    Spacer()
                }
                .padding(.top, 4)
                Text(info.url.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func loadDroppedVideo(from providers: [NSItemProvider]) {
        let supportedTypes = [
            UTType.fileURL.identifier,
            UTType.url.identifier,
            UTType.text.identifier
        ]

        func loadProvider(at index: Int, lastError: String? = nil) {
            guard index < providers.count else {
                let detail = lastError.map { "：\($0)" } ?? ""
                DispatchQueue.main.async {
                    model.recordInputLoadFailure("无法识别拖入的本地视频文件\(detail)")
                }
                return
            }

            let provider = providers[index]
            guard let typeIdentifier = supportedTypes.first(where: {
                provider.hasItemConformingToTypeIdentifier($0)
            }) else {
                loadProvider(at: index + 1, lastError: lastError)
                return
            }

            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, error in
                if let item {
                    switch DroppedVideoURLResolver.resolve(item) {
                    case let .success(url):
                        DispatchQueue.main.async {
                            model.loadVideo(at: url)
                        }
                        return
                    case let .failure(parseError):
                        loadProvider(at: index + 1, lastError: parseError.localizedDescription)
                        return
                    }
                }
                loadProvider(at: index + 1, lastError: error?.localizedDescription)
            }
        }

        loadProvider(at: 0)
    }

    private var targetSection: some View {
        SectionCard(title: "2 · 目标动态壁纸", systemImage: "rectangle.on.rectangle") {
            HStack {
                Text("已安装的动态壁纸")
                    .foregroundStyle(.secondary)
                if model.targets.isEmpty {
                    Picker("已安装的动态壁纸", selection: .constant("")) {
                        Text("请先下载动态壁纸").tag("")
                    }
                    .labelsHidden()
                    .disabled(true)
                    Spacer()
                    Button("打开系统设置→壁纸") {
                        model.openWallpaperSettings()
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Picker("已安装的动态壁纸", selection: $model.selectedUUID) {
                        ForEach(model.targets) { target in
                            Text(target.uuid).tag(target.uuid)
                        }
                    }
                    .labelsHidden()
                    .onChange(of: model.selectedUUID) { value in
                        model.selectTarget(value)
                    }
                    .disabled(model.isReidentifying || model.isPreparingLayout)
                    Spacer()
                }
            }

            HStack {
                Text("目标文件夹")
                    .foregroundStyle(.secondary)
                    .frame(width: 110, alignment: .leading)
                Button("打开动态壁纸文件夹", systemImage: "folder") {
                    model.openDynamicWallpaperFolder()
                }
                .buttonStyle(.bordered)
                Text("快速定位系统动态壁纸文件")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("UUID")
                    .foregroundStyle(.secondary)
                    .frame(width: 110, alignment: .leading)
                TextField("Aerial UUID", text: $model.uuidText, onCommit: {
                    model.uuidFieldChanged()
                })
                .textFieldStyle(.roundedBorder)
                .disabled(model.isReidentifying || model.isPreparingLayout)
                Image(systemName: model.selectedTargetAvailability.isAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(model.selectedTargetAvailability.isAvailable ? .green : .orange)
                Text(
                    model.selectedTargetAvailability.isAvailable
                        ? "目标文件存在"
                        : model.selectedTargetAvailability.message
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Text("默认目标：\(AppModel.defaultUUID)。如果不存在，请先在系统设置→壁纸中下载并应用对应动态壁纸。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let warning = GeometryDiagnostics.displayAspectWarning() {
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var settingsSection: some View {
        SectionCard(title: "3 · 输出设置", systemImage: "slider.horizontal.3") {
            HStack(spacing: 20) {
                SettingField(title: "目标时长（秒）", text: $model.targetDurationText)
                SettingField(title: "码率（Mbps）", text: $model.bitrateText)
                if let info = model.inputInfo, let seconds = Double(model.targetDurationText), seconds > 0 {
                    InfoCell(label: "预计循环", value: "\(max(1, Int(ceil(seconds / info.duration)))) 次")
                }
                Spacer()
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("归档名称（可选）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("例如：我的夜景", text: $model.archiveNameText)
                    .textFieldStyle(.roundedBorder)
                Text("命名本次替换前保存的系统原壁纸，不会重命名刚拖入的新视频。留空使用原 UUID，并始终保留自动编号。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("默认目标时长为 300 秒；比例不一致时会先裁剪并铺满屏幕，不拉伸原画面。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var environmentSection: some View {
        SectionCard(title: "环境检查", systemImage: "checkmark.shield") {
            if model.hasBlockingEnvironmentFailure {
                Label(
                    "还有 \(model.environmentChecks.filter(\.blocksProcessing).count) 项运行环境问题需要处理",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.red)
            } else if model.isEnvironmentChecking {
                Label("正在检查运行环境…", systemImage: "hourglass")
                    .foregroundStyle(.secondary)
            } else {
                Label("环境已就绪，可以处理动态壁纸", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }

            ForEach(model.environmentChecks.filter { $0.requirement == .required }) { check in
                environmentCheckRow(check)
            }

            if let oldAgent = model.environmentChecks.first(where: { $0.id == "oldLaunchAgent" }) {
                environmentCheckRow(oldAgent)
            }

            DisclosureGroup("开发工具（仅源码构建 / 高级恢复需要）") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("普通运行不需要 Git、Python 3、Swift 或 Command Line Tools。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(model.environmentChecks.filter { $0.requirement == .optional && $0.id != "oldLaunchAgent" }) { check in
                        environmentCheckRow(check)
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    @ViewBuilder
    private func environmentCheckRow(_ check: EnvironmentCheck) -> some View {
        HStack(spacing: 10) {
            Image(systemName: environmentStatusIcon(check.status))
                .foregroundStyle(environmentStatusColor(check.status))
            Text(check.name)
                .frame(width: 150, alignment: .leading)
            Text(check.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 8)
            if let title = environmentActionTitle(check.action) {
                Button(title) {
                    model.performEnvironmentAction(check.action)
                }
                .buttonStyle(.link)
            }
        }
    }

    private func environmentStatusIcon(_ status: EnvironmentStatus) -> String {
        switch status {
        case .checking: return "hourglass"
        case .ok: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.circle.fill"
        }
    }

    private func environmentStatusColor(_ status: EnvironmentStatus) -> Color {
        switch status {
        case .checking: return .secondary
        case .ok: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }

    private func environmentActionTitle(_ action: EnvironmentAction) -> String? {
        switch action {
        case .none: return nil
        case .refresh: return "重新检测"
        case .openSoftwareUpdate: return "打开软件更新"
        case .installCommandLineTools: return "安装开发工具"
        case .openWallpaperSettings: return "打开系统设置→壁纸"
        case .openStorageSettings: return "打开存储设置"
        case .disableOldLaunchAgent: return "停用旧脚本"
        case .reinstallApplication: return "重新下载应用"
        case .showHelp: return "查看解决方法"
        }
    }

    private var progressSection: some View {
        SectionCard(title: "处理", systemImage: "gearshape.2") {
            HStack(alignment: .center, spacing: 14) {
                if model.isProcessing {
                    ProgressView()
                        .controlSize(.small)
                } else if case .success = model.phase {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.title2)
                } else if case .failed = model.phase {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.title2)
                } else {
                    Image(systemName: "sparkles")
                        .foregroundStyle(Color.accentColor)
                        .font(.title2)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.phase.title)
                        .fontWeight(.semibold)
                    Text(model.processingDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            if model.isProcessing {
                ProgressView(value: Double(model.progress), total: 8)
                Text("阶段 \(min(model.progress + 1, 8)) / 8")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if case .success = model.phase, let report = model.lastReport {
                VStack(alignment: .leading, spacing: 5) {
                    Text(
                        report.isArchiveReplacement
                            ? "历史动态壁纸替换成功：\(report.uuid)"
                            : report.isRestore
                                ? "备份恢复成功：\(report.uuid)"
                                : "替换成功：\(report.uuid)"
                    )
                    if report.isArchiveReplacement {
                        Text("替换来源：\(report.outputURL.path)")
                        Text("替换前备份：\(report.backupURL.path)")
                    } else if report.isRestore {
                        Text("恢复前备份：\(report.backupURL.path)")
                        Text("恢复来源：\(report.outputURL.path)")
                    } else {
                        Text("壁纸归档：\(report.archiveURL.path)")
                        Text("应用备份：\(report.backupURL.path)")
                        Text("新壁纸归档/处理输出：\(report.outputURL.path)")
                    }
                    if let geometry = model.lastGeometrySummary {
                        Text(geometry)
                    }
                    if let warning = report.reloadWarning {
                        Text(warning)
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .textSelection(.enabled)
                .padding(10)
                .background(Color.green.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
                HStack {
                    Button("打开系统设置→壁纸") { model.openWallpaperSettings() }
                        .buttonStyle(.borderedProminent)
                    Button("打开壁纸归档") { model.openArchiveFolder() }
                        .buttonStyle(.bordered)
                }
                Text("请重新点击对应动态壁纸，并连续测试 5 次锁屏→解锁。桌面保持静态是正常的；黑屏或第二次不播放则应恢复备份。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button(model.isProcessing ? "处理中…" : model.isPreparingLayout ? "读取目标画布…" : "处理并替换") {
                model.requestProcessing()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!model.canStart)
            if let reason = model.processingBlockMessage {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Divider()
            Picker("实际观察到的现象", selection: $model.geometryPhenomenonChoice) {
                ForEach(AppModel.geometryPhenomenonChoices, id: \.self) { choice in
                    Text(choice).tag(choice)
                }
            }
            .pickerStyle(.menu)
            HStack(spacing: 8) {
                Button {
                    model.diagnoseCurrentTarget()
                } label: {
                    Label(
                        model.isGeneratingGeometryDiagnostic ? "正在诊断…" : "诊断当前目标",
                        systemImage: "stethoscope"
                    )
                }
                .buttonStyle(.bordered)
                .disabled(model.isProcessing || model.isGeneratingGeometryDiagnostic || model.isReidentifying)
                Button("导出诊断报告") {
                    model.exportGeometryDiagnostic()
                }
                .buttonStyle(.bordered)
                .disabled(model.lastGeometryDiagnostic == nil || model.isProcessing)
                Button("打开诊断文件夹") {
                    model.openDiagnosticsFolder()
                }
                .buttonStyle(.link)
                Button("重新识别原壁纸") {
                    model.showReidentifyConfirmation = true
                }
                .buttonStyle(.link)
                .disabled(model.isProcessing || model.isPreparingLayout || model.isGeneratingGeometryDiagnostic || model.isReidentifying)
            }
            Text("诊断只读取当前目标、视频几何和显示器信息，不编码、不备份、不替换，也不会重载 WallpaperAgent。")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            if let diagnostic = model.lastGeometryDiagnostic {
                let canvasDescription = diagnostic.chosenCanvas.map {
                    "\($0.width) × \($0.height)"
                } ?? "无法可靠判定"
                let sourceDescription = diagnostic.chosenSource?.displayName ?? "无"
                DisclosureGroup("最近一次几何诊断") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("目标画布：\(canvasDescription)")
                        Text("来源：\(sourceDescription)")
                        if !diagnostic.conflicts.isEmpty {
                            Text("冲突：\(diagnostic.conflicts.joined(separator: "；"))")
                                .foregroundStyle(.orange)
                        }
                        if !diagnostic.notes.isEmpty {
                            Text(diagnostic.notes.joined(separator: "\n"))
                                .foregroundStyle(.secondary)
                        }
                        if let url = model.geometryDiagnosticURL {
                            Text(url.path)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .textSelection(.enabled)
                        }
                    }
                    .font(.caption)
                    .textSelection(.enabled)
                    .padding(.top, 4)
                }
            }
        }
    }

    private var backupSection: some View {
        SectionCard(title: "恢复备份", systemImage: "arrow.uturn.backward.circle") {
            if model.backups.isEmpty {
                Text("当前 UUID 暂无应用备份。每次替换前都会自动创建备份。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack {
                    Picker("备份版本", selection: $model.selectedBackup) {
                        Text("选择一个备份").tag(Optional<BackupEntry>.none)
                        ForEach(model.backups) { backup in
                            Text(backup.displayName).tag(Optional(backup))
                        }
                    }
                    .labelsHidden()
                    Button("恢复") { model.showRestoreConfirmation = true }
                        .buttonStyle(.bordered)
                        .disabled(model.selectedBackup == nil || model.isProcessing)
                    Button("打开日志") { model.openLog() }
                        .buttonStyle(.link)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("WallpaperConverter · v\(appVersion)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
            Text("不使用常驻脚本 · 不需要 root")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? "开发版"
    }
}

private struct AppLogoView: View {
    var body: some View {
        Group {
            if let url = Bundle.main.url(forResource: "AppLogo", withExtension: "png"),
               let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "film.stack.fill")
                    .resizable()
                    .scaledToFit()
                    .padding(14)
                    .foregroundStyle(Color.accentColor)
            }
        }
        .frame(width: 62, height: 62)
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
    }
}

private struct SectionCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.primary.opacity(0.08))
        }
    }
}

private struct InfoCell: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .fontWeight(.medium)
        }
    }
}

private struct SettingField: View {
    let title: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(title, text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 140)
        }
    }
}
