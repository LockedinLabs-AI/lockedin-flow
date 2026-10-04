// swift-tools-version: 6.0
import PackageDescription

// AppKit-heavy targets build in Swift 5 language mode to avoid strict-concurrency
// friction with Apple frameworks; our own modules stay Sendable-aware regardless.
// The public-source build uses a separate runtime identity so it cannot share
// preferences, encrypted storage, or Keychain items with the maintained app.
let relaxed: [SwiftSetting] = [
    .swiftLanguageMode(.v5)
]
let appSettings =
    relaxed + [
        // Headless diagnostics can control the microphone and accessibility
        // insertion. They must never be compiled into a distribution binary.
        .define("LOCKEDIN_INTERNAL_DIAGNOSTICS", .when(configuration: .debug))
    ]

let package = Package(
    name: "LockedInFlow",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "lockedin-flow", targets: ["LockedInFlowApp"]),
        .library(name: "VoiceCore", targets: ["VoiceCore"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            exact: "0.15.5"
        )
    ],
    targets: [
        .target(
            name: "VoiceCore",
            path: "Sources/VoiceCore",
            swiftSettings: relaxed
        ),
        .target(
            name: "AudioCapture",
            dependencies: ["VoiceCore"],
            path: "Sources/AudioCapture",
            swiftSettings: relaxed
        ),
        .target(
            name: "SpeechEngine",
            dependencies: [
                "VoiceCore",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/SpeechEngine",
            swiftSettings: relaxed
        ),
        .target(
            name: "TextIntelligence",
            dependencies: ["VoiceCore"],
            path: "Sources/TextIntelligence",
            swiftSettings: relaxed
        ),
        .target(
            name: "InsertionEngine",
            dependencies: ["VoiceCore"],
            path: "Sources/InsertionEngine",
            swiftSettings: relaxed
        ),
        .target(
            name: "KeyboardShortcuts",
            path: "Vendor/KeyboardShortcuts/Sources/KeyboardShortcuts",
            exclude: ["Localization"],
            swiftSettings: relaxed
        ),
        .executableTarget(
            name: "LockedInFlowApp",
            dependencies: [
                "VoiceCore",
                "AudioCapture",
                "SpeechEngine",
                "TextIntelligence",
                "InsertionEngine",
                "KeyboardShortcuts",
            ],
            path: "Sources/LockedInFlowApp",
            swiftSettings: appSettings
        ),
        .testTarget(
            name: "VoiceCoreTests",
            dependencies: ["VoiceCore"],
            path: "Tests/VoiceCoreTests",
            swiftSettings: relaxed
        ),
        .testTarget(
            name: "TextIntelligenceTests",
            dependencies: ["TextIntelligence", "VoiceCore"],
            path: "Tests/TextIntelligenceTests",
            swiftSettings: relaxed
        ),
        .testTarget(
            name: "AudioCaptureTests",
            dependencies: ["AudioCapture"],
            path: "Tests/AudioCaptureTests",
            swiftSettings: relaxed
        ),
        .testTarget(
            name: "SpeechEngineTests",
            dependencies: ["SpeechEngine"],
            path: "Tests/SpeechEngineTests",
            swiftSettings: relaxed
        ),
        .testTarget(
            name: "InsertionEngineTests",
            dependencies: ["InsertionEngine"],
            path: "Tests/InsertionEngineTests",
            swiftSettings: relaxed
        ),
    ]
)
