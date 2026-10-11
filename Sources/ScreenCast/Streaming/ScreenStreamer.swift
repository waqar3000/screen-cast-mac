import ScreenCaptureKit

/// Captures one display (plus system audio) with ScreenCaptureKit and hands frames and audio to the callbacks.
final class ScreenStreamer: NSObject, @unchecked Sendable {  // state is confined to `queue`
    static let frameRate = 60

    /// Called on the capture queue for each new screen image, with its capture time and
    /// whether it should be sent as a fresh, full-detail key frame.
    var onVideoFrame: ((_ frame: CVPixelBuffer, _ time: CMTime, _ keyFrame: Bool) -> Void)?
    /// Called on the capture queue with system audio.
    var onAudio: ((CMSampleBuffer) -> Void)?
    /// Called on the main queue if capture stops on its own.
    var onFailure: ((Error) -> Void)?

    private let queue = DispatchQueue(label: "ScreenStreamer", qos: .userInteractive)
    private var stream: SCStream?
    private var refreshTimer: DispatchSourceTimer?
    private var latestFrame: CVPixelBuffer?
    private var latestFrameTime = CMTime.zero
    private var lastRefreshTime = CMTime.zero
    private var sentStillKeyFrame = false

    /// Starts capturing `display`, leaving out the windows of `excludedApps`.
    func start(display: SCDisplay, excluding excludedApps: [SCRunningApplication], includeAudio: Bool) async throws {
        let size = Self.outputSize(for: display)
        let config = SCStreamConfiguration()
        config.width = Int(size.width)
        config.height = Int(size.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(Self.frameRate))
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        config.queueDepth = 6
        config.showsCursor = true
        if includeAudio {
            config.capturesAudio = true
            config.sampleRate = AudioEncoder.sampleRate
            config.channelCount = 2
            config.excludesCurrentProcessAudio = true
        }

        let filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if includeAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        }
        queue.sync { self.stream = stream }
        do {
            try await stream.startCapture()
        } catch {
            stop()
            throw error
        }
        queue.async { self.startRefreshTimer() }
    }

    func stop() {
        queue.async { self.tearDown() }
    }

    /// Fits the display inside 1080p, which every Chromecast can decode, keeping its shape.
    static func outputSize(for display: SCDisplay) -> CGSize {
        let width = Double(display.width), height = Double(display.height)
        let scale = min(1920 / width, 1080 / height)
        let even = { (value: Double) in Double(Int(value * scale) / 2 * 2) }  // H.264 wants even sizes
        return CGSize(width: even(width), height: even(height))
    }

    /// ScreenCaptureKit only delivers a frame when something changes. While things move, the encoder
    /// spends few bits per frame, and once the screen stops it has nothing new to improve. So when the
    /// screen settles, send the still image once as a full-detail key frame; after that, re-send it now
    /// and then so a TV that lost a packet can recover.
    private func startRefreshTimer() {
        guard stream != nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in
            guard let self, let latestFrame else { return }
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            let still = (now - latestFrameTime).seconds
            if still >= 0.5, !sentStillKeyFrame {
                sentStillKeyFrame = true
                lastRefreshTime = now
                onVideoFrame?(latestFrame, now, true)
            } else if still >= 1, (now - lastRefreshTime).seconds >= 1 {
                lastRefreshTime = now
                onVideoFrame?(latestFrame, now, false)
            }
        }
        timer.resume()
        refreshTimer = timer
    }

    private func fail(_ error: Error) {
        guard stream != nil else { return }
        tearDown()
        DispatchQueue.main.async { self.onFailure?(error) }
    }

    private func tearDown() {
        refreshTimer?.cancel()
        refreshTimer = nil
        latestFrame = nil
        stream?.stopCapture { _ in }
        stream = nil
    }
}

extension ScreenStreamer: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard self.stream != nil else { return }
        switch type {
        case .screen:
            // Frames where nothing changed carry no image.
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                    as? [[SCStreamFrameInfo: Any]],
                  let status = attachments.first?[.status] as? Int,
                  SCFrameStatus(rawValue: status) == .complete,
                  let pixels = sample.imageBuffer else { return }
            latestFrame = pixels
            latestFrameTime = sample.presentationTimeStamp
            sentStillKeyFrame = false
            onVideoFrame?(pixels, sample.presentationTimeStamp, false)
        case .audio:
            onAudio?(sample)
        default:
            break
        }
    }
}

extension ScreenStreamer: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { self.fail(error) }
    }
}
