// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CleanDesk",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "CleanDesk", targets: ["CleanDesk"])],
    targets: [
        .target(name: "CleanDeskCore"),
        .executableTarget(name: "CleanDesk", dependencies: ["CleanDeskCore"]),
        .testTarget(name: "CleanDeskCoreTests", dependencies: ["CleanDeskCore"]),
        .testTarget(name: "CleanDeskTests", dependencies: ["CleanDesk"]),
    ],
    swiftLanguageModes: [.v5]
)
