// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Protokoll",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .watchOS(.v10),
    ],
    products: [
        .library(name: "SharedKit", targets: ["SharedKit"]),
        .library(name: "Diagnostics", targets: ["Diagnostics"]),
        .library(name: "SearchIndex", targets: ["SearchIndex"]),
        .library(name: "MediaKit", targets: ["MediaKit"]),
        .executable(name: "process-session", targets: ["ProcessSession"]),
    ],
    targets: [
        .target(
            name: "SharedKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "Diagnostics",
            dependencies: ["SharedKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "SearchIndex",
            dependencies: ["SharedKit"],
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(
            name: "MediaKit",
            dependencies: ["SharedKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "ProcessSession",
            dependencies: ["SharedKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SharedKitTests",
            dependencies: ["SharedKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ProcessSessionTests",
            dependencies: ["ProcessSession", "SharedKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "DiagnosticsTests",
            dependencies: ["Diagnostics", "SharedKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SearchIndexTests",
            dependencies: ["SearchIndex", "SharedKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MediaKitTests",
            dependencies: ["MediaKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
