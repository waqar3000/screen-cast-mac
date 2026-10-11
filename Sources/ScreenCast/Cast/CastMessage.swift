import Foundation

/// One Cast V2 message. On the wire it's the `CastMessage` protobuf from Chromium's
/// cast_channel.proto; it's small enough that we encode and decode it by hand.
struct CastMessage {
    var sourceID: String
    var destinationID: String
    var namespace: String
    /// JSON text. Binary payloads (used only for device authentication) are ignored.
    var payload: String

    func encoded() -> Data {
        var out = Data()
        out.appendVarintField(1, 0)                 // protocol_version = CASTV2_1_0
        out.appendBytesField(2, Data(sourceID.utf8))
        out.appendBytesField(3, Data(destinationID.utf8))
        out.appendBytesField(4, Data(namespace.utf8))
        out.appendVarintField(5, 0)                 // payload_type = STRING
        out.appendBytesField(6, Data(payload.utf8))
        return out
    }
}

extension CastMessage {
    init?(decoding data: Data) {
        var reader = ProtobufReader(bytes: [UInt8](data))
        var fields: [UInt64: String] = [:]
        while !reader.isAtEnd {
            guard let key = reader.readVarint() else { return nil }
            switch key & 7 {
            case 0: guard reader.readVarint() != nil else { return nil }
            case 1: guard reader.skip(8) else { return nil }
            case 2:
                guard let bytes = reader.readLengthDelimited() else { return nil }
                fields[key >> 3] = String(decoding: bytes, as: UTF8.self)
            case 5: guard reader.skip(4) else { return nil }
            default: return nil
            }
        }
        guard let source = fields[2], let destination = fields[3], let namespace = fields[4] else { return nil }
        self.init(sourceID: source, destinationID: destination, namespace: namespace, payload: fields[6] ?? "")
    }
}

private struct ProtobufReader {
    let bytes: [UInt8]
    var index = 0

    var isAtEnd: Bool { index >= bytes.count }

    mutating func readVarint() -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while index < bytes.count, shift < 64 {
            let byte = bytes[index]
            index += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        return nil
    }

    mutating func readLengthDelimited() -> ArraySlice<UInt8>? {
        guard let length = readVarint(), length <= UInt64(bytes.count - index) else { return nil }
        defer { index += Int(length) }
        return bytes[index..<index + Int(length)]
    }

    mutating func skip(_ count: Int) -> Bool {
        guard bytes.count - index >= count else { return false }
        index += count
        return true
    }
}

private extension Data {
    mutating func appendVarint(_ value: UInt64) {
        var value = value
        while value >= 0x80 {
            append(UInt8(value & 0x7F) | 0x80)
            value >>= 7
        }
        append(UInt8(value))
    }

    mutating func appendVarintField(_ field: UInt64, _ value: UInt64) {
        appendVarint(field << 3)
        appendVarint(value)
    }

    mutating func appendBytesField(_ field: UInt64, _ bytes: Data) {
        appendVarint(field << 3 | 2)
        appendVarint(UInt64(bytes.count))
        append(bytes)
    }
}
