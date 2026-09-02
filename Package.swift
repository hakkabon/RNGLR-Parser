// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RNGLR-Parser",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "RNGLR-Parser", targets: ["RNGLR-Parser"]),
        .executable(name: "rnglr-gtool", targets: ["rnglr-gtool"]),
        .executable(name: "demo", targets: ["demo"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.6.2"),
        .package(url: "https://github.com/JohnSundell/ShellOut.git", from: "2.0.0"),
        .package(url: "https://github.com/hakkabon/Grammar.git", revision: "69f85d7a493e1862412c34493e3656e94331df06"),
        .package(url: "https://github.com/hakkabon/GrammarTokenizer.git", revision: "880af85a1f5809866f9656405c801fd04bcb4df9"),
        .package(url: "https://github.com/hakkabon/GrammarDiagram.git", revision: "dc17ab061a1614ba0692be06aa69043b45bbbcd4"),
        .package(url: "https://github.com/hakkabon/TerminalColors.git", from: "0.0.1"),
        .package(url: "https://github.com/hakkabon/Parser.git", revision: "3663097550f3ed1b8dcad8a26f4c2c55cc61b4e1"),
    ],
    targets: [
        .target(
            name: "RNGLR-Parser",
            dependencies: [
                .product(name: "Grammar", package: "Grammar"),
                .product(name: "Tokenizer", package: "GrammarTokenizer"),
                .product(name: "GrammarDiagram", package: "GrammarDiagram"),
                .product(name: "TerminalColors", package: "TerminalColors"),
                .product(name: "Parser", package: "Parser"),
            ],
            path: "Sources/RNGLR-Parser",
        ),
        .testTarget(
            name: "RNGLR-ParserTests",
            dependencies: [
                "RNGLR-Parser",
                .product(name: "Grammar", package: "Grammar"),
                .product(name: "Parser", package: "Parser"),
            ],
            path: "Tests/RNGLR-ParserTests"
        ),
        // Move executable target to its destination (grammar toolbox) when library confirmed working.
        .executableTarget(
            name: "rnglr-gtool",
            dependencies: [
                "RNGLR-Parser",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "ShellOut", package: "shellout"),
                .product(name: "Grammar", package: "Grammar"),
                .product(name: "GrammarDiagram", package: "GrammarDiagram"),
                .product(name: "Parser", package: "Parser"),
            ],
            path: "Sources/gtool"
        ),
        .executableTarget(
            name: "demo",
            dependencies: [
                "RNGLR-Parser",
                .product(name: "Grammar", package: "Grammar"),
                .product(name: "Tokenizer", package: "GrammarTokenizer"),
                .product(name: "GrammarDiagram", package: "GrammarDiagram"),
                .product(name: "TerminalColors", package: "TerminalColors"),
                .product(name: "Parser", package: "Parser"),
            ],
       ),
    ]
)
