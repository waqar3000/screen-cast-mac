import CGVirtualDisplay
import CoreGraphics

/// An extra display that macOS treats like a real monitor, for using the TV as a second screen.
/// It exists for as long as this object does.
final class VirtualDisplay {
    /// A screen size in points. macOS draws it at twice the size in pixels (like a Retina screen),
    /// which keeps text sharp when the picture is scaled to the TV.
    struct Size: Hashable {
        let width: Int
        let height: Int
    }

    private let display: CGVirtualDisplay

    var displayID: CGDirectDisplayID { display.displayID }

    /// Creates the display offering `sizes` (all of which also show up in System Settings › Displays).
    init?(name: String, sizes: [Size]) {
        guard let largest = sizes.max(by: { $0.width < $1.width }) else { return nil }
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.queue = DispatchQueue.global(qos: .userInteractive)
        descriptor.name = name
        descriptor.maxPixelsWide = UInt32(largest.width * 2)
        descriptor.maxPixelsHigh = UInt32(largest.height * 2)
        // Report the physical size of a 50" TV so macOS picks sensible defaults.
        descriptor.sizeInMillimeters = CGSize(width: 1107, height: 623)
        // macOS wants a non-zero vendor ID and distinct serial numbers.
        descriptor.vendorID = 0x5343
        descriptor.productID = 1
        descriptor.serialNum = 1
        descriptor.serialNumber = 1
        // sRGB primaries and D65 white point.
        descriptor.redPrimary = CGPoint(x: 0.64, y: 0.33)
        descriptor.greenPrimary = CGPoint(x: 0.30, y: 0.60)
        descriptor.bluePrimary = CGPoint(x: 0.15, y: 0.06)
        descriptor.whitePoint = CGPoint(x: 0.3127, y: 0.3290)
        guard let display = CGVirtualDisplay(descriptor: descriptor) else { return nil }

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 1
        settings.modes = sizes.map { CGVirtualDisplayMode(width: UInt32($0.width), height: UInt32($0.height), refreshRate: 60) }
        guard display.apply(settings) else { return nil }
        self.display = display
    }

    /// Switches the display to `size`, preferring the sharp (double-resolution) version of the mode.
    @discardableResult
    func use(_ size: Size) -> Bool {
        if let current = CGDisplayCopyDisplayMode(displayID), current.width == size.width, current.height == size.height {
            return true
        }
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] else { return false }
        let matching = modes.filter { $0.width == size.width && $0.height == size.height }
        guard let mode = matching.max(by: { $0.pixelWidth < $1.pixelWidth }) else { return false }
        let applied = CGDisplaySetDisplayMode(displayID, mode, nil) == .success
        if let current = CGDisplayCopyDisplayMode(displayID) {
            Log.stream("TV display now looks like \(current.width)×\(current.height) (\(current.pixelWidth)×\(current.pixelHeight) pixels)")
        }
        return applied
    }
}
