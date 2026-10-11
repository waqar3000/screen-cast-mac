import XCTest
@testable import ScreenCast

final class ReceiverFeedbackTests: XCTestCase {
    func testParsesCastFeedback() throws {
        let feedback = try XCTUnwrap(ReceiverFeedback(parsing: castFeedback(checkpoint: 7, nacks: [(8, 2, 0b101)], delay: 100)))
        XCTAssertEqual(feedback.receiverSSRC, 0x11)
        XCTAssertEqual(feedback.checkpoint, 7)
        XCTAssertEqual(feedback.targetDelay, 100)
        XCTAssertEqual(feedback.nacks.count, 1)
        XCTAssertEqual(feedback.nacks[0].frame, 8)
        XCTAssertEqual(feedback.nacks[0].packet, 2)
        XCTAssertEqual(feedback.nacks[0].following, 0b101)
    }

    func testParsesCompoundPacketWithReportAndPictureLoss() throws {
        var packet = Data([0x81, 201])  // receiver report with one report block
        packet.appendBigEndian(UInt16(7))
        packet.appendBigEndian(UInt32(0x11))
        packet.appendBigEndian(UInt32(0xAABB_CCDD))
        packet.appendBigEndian(UInt32(0x4000_0000))  // a quarter of packets lost
        packet.appendBigEndian(UInt32(0))
        packet.appendBigEndian(UInt32(0))
        packet.appendBigEndian(UInt32(0x1234_5678))  // last sender report
        packet.appendBigEndian(UInt32(65536))        // held for one second
        packet.append(contentsOf: [0x81, 206, 0, 2])  // picture loss indicator
        packet.appendBigEndian(UInt32(0x11))
        packet.appendBigEndian(UInt32(0xAABB_CCDD))

        let feedback = try XCTUnwrap(ReceiverFeedback(parsing: packet))
        XCTAssertEqual(feedback.report?.fractionLost, 0x40)
        XCTAssertEqual(feedback.report?.lastSenderReport, 0x1234_5678)
        XCTAssertEqual(feedback.report?.delaySinceLastSenderReport, 65536)
        XCTAssertTrue(feedback.pictureLost)
    }

    func testParsesReceiverFrameLog() throws {
        var packet = Data([0x82, 204])  // application-defined, receiver log subtype
        packet.appendBigEndian(UInt16(6))  // 24 bytes after the header
        packet.appendBigEndian(UInt32(0x11))
        packet.append(contentsOf: Array("CAST".utf8))
        packet.appendBigEndian(UInt32(90_000))     // RTP timestamp
        packet.appendBigEndian(UInt32(1 << 24))    // two events
        packet.appendBigEndian(UInt16(0))          // decoded
        packet.appendBigEndian(UInt16(13 << 12))
        packet.appendBigEndian(UInt16(20))         // played 20 ms late
        packet.appendBigEndian(UInt16(12 << 12))

        let events = try XCTUnwrap(ReceiverFeedback(parsing: packet)).events
        XCTAssertEqual(events.map(\.kind), [.decoded, .played])
        XCTAssertEqual(events[1].delay, 20)
    }

    func testRejectsGarbage() {
        XCTAssertNil(ReceiverFeedback(parsing: Data([1, 2, 3, 4, 5, 6, 7, 8])))
    }
}
