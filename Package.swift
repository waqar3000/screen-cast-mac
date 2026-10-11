// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ScreenCast",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "CGVirtualDisplay", path: "Sources/CGVirtualDisplay",
                linkerSettings: [.linkedFramework("CoreGraphics")]),
        .executableTarget(name: "ScreenCast", dependencies: ["CGVirtualDisplay"], path: "Sources/ScreenCast"),
        .testTarget(name: "ScreenCastTests", dependencies: ["ScreenCast"], path: "Tests/ScreenCastTests"),
    ]
)
