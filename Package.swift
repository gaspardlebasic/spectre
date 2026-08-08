// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Transcripteur",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Transcripteur",
            path: "Sources/Transcripteur",
            swiftSettings: [.unsafeFlags(["-Ounchecked"], .when(configuration: .release))]
        )
    ]
)
