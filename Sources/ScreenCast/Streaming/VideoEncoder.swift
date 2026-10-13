import Foundation
import VideoToolbox

enum EncoderError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let what): "Couldn't start the \(what) encoder."
        }
    }
}

/// Hardware H.264 encoding tuned for mirroring: real time, no frame reordering, no buffering.
/// Output is Annex B (start codes) with SPS/PPS in front of every key frame, as Cast receivers expect.
final class VideoEncoder: @unchecked Sendable {  // state is confined to `queue`, except the copy bookkeeping (locked)
    /// Called on a VideoToolbox thread for every encoded frame.
    /// `isCopy` marks the copies used to push a frame out of the encoder (see `encode`).
    var onEncodedFrame: ((_ data: Data, _ isKeyFrame: Bool, _ isCopy: Bool, _ presentationTime: CMTime) -> Void)?

    private let session: VTCompressionSession
    /// Every frame reaches the encoder from this queue, so captured frames and push-out copies can't
    /// collide or arrive out of order.
    private let queue = DispatchQueue(label: "VideoEncoder", qos: .userInteractive)
    private var forceKeyFrame = false
    private var latestFrame: CVPixelBuffer?
    private var latestTime = CMTime.negativeInfinity
    private var framesSubmitted = 0
    private var copiesSubmitted = 0
    private var lastWasCopy = false
    // Copy bookkeeping, shared with VideoToolbox's output thread.
    private let copyLock = NSLock()
    private var lastCopyOut = 0
    /// For a copy still in the encoder when the next frame arrives: show it just before that frame.
    private var copyShowTimes: [Int: CMTime] = [:]

    init(width: Int, height: Int, frameRate: Int, bitRate: Int) throws {
        var session: VTCompressionSession?
        let specification = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true] as CFDictionary
        guard VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
                                         codecType: kCMVideoCodecType_H264, encoderSpecification: specification,
                                         imageBufferAttributes: nil, compressedDataAllocator: nil,
                                         outputCallback: nil, refcon: nil, compressionSessionOut: &session) == noErr,
              let session else { throw EncoderError.unavailable("video") }
        self.session = session

        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_High_AutoLevel,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_MaxFrameDelayCount: 0,
            kVTCompressionPropertyKey_ExpectedFrameRate: frameRate,
            kVTCompressionPropertyKey_AverageBitRate: bitRate,
            // Cap bursts so a busy screen doesn't flood the Wi-Fi.
            kVTCompressionPropertyKey_DataRateLimits: [bitRate * 3 / 2 / 8, 1] as CFArray,
            // The receiver asks for key frames when it needs one; this is just a safety net.
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 10,
            kVTCompressionPropertyKey_ColorPrimaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
            kVTCompressionPropertyKey_TransferFunction: kCVImageBufferTransferFunction_ITU_R_709_2,
            kVTCompressionPropertyKey_YCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
        ]
        for (key, value) in properties {
            // Some encoders don't support every property; the defaults are fine when one is refused.
            VTSessionSetProperty(session, key: key, value: value as CFTypeRef)
        }
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    deinit {
        VTCompressionSessionInvalidate(session)
    }

    /// Makes the next captured frame a key frame. Any thread.
    func requestKeyFrame() {
        queue.async { self.forceKeyFrame = true }
    }

    /// Encodes a captured frame. Any thread.
    func encode(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        queue.async { [self] in
            submit(pixelBuffer, at: presentationTime, isCopy: false)
            // The hardware encoder holds each frame until the next one arrives, which on a still screen could be
            // seconds. If nothing new comes within 25 ms (a little over a frame at 60 fps), feed it a copy of the
            // frame to push the real one out.
            // The copy encodes to a few bytes and is sent like any other frame, keeping the TV's decoder in step.
            let submitted = framesSubmitted
            queue.asyncAfter(deadline: .now() + .milliseconds(25)) { [weak self] in
                guard let self, framesSubmitted == submitted, let latestFrame else { return }
                submit(latestFrame, at: CMClockGetTime(CMClockGetHostTimeClock()), isCopy: true)
            }
        }
    }

    private func submit(_ pixelBuffer: CVPixelBuffer, at time: CMTime, isCopy: Bool) {
        // Timestamps must keep increasing, even if a captured frame was stamped just before a copy.
        latestTime = max(time, latestTime + CMTime(value: 1, timescale: 90_000))
        let keyFrame = forceKeyFrame && !isCopy
        var copy = 0
        if isCopy {
            copiesSubmitted += 1
            copy = copiesSubmitted
        } else {
            latestFrame = pixelBuffer
            framesSubmitted += 1
            forceKeyFrame = false
            if lastWasCopy {
                let showTime = latestTime - CMTime(value: 1, timescale: 90_000)
                copyLock.withLock {
                    if lastCopyOut < copiesSubmitted { copyShowTimes[copiesSubmitted] = showTime }
                }
            }
        }
        lastWasCopy = isCopy

        let options = keyFrame ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        VTCompressionSessionEncodeFrame(session, imageBuffer: pixelBuffer, presentationTimeStamp: latestTime,
                                        duration: .invalid, frameProperties: options, infoFlagsOut: nil) {
            [weak self] status, _, sample in
            guard let self, status == noErr, let sample, let (data, isKeyFrame) = Self.annexB(from: sample) else { return }
            // A copy usually comes out late, when the next frame pushes it; show it just before that frame.
            // If it came out on its own, its own timestamp is already in order.
            var time = sample.presentationTimeStamp
            if isCopy {
                copyLock.withLock {
                    self.lastCopyOut = copy
                    if let showTime = self.copyShowTimes.removeValue(forKey: copy) { time = showTime }
                }
            }
            onEncodedFrame?(data, isKeyFrame, isCopy, time)
        }
    }

    /// Converts VideoToolbox's length-prefixed NAL units into an Annex B byte stream.
    private static func annexB(from sample: CMSampleBuffer) -> (Data, Bool)? {
        guard let block = sample.dataBuffer, let format = sample.formatDescription else { return nil }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let isKeyFrame = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool != true
        let startCode: [UInt8] = [0, 0, 0, 1]
        var output = Data()

        var parameterSetCount = 0
        var lengthSize: Int32 = 4
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                           parameterSetSizeOut: nil, parameterSetCountOut: &parameterSetCount,
                                                           nalUnitHeaderLengthOut: &lengthSize)
        if isKeyFrame {
            for index in 0..<parameterSetCount {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index,
                                                                         parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                                                                         parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
                      let pointer else { return nil }
                output.append(contentsOf: startCode)
                output.append(pointer, count: size)
            }
        }

        let length = CMBlockBufferGetDataLength(block)
        var bytes = [UInt8](repeating: 0, count: length)
        guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &bytes) == noErr else { return nil }
        var offset = 0
        let prefix = Int(lengthSize)
        while offset + prefix <= length {
            let nalLength = bytes[offset..<offset + prefix].reduce(0) { $0 << 8 | Int($1) }
            offset += prefix
            guard nalLength > 0, offset + nalLength <= length else { break }
            output.append(contentsOf: startCode)
            output.append(contentsOf: bytes[offset..<offset + nalLength])
            offset += nalLength
        }
        return (output, isKeyFrame)
    }
}
