// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "mdr",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "mdr", targets: ["MDRApp"]), .library(name: "MDRCore", targets: ["MDRCore"])],
    targets: [
        .target(name: "MDRCore"),
        .executableTarget(name: "MDRApp", dependencies: ["MDRCore"], resources: [.copy("Resources/Web")]),
        .testTarget(name: "MDRCoreTests", dependencies: ["MDRCore"])
    ],
    swiftLanguageModes: [.v5]
)
