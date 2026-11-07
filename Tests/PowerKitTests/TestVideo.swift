import AVFoundation
import CoreVideo

/// Writes a tiny real H.264 QuickTime movie so the importer and the players are tested against an actual file, not a stand-in.
/// Nothing here plays anything; it only writes a file into the folder it is given.
enum TestVideo {
    enum Failure: Error { case writer(String) }

    @discardableResult
    static func make(seconds: Double, width: Int = 64, height: Int = 64, fps: Int = 10, audio: Bool = false,
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
        var audioInput: AVAssetWriterInput?
        if audio {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false])
            guard writer.canAdd(a) else { throw Failure.writer("cannot add audio input") }
            writer.add(a)
            audioInput = a
        }
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
        if let audioInput {
            // One second of silence per second of video, in one-second buffers.
            for second in 0..<max(1, Int(seconds.rounded(.up))) {
                while !audioInput.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
                audioInput.append(try silence(startingAt: second))
            }
            audioInput.markAsFinished()
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw Failure.writer(writer.error?.localizedDescription ?? "not completed") }
        return url
    }

    /// One second of 44.1 kHz mono 16-bit silence as a sample buffer.
    private static func silence(startingAt second: Int) throws -> CMSampleBuffer {
        let frames = 44100, bytes = frames * 2
        var asbd = AudioStreamBasicDescription(mSampleRate: 44100, mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                                               mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
                                               mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                             magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr, let format else {
            throw Failure.writer("no audio format")
        }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == noErr, let block else { throw Failure.writer("no block") }
        CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes)
        var sample: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: frames,
            presentationTimeStamp: CMTime(value: CMTimeValue(second), timescale: 1), packetDescriptions: nil,
            sampleBufferOut: &sample) == noErr, let sample else { throw Failure.writer("no sample buffer") }
        return sample
    }
}
