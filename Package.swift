// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StreamDrop",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "StreamDrop", targets: ["StreamDrop"])],
    targets: [
        .executableTarget(name: "StreamDrop"),
        .testTarget(name: "StreamDropTests", dependencies: ["StreamDrop"])
    ],
    swiftLanguageModes: [.v5]
)
