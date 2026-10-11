import AVFoundation

/// Encodes system audio into 10 ms Opus packets, the format Chrome's mirroring uses.
/// Not thread-safe: use it from a single queue.
final class AudioEncoder {
    static let sampleRate = 48_000
    static let samplesPerPacket = 480  // 10 ms

    /// Called for each encoded packet with the capture time of its first sample.
    var onPacket: ((_ data: Data, _ time: CMTime) -> Void)?

    private let pcmFormat = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 2)!
    private let converter: AVAudioConverter
    private let chunk: AVAudioPCMBuffer
    private var left: [Float] = []
    private var right: [Float] = []
    /// Capture time of the first sample in `left`/`right`.
    private var bufferStart: CMTime?

    init(bitRate: Int = 128_000) throws {
        var description = AudioStreamBasicDescription(
            mSampleRate: Double(Self.sampleRate), mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(Self.samplesPerPacket), mBytesPerFrame: 0, mChannelsPerFrame: 2,
            mBitsPerChannel: 0, mReserved: 0)
        guard let opus = AVAudioFormat(streamDescription: &description),
              let converter = AVAudioConverter(from: pcmFormat, to: opus),
              let chunk = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(Self.samplesPerPacket))
        else { throw EncoderError.unavailable("audio") }
        converter.bitRate = bitRate
        self.converter = converter
        self.chunk = chunk
    }

    func append(_ sample: CMSampleBuffer) {
        let frames = sample.numSamples
        guard frames > 0,
              let input = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(frames)) else { return }
        input.frameLength = AVAudioFrameCount(frames)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames),
                                                           into: input.mutableAudioBufferList) == noErr,
              let channels = input.floatChannelData else { return }

        // ScreenCaptureKit skips audio while the Mac is silent. After a gap, start a fresh timeline.
        let time = sample.presentationTimeStamp
        if let bufferStart {
            let expected = bufferStart + CMTime(value: CMTimeValue(left.count), timescale: CMTimeScale(Self.sampleRate))
            if abs((time - expected).seconds) > 0.02 { restart(at: time) }
        } else {
            restart(at: time)
        }
        left.append(contentsOf: UnsafeBufferPointer(start: channels[0], count: frames))
        right.append(contentsOf: UnsafeBufferPointer(start: channels[1], count: frames))

        while left.count >= Self.samplesPerPacket, let start = bufferStart {
            encodeChunk(at: start)
            left.removeFirst(Self.samplesPerPacket)
            right.removeFirst(Self.samplesPerPacket)
            bufferStart = start + CMTime(value: CMTimeValue(Self.samplesPerPacket), timescale: CMTimeScale(Self.sampleRate))
        }
    }

    private func restart(at time: CMTime) {
        left.removeAll(keepingCapacity: true)
        right.removeAll(keepingCapacity: true)
        bufferStart = time
        converter.reset()
    }

    private func encodeChunk(at time: CMTime) {
        chunk.frameLength = AVAudioFrameCount(Self.samplesPerPacket)
        left.withUnsafeBufferPointer { chunk.floatChannelData![0].update(from: $0.baseAddress!, count: Self.samplesPerPacket) }
        right.withUnsafeBufferPointer { chunk.floatChannelData![1].update(from: $0.baseAddress!, count: Self.samplesPerPacket) }

        let output = AVAudioCompressedBuffer(format: converter.outputFormat, packetCapacity: 1,
                                             maximumPacketSize: converter.maximumOutputPacketSize)
        var supplied = false
        let status = converter.convert(to: output, error: nil) { [chunk] _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return chunk
        }
        guard status != .error, output.packetCount > 0 else { return }
        onPacket?(Data(bytes: output.data, count: Int(output.byteLength)), time)
    }
}
