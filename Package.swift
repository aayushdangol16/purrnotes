// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PurrNotes",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "PurrNotes", path: "Sources/PurrNotes")
    ]
)
