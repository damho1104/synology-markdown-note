// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SynologyNote",
    platforms: [.macOS(.v14)],
    products: [.library(name: "NoteCore", targets: ["NoteCore"]), .executable(name: "SynologyNote", targets: ["SynologyNote"]),
               .executable(name: "CLIContractFixtures", targets: ["CLIContractFixtures"])],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.8.0"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", exact: "2.13.6")
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "NoteCore", dependencies: ["CSQLite", .product(name: "Markdown", package: "swift-markdown"), .product(name: "SwiftSoup", package: "SwiftSoup")]),
        .executableTarget(name: "CLIContractFixtures", dependencies: ["NoteCore"]),
        .executableTarget(
            name: "SynologyNote",
            dependencies: ["NoteCore"],
            resources: [.process("Resources")]
        ),
        .testTarget(name: "NoteCoreTests", dependencies: ["NoteCore", "SynologyNote", "CSQLite"])
    ]
)
