//
//  RunExample.swift
//  demo
//
//  Shared harness for the RNGLR parser demo.
//  Demonstrates: tokenizer pipeline, BSR triples, SPPF graph, and CST enumeration.
//

import Foundation
import RNGLR_Parser
import Grammar

/// Run a single named parse example, printing full diagnostic output.
///
/// - Parameters:
///   - name:    Display name for the example.
///   - grammar: Grammar to use (built via `Grammar(bnf:start:)`).
///   - input:   Raw source string to parse (tokenised internally by `RNGLRParser`).
public func runExample(name: String, grammar: Grammar, input: String) {
    print("\n" + String(repeating: "═", count: 68))
    print("  \(name)")
    print(String(repeating: "═", count: 68))
    print("  Input:  \"\(input)\"\n")

    let parser = RNGLRParser(grammar: grammar)

    // Show what the tokenizer sees (diagnostic only).
    let tokens = parser.tokenize(input)
    let tokenDisplay = tokens
        .filter { $0.type != .eof }
        .map { "[\($0.type.value)]" }
        .joined(separator: " ")
    print("  Tokens: \(tokenDisplay)")
    print("  Count:  \(tokens.filter { $0.type != .eof }.count)\n")

    let result: ParseResult
    do {
        result = try parser.parse(input)
    } catch {
        print("  ✗ Tokenizer error: \(error)")
        return
    }

    switch result {
    case .failure(let pos, let msg):
        print("  ✗ Parse FAILED at position \(pos): \(msg)")

    case .success(let bsr, let sppf):
        print("  ✓ Parse succeeded")
        print("  BSR triples recorded: \(bsr.count)")
        if result.hasAmbiguity { print("  ⚡ Grammar is AMBIGUOUS for this input") }

        let startName = grammar.start.name
        // inputLength = number of real tokens (exclude the EOF sentinel)
        let tokenCount = tokens.count { $0.type != .eof }
        guard let root = sppf.root(startSymbol: startName, inputLength: tokenCount) else {
            print("  ✗ SPPF root not found (startSymbol=\(startName), length=\(tokenCount))")
            print("  Available roots (sample):")
            for n in sppf.allNodes.prefix(6) { print("    \(n)") }
            return
        }

        let enumerator = CSTEnumerator(graph: sppf)
        var visited = Set<SPPFNode>()
        let allTrees = enumerator.trees(for: root, visited: &visited)

        print("  Derivations (parse trees): \(allTrees.count)")
        for (i, tree) in allTrees.prefix(4).enumerated() {
            print("\n  ── Tree \(i + 1) ──────────────────────────")
            for node in tree { print(node.description) }
        }
        if allTrees.count > 4 {
            print("  … (\(allTrees.count - 4) more trees omitted)")
        }

        print("\n  ── BSR Triples ──────────────────────────")
        for triple in bsr.all.sorted(by: {
            ($0.leftExtent, $0.rightExtent) < ($1.leftExtent, $1.rightExtent)
        }) {
            print("  [\(triple.slot)] @ [\(triple.leftExtent), \(triple.rightExtent))")
        }

        print("\n  ── SPPF Nodes ───────────────────────────")
        for node in sppf.allNodes.sorted(by: { $0.description < $1.description }) {
            let kids = sppf.children(of: node)
            if kids.isEmpty {
                print("  \(node)")
            } else {
                let kidStr = kids.map(\.description).joined(separator: ", ")
                print("  \(node)  →  \(kidStr)")
            }
        }
    }
}
