// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "WhyNodeCore",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "WhyNodeCore", targets: ["WhyNodeCore"]),
    ],
    targets: [
        .target(name: "WhyNodeCore"),
        .testTarget(
            name: "WhyNodeCoreTests",
            dependencies: ["WhyNodeCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
