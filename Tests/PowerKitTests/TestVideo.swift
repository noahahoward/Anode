import AVFoundation
import CoreVideo

/// Writes a tiny real H.264 QuickTime movie so the importer and the players are tested against an actual file, not a stand-in.
/// Nothing here plays anything; it only writes a file into the folder it is given.
enum TestVideo {
    enum Failure: Error { case writer(String) }

    @discardableResult
    static func make(seconds: Double, width: Int = 64, height: Int = 64, fps: Int = 10,
                     in dir: URL, name: String = "clip.mov") async throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        guard writer.canAdd(input) else { throw Failure.writer("cannot add input") }
        writer.add(input)
        guard writer.startWriting() else { throw Failure.writer(writer.error?.localizedDescription ?? "startWriting") }
        writer.startSession(atSourceTime: .zero)

        let frames = max(1, Int((seconds * Double(fps)).rounded()))
        for i in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            guard let pool = adaptor.pixelBufferPool else { throw Failure.writer("no pixel buffer pool") }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let pb = buffer else { throw Failure.writer("no pixel buffer") }
            CVPixelBufferLockBaseAddress(pb, [])
            if let base = CVPixelBufferGetBaseAddress(pb) {
                // A colour that changes frame to frame, so the clip is not one repeated frame.
                memset(base, Int32((i * 23) % 256), CVPixelBufferGetBytesPerRow(pb) * height)
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw Failure.writer(writer.error?.localizedDescription ?? "not completed") }
        return url
    }
}
