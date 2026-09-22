// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "InterviewRecorder",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "InterviewRecorder",
            path: "Sources/InterviewRecorder",
            // ponytail: Swift 5 mode. Strict concurrency fights every CoreAudio
            // callback here and buys nothing: each callback owns its own track.
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
