// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TMT88VCompat",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "tmt88v-diag", targets: ["tmt88v-diag"]),
        .executable(name: "tmt88v-test", targets: ["tmt88v-test"]),
    ],
    targets: [
        .target(
            name: "TMT88VCore",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("IOUSBHost"),
            ]
        ),
        .executableTarget(name: "tmt88v-diag", dependencies: ["TMT88VCore"]),
        .executableTarget(name: "tmt88v-test", dependencies: ["TMT88VCore"]),
        .testTarget(name: "TMT88VCoreTests", dependencies: ["TMT88VCore"]),
    ]
)
