import AVFoundation
import CoreMedia
import Foundation

struct GeometrySnapshot {
    let naturalSize: CGSize
    let preferredTransform: CGAffineTransform
    let encodedSize: CMVideoDimensions
    let cleanAperture: CGRect
    let presentationSize: CGSize
    let pixelAspectRatio: (horizontal: Int, vertical: Int)?
    let hasExplicitCleanAperture: Bool
}

func loadGeometry(at url: URL) async throws -> GeometrySnapshot {
    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: .video).first else {
        throw NSError(domain: "VideoGeometry", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "No video track"
        ])
    }
    let naturalSize = try await track.load(.naturalSize)
    let preferredTransform = try await track.load(.preferredTransform)
    guard let description = try await track.load(.formatDescriptions).first else {
        throw NSError(domain: "VideoGeometry", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "No video format description"
        ])
    }
    let encodedSize = CMVideoFormatDescriptionGetDimensions(description)
    let cleanAperture = CMVideoFormatDescriptionGetCleanAperture(
        description,
        originIsAtTopLeft: true
    )
    let presentationSize = CMVideoFormatDescriptionGetPresentationDimensions(
        description,
        usePixelAspectRatio: true,
        useCleanAperture: true
    )
    let extensions = CMFormatDescriptionGetExtensions(description) as NSDictionary? ?? [:]
    let hasExplicitCleanAperture = extensions[kCMFormatDescriptionExtension_CleanAperture] != nil
    let pixelAspectRatio: (horizontal: Int, vertical: Int)?
    if let values = extensions[kCMFormatDescriptionExtension_PixelAspectRatio] as? NSDictionary,
       let horizontal = values[kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing] as? NSNumber,
       let vertical = values[kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing] as? NSNumber {
        pixelAspectRatio = (horizontal.intValue, vertical.intValue)
    } else {
        pixelAspectRatio = nil
    }
    return GeometrySnapshot(
        naturalSize: naturalSize,
        preferredTransform: preferredTransform,
        encodedSize: encodedSize,
        cleanAperture: cleanAperture,
        presentationSize: presentationSize,
        pixelAspectRatio: pixelAspectRatio,
        hasExplicitCleanAperture: hasExplicitCleanAperture
    )
}

func approximatelyEqual(_ left: CGFloat, _ right: CGFloat) -> Bool {
    abs(left - right) < 0.01
}

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write(
        "Usage: swift Scripts/verify_video_geometry.swift VIDEO [EXPECTED_WIDTH EXPECTED_HEIGHT]\n"
            .data(using: .utf8)!
    )
    exit(2)
}

let videoURL = URL(fileURLWithPath: CommandLine.arguments[1])
let expectedSize: CGSize? = {
    guard CommandLine.arguments.count == 4,
          let width = Double(CommandLine.arguments[2]),
          let height = Double(CommandLine.arguments[3]) else {
        return nil
    }
    return CGSize(width: width, height: height)
}()

let semaphore = DispatchSemaphore(value: 0)
Task {
    defer { semaphore.signal() }
    do {
        let geometry = try await loadGeometry(at: videoURL)
        let transform = geometry.preferredTransform
        let pixelAspect = geometry.pixelAspectRatio.map { "\($0.horizontal):\($0.vertical) (explicit)" } ?? "missing"
        print("file=\(videoURL.path)")
        print("natural=\(Int(geometry.naturalSize.width))x\(Int(geometry.naturalSize.height))")
        print("encoded=\(geometry.encodedSize.width)x\(geometry.encodedSize.height)")
        print("clean=\(Int(geometry.cleanAperture.width))x\(Int(geometry.cleanAperture.height))")
        print("cleanApertureMetadata=\(geometry.hasExplicitCleanAperture ? "explicit" : "missing")")
        print("presentation=\(Int(geometry.presentationSize.width))x\(Int(geometry.presentationSize.height))")
        print("pixelAspect=\(pixelAspect)")
        print("transform=[\(transform.a),\(transform.b),\(transform.c),\(transform.d),\(transform.tx),\(transform.ty)]")

        guard let expectedSize else { return }
        let isIdentity = approximatelyEqual(transform.a, 1)
            && approximatelyEqual(transform.b, 0)
            && approximatelyEqual(transform.c, 0)
            && approximatelyEqual(transform.d, 1)
            && approximatelyEqual(transform.tx, 0)
            && approximatelyEqual(transform.ty, 0)
        let hasExplicitSquarePixels = geometry.pixelAspectRatio.map {
            $0.horizontal == 1 && $0.vertical == 1
        } ?? false
        let matches = approximatelyEqual(geometry.naturalSize.width, expectedSize.width)
            && approximatelyEqual(geometry.naturalSize.height, expectedSize.height)
            && geometry.encodedSize.width == Int32(expectedSize.width)
            && geometry.encodedSize.height == Int32(expectedSize.height)
            && approximatelyEqual(geometry.cleanAperture.width, expectedSize.width)
            && approximatelyEqual(geometry.cleanAperture.height, expectedSize.height)
            && approximatelyEqual(geometry.presentationSize.width, expectedSize.width)
            && approximatelyEqual(geometry.presentationSize.height, expectedSize.height)
            && isIdentity
            && geometry.hasExplicitCleanAperture
            && hasExplicitSquarePixels
        guard matches else {
            FileHandle.standardError.write(
                "FAIL: video geometry lacks the expected full-canvas clean aperture, explicit 1:1 PAR, or identity transform\n".data(using: .utf8)!
            )
            exit(1)
        }
        print("PASS: fixed canvas has explicit full-canvas clean aperture, explicit 1:1 PAR, and identity transform")
    } catch {
        FileHandle.standardError.write("FAIL: \(error.localizedDescription)\n".data(using: .utf8)!)
        exit(1)
    }
}
semaphore.wait()
