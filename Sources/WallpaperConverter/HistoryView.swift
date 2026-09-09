import AppKit
import SwiftUI

struct HistoryView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            if model.isGeneratingPreviews {
                Label("正在生成缺失的首帧预览…", systemImage: "photo.badge.arrow.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if model.archiveEntries.isEmpty {
                emptyState
            } else {
                archiveGrid
                if let selectedArchive = model.selectedArchive {
                    detail(for: selectedArchive)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(28)
        .frame(minWidth: 820, minHeight: 700, alignment: .topLeading)
        .confirmationDialog(
            "删除历史动态壁纸？",
            isPresented: $model.showArchiveDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("删除视频与预览", role: .destructive) { model.deleteArchive() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("将删除“\(model.archiveToDelete?.displayName ?? "此项目")”及其首帧预览，删除后无法通过应用快速替换。")
        }
        .confirmationDialog(
            "确认替换历史动态壁纸？",
            isPresented: $model.showArchiveReplaceConfirmation,
            titleVisibility: .visible
        ) {
            Button("继续替换", role: .destructive) { model.quickReplaceSelectedArchive() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("当前系统动态壁纸会先备份，然后安装选中的历史视频，并重载一次 WallpaperAgent。")
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("历史动态壁纸")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Text("预览、重命名或快速替换已归档的视频壁纸")
                    .foregroundStyle(.secondary)
                Text(AppPaths.archiveDirectory.path)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                Text("已编码壁纸：\(AppPaths.encodedArchiveDirectory.path)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
            Spacer()
            Button {
                model.refreshArchives()
            } label: {
                Label("刷新预览", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(model.isProcessing)
            Button {
                model.openArchiveFolder()
            } label: {
                Label("打开归档文件夹", systemImage: "folder")
            }
            .buttonStyle(.bordered)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 42))
                .foregroundStyle(Color.accentColor)
            Text("还没有历史动态壁纸")
                .font(.headline)
            Text("完成一次新壁纸替换后，原视频和新编码视频都会保存在应用的“壁纸”文件夹中。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("打开归档文件夹") { model.openArchiveFolder() }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, minHeight: 300)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var archiveGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 170, maximum: 230), spacing: 16)],
                spacing: 16
            ) {
                ForEach(model.archiveEntries) { entry in
                    ArchiveThumbnailCard(
                        entry: entry,
                        isSelected: model.selectedArchive?.url == entry.url
                    )
                    .onTapGesture { model.selectArchive(entry) }
                    .contextMenu {
                        Button("打开视频") { model.openArchiveVideo(entry) }
                        Button("显示所在文件夹") { model.revealArchive(entry) }
                        Divider()
                        Button("删除视频与预览", role: .destructive) {
                            model.requestDeleteArchive(entry)
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .frame(maxHeight: 330)
    }

    private func detail(for entry: WallpaperArchiveEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            HStack(alignment: .top, spacing: 20) {
                ArchivePreviewImage(entry: entry)
                    .frame(width: 420, height: 236)

                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 8) {
                        Text(entry.displayName)
                            .font(.headline)
                        Text(entry.kindLabel)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(
                                entry.kind == .encoded
                                    ? Color.accentColor.opacity(0.13)
                                    : Color.primary.opacity(0.08),
                                in: Capsule()
                            )
                    }
                    Text(
                        entry.kind == .encoded
                            ? "这是应用编码并安装过的新壁纸，回退原壁纸后仍可再次使用。"
                            : "这是替换前自动保存的原动态壁纸。"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if let uuid = entry.uuid {
                        Text("目标 UUID：\(uuid)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("该归档缺少目标 UUID，无法自动替换。")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Text(entry.url.path)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)

                    HStack(spacing: 8) {
                        TextField("编辑名称", text: $model.archiveRenameText)
                            .textFieldStyle(.roundedBorder)
                        Button("保存名称") { model.renameSelectedArchive() }
                            .buttonStyle(.bordered)
                            .disabled(model.archiveRenameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isProcessing)
                    }

                    HStack(spacing: 8) {
                        Button("快速替换") { model.requestArchiveReplacement() }
                            .buttonStyle(.borderedProminent)
                            .disabled(entry.uuid == nil || model.isProcessing)
                        Button("打开视频") { model.openArchiveVideo(entry) }
                            .buttonStyle(.bordered)
                        Button("所在文件夹") { model.revealArchive(entry) }
                            .buttonStyle(.bordered)
                    }
                    Button("删除视频与预览", role: .destructive) {
                        model.requestDeleteArchive(entry)
                    }
                    .buttonStyle(.link)
                }
                Spacer(minLength: 0)
            }

            if model.isProcessing,
               case let .running(_, title, detail) = model.phase {
                Label("\(title)：\(detail)", systemImage: "hourglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if case .success = model.phase,
                      let report = model.lastReport,
                      report.isArchiveReplacement {
                Label("历史动态壁纸替换成功，请在系统设置中重新选择它。", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct ArchiveThumbnailCard: View {
    let entry: WallpaperArchiveEntry
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                ArchivePreviewImage(entry: entry)
                    .frame(height: 96)
                Text(entry.kindLabel)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.58), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(7)
            }
            Text(entry.displayName)
                .font(.caption)
                .fontWeight(isSelected ? .semibold : .regular)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(
            isSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    isSelected ? Color.accentColor : Color.primary.opacity(0.08),
                    lineWidth: isSelected ? 2 : 1
                )
        }
    }
}

private struct ArchivePreviewImage: View {
    let entry: WallpaperArchiveEntry

    var body: some View {
        Group {
            if let image = NSImage(contentsOf: entry.previewURL) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(4)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "photo")
                        .font(.title2)
                    Text("暂无预览")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .clipped()
    }
}
