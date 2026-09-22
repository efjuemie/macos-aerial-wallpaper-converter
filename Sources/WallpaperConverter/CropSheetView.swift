import AppKit
import Foundation
import SwiftUI

struct CropSheetView: View {
    @ObservedObject var model: AppModel
    @State private var previewData: Data?
    @State private var previewLoadFailed = false
    @State private var zoomFactor = 1.0

    var body: some View {
        let availableHeight = NSScreen.main?.visibleFrame.height ?? 840
        let availableWidth = NSScreen.main?.visibleFrame.width ?? 760
        let sheetWidth = max(360, min(760, availableWidth - 40))
        let sheetHeight = max(360, min(840, availableHeight - 80))
        VStack(alignment: .leading, spacing: 16) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("调整动态壁纸画面")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                        Text("输入视频、目标画布或主显示器比例不同时，裁剪框会锁定为屏幕比例；拖动白框选择取景，并用滑块控制显示范围。")
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
                                if previewLoadFailed {
                                    Image(systemName: "photo.badge.exclamationmark")
                                        .font(.title2)
                                    Text("首帧预览生成失败；仍可使用取景范围和默认裁剪继续。")
                                        .font(.caption)
                                        .multilineTextAlignment(.center)
                                        .foregroundStyle(.secondary)
                                } else {
                                    ProgressView()
                                    Text("正在生成视频首帧预览…")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 360)
                            .background(Color.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                        }

                        let maxSelection = WallpaperGeometry.maximumSelection(for: selection)
                        let originRange = WallpaperGeometry.achievableOriginRange(for: selection)
                        let screenSnapshots = GeometryDiagnostics.currentScreens()
                        let screen = screenSnapshots.first(where: \.isMain)
                        let orientation = model.pendingCropOrientation ?? GeometryDiagnostics.orientationAssessment(
                            sourceSize: GeometrySize(width: selection.sourceWidth, height: selection.sourceHeight),
                            screens: screenSnapshots,
                            targetProfile: nil,
                            referenceOriginalProfile: nil,
                            chosenCanvas: AerialCanvas(width: selection.outputWidth, height: selection.outputHeight),
                            chosenSource: model.lastGeometrySource.flatMap(NativeCanvasSource.init(rawValue:)),
                            manifestCanvas: nil
                        )

                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("原视频：\(info.width) × \(info.height)")
                                Spacer()
                                Text("主显示器：\(screen.map { "\($0.pixelWidth) × \($0.pixelHeight)" } ?? "未知")")
                            }
                            HStack {
                                Text("目标编码画布：\(selection.outputWidth) × \(selection.outputHeight)")
                                Spacer()
                                Text("画布来源：\(model.lastGeometrySource.flatMap(NativeCanvasSource.init(rawValue:))?.displayName ?? "未知")")
                            }
                            HStack {
                                Text("当前取景：\(Int(selection.cropWidth.rounded())) × \(Int(selection.cropHeight.rounded()))")
                                Spacer()
                                Text("最大合法取景：\(maxSelection.map { "\(Int($0.cropWidth.rounded())) × \(Int($0.cropHeight.rounded()))" } ?? "不可用")")
                            }
                            Text(
                                "方向：源视频 \(orientation.sourceOrientation.displayName) · " +
                                "目标画布 \(orientation.chosenCanvasOrientation.displayName) · " +
                                "主显示器 \(orientation.screenOrientation.displayName)"
                            )
                            if let originRange {
                                let movementWidth = max(0, originRange.maxX - originRange.minX)
                                let movementHeight = max(0, originRange.maxY - originRange.minY)
                                HStack {
                                    Text("可移动范围：X \(originRangeText(originRange.minX, originRange.maxX))")
                                    Spacer()
                                    Text("Y \(originRangeText(originRange.minY, originRange.maxY))")
                                }
                                .foregroundStyle(.secondary)
                                HStack {
                                    Text(movementWidth <= 2 ? "X 方向已锁定" : "X 可移动 \(Int(movementWidth.rounded())) px")
                                    Spacer()
                                    Text(movementHeight <= 2 ? "Y 方向已锁定" : "Y 可移动 \(Int(movementHeight.rounded())) px")
                                }
                                .foregroundStyle(.secondary)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        HStack(spacing: 10) {
                            Text("显示更多")
                                .font(.caption)
                            Slider(value: $zoomFactor, in: 1...3, step: 0.01)
                                .onChange(of: zoomFactor) { value in
                                    model.updatePendingCropZoom(zoomFactor: value)
                                }
                            Text("放大主体")
                                .font(.caption)
                            Text("×\(zoomFactor, specifier: "%.2f")")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }

                        HStack {
                            Button("重置为最大范围并居中") {
                                zoomFactor = 1
                                model.resetPendingCrop()
                            }
                            .buttonStyle(.bordered)
                            Spacer()
                            Text("比例 \(aspectText(selection.cropWidth / selection.cropHeight))（固定）")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        if let warning = model.pendingCropWarning ?? orientation.warningMessage {
                            Label(warning, systemImage: orientation.shouldBlockProcessing ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(orientation.shouldBlockProcessing ? .red : .orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        Text("无法读取裁剪信息，请重新选择视频。")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 360)
                    }

                    Text("预览使用视频首帧；确认后会对整个动态视频使用同一裁剪区域。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)

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
        .frame(width: sheetWidth, height: sheetHeight)
        .task(id: model.inputInfo?.url) {
            previewData = nil
            previewLoadFailed = false
            zoomFactor = 1
            guard let url = model.inputInfo?.url else {
                previewLoadFailed = true
                return
            }
            do {
                previewData = try await PreviewService.firstFrameJPEG(from: url)
            } catch {
                previewLoadFailed = true
            }
        }
        .onAppear {
            if let selection = model.pendingCropSelection {
                zoomFactor = Self.zoomFactor(for: selection)
            }
        }
        .onChange(of: model.pendingCropSelection) { selection in
            guard let selection else { return }
            zoomFactor = Self.zoomFactor(for: selection)
        }
    }

    private func aspectText(_ aspect: Double) -> String {
        String(format: "%.2f:1", aspect)
    }

    private func originRangeText(_ minValue: Double, _ maxValue: Double) -> String {
        "\(Int(minValue.rounded()))–\(Int(maxValue.rounded()))"
    }

    private static func zoomFactor(for selection: WallpaperCropSelection) -> Double {
        guard let maximum = WallpaperGeometry.maximumSelection(for: selection),
              selection.cropWidth > 1,
              selection.cropHeight > 1 else {
            return 1
        }
        let factor = max(
            maximum.cropWidth / selection.cropWidth,
            maximum.cropHeight / selection.cropHeight
        )
        return min(3, max(1, factor))
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
                let sourceSize = CGSize(
                    width: CGFloat(selection.sourceWidth),
                    height: CGFloat(selection.sourceHeight)
                )
                let displayRect = Self.fittedRect(imageSize: sourceSize, containerSize: geometry.size)
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
                        .aspectRatio(contentMode: .fit)
                        .frame(width: displayRect.width, height: displayRect.height)
                        .position(x: displayRect.midX, y: displayRect.midY)

                    Path { path in
                        path.addRect(CGRect(origin: .zero, size: geometry.size))
                        path.addRect(cropRect)
                    }
                    .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))

                    Rectangle()
                        .fill(Color.clear)
                        .frame(
                            width: max(cropRect.width + 24, 44),
                            height: max(cropRect.height + 24, 44)
                        )
                        .contentShape(Rectangle())
                        .overlay {
                            Rectangle()
                                .stroke(Color.white, lineWidth: 2)
                                .frame(width: cropRect.width, height: cropRect.height)
                        }
                        .position(x: cropRect.midX, y: cropRect.midY)
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
