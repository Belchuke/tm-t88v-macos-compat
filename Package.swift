// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TMT88VCompat",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "tmt88v-diag", targets: ["tmt88v-diag"]),
        .executable(name: "tmt88v-test", targets: ["tmt88v-test"]),
        .executable(name: "tmt88v-raster-test", targets: ["tmt88v-raster-test"]),
        .executable(name: "tmt88v-service", targets: ["tmt88v-service"]),
        .executable(name: "tmt88v-updater", targets: ["tmt88v-updater"]),
    ],
    targets: [
        .target(
            name: "TMT88VCore",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("IOUSBHost"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreText"),
                .linkedFramework("ImageIO"),
            ]
        ),
        .executableTarget(name: "tmt88v-diag", dependencies: ["TMT88VCore"]),
        .executableTarget(name: "tmt88v-test", dependencies: ["TMT88VCore"]),
        .executableTarget(name: "tmt88v-raster-test", dependencies: ["TMT88VCore"]),
        .executableTarget(name: "tmt88v-service", dependencies: ["TMT88VCore"]),
        .target(name: "TMT88VUpdater"),
        .executableTarget(name: "tmt88v-updater", dependencies: ["TMT88VUpdater"]),
        .testTarget(name: "TMT88VCoreTests", dependencies: ["TMT88VCore"]),
        .testTarget(name: "TMT88VUpdaterTests", dependencies: ["TMT88VUpdater"]),
    ]
)
