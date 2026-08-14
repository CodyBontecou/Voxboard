// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VoxboardShared",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .watchOS(.v10),
    ],
    products: [
        .library(name: "VoxboardCaptureCore", targets: ["VoxboardCaptureCore"]),
        .library(name: "VoxCoreGenerated", targets: ["VoxCoreGenerated"]),
        .library(name: "VoxCoreRust", targets: ["VoxCoreRust"]),
        .library(name: "VoxboardShared", targets: ["VoxboardShared"]),
        .executable(name: "VoxboardPersistenceFixtures", targets: ["VoxboardPersistenceFixtures"]),
        .executable(name: "VoxboardM2Oracle", targets: ["VoxboardM2Oracle"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.13.4"),
        .package(url: "https://github.com/CodyBontecou/ExportKit", branch: "main"),
    ],
    targets: [
        .systemLibrary(
            name: "VoxCoreFFI"
        ),
        .target(
            name: "VoxCoreGenerated",
            dependencies: ["VoxCoreFFI"]
        ),
        .target(
            name: "VoxboardCaptureCore"
        ),
        .target(
            name: "VoxCoreRust",
            dependencies: ["VoxCoreGenerated", "VoxboardCaptureCore"]
        ),
        .target(
            name: "VoxboardShared",
            dependencies: [
                "VoxboardCaptureCore",
                .target(name: "whisper", condition: .when(platforms: [.iOS, .macOS])),
                .product(name: "FluidAudio", package: "FluidAudio", condition: .when(platforms: [.iOS, .macOS])),
                .product(name: "ExportKit", package: "ExportKit"),
            ],
            linkerSettings: [
                .linkedFramework("Accelerate"),
                .linkedFramework("Metal"),
                .linkedFramework("Foundation"),
                .linkedFramework("Security"),
                .linkedFramework("CoreML"),
            ]
        ),
        .binaryTarget(
            name: "whisper",
            path: "../../whisper.xcframework"
        ),
        .executableTarget(
            name: "VoxboardPersistenceFixtures",
            dependencies: ["VoxboardCaptureCore", "VoxboardShared"]
        ),
        .executableTarget(
            name: "VoxboardM2Oracle",
            dependencies: ["VoxboardCaptureCore"]
        ),
        .testTarget(
            name: "VoxboardCaptureCoreTests",
            dependencies: ["VoxboardCaptureCore"]
        ),
        .testTarget(
            name: "VoxboardSharedTests",
            dependencies: [
                "VoxboardShared",
                .product(name: "ExportKit", package: "ExportKit"),
            ]
        ),
    ]
)
