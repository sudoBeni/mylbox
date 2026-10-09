// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RallyMail",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "RallyMail", targets: ["RallyMail"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.27.0"),
    ],
    targets: [
        // llama.cpp (pinned release b11165, 2026-09-24) for the on-device mail model.
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b11165/llama-b11165-xcframework.zip",
            checksum: "f55ff56e7e40d72cf192cb065f60e81de52d1597aa6d5bb347989efda876b36d"
        ),
        .target(
            name: "RallyMailCore",
            dependencies: [
                "llama",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "RallyMail",
            dependencies: ["RallyMailCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "RallyMailCoreTests",
            dependencies: ["RallyMailCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
