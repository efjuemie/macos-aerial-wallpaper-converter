sed: --: No such file or directory
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
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
        .frame(minWidth: 760, minHeight: 700)
        .background(Color(nsColor: .windowBackgroundColor))
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
            Text("应用会先验证视频，再备份当前 Aerial，最后替换系统壁纸文件。原文件会保留在桌面“壁纸”文件夹中。")
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
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Aerial Wallpaper Converter")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Text("将视频转换为更稳定的 macOS 动态航拍壁纸")
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
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { model.loadVideo(at: url) }
                }
                return true
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

    private var targetSection: some View {
        SectionCard(title: "2 · 目标 Aerial", systemImage: "rectangle.on.rectangle") {
            HStack {
                Text("已安装的航拍壁纸")
                    .foregroundStyle(.secondary)
                Picker("已安装的航拍壁纸", selection: $model.selectedUUID) {
                    Text("手动输入 UUID").tag("")
                    ForEach(model.targets) { target in
                        Text(target.uuid).tag(target.uuid)
                    }
                }
                .labelsHidden()
                .onChange(of: model.selectedUUID) { value in
                    model.selectTarget(value)
                }
                Spacer()
            }

            HStack {
                Text("UUID")
                    .foregroundStyle(.secondary)
                    .frame(width: 110, alignment: .leading)
                TextField("Aerial UUID", text: $model.uuidText, onCommit: {
                    model.uuidFieldChanged()
                })
                .textFieldStyle(.roundedBorder)
                Image(systemName: model.selectedTargetExists ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(model.selectedTargetExists ? .green : .orange)
                Text(model.selectedTargetExists ? "目标文件存在" : "目标文件不存在")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("默认目标：\(AppModel.defaultUUID)。如果不存在，请先在系统设置→壁纸中下载并应用对应航拍壁纸。")
                .font(.caption)
                .foregroundStyle(.secondary)
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
            Text("默认目标时长为 300 秒，使用 HEVC Main 10 和 temporal sample groups。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var environmentSection: some View {
        SectionCard(title: "环境检查", systemImage: "checkmark.shield") {
            if model.environmentChecks.isEmpty {
                ProgressView("正在检查…")
            } else {
                ForEach(model.environmentChecks) { check in
                    HStack(spacing: 10) {
                        Image(systemName: check.isOK ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(check.isOK ? .green : .red)
                        Text(check.name)
                            .frame(width: 150, alignment: .leading)
                        Text(check.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                    }
                }
            }

            if let warning = model.oldAgentWarning {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("发现旧的自动修复脚本")
                            .fontWeight(.semibold)
                        Text(warning + "。它可能导致锁屏/解锁后的壁纸异常。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("停用旧脚本") { model.disableOldAgent() }
                            .buttonStyle(.link)
                    }
                    Spacer()
                }
                .padding(10)
                .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }
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
                    Text(model.phase.detail)
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
                    Text(report.isRestore ? "备份恢复成功：\(report.uuid)" : "替换成功：\(report.uuid)")
                    if report.isRestore {
                        Text("恢复前备份：\(report.backupURL.path)")
                        Text("恢复来源：\(report.outputURL.path)")
                    } else {
                        Text("桌面归档：\(report.archiveURL.path)")
                        Text("应用备份：\(report.backupURL.path)")
                        Text("处理输出：\(report.outputURL.path)")
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
                    Button("打开桌面归档") { model.openArchiveFolder() }
                        .buttonStyle(.bordered)
                }
                Text("请重新点击对应航拍壁纸，并连续测试 5 次锁屏→解锁。桌面保持静态是正常的；黑屏或第二次不播放则应恢复备份。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button(model.isProcessing ? "处理中…" : "处理并替换") {
                model.showProcessConfirmation = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!model.canStart)
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
            Text("WallpaperConverter · v0.1.0")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
            Text("不使用常驻脚本 · 不需要 root")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
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
