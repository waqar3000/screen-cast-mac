import CoreMedia
import XCTest
@testable import ScreenCast

final class VideoEncoderTests: XCTestCase {
    /// Frames arrive from the capture queue while push-out copies and key frame requests come from elsewhere.
    /// Everything must reach the encoder in order, or the TV gets frames with timestamps out of order.
    func testFramesAndPushOutCopiesComeOutInOrder() throws {
        let encoder = try VideoEncoder(width: 1920, height: 1080, frameRate: 60, bitRate: 12_000_000)
        let lock = NSLock()
        var outputs: [(time: CMTime, isCopy: Bool)] = []
        encoder.onEncodedFrame = { _, _, isCopy, time in lock.withLock { outputs.append((time, isCopy)) } }

        let frames = (0..<4).map { shade -> CVPixelBuffer in
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 1920, 1080, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
            CVPixelBufferLockBaseAddress(buffer!, [])
            memset(CVPixelBufferGetBaseAddressOfPlane(buffer!, 0), Int32(60 * shade), CVPixelBufferGetBytesPerRowOfPlane(buffer!, 0) * 1080)
            CVPixelBufferUnlockBaseAddress(buffer!, [])
            return buffer!
        }
        // Gaps of 20–30 ms land right where the 25 ms push-out copy fires, like a mostly still second display.
        let capture = DispatchQueue(label: "capture")
        for index in 0..<120 {
            capture.async {
                encoder.encode(frames[index % frames.count], presentationTime: CMClockGetTime(CMClockGetHostTimeClock()))
                if index % 10 == 0 { DispatchQueue.global().async { encoder.requestKeyFrame() } }
                usleep(UInt32.random(in: 20_000...30_000))
            }
        }
        capture.sync {}
        Thread.sleep(forTimeInterval: 0.5)

        let results = lock.withLock { outputs }
        XCTAssertGreaterThan(results.count, 100)
        XCTAssertTrue(results.contains { $0.isCopy }, "expected push-out copies")
        for (previous, next) in zip(results, results.dropFirst()) {
            XCTAssertLessThan(previous.time, next.time, "frames came out of the encoder out of order")
        }
    }
}
