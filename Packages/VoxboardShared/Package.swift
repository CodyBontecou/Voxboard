// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VoxboardShared",
    platforms: [
        .iOS(.v17),
    ],
    products: [
        .library(name: "VoxboardShared", targets: ["VoxboardShared"]),
    ],
    targets: [
        .target(
            name: "VoxboardShared",
            dependencies: ["whisper"],
            linkerSettings: [
                .linkedFramework("Accelerate"),
                .linkedFramework("Metal"),
                .linkedFramework("Foundation"),
                .linkedFramework("CoreML"),
            ]
        ),
        .binaryTarget(
            name: "whisper",
            path: "../../whisper.xcframework"
        ),
    ]
)
