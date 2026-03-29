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
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.5"),
    ],
    targets: [
        .target(
            name: "VoxboardShared",
            dependencies: [
                "whisper",
                .product(name: "FluidAudio", package: "FluidAudio"),
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
    ]
)
