import AppKit
import Foundation
import SwiftUI

struct CropSheetView: View {
    @ObservedObject var model: AppModel
    @State private var previewData: Data?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("调整动态壁纸画面")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text("输入视频与主显示器比例不同。裁剪框已锁定为屏幕比例，拖动白框选择取景；不调整时将使用居中裁剪并铺满屏幕。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let info = model.inputInfo,
               let selection = model.pendingCropSelection {
                if let previewData {
                    CropPreviewCanvas(
                        previewData: previewData,
                        selection: selection,
                        onMove: { originX, originY in
                            model.updatePendingCrop(originX: originX, originY: originY)
                        }
                    )
                    .frame(maxWidth: .infinity)
                    .frame(height: 360)
                } else {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("正在生成视频首帧预览…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 360)
                    .background(Color.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                }

                HStack {
                    Text("原视频：\(info.width) × \(info.height)")
                    Spacer()
                    Text("目标编码画布：\(selection.outputWidth) × \(selection.outputHeight)")
                    Text("比例 \(aspectText(selection.cropWidth / selection.cropHeight))")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Text("无法读取裁剪信息，请重新选择视频。")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 360)
            }

            Text("预览使用视频首帧；确认后会对整个动态视频使用同一裁剪区域。")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("取消", role: .cancel) {
                    model.cancelCropSelection()
                }
                Button("下一步") {
                    model.continueWithCropSelection()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 760, height: 620)
        .task(id: model.inputInfo?.url) {
            previewData = nil
            guard let url = model.inputInfo?.url else { return }
            previewData = try? await PreviewService.firstFrameJPEG(from: url)
        }
    }

    private func aspectText(_ aspect: Double) -> String {
        String(format: "%.2f:1", aspect)
    }
}

private struct CropPreviewCanvas: View {
    let previewData: Data
    let selection: WallpaperCropSelection
    let onMove: (Double, Double) -> Void

    @State private var dragStart: CGPoint?

    var body: some View {
        GeometryReader { geometry in
            if let image = NSImage(data: previewData),
               image.size.width > 0,
               image.size.height > 0 {
                let displayRect = Self.fittedRect(imageSize: image.size, containerSize: geometry.size)
                let scaleX = displayRect.width / CGFloat(selection.sourceWidth)
                let scaleY = displayRect.height / CGFloat(selection.sourceHeight)
                let cropRect = CGRect(
                    x: displayRect.minX + CGFloat(selection.originX) * scaleX,
                    y: displayRect.minY + CGFloat(selection.originY) * scaleY,
                    width: CGFloat(selection.cropWidth) * scaleX,
                    height: CGFloat(selection.cropHeight) * scaleY
                )

                ZStack {
                    Color.black
                    Image(nsImage: image)
                        .resizable()
                        .frame(width: displayRect.width, height: displayRect.height)
                        .position(x: displayRect.midX, y: displayRect.midY)

                    Path { path in
                        path.addRect(CGRect(origin: .zero, size: geometry.size))
                        path.addRect(cropRect)
                    }
                    .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))

                    Rectangle()
                        .stroke(Color.white, lineWidth: 2)
                        .frame(width: cropRect.width, height: cropRect.height)
                        .position(x: cropRect.midX, y: cropRect.midY)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    guard scaleX > 0, scaleY > 0 else { return }
                                    let start = dragStart ?? CGPoint(
                                        x: selection.originX,
                                        y: selection.originY
                                    )
                                    if dragStart == nil {
                                        dragStart = start
                                    }
                                    guard let range = WallpaperGeometry.achievableOriginRange(
                                        for: selection
                                    ) else { return }
                                    let originX = min(
                                        max(range.minX, Double(start.x) + Double(value.translation.width) / Double(scaleX)),
                                        range.maxX
                                    )
                                    let originY = min(
                                        max(range.minY, Double(start.y) + Double(value.translation.height) / Double(scaleY)),
                                        range.maxY
                                    )
                                    onMove(originX, originY)
                                }
                                .onEnded { _ in
                                    dragStart = nil
                                }
                        )
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.primary.opacity(0.12))
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "photo")
                        .font(.title2)
                    Text("无法生成首帧预览，但仍可使用默认居中裁剪。")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private static func fittedRect(imageSize: CGSize, containerSize: CGSize) -> CGRect {
        let inset: CGFloat = 12
        let availableWidth = max(1, containerSize.width - inset * 2)
        let availableHeight = max(1, containerSize.height - inset * 2)
        let scale = min(
            availableWidth / imageSize.width,
            availableHeight / imageSize.height
        )
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        return CGRect(
            x: (containerSize.width - width) / 2,
            y: (containerSize.height - height) / 2,
            width: width,
            height: height
        )
    }
}
