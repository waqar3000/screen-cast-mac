import XCTest
@testable import ScreenCast

final class FrameCryptoTests: XCTestCase {
    /// NIST SP 800-38A, F.5.1 (CTR-AES128). With frame ID 0 the counter is just the IV mask.
    func testMatchesNISTVector() {
        let crypto = FrameCrypto(key: bytes("2b7e151628aed2a6abf7158809cf4f3c"), ivMask: bytes("f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff"))
        let plaintext = Data(bytes("6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e51"))
        XCTAssertEqual(crypto.crypt(plaintext, frameID: 0),
                       Data(bytes("874d6191b620e3261bef6864990db6ce9806f66b7970fdff8617187bb9fffdff")))
    }

    /// The frame ID is XOR'd into bytes 8–11 of the counter, big-endian.
    func testFrameIDGoesIntoCounterBytes8To11() {
        let key = bytes("000102030405060708090a0b0c0d0e0f")
        let mask = bytes("a0a1a2a3a4a5a6a7a8a9aaabacadaeaf")
        var shifted = mask
        shifted[8] ^= 0x01; shifted[9] ^= 0x02; shifted[10] ^= 0x03; shifted[11] ^= 0x04
        let data = Data(repeating: 0x5A, count: 100)
        XCTAssertEqual(FrameCrypto(key: key, ivMask: mask).crypt(data, frameID: 0x0102_0304),
                       FrameCrypto(key: key, ivMask: shifted).crypt(data, frameID: 0))
    }

    func testDecryptsBackToPlaintext() {
        let crypto = FrameCrypto.random()
        let data = Data((0..<5000).map { UInt8($0 % 251) })
        XCTAssertEqual(crypto.crypt(crypto.crypt(data, frameID: 42), frameID: 42), data)
    }
}

func bytes(_ hex: String) -> [UInt8] {
    stride(from: 0, to: hex.count, by: 2).map {
        let start = hex.index(hex.startIndex, offsetBy: $0)
        return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
    }
}
