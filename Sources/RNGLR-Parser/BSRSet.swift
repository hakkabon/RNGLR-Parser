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
        var stepsDone: Set<StepKey> = []
        buildSymbolNodes(graph: graph, grammar: grammar, visited: &visited, stepsDone: &stepsDone)
        return graph
    }

    // MARK: Private SPPF builders

    /// Identifies one right-to-left binarisation step: "resolve `production`'s
    /// symbol at `dot - 1` across a span ending at `right`". Once this exact
    /// step has been fully attached to the graph, doing it again would only
    /// recreate (via `graph.intern`/`addChild`'s own deduplication) the same
    /// nodes and edges — this lets `attachSymbol` skip the repeat instead of
    /// redoing it, which matters because the same step can be reached from
    /// more than one candidate one level up whenever a span has more than
    /// one valid derivation.
    private struct StepKey: Hashable {
        let production: Production
        let dot: Int
        let leftExtent: Int
        let right: Int
    }

    private func buildSymbolNodes(graph: SPPFGraph, grammar: Grammar,
                                   visited: inout Set<BSRTriple>,
                                   stepsDone: inout Set<StepKey>) {
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

            // Attach every valid derivation of `prod` across this span as its
            // own packed-node child of symNode — see attachSymbol(_:)'s doc
            // comment for why this has to be "every", not just one.
            attachDerivations(to: symNode, production: prod,
                               leftExtent: triple.leftExtent, rightExtent: triple.rightExtent,
                               graph: graph, stepsDone: &stepsDone)
        }
    }

    private func attachDerivations(to parent: SPPFNode, production: Production,
                                    leftExtent: Int, rightExtent: Int,
                                    graph: SPPFGraph, stepsDone: inout Set<StepKey>) {
        let rule = production.rule

        // ε production (or a lone epsilon meta-terminal): one packed node, no children.
        if rule.isEmpty || (rule.count == 1 && isEpsilonSymbol(rule[0])) {
            let packed = graph.intern(SPPFNode.packed(slot: GrammarSlot(production: production, dot: rule.count), pivot: leftExtent))
            graph.addChild(packed, to: parent)
            return
        }

        attachSymbol(idx: rule.count - 1, rule: rule, production: production,
                     parent: parent, leftExtent: leftExtent, right: rightExtent,
                     graph: graph, stepsDone: &stepsDone)
    }

    /// Resolves `rule[idx]` (walking right-to-left, per the binarisation
    /// scheme described where the intermediate nodes are built below) across
    /// *every* valid span ending at `right`, attaching one packed-node
    /// alternative to `parent` per candidate — not just the first.
    ///
    /// A non-terminal symbol can have more than one valid span ending at the
    /// same `right` exactly when the grammar is ambiguous at this point (for
    /// example `S ::= S S` parsing three tokens: the first `S` can cover
    /// either the first token alone or the first two, and both are valid).
    /// Picking only one — which an earlier version of this method did, via
    /// `triples.first(where:)` — silently discards every alternative
    /// derivation, which is exactly the bug behind under-counting (or
    /// mis-counting) ambiguous parses.
    private func attachSymbol(idx: Int, rule: [Symbol], production: Production,
                               parent: SPPFNode, leftExtent: Int, right: Int,
                               graph: SPPFGraph, stepsDone: inout Set<StepKey>) {
        let sym = rule[idx]

        // Residual EBNF meta-symbols and epsilon meta-terminals occupy no
        // span; skip straight to the next symbol to the left (or finish).
        if isEpsilonSymbol(sym) || isMetaSymbol(sym) {
            if idx == 0 {
                let packed = graph.intern(SPPFNode.packed(slot: GrammarSlot(production: production, dot: 0), pivot: right))
                graph.addChild(packed, to: parent)
            } else {
                attachSymbol(idx: idx - 1, rule: rule, production: production,
                             parent: parent, leftExtent: leftExtent, right: right,
                             graph: graph, stepsDone: &stepsDone)
            }
            return
        }

        // Every valid (childNode, newRight) pair for rule[idx] ending at `right`.
        let candidates: [(node: SPPFNode, newRight: Int)]
        switch sym {
        case .terminal(let t):
            let childLeft = right - 1
            candidates = [(graph.intern(SPPFNode.terminal(symbol: terminalString(t), leftExtent: childLeft, rightExtent: right)), childLeft)]

        case .nonTerminal(let nt):
            let matches = triples.filter {
                $0.slot.isCompleted && $0.slot.production.goal == nt && $0.rightExtent == right
            }
            if matches.isEmpty {
                // Nullable: zero-width node, no ambiguity possible here.
                candidates = [(graph.intern(SPPFNode.symbol(name: nt.name, leftExtent: right, rightExtent: right)), right)]
            } else {
                candidates = matches.map {
                    (graph.intern(SPPFNode.symbol(name: nt.name, leftExtent: $0.leftExtent, rightExtent: right)), $0.leftExtent)
                }
            }

        case .metaSymbol:
            fatalError("unreachable: handled by the isMetaSymbol(_:) check above")
        }

        for (childNode, newRight) in candidates {
            if idx == 0 {
                // First symbol of the RHS: valid only if it actually reaches
                // back to the production's own left edge.
                guard newRight == leftExtent else { continue }
                let packed = graph.intern(SPPFNode.packed(slot: GrammarSlot(production: production, dot: 0), pivot: newRight))
                graph.addChild(packed, to: parent)
                graph.addChild(childNode, to: packed)
            } else {
                // Binarise: packed.children = [intermediate-node-for-prefix, thisSymbol].
                // (An earlier version of this method created the intermediate
                // node but never actually attached it here — silently
                // dropping every RHS symbol except the last from the tree.)
                let prefixSlot = GrammarSlot(production: production, dot: idx)
                let intNode = graph.intern(SPPFNode.intermediate(slot: prefixSlot, leftExtent: leftExtent, rightExtent: newRight))
                let packed  = graph.intern(SPPFNode.packed(slot: GrammarSlot(production: production, dot: idx + 1), pivot: newRight))
                graph.addChild(packed, to: parent)
                graph.addChild(intNode, to: packed)
                graph.addChild(childNode, to: packed)

                let step = StepKey(production: production, dot: idx, leftExtent: leftExtent, right: newRight)
                if stepsDone.insert(step).inserted {
                    attachSymbol(idx: idx - 1, rule: rule, production: production,
                                 parent: intNode, leftExtent: leftExtent, right: newRight,
                                 graph: graph, stepsDone: &stepsDone)
                }
            }
        }
    }

    // MARK: - Symbol helpers

    private func isEpsilonSymbol(_ sym: Symbol) -> Bool {
        if case .terminal(let t) = sym, case .meta(.eps) = t { return true }
        return false
    }

    private func isMetaSymbol(_ sym: Symbol) -> Bool {
        if case .metaSymbol = sym { return true }
        return false
    }

    /// Extract the display string for a Terminal value.
    private func terminalString(_ terminal: Terminal) -> String {
        switch terminal {
        case .string(let s):                return s
        case .characterRange(let r):        return "\(r.lowerBound)...\(r.upperBound)"
        case .stringList(let list):         return list.joined(separator: "|")
        case .regularExpression(let re):    return re.pattern
        case .meta(let m):                  return m.rawValue
        }
    }
}
