// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PaintMac",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "PaintMac", targets: ["PaintMac"])],
    targets: [
        .executableTarget(name: "PaintMac", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "PaintMacTests", dependencies: ["PaintMac"], swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
