// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "WhyNodeCore",
    defaultLocalization: "en",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "WhyNodeCore", targets: ["WhyNodeCore"]),
    ],
    targets: [
        .target(name: "WhyNodeCore", resources: [.process("Resources")]),
        .testTarget(
            name: "WhyNodeCoreTests",
            dependencies: ["WhyNodeCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
