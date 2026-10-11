import CoreMedia
import Foundation
import Network

/// One Cast Streaming ("mirroring") session, the protocol Chrome uses to cast a tab or screen.
/// Offers an Opus audio stream and an H.264 video stream, then sends each encoded frame as
/// encrypted RTP over UDP and answers the receiver's RTCP feedback (resends, key frame requests).
final class CastStreamingSession: @unchecked Sendable {  // state is confined to `queue`
    struct Configuration {
        var width: Int
        var height: Int
        var frameRate = 30
        var videoBitRate = 12_000_000
        var includeAudio = true
        /// How far behind live the TV plays, in milliseconds. Lower feels snappier; higher rides out Wi-Fi hiccups.
        var targetDelay = 150
    }

    /// A once-a-second snapshot of how the stream is doing, mostly as the TV reports it.
    struct Statistics {
        var width: Int
        var height: Int
        /// Screen updates sent per second. Only changes are sent, so this drops when nothing moves.
        var frameRate: Int
        /// Bits per second sent, video and audio.
        var bitRate: Int
        /// How long the TV waits before showing each frame, in milliseconds.
        var delay: Int
        /// Time for a report to travel to the TV and back, in milliseconds.
        var roundTrip: Int?
        /// Share of video packets the TV didn't get first time (0–1).
        var packetLoss: Double
        /// Packets resent in the last second.
        var resent: Int
        /// Frames the TV showed late in the last second.
        var lateFrames: Int
        /// Average and worst time from capture until a frame's last packet left the Mac, in milliseconds.
        var sendTime: Int?
        var worstSendTime: Int?
        var hasAudio: Bool
    }

    /// Called on the main queue if the stream breaks.
    var onFailure: ((Error) -> Void)?
    /// Called on the main queue once a second.
    var onStatistics: ((Statistics) -> Void)?

    // Payload types Chrome sends regardless of codec; some receivers insist on them.
    private static let audioPayloadType: UInt8 = 127
    private static let videoPayloadType: UInt8 = 96
    /// Stop sending new video if the receiver falls this far behind; a key frame catches it up.
    private static let maxUnackedVideoFrames: Int64 = 60

    private let config: Configuration
    private let queue = DispatchQueue(label: "CastStreaming", qos: .userInteractive)
    private let video: RtpSender
    private let audio: RtpSender?
    private let videoEncoder: VideoEncoder
    private let audioEncoder: AudioEncoder?
    private let startTime = CMClockGetTime(CMClockGetHostTimeClock())
    private let startWallClock = Date().timeIntervalSince1970

    private var connection: NWConnection?
    private var senders: [UInt32: RtpSender] = [:]  // by receiver SSRC
    /// Video packets waiting to go out. A frame's last packet carries its capture time, for timing.
    private var outbox: [(packet: Data, captured: CMTime?)] = []
    private var timers: [DispatchSourceTimer] = []
    private var waitingForKeyFrame = false
    private var lastKeyFrameRequest: UInt64 = 0
    private var lastFeedback: UInt64 = 0
    private var unknownSSRCs: Set<UInt32> = []
    private var stopped = false
    private var supportsDelayChanges = false
    private var screenFramesSent = 0
    private var captureTiming = Timing()
    private var encodeTiming = Timing()
    private var sendTiming = Timing()
    private var roundTrip: Int?
    private var packetLoss = 0.0

    init(configuration: Configuration) throws {
        config = configuration
        // Small SSRCs like Chrome's (audio 1–50000, video 50001–100000): some receivers reject values of 2^31 and up.
        video = RtpSender(ssrc: .random(in: 50_001 ... 100_000), payloadType: Self.videoPayloadType,
                          rtpTimebase: 90_000, crypto: .random())
        audio = configuration.includeAudio
            ? RtpSender(ssrc: .random(in: 1 ... 50_000), payloadType: Self.audioPayloadType,
                        rtpTimebase: AudioEncoder.sampleRate, crypto: .random())
            : nil
        videoEncoder = try VideoEncoder(width: configuration.width, height: configuration.height,
                                        frameRate: configuration.frameRate, bitRate: configuration.videoBitRate)
        audioEncoder = configuration.includeAudio ? try AudioEncoder() : nil

        videoEncoder.onEncodedFrame = { [weak self] data, isKeyFrame, isCopy, time in
            self?.queue.async { self?.sendEncodedVideo(data, isKeyFrame: isKeyFrame, isCopy: isCopy, time: time) }
        }
        audioEncoder?.onPacket = { [weak self] data, time in self?.sendEncodedAudio(data, time: time) }
    }

    /// The OFFER message body describing our streams.
    var offer: [String: Any] {
        var streams: [[String: Any]] = []
        if let audio {
            streams.append(stream(audio, index: 0, type: "audio_source", codec: "opus").merging([
                "channels": 2,
                "bitRate": 128_000,
            ]) { $1 })
        }
        streams.append(stream(video, index: streams.count, type: "video_source", codec: "h264").merging([
            "maxFrameRate": "\(config.frameRate)",
            "maxBitRate": config.videoBitRate * 5 / 4,
            "resolutions": [["width": config.width, "height": config.height]],
        ]) { $1 })
        return ["castMode": "mirroring", "receiverGetStatus": true, "supportedStreams": streams]
    }

    private func stream(_ sender: RtpSender, index: Int, type: String, codec: String) -> [String: Any] {
        [
            "index": index,
            "type": type,
            "codecName": codec,
            "rtpProfile": "cast",
            "rtpPayloadType": Int(sender.payloadType),
            "ssrc": sender.ssrc,
            "targetDelay": config.targetDelay,
            "aesKey": sender.crypto.key.map { String(format: "%02x", $0) }.joined(),
            "aesIvMask": sender.crypto.ivMask.map { String(format: "%02x", $0) }.joined(),
            "receiverRtcpEventLog": true,
            "timeBase": "1/\(sender.rtpTimebase)",
            // Lets us change the TV's playout delay mid-stream.
            "rtpExtensions": ["adaptive_playout_delay"],
        ]
    }

    /// Starts streaming to the address and port from the receiver's ANSWER.
    func start(answer: [String: Any], receiverAddress: String) throws {
        let indexes = answer["sendIndexes"] as? [Int] ?? []
        let ssrcs = (answer["ssrcs"] as? [NSNumber] ?? []).map(\.uint32Value)
        guard let udpPort = (answer["udpPort"] as? Int).flatMap({ NWEndpoint.Port(rawValue: UInt16(clamping: $0)) }),
              indexes.count == ssrcs.count else {
            throw CastError.streamRefused("the answer was incomplete")
        }
        let offered = audio.map { [$0, video] } ?? [video]
        var accepted: [UInt32: RtpSender] = [:]
        for (index, receiverSSRC) in zip(indexes, ssrcs) where offered.indices.contains(index) {
            accepted[receiverSSRC] = offered[index]
        }
        guard accepted.values.contains(where: { $0 === video }) else {
            throw CastError.streamRefused("it doesn't accept H.264 video")
        }
        Log.stream("streaming to \(receiverAddress):\(udpPort.rawValue) with \(accepted.count) stream(s)")

        let connection = NWConnection(host: NWEndpoint.Host(receiverAddress), port: udpPort, using: .udp)
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state { self?.fail(error) }
        }
        let extensions = answer["rtpExtensions"] as? [[String]] ?? []
        let canChangeDelay = !extensions.isEmpty && extensions.allSatisfy { $0.contains("adaptive_playout_delay") }
        queue.sync { [self] in
            supportsDelayChanges = canChangeDelay
            for (receiverSSRC, sender) in accepted { sender.receiverSSRC = receiverSSRC }
            senders = accepted
            self.connection = connection
            connection.start(queue: queue)
            receiveRTCP()
            lastFeedback = DispatchTime.now().uptimeNanoseconds
            sendSenderReports()
            schedule(every: .milliseconds(2)) { $0.drainOutbox() }
            schedule(every: .milliseconds(50)) { $0.kickstart() }
            schedule(every: .milliseconds(500)) { $0.sendSenderReports() }
            schedule(every: .seconds(1)) { $0.reportStatistics() }
        }
    }

    /// Feeds a captured frame to the encoder, optionally as a full-detail key frame. Any queue.
    func sendVideoFrame(_ pixelBuffer: CVPixelBuffer, at time: CMTime, keyFrame: Bool) {
        let waited = (CMClockGetTime(CMClockGetHostTimeClock()) - time).seconds
        queue.async { self.captureTiming.add(waited) }
        if keyFrame { videoEncoder.requestKeyFrame() }
        videoEncoder.encode(pixelBuffer, presentationTime: time)
    }

    /// Feeds captured system audio to the encoder. Any queue.
    func sendAudio(_ sample: CMSampleBuffer) {
        queue.async { [self] in
            guard connection != nil, !stopped else { return }
            audioEncoder?.append(sample)
        }
    }

    /// Changes how far behind live the TV plays, without restarting the stream (if the TV supports it).
    func setTargetDelay(_ milliseconds: Int) {
        queue.async { [self] in
            guard supportsDelayChanges else {
                return Log.stream("the TV can't change its delay mid-stream; \(milliseconds) ms applies next time")
            }
            for sender in senders.values { sender.pendingPlayoutDelay = milliseconds }
        }
    }

    func stop() {
        queue.async { [self] in
            stopped = true
            timers.forEach { $0.cancel() }
            timers = []
            outbox = []
            connection?.cancel()
            connection = nil
        }
    }

    // MARK: - Sending

    private func sendEncodedVideo(_ data: Data, isKeyFrame: Bool, isCopy: Bool, time: CMTime) {
        guard connection != nil, !stopped, video.receiverSSRC != 0 else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        if !isKeyFrame {
            // A dropped frame breaks every frame after it, so once we drop, wait for the next key frame.
            if waitingForKeyFrame || video.unackedFrames > Self.maxUnackedVideoFrames {
                if !waitingForKeyFrame || now - lastKeyFrameRequest > 1_000_000_000 {
                    waitingForKeyFrame = true
                    lastKeyFrameRequest = now
                    videoEncoder.requestKeyFrame()
                }
                return
            }
        }
        waitingForKeyFrame = false
        let packets = video.packetize(data, rtpTimestamp: rtpTimestamp(time, timebase: video.rtpTimebase),
                                      isKeyFrame: isKeyFrame, now: now)
        if isCopy {
            outbox += packets.map { ($0, nil) }
        } else {
            screenFramesSent += 1
            encodeTiming.add((CMClockGetTime(CMClockGetHostTimeClock()) - time).seconds)
            outbox += packets.enumerated().map { ($1, $0 == packets.count - 1 ? time : nil) }
        }
    }

    private func sendEncodedAudio(_ data: Data, time: CMTime) {
        guard let audio, audio.receiverSSRC != 0 else { return }
        // Audio packets are tiny and timing-sensitive, so they skip the pacing queue.
        for packet in audio.packetize(data, rtpTimestamp: rtpTimestamp(time, timebase: audio.rtpTimebase),
                                      isKeyFrame: true, now: DispatchTime.now().uptimeNanoseconds) {
            connection?.send(content: packet, completion: .idempotent)
        }
    }

    /// Sends queued video packets in small bursts (up to ~90 Mbps) so a big key frame doesn't overrun the TV's buffers.
    private func drainOutbox() {
        guard let connection, !outbox.isEmpty else { return }
        let count = min(16, outbox.count)
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        for (packet, captured) in outbox.prefix(count) {
            connection.send(content: packet, completion: .idempotent)
            if let captured { sendTiming.add((now - captured).seconds) }
        }
        outbox.removeFirst(count)
    }

    private func kickstart() {
        let now = DispatchTime.now().uptimeNanoseconds
        for sender in senders.values {
            if let packet = sender.kickstartPacket(now: now) { outbox.insert((packet, nil), at: 0) }
        }
    }

    private func sendSenderReports() {
        guard let connection else { return }
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        for sender in senders.values {
            let report = sender.senderReport(ntpTimestamp: ntpTimestamp(now),
                                             rtpTimestamp: rtpTimestamp(now, timebase: sender.rtpTimebase))
            connection.send(content: report, completion: .idempotent)
        }
    }

    // MARK: - Receiving

    private func receiveRTCP() {
        connection?.receiveMessage { [weak self] data, _, _, error in
            guard let self, !stopped else { return }
            if let data, let feedback = ReceiverFeedback(parsing: data), senders[feedback.receiverSSRC] == nil,
               unknownSSRCs.insert(feedback.receiverSSRC).inserted {
                Log.stream("RTCP from unexpected SSRC \(feedback.receiverSSRC): \(data.map { String(format: "%02x", $0) }.joined())")
            }
            if let data, let feedback = ReceiverFeedback(parsing: data), let sender = senders[feedback.receiverSSRC] {
                let now = DispatchTime.now().uptimeNanoseconds
                lastFeedback = now
                if let report = feedback.report, sender === video { noteReceptionReport(report) }
                // Resent packets jump the queue: the receiver is waiting on them.
                outbox.insert(contentsOf: sender.apply(feedback, now: now).map { ($0, nil) }, at: 0)
                if feedback.pictureLost, sender === video, now - lastKeyFrameRequest > 200_000_000 {
                    lastKeyFrameRequest = now
                    videoEncoder.requestKeyFrame()
                }
            }
            if error == nil { receiveRTCP() }
        }
    }

    /// Works out packet loss and the round trip from the TV's reception report. The report echoes the
    /// time of our last sender report and how long the TV held it, so the rest of the time was travel.
    private func noteReceptionReport(_ report: ReceiverFeedback.Report) {
        packetLoss = Double(report.fractionLost) / 256
        guard report.lastSenderReport != 0 else { return }
        let now = UInt32(truncatingIfNeeded: ntpTimestamp(CMClockGetTime(CMClockGetHostTimeClock())) >> 16)
        let elapsed = now &- report.lastSenderReport &- report.delaySinceLastSenderReport  // in 1/65536 s
        if elapsed < 65_536 * 5 { roundTrip = Int(Double(elapsed) * 1000 / 65_536) }
    }

    private func reportStatistics() {
        var statistics = Statistics(width: config.width, height: config.height, frameRate: screenFramesSent, bitRate: 0,
                                    delay: video.stats.targetDelay, roundTrip: roundTrip, packetLoss: packetLoss,
                                    resent: 0, lateFrames: video.stats.lateFrames,
                                    sendTime: sendTiming.average, worstSendTime: sendTiming.worst, hasAudio: false)
        for (name, sender) in [("video", video), ("audio", audio)] {
            guard let sender, sender.receiverSSRC != 0 else { continue }
            let s = sender.stats
            statistics.bitRate += s.bytesSent * 8
            statistics.resent += s.retransmitted
            if sender === audio { statistics.hasAudio = true }
            let delay = s.framesPlayed > 0 ? s.renderDelaySum / s.framesPlayed : 0
            Log.stream("""
                \(name): sent \(s.framesSent)/s \(s.bytesSent * 8 / 1000) kbps · \
                TV decoded \(s.framesDecoded)/s played \(s.framesPlayed)/s (avg \(delay) ms off target, \(s.lateFrames) late) · \
                resent \(s.retransmitted) · key frame requests \(s.pictureLossReports) · unacked \(sender.unackedFrames) · \
                TV delay \(s.targetDelay) ms · round trip \(roundTrip.map { "\($0) ms" } ?? "?") · loss \(Int(packetLoss * 100))%
                """)
            sender.resetStats()
        }
        Log.stream("""
            Mac pipeline: captured +\(captureTiming.average ?? 0) ms, encoded +\(encodeTiming.average ?? 0) ms, \
            sent +\(sendTiming.average ?? 0) ms (worst \(sendTiming.worst ?? 0) ms)
            """)
        screenFramesSent = 0
        captureTiming = Timing()
        encodeTiming = Timing()
        sendTiming = Timing()
        DispatchQueue.main.async { self.onStatistics?(statistics) }

        if DispatchTime.now().uptimeNanoseconds - lastFeedback > 8_000_000_000 {
            fail(CastError.streamRefused("it stopped responding. A firewall or Wi-Fi setting may be blocking the stream"))
        }
    }

    private func fail(_ error: Error) {
        guard !stopped else { return }
        Log.stream("stream failed: \(error.localizedDescription)")
        stop()
        DispatchQueue.main.async { self.onFailure?(error) }
    }

    // MARK: - Clocks

    private func schedule(every interval: DispatchTimeInterval, _ action: @escaping (CastStreamingSession) -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            guard let self, !stopped else { return }
            action(self)
        }
        timer.resume()
        timers.append(timer)
    }

    /// Media time on each stream's RTP clock. All streams share the session start as their origin
    /// (offset a little so slightly-early captures don't go negative), which keeps audio and video in sync.
    private func rtpTimestamp(_ time: CMTime, timebase: Int) -> UInt32 {
        let ticks = ((time - startTime).seconds + 10) * Double(timebase)
        return UInt32(truncatingIfNeeded: Int64(ticks.rounded()))
    }

    /// Wall-clock time in NTP format (seconds since 1900, 32.32 fixed point), advanced by the monotonic host clock.
    private func ntpTimestamp(_ time: CMTime) -> UInt64 {
        let seconds = startWallClock + (time - startTime).seconds + 2_208_988_800
        let whole = seconds.rounded(.down)
        return UInt64(whole) << 32 | UInt64((seconds - whole) * 4_294_967_296)
    }
}

/// Average and worst of a set of durations, reported in milliseconds.
private struct Timing {
    private var total = 0.0
    private var count = 0
    private var longest = 0.0

    mutating func add(_ seconds: Double) {
        total += seconds
        count += 1
        longest = max(longest, seconds)
    }

    var average: Int? { count > 0 ? Int(total / Double(count) * 1000) : nil }
    var worst: Int? { count > 0 ? Int(longest * 1000) : nil }
}
