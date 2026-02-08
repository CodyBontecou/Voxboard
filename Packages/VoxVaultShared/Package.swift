// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VoxVaultShared",
    platforms: [
        .iOS(.v17),
    ],
    products: [
        .library(name: "VoxVaultShared", targets: ["VoxVaultShared"]),
    ],
    targets: [
        .target(
            name: "VoxVaultShared",
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
