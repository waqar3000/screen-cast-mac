import XCTest
@testable import ScreenCast

final class RtpSenderTests: XCTestCase {
    private func makeSender() -> RtpSender {
        RtpSender(ssrc: 0xAABB_CCDD, payloadType: 96, rtpTimebase: 90_000, crypto: .random())
    }

    func testKeyFrameHeaders() {
        let sender = makeSender()
        let packets = sender.packetize(Data(count: 3000), rtpTimestamp: 1234, isKeyFrame: true, now: 0).map { [UInt8]($0) }
        XCTAssertEqual(packets.count, 3)
        XCTAssertTrue(packets.allSatisfy { $0.count <= RtpSender.maxPacketSize })
        let first = packets[0]
        XCTAssertEqual(first[0], 0x80)                          // RTP version 2
        XCTAssertEqual(first[1], 96)                            // no marker on the first packet
        XCTAssertEqual(Array(first[4..<8]), [0, 0, 0x04, 0xD2]) // RTP timestamp 1234
        XCTAssertEqual(Array(first[8..<12]), [0xAA, 0xBB, 0xCC, 0xDD])
        XCTAssertEqual(first[12], 0xC0)                         // key frame + reference frame ID present
        XCTAssertEqual(first[13], 0)                            // frame ID
        XCTAssertEqual(Array(first[14..<18]), [0, 0, 0, 2])     // packet 0 of max packet 2
        XCTAssertEqual(first[18], 0)                            // a key frame references itself
        XCTAssertEqual(packets[2][1], 0x80 | 96)                // marker bit on the last packet
    }

    func testDeltaFrameReferencesPreviousFrame() {
        let sender = makeSender()
        _ = sender.packetize(Data(count: 10), rtpTimestamp: 0, isKeyFrame: true, now: 0)
        let delta = [UInt8](sender.packetize(Data(count: 10), rtpTimestamp: 3000, isKeyFrame: false, now: 0)[0])
        XCTAssertEqual(delta[12], 0x40)  // not a key frame
        XCTAssertEqual(delta[13], 1)     // frame ID 1
        XCTAssertEqual(delta[18], 0)     // references frame 0
    }

    func testAnnouncesNewPlayoutDelayInFirstPacket() {
        let sender = makeSender()
        sender.pendingPlayoutDelay = 100
        let packets = sender.packetize(Data(count: 3000), rtpTimestamp: 0, isKeyFrame: true, now: 0).map { [UInt8]($0) }
        XCTAssertEqual(packets[0][12] & 0x3F, 1)                       // one extension
        XCTAssertEqual(Array(packets[0][19..<23]), [0x04, 0x02, 0, 100]) // type 1, size 2, 100 ms
        XCTAssertEqual(packets[1][12] & 0x3F, 0)                       // only on the first packet
    }

    func testSenderReportLayout() {
        let report = [UInt8](makeSender().senderReport(ntpTimestamp: 0x0102_0304_0506_0708, rtpTimestamp: 9))
        XCTAssertEqual(report.count, 28)
        XCTAssertEqual(Array(report[0..<4]), [0x80, 200, 0, 6])
        XCTAssertEqual(Array(report[8..<16]), [1, 2, 3, 4, 5, 6, 7, 8])
    }

    func testResendsPacketsTheReceiverReportsMissing() throws {
        let sender = makeSender()
        let first = sender.packetize(Data(count: 10), rtpTimestamp: 0, isKeyFrame: true, now: 0)
        let second = sender.packetize(Data(count: 10), rtpTimestamp: 3000, isKeyFrame: false, now: 0)
        // Receiver has frame 0 and is missing packet 0 of frame 1.
        let feedback = try XCTUnwrap(ReceiverFeedback(parsing: castFeedback(checkpoint: 0, nacks: [(1, 0, 0)])))
        XCTAssertEqual(sender.apply(feedback, now: 50_000_000), [second[0]])
        XCTAssertEqual(sender.unackedFrames, 1)
        XCTAssertNotEqual(first, second)
    }

    func testIgnoresRepeatedRequestsForAPacketJustResent() throws {
        let sender = makeSender()
        _ = sender.packetize(Data(count: 10), rtpTimestamp: 0, isKeyFrame: true, now: 0)
        let feedback = try XCTUnwrap(ReceiverFeedback(parsing: castFeedback(checkpoint: 0xFF, nacks: [(0, 0xFFFF, 0)])))
        XCTAssertEqual(sender.apply(feedback, now: 50_000_000).count, 1)
        XCTAssertEqual(sender.apply(feedback, now: 51_000_000).count, 0)
    }
}

/// A Cast feedback RTCP packet from receiver SSRC 0x11 to sender SSRC 0xAABBCCDD.
func castFeedback(checkpoint: UInt8, nacks: [(UInt8, UInt16, UInt8)], delay: UInt16 = 200) -> Data {
    var packet = Data([0x8F, 206])
    packet.appendBigEndian(UInt16(4 + nacks.count))
    packet.appendBigEndian(UInt32(0x11))
    packet.appendBigEndian(UInt32(0xAABB_CCDD))
    packet.append(contentsOf: Array("CAST".utf8))
    packet.append(checkpoint)
    packet.append(UInt8(nacks.count))
    packet.appendBigEndian(delay)
    for (frame, packetID, following) in nacks {
        packet.append(frame)
        packet.appendBigEndian(packetID)
        packet.append(following)
    }
    return packet
}
