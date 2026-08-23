// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Snap",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "Snap", targets: ["Snap"]),
    ],
    targets: [
        .target(
            name: "SnapCore",
            path: "Sources/Snap",
            exclude: ["main.swift"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
            ]
        ),
        .executableTarget(
            name: "Snap",
            dependencies: ["SnapCore"],
            path: "Sources/Snap",
            exclude: [
                "App",
                "Services",
            ]
        ),
        // Named Testing so `swift test` on Command Line Tools can call
        // __swiftPMEntryPoint without Apple's Testing.framework, which is
        // incomplete in CLT (missing lib_TestingInterop.dylib).
        .testTarget(
            name: "Testing",
            dependencies: ["SnapCore"],
            path: "Tests/SnapTests"
        ),
    ]
)
