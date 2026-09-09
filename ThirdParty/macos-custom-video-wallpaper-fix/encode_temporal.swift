import Foundation
import AVFoundation
import VideoToolbox
import CoreMedia

// usage: encode_temporal <input.mov> <output.mov> [loopCount] [bitrateMbps]
let args = CommandLine.arguments
guard args.count >= 3 else { FileHandle.standardError.write("usage: encode_temporal in out [loops] [mbps]\n".data(using:.utf8)!); exit(2) }
let inURL = URL(fileURLWithPath: args[1])
let outURL = URL(fileURLWithPath: args[2])
let loopCount = args.count >= 4 ? max(1, Int(args[3]) ?? 1) : 1
let bitrate = args.count >= 5 ? (Int(args[4]) ?? 10) * 1_000_000 : 10_000_000
try? FileManager.default.removeItem(at: outURL)

let asset = AVURLAsset(url: inURL)
var vtrack: AVAssetTrack!
var natSize = CGSize.zero; var nomFps: Float = 24; var clipDur = CMTime.zero
let sem = DispatchSemaphore(value: 0)
Task {
    vtrack = try await asset.loadTracks(withMediaType: .video).first
    natSize = try await vtrack.load(.naturalSize)
    nomFps = try await vtrack.load(.nominalFrameRate)
    clipDur = try await asset.load(.duration)
    sem.signal()
}
sem.wait()
guard let vtrack = vtrack else { fatalError("no video track") }
let W = Int(natSize.width), H = Int(natSize.height)
if nomFps < 1 { nomFps = 24 }
FileHandle.standardError.write("source \(W)x\(H) @\(nomFps)fps clip=\(CMTimeGetSeconds(clipDur))s loops=\(loopCount) br=\(bitrate)\n".data(using:.utf8)!)

final class StreamWriter {
    let outURL: URL; var writer: AVAssetWriter?; var input: AVAssetWriterInput?
    var started = false; let lock = NSLock(); var appended = 0; var failed = false
    init(_ u: URL) { outURL = u }
    func handle(_ sb: CMSampleBuffer) {
        lock.lock(); defer { lock.unlock() }
        if failed || !CMSampleBufferDataIsReady(sb) { return }
        if !started {
            guard let fmt = CMSampleBufferGetFormatDescription(sb) else { return }
            let w = try! AVAssetWriter(outputURL: outURL, fileType: .mov)
            let inp = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: fmt)
            inp.expectsMediaDataInRealTime = false
            inp.transform = .identity
            w.add(inp); w.startWriting()
            w.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sb))
            writer = w; input = inp; started = true
        }
        while !(input!.isReadyForMoreMediaData) { usleep(500) }
        if !input!.append(sb) { failed = true; FileHandle.standardError.write("append failed: \(String(describing: writer!.error))\n".data(using:.utf8)!) }
        else { appended += 1 }
    }
    func finish() {
        lock.lock(); let w = writer; let inp = input; lock.unlock()
        guard let w = w, let inp = inp else { fatalError("nothing written") }
        inp.markAsFinished()
        let s = DispatchSemaphore(value: 0); w.finishWriting { s.signal() }; s.wait()
        if w.status == .completed { print("OK wrote \(outURL.path), \(appended) frames") }
        else { FileHandle.standardError.write("writer status \(w.status.rawValue) err \(String(describing: w.error))\n".data(using:.utf8)!); exit(1) }
    }
}
let sw = StreamWriter(outURL)

let cb: VTCompressionOutputCallback = { (refCon, _, status, _, sbuf) in
    guard status == noErr, let sbuf = sbuf else { return }
    Unmanaged<StreamWriter>.fromOpaque(refCon!).takeUnretainedValue().handle(sbuf)
}

var session: VTCompressionSession?
let spec: [CFString: Any] = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true]
let cs = VTCompressionSessionCreate(allocator: kCFAllocatorDefault, width: Int32(W), height: Int32(H),
    codecType: kCMVideoCodecType_HEVC, encoderSpecification: spec as CFDictionary, imageBufferAttributes: nil,
    compressedDataAllocator: nil, outputCallback: cb, refcon: Unmanaged.passUnretained(sw).toOpaque(),
    compressionSessionOut: &session)
guard cs == noErr, let session = session else { fatalError("VTCompressionSessionCreate failed \(cs)") }

func setP(_ key: CFString, _ val: CFTypeRef) {
    let s = VTSessionSetProperty(session, key: key, value: val)
    if s != noErr { FileHandle.standardError.write("set \(key) failed: \(s)\n".data(using:.utf8)!) }
}
func setRequiredP(_ key: CFString, _ val: CFTypeRef) {
    let status = VTSessionSetProperty(session, key: key, value: val)
    guard status == noErr else {
        FileHandle.standardError.write("required set \(key) failed: \(status)\n".data(using:.utf8)!)
        exit(1)
    }
}
setP(kVTCompressionPropertyKey_RealTime, kCFBooleanFalse)
setP(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main10_AutoLevel)
setP(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanTrue)
setP(kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: nomFps))
setP(kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: Int(nomFps * 5)))
setP(kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: bitrate))
setP(kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)
setP(kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2)
setP(kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
let cleanAperture: [CFString: Any] = [
    kCMFormatDescriptionKey_CleanApertureWidth: W,
    kCMFormatDescriptionKey_CleanApertureHeight: H,
    kCMFormatDescriptionKey_CleanApertureHorizontalOffset: 0,
    kCMFormatDescriptionKey_CleanApertureVerticalOffset: 0
]
let squarePixelAspect: [CFString: Any] = [
    kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing: 1,
    kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing: 1
]
setRequiredP(kVTCompressionPropertyKey_CleanAperture, cleanAperture as CFDictionary)
setRequiredP(kVTCompressionPropertyKey_PixelAspectRatio, squarePixelAspect as CFDictionary)
// Temporal scalability (2 sub-layers) emits tscl/tsas sample groups.
setP(kVTCompressionPropertyKey_AllowTemporalCompression, kCFBooleanTrue)
setP(kVTCompressionPropertyKey_BaseLayerFrameRate, NSNumber(value: Double(nomFps) / 2.0))
VTCompressionSessionPrepareToEncodeFrames(session)

func makeReader() -> AVAssetReaderTrackOutput {
    let reader = try! AVAssetReader(asset: asset)
    let rout = AVAssetReaderTrackOutput(track: vtrack, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange])
    rout.alwaysCopiesSampleData = false
    reader.add(rout); reader.startReading(); return rout
}

var n = 0
for loop in 0..<loopCount {
    let offset = CMTimeMultiply(clipDur, multiplier: Int32(loop))
    let rout = makeReader()
    while let sbuf = rout.copyNextSampleBuffer() {
        guard let pb = CMSampleBufferGetImageBuffer(sbuf) else { continue }
        let pts = CMTimeAdd(CMSampleBufferGetPresentationTimeStamp(sbuf), offset)
        var dur = CMSampleBufferGetDuration(sbuf)
        if !dur.isValid || dur.value == 0 { dur = CMTimeMake(value: 1, timescale: Int32(nomFps.rounded())) }
        VTCompressionSessionEncodeFrame(session, imageBuffer: pb, presentationTimeStamp: pts, duration: dur,
            frameProperties: nil, sourceFrameRefcon: nil, infoFlagsOut: nil)
        n += 1
    }
    if (loop % 10) == 0 { FileHandle.standardError.write("  loop \(loop)/\(loopCount) fed \(n) frames\n".data(using:.utf8)!) }
}
VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
FileHandle.standardError.write("fed \(n) frames total\n".data(using:.utf8)!)
sw.finish()
