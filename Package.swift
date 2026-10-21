// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SnapDock",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "SnapDock", targets: ["SnapDock"])
    ],
    dependencies: [
        // Vendored: Command Line Tools cannot compile upstream #Preview macros.
        .package(path: "Vendor/KeyboardShortcuts")
    ],
    targets: [
        .executableTarget(
            name: "SnapDock",
            dependencies: [
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts")
            ],
            path: "Sources/SnapDock",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "SnapDockTests",
            dependencies: [
                "SnapDock",
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts")
            ],
            path: "Tests/SnapDockTests"
        )
    ]
)
