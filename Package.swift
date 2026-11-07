// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwiftIT",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .tvOS(.v17),
        .watchOS(.v10),
        .visionOS(.v1)
    ],
    products: [
        .library(name: "SwiftIT", targets: ["SwiftIT"])
    ],
    targets: [
        .target(name: "SwiftIT"),
        .testTarget(name: "SwiftITTests", dependencies: ["SwiftIT"])
    ],
    swiftLanguageModes: [.v6]
)
