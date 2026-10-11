import AppKit
import AVFoundation

/// A moving test card with a running clock and a beep at the top of each second. Used to check the
/// connection to a TV, and to measure delay and lip sync, without capturing the screen.
final class TestPattern: @unchecked Sendable {  // state is confined to `queue`
    var onVideoFrame: ((_ frame: CVPixelBuffer, _ time: CMTime, _ keyFrame: Bool) -> Void)?
    var onAudio: ((CMSampleBuffer) -> Void)?

    private let width: Int
    private let height: Int
    private let queue = DispatchQueue(label: "TestPattern", qos: .userInteractive)
    private let audioFormat = AVAudioFormat(standardFormatWithSampleRate: Double(AudioEncoder.sampleRate), channels: 2)!
    private var pool: CVPixelBufferPool?
    private var timer: DispatchSourceTimer?
    private var frameNumber = 0
    private var audioStart: CMTime?
    private var audioSamples: Int64 = 0

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        CVPixelBufferPoolCreate(nil, nil, [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:],
        ] as CFDictionary, &pool)
    }

    func start(frameRate: Int) {
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.schedule(deadline: .now(), repeating: 1 / Double(frameRate))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        queue.async { self.timer?.cancel() }
    }

    private func tick() {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        if let frame = drawFrame() { onVideoFrame?(frame, now, false) }
        emitAudio(upTo: now)
        frameNumber += 1
    }

    private func drawFrame() -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }

        let w = CGFloat(width), h = CGFloat(height)
        context.setFillColor(NSColor(hue: CGFloat(frameNumber % 600) / 600, saturation: 0.5, brightness: 0.35, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // A bar sweeping across once a second makes stutter and delay easy to see.
        let sweep = CGFloat(frameNumber % 30) / 30
        context.setFillColor(.white)
        context.fill(CGRect(x: sweep * (w - w / 30), y: 0, width: w / 30, height: h / 6))

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let clock = NSAttributedString(string: formatter.string(from: Date()), attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: h / 6, weight: .bold),
            .foregroundColor: NSColor.white,
        ])
        clock.draw(at: CGPoint(x: (w - clock.size().width) / 2, y: h * 0.4))
        let caption = NSAttributedString(string: "Screen Cast test pattern · frame \(frameNumber)", attributes: [
            .font: NSFont.systemFont(ofSize: h / 24),
            .foregroundColor: NSColor.white.withAlphaComponent(0.8),
        ])
        caption.draw(at: CGPoint(x: (w - caption.size().width) / 2, y: h * 0.3))
        NSGraphicsContext.restoreGraphicsState()
        return buffer
    }

    /// Generates audio up to `now`: a short 880 Hz beep at the start of every second, silence otherwise.
    private func emitAudio(upTo now: CMTime) {
        let rate = Int64(AudioEncoder.sampleRate)
        if audioStart == nil { audioStart = now }
        guard let audioStart else { return }
        let target = Int64((now - audioStart).seconds * Double(rate))
        let count = Int(target - audioSamples)
        guard count > 0, let pcm = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: AVAudioFrameCount(count)),
              let channels = pcm.floatChannelData else { return }
        pcm.frameLength = AVAudioFrameCount(count)
        let wallStart = Date().timeIntervalSince1970 - Double(count) / Double(rate)
        for i in 0..<count {
            let t = wallStart + Double(i) / Double(rate)
            let inBeep = t - t.rounded(.down) < 0.1
            let value = inBeep ? Float(sin(2 * .pi * 880 * t) * 0.3) : 0
            channels[0][i] = value
            channels[1][i] = value
        }
        let time = audioStart + CMTime(value: audioSamples, timescale: CMTimeScale(rate))
        audioSamples = target

        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(rate)),
                                        presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil,
                                   refcon: nil, formatDescription: audioFormat.formatDescription,
                                   sampleCount: count, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                   sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample) == noErr,
              let sample,
              CMSampleBufferSetDataBufferFromAudioBufferList(sample, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
                                                             flags: 0, bufferList: pcm.audioBufferList) == noErr
        else { return }
        onAudio?(sample)
    }
}
