import CommonCrypto
import Foundation

/// AES-128-CTR payload encryption for Cast Streaming. Each frame starts a fresh counter:
/// the stream's IV mask XOR'd with the frame ID (big-endian, in bytes 8–11).
struct FrameCrypto {
    let key: [UInt8]
    let ivMask: [UInt8]

    static func random() -> FrameCrypto {
        FrameCrypto(key: randomBytes(16), ivMask: randomBytes(16))
    }

    func crypt(_ data: Data, frameID: Int64) -> Data {
        var counter = ivMask
        let id = UInt32(truncatingIfNeeded: frameID)
        counter[8] ^= UInt8(id >> 24)
        counter[9] ^= UInt8(id >> 16 & 0xFF)
        counter[10] ^= UInt8(id >> 8 & 0xFF)
        counter[11] ^= UInt8(id & 0xFF)

        var cryptor: CCCryptorRef?
        guard CCCryptorCreateWithMode(CCOperation(kCCEncrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES),
                                      CCPadding(ccNoPadding), counter, key, key.count, nil, 0, 0,
                                      CCModeOptions(kCCModeOptionCTR_BE), &cryptor) == kCCSuccess,
              let cryptor else { return data }
        defer { CCCryptorRelease(cryptor) }
        var output = Data(count: data.count)
        var moved = 0
        output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                _ = CCCryptorUpdate(cryptor, input.baseAddress, data.count, out.baseAddress, data.count, &moved)
            }
        }
        return output
    }
}

func randomBytes(_ count: Int) -> [UInt8] {
    (0..<count).map { _ in UInt8.random(in: .min ... .max) }
}

/// Turns one stream's encoded frames into encrypted Cast RTP packets, keeps recent packets
/// for retransmission, and applies the receiver's feedback. Use it from a single queue.
final class RtpSender {
    /// Packets stay under a typical Wi-Fi/Ethernet MTU with room to spare for VPNs and tunnels.
    static let maxPacketSize = 1400
    /// 12 bytes of RTP header + 7 bytes of Cast header, plus room for the 4-byte playout delay extension.
    private static let headerSize = 23

    let ssrc: UInt32
    let payloadType: UInt8
    let rtpTimebase: Int
    let crypto: FrameCrypto
    var receiverSSRC: UInt32 = 0
    /// A new playout delay (ms) to announce to the receiver; repeated on each frame until the receiver confirms it.
    var pendingPlayoutDelay: Int?

    private(set) var stats = Stats()
    private var sequenceNumber = UInt16.random(in: .min ... .max)
    private var nextFrameID: Int64 = 0
    /// The receiver has every frame up to and including this one.
    private var checkpoint: Int64 = -1
    private var sentFrames: [Int64: SentFrame] = [:]
    private var packetCount: UInt32 = 0
    private var octetCount: UInt32 = 0
    private var lastKickstart: UInt64 = 0

    struct Stats {
        var framesSent = 0
        var bytesSent = 0
        var retransmitted = 0
        var pictureLossReports = 0
        var framesDecoded = 0
        var framesPlayed = 0
        var lateFrames = 0
        var renderDelaySum = 0
        var targetDelay = 0
    }

    private struct SentFrame {
        var packets: [Data]
        var lastSent: [UInt64]
    }

    init(ssrc: UInt32, payloadType: UInt8, rtpTimebase: Int, crypto: FrameCrypto) {
        self.ssrc = ssrc
        self.payloadType = payloadType
        self.rtpTimebase = rtpTimebase
        self.crypto = crypto
    }

    var latestFrameID: Int64 { nextFrameID - 1 }
    /// Frames sent that the receiver hasn't confirmed yet.
    var unackedFrames: Int64 { latestFrameID - checkpoint }

    /// Starts a new counting period. The TV's current delay carries over; it's only reported now and then.
    func resetStats() {
        stats = Stats(targetDelay: stats.targetDelay)
    }

    /// Encrypts and packetizes a frame. Key frames stand alone; other frames depend on the previous one.
    func packetize(_ frame: Data, rtpTimestamp: UInt32, isKeyFrame: Bool, now: UInt64) -> [Data] {
        let frameID = nextFrameID
        nextFrameID += 1
        let payload = crypto.crypt(frame, frameID: frameID)
        let chunkSize = Self.maxPacketSize - Self.headerSize
        let count = max(1, (payload.count + chunkSize - 1) / chunkSize)

        var packets: [Data] = []
        packets.reserveCapacity(count)
        for packetID in 0..<count {
            let chunk = payload[payload.startIndex + packetID * chunkSize ..< payload.startIndex + min(payload.count, (packetID + 1) * chunkSize)]
            let announceDelay = packetID == 0 ? pendingPlayoutDelay : nil
            var packet = Data(capacity: Self.headerSize + chunk.count)
            // RTP header: version 2, marker bit on the frame's last packet.
            packet.append(0x80)
            packet.append((packetID == count - 1 ? 0x80 : 0) | payloadType)
            packet.appendBigEndian(sequenceNumber)
            packet.appendBigEndian(rtpTimestamp)
            packet.appendBigEndian(ssrc)
            // Cast header: key frame flag, "reference frame ID present", no extensions.
            packet.append((isKeyFrame ? 0x80 : 0) | 0x40 | (announceDelay != nil ? 1 : 0))
            packet.append(UInt8(truncatingIfNeeded: frameID))
            packet.appendBigEndian(UInt16(packetID))
            packet.appendBigEndian(UInt16(count - 1))
            packet.append(UInt8(truncatingIfNeeded: isKeyFrame ? frameID : frameID - 1))
            if let announceDelay {
                // Adaptive latency extension: type 1, 2 bytes of data.
                packet.appendBigEndian(UInt16(1 << 10 | 2))
                packet.appendBigEndian(UInt16(clamping: announceDelay))
            }
            packet.append(chunk)
            packets.append(packet)
            sequenceNumber &+= 1
            packetCount &+= 1
            octetCount &+= UInt32(chunk.count)
        }
        sentFrames[frameID] = SentFrame(packets: packets, lastSent: Array(repeating: now, count: count))
        // Don't hold on to frames forever if the receiver goes quiet.
        sentFrames[frameID - 300] = nil
        stats.framesSent += 1
        stats.bytesSent += frame.count
        return packets
    }

    /// An RTCP Sender Report tying `rtpTimestamp` to the wall-clock `ntpTimestamp`, so the receiver can schedule playout.
    func senderReport(ntpTimestamp: UInt64, rtpTimestamp: UInt32) -> Data {
        var packet = Data(capacity: 28)
        packet.append(0x80)
        packet.append(200)
        packet.appendBigEndian(UInt16(6))  // payload length in 32-bit words
        packet.appendBigEndian(ssrc)
        packet.appendBigEndian(ntpTimestamp)
        packet.appendBigEndian(rtpTimestamp)
        packet.appendBigEndian(packetCount)
        packet.appendBigEndian(octetCount)
        return packet
    }

    /// Applies receiver feedback and returns any packets that need to be sent again.
    func apply(_ feedback: ReceiverFeedback, now: UInt64) -> [Data] {
        var reportCheckpoint = checkpoint
        if let truncated = feedback.checkpoint {
            reportCheckpoint = expand(truncated, atMost: latestFrameID)
            if reportCheckpoint > checkpoint {
                for id in checkpoint + 1 ... reportCheckpoint { sentFrames[id] = nil }
                checkpoint = reportCheckpoint
            }
        }
        if let delay = feedback.targetDelay {
            stats.targetDelay = delay
            if delay == pendingPlayoutDelay { pendingPlayoutDelay = nil }
        }
        if feedback.pictureLost { stats.pictureLossReports += 1 }
        for event in feedback.events {
            switch event.kind {
            case .decoded: stats.framesDecoded += 1
            case .played:
                stats.framesPlayed += 1
                stats.renderDelaySum += event.delay
                if event.delay > 15 { stats.lateFrames += 1 }
            case .other: break
            }
        }

        var resend: [Data] = []
        for nack in feedback.nacks {
            let frameID = expand(nack.frame, above: reportCheckpoint)
            guard var frame = sentFrames[frameID] else { continue }
            var packetIDs: [Int] = []
            if nack.packet == 0xFFFF {
                packetIDs = Array(frame.packets.indices)
            } else {
                packetIDs.append(Int(nack.packet))
                for bit in 0..<8 where nack.following & (1 << bit) != 0 {
                    packetIDs.append(Int(nack.packet) + bit + 1)
                }
            }
            // Skip packets we just sent; the receiver may not have seen them yet.
            for id in packetIDs where id < frame.packets.count && now - frame.lastSent[id] > 10_000_000 {
                resend.append(frame.packets[id])
                frame.lastSent[id] = now
            }
            sentFrames[frameID] = frame
        }
        stats.retransmitted += resend.count
        return resend
    }

    /// If the newest frame hasn't been acknowledged for a while, its last packet may have been lost and the
    /// receiver can't know to ask for it. Re-sending it prompts the receiver to report what's missing.
    func kickstartPacket(now: UInt64) -> Data? {
        guard checkpoint < latestFrameID, now - lastKickstart > 100_000_000,
              let frame = sentFrames[latestFrameID], now - frame.lastSent[frame.packets.count - 1] > 100_000_000
        else { return nil }
        lastKickstart = now
        return frame.packets.last
    }

    /// Frame IDs travel as their low 8 bits; recover the full ID nearest to a known reference.
    private func expand(_ truncated: UInt8, atMost reference: Int64) -> Int64 {
        var value = (reference & ~0xFF) | Int64(truncated)
        if value > reference { value -= 256 }
        return value
    }

    private func expand(_ truncated: UInt8, above reference: Int64) -> Int64 {
        var value = (reference & ~0xFF) | Int64(truncated)
        if value <= reference { value += 256 }
        return value
    }
}

extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}
