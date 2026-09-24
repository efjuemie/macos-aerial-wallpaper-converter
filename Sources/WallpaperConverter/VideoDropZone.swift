import SwiftUI
import UniformTypeIdentifiers

/// A non-editable drop target kept separate from the path TextField.
///
/// Finder can deliver a dropped file as text to an NSTextField. Keeping this
/// target independent makes the file-drop route deterministic while the path
/// field remains available for explicit typing, pasting, and submission.
struct VideoDropZone: View {
    @Binding var isTargeted: Bool
    let loadedFileName: String?
    let isInspecting: Bool
    let onDrop: ([NSItemProvider]) -> Bool

    private static let supportedTypeIdentifiers = [
        UTType.fileURL.identifier,
        UTType.url.identifier,
        UTType.text.identifier
    ]

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: isTargeted ? "arrow.down.doc.fill" : "arrow.down.doc")
                .font(.title2)
                .foregroundStyle(Color.accentColor)

            if isInspecting {
                Text("正在读取视频信息…")
                    .font(.subheadline.weight(.medium))
            } else if let loadedFileName {
                Text("已载入：\(loadedFileName)")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
            } else if isTargeted {
                Text("松开以载入视频")
                    .font(.subheadline.weight(.medium))
            } else {
                Text("将本地视频拖到这里")
                    .font(.subheadline.weight(.medium))
            }

            Text("支持 MOV / MP4 / M4V")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 92)
        .padding(.horizontal, 16)
        .background(
            (isTargeted ? Color.accentColor.opacity(0.18) : Color.accentColor.opacity(0.07)),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.accentColor.opacity(0.35),
                    style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: [6])
                )
        }
        .contentShape(Rectangle())
        .onDrop(
            of: Self.supportedTypeIdentifiers,
            isTargeted: $isTargeted,
            perform: onDrop
        )
    }
}
