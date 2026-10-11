import XCTest
@testable import ScreenCast

final class CastMessageTests: XCTestCase {
    func testEncodesProtobufFieldsInOrder() {
        let message = CastMessage(sourceID: "sender-0", destinationID: "receiver-0",
                                  namespace: "urn:x-cast:com.google.cast.tp.connection", payload: #"{"type":"CONNECT"}"#)
        let bytes = [UInt8](message.encoded())
        // protocol_version = 0, then source_id as a length-delimited field.
        XCTAssertEqual(Array(bytes.prefix(4)), [0x08, 0x00, 0x12, 0x08])
        XCTAssertEqual(String(decoding: bytes[4..<12], as: UTF8.self), "sender-0")
        XCTAssertEqual(bytes[12], 0x1A)  // destination_id, field 3
    }

    func testRoundTrips() throws {
        let message = CastMessage(sourceID: "a", destinationID: "b", namespace: "ns", payload: "{}")
        let decoded = try XCTUnwrap(CastMessage(decoding: message.encoded()))
        XCTAssertEqual(decoded.sourceID, "a")
        XCTAssertEqual(decoded.destinationID, "b")
        XCTAssertEqual(decoded.namespace, "ns")
        XCTAssertEqual(decoded.payload, "{}")
    }

    func testRejectsTruncatedMessages() {
        let encoded = CastMessage(sourceID: "a", destinationID: "b", namespace: "ns", payload: "{}").encoded()
        XCTAssertNil(CastMessage(decoding: encoded.prefix(encoded.count - 3)))
    }
}
