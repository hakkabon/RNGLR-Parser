//
//  BSRSet.swift
//  RNGLRParser
//
//  Created by Ulf Akerstedt-Inoue on 2026/05/24.
//  Ported to use the Grammar package (hakkabon/Grammar) — uses NonTerminal, Production, Symbol.
//

import Foundation
import Grammar

// MARK: - BSR Triple

/// A Binary Subtree Representation triple: (slot, leftExtent, rightExtent).
/// Corresponds to a completed (or right-nulled) grammar slot over input[l..<r].
public struct BSRTriple: Hashable {
    public let slot: GrammarSlot
    public let leftExtent: Int
    public let rightExtent: Int
}

// MARK: - BSR Set

/// The BSR set accumulates all derivations recorded during the parse.
/// Space: O(n²) in the length of the input.  Each triple is stored once.
public final class BSRSet {
    private var triples: Set<BSRTriple> = []

    // MARK: Recording

    /// Record the triple (slot, l, r) — idempotent (set semantics).
    @discardableResult
    public func add(slot: GrammarSlot, leftExtent: Int, rightExtent: Int) -> Bool {
        let triple = BSRTriple(slot: slot, leftExtent: leftExtent, rightExtent: rightExtent)
        return triples.insert(triple).inserted
    }

    public var isEmpty: Bool { triples.isEmpty }
    public var count: Int { triples.count }

    // MARK: Querying

    /// All triples for a completed slot (dot == rule.count) that start at `l`.
    public func completed(from l: Int) -> [BSRTriple] {
        triples.filter { $0.slot.isCompleted && $0.leftExtent == l }
    }

    /// All triples whose slot's LHS is `nt` and that span [l, r).
    public func triples(lhs nt: NonTerminal, from l: Int, to r: Int) -> [BSRTriple] {
        triples.filter {
            $0.slot.isCompleted &&
            $0.slot.production.goal == nt &&
            $0.leftExtent == l &&
            $0.rightExtent == r
        }
    }

    /// All recorded triples (for SPPF construction).
    public var all: Set<BSRTriple> { triples }

    public func reset() { triples.removeAll() }

    // MARK: - SPPF Derivation

    /// Build an SPPF graph from the current BSR set.
    /// Call this after a successful parse.
    public func buildSPPF(grammar: Grammar) -> SPPFGraph {
        let graph = SPPFGraph()
        var visited: Set<BSRTriple> = []
        buildSymbolNodes(graph: graph, grammar: grammar, visited: &visited)
        return graph
    }

    // MARK: Private SPPF builders

    private func buildSymbolNodes(graph: SPPFGraph, grammar: Grammar, visited: inout Set<BSRTriple>) {
        for triple in triples {
            guard triple.slot.isCompleted else { continue }
            guard visited.insert(triple).inserted else { continue }

            let prod = triple.slot.production

            // Symbol node: non-terminal `goal` spanning [leftExtent, rightExtent)
            let symNode = graph.intern(
                SPPFNode.symbol(name: prod.goal.name,
                                leftExtent: triple.leftExtent,
                                rightExtent: triple.rightExtent)
            )

            // Packed node for this derivation alternative
            let packedNode = graph.intern(
                SPPFNode.packed(slot: triple.slot, pivot: triple.leftExtent)
            )
            graph.addChild(packedNode, to: symNode)

            // Attach the RHS children to the packed node
            attachRHS(to: packedNode,
                      production: prod,
                      leftExtent: triple.leftExtent,
                      rightExtent: triple.rightExtent,
                      graph: graph)
        }
    }

    private func attachRHS(to packed: SPPFNode,
                           production: Production,
                           leftExtent: Int,
                           rightExtent: Int,
                           graph: SPPFGraph){
        // ε production: no children
        if production.rule.isEmpty { return }
        // Also skip if the sole symbol is an epsilon meta-terminal
        if production.rule.count == 1,
           case .terminal(let t) = production.rule[0],
           case .meta(.eps) = t { return }

        // Binarise: walk RHS from right to left, creating intermediate nodes.
        // For A → X₁ X₂ … Xn we create:
        //   Int(A→X₁…Xk•Xk+1…Xn, l, m) → packed → [Int(…,l,m'), Term/Sym(Xk,m',m)]
        var right = rightExtent
        var parent: SPPFNode = packed

        for idx in stride(from: production.rule.count - 1, through: 0, by: -1) {
            let sym = production.rule[idx]
            let childNode: SPPFNode

            switch sym {
            case .terminal(let t):
                // Skip epsilon meta-terminals — they have no span
                if case .meta(.eps) = t { continue }
                let tokenString = terminalString(t)
                childNode = graph.intern(
                    SPPFNode.terminal(symbol: tokenString,
                                      leftExtent: right - 1,
                                      rightExtent: right)
                )
                right -= 1

            case .nonTerminal(let nt):
                // Find a BSR triple for this non-terminal ending at `right`
                if let match = triples.first(where: {
                    $0.slot.isCompleted &&
                    $0.slot.production.goal == nt &&
                    $0.rightExtent == right
                }) {
                    childNode = graph.intern(
                        SPPFNode.symbol(name: nt.name,
                                        leftExtent: match.leftExtent,
                                        rightExtent: right)
                    )
                    right = match.leftExtent
                } else {
                    // Nullable: zero-width node
                    childNode = graph.intern(
                        SPPFNode.symbol(name: nt.name, leftExtent: right, rightExtent: right)
                    )
                }

            case .metaSymbol:
                // EBNF meta-symbols are expanded before parsing — ignore residual ones
                continue
            }

            graph.addChild(childNode, to: parent)

            // If there are more symbols to the left, create an intermediate node
            if idx > 0 {
                let slot = GrammarSlot(production: production, dot: idx)
                let intNode = graph.intern(
                    SPPFNode.intermediate(slot: slot, leftExtent: leftExtent, rightExtent: right)
                )
                let intPacked = graph.intern(
                    SPPFNode.packed(slot: slot, pivot: right)
                )
                graph.addChild(intPacked, to: intNode)
                parent = intPacked
            }
        }
    }

    // MARK: - Symbol helpers

    /// Extract the display string for a Terminal value.
    private func terminalString(_ terminal: Terminal) -> String {
        switch terminal {
        case .string(let s):                return s
        case .characterRange(let r):        return "\(r.lowerBound)...\(r.upperBound)"
        case .regularExpression(let re):    return re.pattern
        case .meta(let m):                  return m.rawValue
        }
    }
}
