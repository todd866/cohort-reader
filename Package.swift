// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CohortReader",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "ReaderModel", targets: ["ReaderModel"]),
        .library(name: "EPUBEngine", targets: ["EPUBEngine"]),
        .library(name: "PDFEngine", targets: ["PDFEngine"]),
        .library(name: "ReaderStorage", targets: ["ReaderStorage"]),
        .library(name: "ManifoldClient", targets: ["ManifoldClient"]),
        .library(name: "HomeLibraryClient", targets: ["HomeLibraryClient"]),
        .library(name: "ReaderKit", targets: ["ReaderKit"]),
        .executable(name: "SnapshotTool", targets: ["SnapshotTool"]),
    ],
    targets: [
        .target(
            name: "ReaderModel",
            path: "Sources/ReaderModel"
        ),
        .target(
            name: "EPUBEngine",
            dependencies: ["ReaderModel"],
            path: "Sources/EPUBEngine",
            linkerSettings: [.linkedLibrary("z")]
        ),
        .target(
            name: "PDFEngine",
            dependencies: ["ReaderModel"],
            path: "Sources/PDFEngine"
        ),
        .target(
            name: "ReaderStorage",
            dependencies: ["ReaderModel"],
            path: "Sources/ReaderStorage",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(
            name: "ManifoldClient",
            dependencies: ["ReaderModel"],
            path: "Sources/ManifoldClient"
        ),
        .target(
            name: "HomeLibraryClient",
            dependencies: ["ReaderModel"],
            path: "Sources/HomeLibraryClient"
        ),
        .target(
            name: "ReaderKit",
            dependencies: [
                "ReaderModel",
                "EPUBEngine",
                "PDFEngine",
                "ReaderStorage",
                "ManifoldClient",
                "HomeLibraryClient",
            ],
            path: "Sources/ReaderKit"
        ),
        .executableTarget(
            name: "SnapshotTool",
            dependencies: ["ReaderKit"],
            path: "Sources/SnapshotTool"
        ),
        .testTarget(
            name: "ReaderKitTests",
            dependencies: ["ReaderKit"],
            path: "Tests/ReaderKitTests"
        ),
    ]
)
