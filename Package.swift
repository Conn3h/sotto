// swift-tools-version: 6.2
import PackageDescription

// Three products, deliberately split:
// - SottoText and SottoDictionary are Foundation-only and platform-neutral, so every
//   line of text processing is unit-testable without a window, a microphone, or macOS 26.
// - Sotto is the app: AppKit, SwiftUI, Speech, and the OS-level machinery.
let package = Package(
    name: "Sotto",
    platforms: [.macOS(.v26)],
    targets: [
        .target(
            name: "SottoText",
            path: "Sources/SottoText",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "SottoDictionary",
            path: "Sources/SottoDictionary",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "Sotto",
            dependencies: ["SottoText", "SottoDictionary"],
            path: "Sources/Sotto",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SottoTextTests",
            dependencies: ["SottoText"],
            path: "Tests/SottoTextTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SottoDictionaryTests",
            dependencies: ["SottoDictionary"],
            path: "Tests/SottoDictionaryTests",
            resources: [.copy("vectors.json")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
