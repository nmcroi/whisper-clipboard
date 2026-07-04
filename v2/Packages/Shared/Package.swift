// swift-tools-version: 6.0
import PackageDescription

// WhisperShared: the cross-platform (macOS + iOS) layer shared by the mac app
// and the iOS companion app. It holds the pieces that are pure Foundation +
// cross-platform frameworks (Core, GRDB, FluidAudio, AVFoundation) and carry no
// AppKit/UIKit dependency:
//   • the TranscriptionEngine protocol + ParakeetEngine (FluidAudio, iOS 17+),
//   • the GRDB HistoryStore + schema + record bridges,
//   • AppSupport path helpers, and TranscriptSourceStyle.
//
// Anything AppKit-bound (AudioEngine's tap plumbing, the mac AppleSpeechEngine,
// captions, etc.) stays in the mac target; the iOS app gets its own thin
// AVAudioSession-based capture variant.
let package = Package(
    name: "WhisperShared",
    platforms: [
        .macOS(.v15),
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "WhisperShared",
            targets: ["WhisperShared"]
        )
    ],
    dependencies: [
        .package(path: "../Core"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.4")
    ],
    targets: [
        .target(
            name: "WhisperShared",
            dependencies: [
                .product(name: "Core", package: "Core"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "FluidAudio", package: "FluidAudio")
            ]
        )
    ]
)
