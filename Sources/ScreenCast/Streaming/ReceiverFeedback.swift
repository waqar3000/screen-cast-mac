import Foundation

/// What one compound RTCP packet from the Cast receiver says about one stream.
struct ReceiverFeedback {
    struct Nack {
        let frame: UInt8
        /// 0xFFFF means every packet of the frame is missing.
        let packet: UInt16
        /// Bit n set means packet `packet + n + 1` is missing too.
        let following: UInt8
    }

    struct Event {
        enum Kind { case decoded, played, other }
        let kind: Kind
        /// For `played`: how far off the target playout time the frame was shown, in milliseconds.
        let delay: Int
    }

    /// The receiver's reception report: packet loss, and the timing needed to work out the round trip.
    struct Report {
        /// Share of packets lost since the last report, out of 256.
        let fractionLost: UInt8
        /// Middle 32 bits of the NTP time in our last sender report, and the delay since the receiver got it
        /// (both in 1/65536 s).
        let lastSenderReport: UInt32
        let delaySinceLastSenderReport: UInt32
    }

    /// The SSRC the receiver uses for this stream; identifies which stream the feedback is about.
    var receiverSSRC: UInt32
    var checkpoint: UInt8?
    var targetDelay: Int?
    var nacks: [Nack] = []
    var pictureLost = false
    var events: [Event] = []
    var report: Report?

    /// Parses a compound RTCP packet (receiver report, Cast feedback, picture loss, frame logs…).
    init?(parsing packet: Data) {
        var reader = ByteReader(packet)
        var ssrc: UInt32?
        var feedback = (checkpoint: UInt8?.none, delay: Int?.none, nacks: [Nack](), pictureLost: false, events: [Event](),
                        report: Report?.none)

        while reader.remaining >= 4 {
            let first = reader.u8(), packetType = reader.u8(), words = reader.u16()
            guard first >> 6 == 2, var body = reader.take(Int(words) * 4), body.remaining >= 4 else { return nil }
            let subtype = first & 0x1F
            let author = body.u32()
            if ssrc == nil { ssrc = author }

            switch (packetType, subtype) {
            case (201, 1...):  // Receiver report with a report block
                guard body.remaining >= 24 else { break }
                _ = body.u32()  // our SSRC
                let fractionLost = UInt8(body.u32() >> 24)
                _ = body.u32()  // highest sequence number
                _ = body.u32()  // jitter
                feedback.report = Report(fractionLost: fractionLost, lastSenderReport: body.u32(),
                                         delaySinceLastSenderReport: body.u32())

            case (206, 1):  // Picture loss indicator
                feedback.pictureLost = true

            case (206, 15):  // Cast feedback: ACK checkpoint + NACKs
                guard body.remaining >= 12 else { break }
                _ = body.u32()  // sender SSRC
                guard body.u32() == 0x4341_5354 else { break }  // "CAST"
                feedback.checkpoint = body.u8()
                let lossFields = Int(body.u8())
                feedback.delay = Int(body.u16())
                for _ in 0..<lossFields where body.remaining >= 4 {
                    feedback.nacks.append(Nack(frame: body.u8(), packet: body.u16(), following: body.u8()))
                }

            case (204, 2):  // Receiver frame logs
                guard body.remaining >= 4, body.u32() == 0x4341_5354 else { break }
                while body.remaining >= 8 {
                    _ = body.u32()  // RTP timestamp
                    let eventCount = Int(body.u32() >> 24) + 1
                    for _ in 0..<eventCount where body.remaining >= 4 {
                        let delayOrPacket = Int16(bitPattern: body.u16())
                        let kind: Event.Kind = switch body.u16() >> 12 {
                        case 13, 3, 7: .decoded
                        case 12, 2, 6: .played
                        default: .other
                        }
                        feedback.events.append(Event(kind: kind, delay: Int(delayOrPacket)))
                    }
                }

            default:
                break  // Extended reports aren't needed
            }
        }

        guard let ssrc else { return nil }
        receiverSSRC = ssrc
        checkpoint = feedback.checkpoint
        targetDelay = feedback.delay
        nacks = feedback.nacks
        pictureLost = feedback.pictureLost
        events = feedback.events
        report = feedback.report
    }
}

/// Reads big-endian fields from a byte buffer. Reads past the end return zero.
struct ByteReader {
    private let bytes: [UInt8]
    private var index = 0

    init(_ data: Data) { bytes = [UInt8](data) }
    private init(bytes: ArraySlice<UInt8>) { self.bytes = Array(bytes) }

    var remaining: Int { bytes.count - index }

    mutating func u8() -> UInt8 {
        guard index < bytes.count else { return 0 }
        defer { index += 1 }
        return bytes[index]
    }

    mutating func u16() -> UInt16 { UInt16(u8()) << 8 | UInt16(u8()) }
    mutating func u32() -> UInt32 { UInt32(u16()) << 16 | UInt32(u16()) }

    mutating func take(_ count: Int) -> ByteReader? {
        guard count <= remaining else { return nil }
        defer { index += count }
        return ByteReader(bytes: bytes[index..<index + count])
    }
}
