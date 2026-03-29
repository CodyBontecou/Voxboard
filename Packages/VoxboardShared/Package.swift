// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VoxboardShared",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "VoxboardShared", targets: ["VoxboardShared"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.5"),
    ],
    targets: [
        .target(
            name: "VoxboardShared",
            dependencies: [
                .target(name: "whisper", condition: .when(platforms: [.iOS])),
                .product(name: "FluidAudio", package: "FluidAudio", condition: .when(platforms: [.iOS])),
            ],
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
        .testTarget(
            name: "VoxboardSharedTests",
            dependencies: ["VoxboardShared"]
        ),
    ]
)
