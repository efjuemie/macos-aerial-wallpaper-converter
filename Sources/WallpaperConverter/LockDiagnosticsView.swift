import AppKit
import SwiftUI

struct LockDiagnosticsView: View {
    @ObservedObject var model: AppModel

    private let settingFields: [(key: String, title: String, placeholder: String)] = [
        ("screenSaverDelay", "屏保启动时间", "例如：永不 / 5 分钟"),
        ("displayIdleOnBattery", "电池显示器关闭", "例如：永不 / 10 分钟"),
        ("displayIdleOnAC", "电源显示器关闭", "例如：永不 / 10 分钟"),
        ("passwordDelay", "密码要求", "例如：立即 / 5 秒"),
        ("triggerCorners", "触发角", "例如：未设置"),
        ("lidClosed", "合盖状态", "例如：未合盖")
    ]

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                symptomPicker
                incidentTime
                settingsGrid
                actionRow
                reportSummary
                comparisonNotes
            }
            .padding(.top, 4)
        } label: {
            Label("排查意外锁屏", systemImage: "lock.trianglebadge.exclamationmark")
                .font(.headline)
        }
    }

    private var symptomPicker: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("实际观察到的现象")
                .frame(width: 126, alignment: .leading)
            Picker("实际观察到的现象", selection: $model.lockSymptom) {
                ForEach(LockSymptom.allCases, id: \.self) { symptom in
                    Text(symptom.displayName).tag(symptom)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            Spacer()
        }
    }

    private var incidentTime: some View {
        VStack(alignment: .leading, spacing: 5) {
            Toggle("我知道大致发生时间", isOn: $model.lockIncidentDateEnabled)
            if model.lockIncidentDateEnabled {
                DatePicker(
                    "事件时间",
                    selection: $model.lockIncidentDate,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .datePickerStyle(.compact)
            }
            Text("时间由用户提供，只用于限定系统日志回溯范围。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var settingsGrid: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("可选：填写你在系统设置中看到的选项")
                .font(.subheadline.weight(.semibold))
            LazyVGrid(
                columns: [
                    GridItem(.flexible(minimum: 180), alignment: .leading),
                    GridItem(.flexible(minimum: 180), alignment: .leading)
                ],
                alignment: .leading,
                spacing: 7
            ) {
                ForEach(settingFields, id: \.key) { field in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(field.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField(
                            field.placeholder,
                            text: settingBinding(for: field.key)
                        )
                        .textFieldStyle(.roundedBorder)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var actionRow: some View {
        HStack(spacing: 8) {
            if model.isCapturingLockDiagnostic {
                ProgressView()
                    .controlSize(.small)
                Text("正在读取系统状态和有限日志…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("取消") {
                    model.cancelLockBehaviorDiagnostic()
                }
                .buttonStyle(.bordered)
            } else {
                Button("读取当前状态") {
                    model.captureLockBehaviorDiagnostic()
                }
                .buttonStyle(.bordered)
                .disabled(model.isProcessing)
                Button("导出诊断报告") {
                    model.exportLockBehaviorDiagnostic()
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isProcessing)
            }
            Button("打开诊断文件夹") {
                model.openDiagnosticsFolder()
            }
            .buttonStyle(.link)
            Button("打开最近报告") {
                model.openLockBehaviorReport()
            }
            .buttonStyle(.link)
            .disabled(model.lockBehaviorReportURL == nil)
        }
        Text("仅保存在本地；系统日志和手填内容可能含个人信息，分享前请检查报告。")
            .font(.caption2)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var reportSummary: some View {
        if let report = model.lockBehaviorReport {
            VStack(alignment: .leading, spacing: 4) {
                Text("最近报告：\(report.reportedSymptom.displayName) · \(confidenceText(report.confidence))")
                    .font(.caption.weight(.semibold))
                Text(
                    "系统：\(report.macOSVersion.value ?? "不可用") · " +
                    "架构：\(report.architecture.value ?? "不可用") · " +
                    "电源：\(report.powerSource.value ?? "不可用")"
                )
                Text(
                    "显示器：\(report.displayCount.value.map(String.init) ?? "不可用") · " +
                    "外接：\(report.externalDisplayCount.value.map(String.init) ?? "不可用")"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                if let url = model.lockBehaviorReportURL {
                    Text(url.path)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                } else {
                    Text("已读取状态；点击“导出诊断报告”保存 JSON。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if !report.warnings.isEmpty {
                    DisclosureGroup("诊断提示（\(report.warnings.count)）") {
                        Text(report.warnings.joined(separator: "\n"))
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 3)
                    }
                }
            }
            .padding(8)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
        }
    }

    private var comparisonNotes: some View {
        DisclosureGroup("系统设置对照说明") {
            Text("屏幕保护程序启动、显示器闲置关闭、睡眠，以及关闭后是否要求密码，是可以分别设置的项目。只有出现需要身份验证的会话锁定，才属于真正的锁屏；黑屏、屏保或壁纸切换不能直接判定为锁屏。应用只读取状态和有限日志，不修改节能、安全或屏保设置，也不会安装后台进程。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
    }

    private func settingBinding(for key: String) -> Binding<String> {
        Binding(
            get: { model.lockUserSettings[key, default: ""] },
            set: { model.lockUserSettings[key] = $0 }
        )
    }

    private func confidenceText(_ confidence: LockBehaviorConfidence) -> String {
        switch confidence {
        case .userReported:
            return "用户观察"
        case .insufficient:
            return "证据不足"
        }
    }
}
