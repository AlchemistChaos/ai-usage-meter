// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CCManager",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "CCManager",
            path: "Sources/CCManager",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
