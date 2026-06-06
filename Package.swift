// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RNGLR-Parser",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "RNGLR-Parser", targets: ["RNGLR-Parser"]),
        .executable(name: "gtool", targets: ["gtool"]),
        .executable(name: "demo", targets: ["demo"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.6.2"),
        .package(url: "https://github.com/JohnSundell/ShellOut.git", from: "2.0.0"),
        .package(url: "https://github.com/hakkabon/Grammar.git", branch: "main"),
        .package(url: "https://github.com/hakkabon/GrammarTokenizer.git", branch: "main"),
        .package(url: "https://github.com/hakkabon/GrammarDiagram.git", branch: "main"),
        .package(url: "https://github.com/hakkabon/TerminalColors.git", from: "0.0.1"),
    ],
    targets: [
        .target(
            name: "RNGLR-Parser",
            dependencies: [
                .product(name: "Grammar", package: "Grammar"),
                .product(name: "Tokenizer", package: "GrammarTokenizer"),
                .product(name: "GrammarDiagram", package: "GrammarDiagram"),
                .product(name: "TerminalColors", package: "TerminalColors"),
            ],
            path: "Sources/RNGLR-Parser",
        ),
        .testTarget(
            name: "RNGLR-ParserTests",
            dependencies: [
                "RNGLR-Parser",
                .product(name: "Grammar", package: "Grammar"),
            ],
            path: "Tests/RNGLR-ParserTests"
        ),
        // Move executable target to its destination (grammar toolbox) when library confirmed working.
        .executableTarget(
            name: "gtool",
            dependencies: [
                "RNGLR-Parser",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "ShellOut", package: "shellout"),
                .product(name: "Grammar", package: "Grammar"),
                .product(name: "GrammarDiagram", package: "GrammarDiagram"),
            ]
        ),
        .executableTarget(
            name: "demo",
            dependencies: [
                "RNGLR-Parser",
                .product(name: "Grammar", package: "Grammar"),
                .product(name: "Tokenizer", package: "GrammarTokenizer"),
                .product(name: "GrammarDiagram", package: "GrammarDiagram"),
                .product(name: "TerminalColors", package: "TerminalColors"),
            ],
        ),
    ]
)
