import Foundation
import Grammar
import Parser

/// Engine-owned executable microbenchmarks for the RNGLR implementation.
public enum RNGLRMicrobenchmarks {
    public static let ownerVersion = "0.2.3"
    public static let inputScale = 20

    private static let grammarSource = """
    <E> ::= <E> '+' <E> | 'id'
    """
    private static var input: String {
        Array(repeating: "id", count: inputScale).joined(separator: " + ")
    }

    public static func suite(
        buildConfiguration: ParserEngineMicrobenchmarkSuite.BuildConfiguration,
        warmupIterations: Int = 2,
        measurementIterations: Int = 10
    ) -> ParserEngineMicrobenchmarkSuite {
        .init(
            owner: .init(repository: "RNGLR-Parser", version: ownerVersion),
            engineID: "rnglr", id: "rnglr-core-v1", title: "RNGLR core workloads",
            buildConfiguration: buildConfiguration,
            warmupIterations: warmupIterations,
            measurementIterations: measurementIterations,
            cases: [.init(
                id: "ambiguous-expression-forest", title: "Build an ambiguous expression forest",
                operation: .forestConstruction,
                boundary: "Tokenize and construct the GSS, BSR, and SPPF with a pre-built RNGLRParser.",
                workloadFingerprint: ParserEngineMicrobenchmarkCodec.evidenceFingerprint([
                    grammarSource, input, "prebuilt-parser", "gss-bsr-sppf"
                ]),
                scale: inputScale
            )]
        )
    }

    public static func run(
        buildConfiguration: ParserEngineMicrobenchmarkSuite.BuildConfiguration,
        warmupIterations: Int = 2,
        measurementIterations: Int = 10,
        environment: ParserEngineMicrobenchmarkEnvironment = .current
    ) throws -> ParserEngineMicrobenchmarkReport {
        let parser = RNGLRParser(grammar: try Grammar(bnf: grammarSource, start: "E"))
        return try ParserEngineMicrobenchmarkRunner.run(
            suite(
                buildConfiguration: buildConfiguration,
                warmupIterations: warmupIterations,
                measurementIterations: measurementIterations
            ),
            environment: environment
        ) { _ in
            let result = try parser.parse(input)
            let nodes = result.sppfGraph?.getAllNodes().count ?? 0
            return .init(
                evidenceFingerprint: ParserEngineMicrobenchmarkCodec.evidenceFingerprint([
                    String(result.isSuccessful), String(result.bsr.count), String(nodes),
                    String(result.hasAmbiguity)
                ]),
                counters: [
                    "accepted": result.isSuccessful ? 1 : 0,
                    "ambiguous": result.hasAmbiguity ? 1 : 0,
                    "bsrCount": result.bsr.count, "forestNodeCount": nodes
                ]
            )
        }
    }
}
