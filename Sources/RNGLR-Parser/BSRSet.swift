//
//  BSRSet.swift
//  RNGLRParser
//
//  Created by Ulf Akerstedt-Inoue on 2026/05/22.
//  Ported to use the Grammar package (hakkabon/Grammar) and the shared
//  Parser package's generic SPPFNode<Label> / SPPFGraph<Label> types.
//
// Binary Subtree Representation (BSR) set — records every completed grammar
// slot span discovered during a parse, à la Scott & Johnstone. The BSR set
// itself is algorithm-agnostic bookkeeping; `buildSPPF(grammar:)` is what
// turns it into a proper (binarised, shared) parse forest, walking the
// right-hand side of each completed production right-to-left and attaching
// `.symbol` / `.intermediate` / `.packed` / `.leaf` nodes as it goes.
//

import Foundation
import Grammar
import Parser

// MARK: - BSR Triple

/// One completed derivation step: `slot` (a fully-dotted `GrammarSlot`)
/// spanning `[leftExtent, rightExtent)`.
///
/// This is the literal Scott & Johnstone BSR triple — no pivot is recorded
/// here. A production's RHS can bind to more than one internal split point
/// once the SPPF is built (see `attachSymbol`), so a single pivot could not
/// be stored faithfully at this level even if we wanted to.
public struct BSRTriple: Hashable {
    public let slot: GrammarSlot
    public let leftExtent: Int
    public let rightExtent: Int
}

// MARK: - BSR Set

public final class BSRSet {
    private var triples: Set<BSRTriple> = []

    public init() {}

    public var isEmpty: Bool { triples.isEmpty }
    public var count: Int { triples.count }
    public var all: [BSRTriple] { Array(triples) }

    /// Record a completed slot spanning `[leftExtent, rightExtent)`.
    /// Returns `true` if this is a new triple.
    @discardableResult
    public func add(slot: GrammarSlot, leftExtent: Int, rightExtent: Int) -> Bool {
        triples.insert(BSRTriple(slot: slot, leftExtent: leftExtent, rightExtent: rightExtent)).inserted
    }

    public func reset() { triples.removeAll() }

    /// Best-effort conversion to the shared module's `BSR<GrammarSlot>`
    /// record, for diagnostic/inspection purposes only (e.g. `gtool`'s
    /// `--analysis sppf` output, or `ParseResult.bsr`). RNGLR's own
    /// `BSRTriple` predates per-symbol binarisation and, unlike an
    /// incrementally-built chart entry, does not carry a single pivot — a
    /// multi-symbol RHS can bind to several distinct pivots once the SPPF is
    /// built (see `attachSymbol`). `pivot` is set to `leftExtent` here as a
    /// documented placeholder; nothing in the parse or SPPF-construction
    /// pipeline reads it back.
    public var asSharedBSRSet: Set<BSR<GrammarSlot>> {
        Set(triples.map { triple in
            BSR(label: triple.slot, leftExtent: triple.leftExtent, pivot: triple.leftExtent, rightExtent: triple.rightExtent)
        })
    }

    // MARK: - SPPF construction

    /// Build an SPPF graph from the recorded BSR triples.
    public func buildSPPF(grammar: Grammar) -> SPPFGraph<GrammarSlot> {
        let graph = SPPFGraph<GrammarSlot>()
        var visited: Set<BSRTriple> = []
        var stepsDone: Set<StepKey> = []
        buildSymbolNodes(graph: graph, grammar: grammar, visited: &visited, stepsDone: &stepsDone)
        return graph
    }

    /// De-duplicates recursive `attachSymbol` calls: (production, dot,
    /// leftExtent, right) uniquely identifies one binarisation step, and
    /// without this guard a shared sub-derivation reachable through several
    /// packed-node alternatives would be re-expanded (and re-recursed) once
    /// per alternative.
    private struct StepKey: Hashable {
        let production: Production
        let dot: Int
        let leftExtent: Int
        let right: Int
    }

    private func buildSymbolNodes(
        graph: SPPFGraph<GrammarSlot>,
        grammar: Grammar,
        visited: inout Set<BSRTriple>,
        stepsDone: inout Set<StepKey>
    ) {
        for triple in triples {
            guard triple.slot.isCompleted else { continue }
            guard visited.insert(triple).inserted else { continue }

            let production = triple.slot.production
            let symNode = SPPFNode<GrammarSlot>.symbol(label: production.goal.name, leftExtent: triple.leftExtent, rightExtent: triple.rightExtent)
            graph.add(symNode)

            attachDerivations(
                to: symNode,
                production: production,
                leftExtent: triple.leftExtent,
                rightExtent: triple.rightExtent,
                grammar: grammar,
                graph: graph,
                stepsDone: &stepsDone
            )
        }
    }

    /// Attach every packed-node alternative for `production` to `parent`
    /// (a `.symbol` node representing the fully completed production).
    private func attachDerivations(
        to parent: SPPFNode<GrammarSlot>,
        production: Production,
        leftExtent: Int,
        rightExtent: Int,
        grammar: Grammar,
        graph: SPPFGraph<GrammarSlot>,
        stepsDone: inout Set<StepKey>
    ) {
        let rule = production.rule

        // A genuine epsilon production (rule == []) never advances the
        // input, so its packed node has no children at all — Grammar's
        // Production normalizes any bare-epsilon RHS down to `[]` (see
        // hakkabon/Grammar's Production.swift), so `rule.isEmpty` is the
        // reliable test. The `rule.count == 1 && rule[0].isEpsilon` arm below
        // is defensive: it should be unreachable given that normalization,
        // but is kept in case a symbol slips through un-normalized.
        if rule.isEmpty || (rule.count == 1 && rule[0].isEpsilon) {
            let packed = SPPFNode<GrammarSlot>.packed(label: GrammarSlot(production: production, dot: rule.count), leftExtent: leftExtent, rightExtent: rightExtent, pivot: leftExtent)
            graph.add(packed)
            graph.addEdge(from: parent, to: packed)
            return
        }

        attachSymbol(
            idx: rule.count - 1,
            rule: rule,
            production: production,
            parent: parent,
            leftExtent: leftExtent,
            right: rightExtent,
            grammar: grammar,
            graph: graph,
            stepsDone: &stepsDone
        )
    }

    /// Resolve `rule[idx]` (walking the RHS right-to-left) across every
    /// valid span ending at `right`, attaching one packed-node alternative
    /// to `parent` per candidate.
    ///
    /// `p = idx + 1` symbols have been matched once this step completes
    /// (`rule[0...idx]`). Per Scott & Johnstone §3.2's `mkPN`, a packed
    /// node's *left* part (`rule[0..<idx]`, i.e. everything but the just
    /// -resolved last symbol) is:
    ///   - absent                       when p == 1 (no left part at all — the
    ///                                   lone right child is the only child)
    ///   - a direct symbol/leaf node     when p == 2 (`|α| = 2`)
    ///   - an `.intermediate` node       when p  > 2 (`|α| > 2`), which is
    ///                                   itself recursively expanded
    ///
    /// Collapsing this into a single "always wrap idx > 0 in an
    /// intermediate node" rule (which is what a naive right-to-left walk
    /// would do) would attach an `.intermediate` left child even when
    /// `p == 2`, which the shared `CSTEnumeration` in the Parser module
    /// does not expect for a 2-symbol packed node — it looks for the plain
    /// symbol/leaf node directly. The three-way split below matches
    /// `CSTEnumeration._expandPackedNode`'s `alpha.count` branches exactly.
    private func attachSymbol(
        idx: Int,
        rule: [Symbol],
        production: Production,
        parent: SPPFNode<GrammarSlot>,
        leftExtent: Int,
        right: Int,
        grammar: Grammar,
        graph: SPPFGraph<GrammarSlot>,
        stepsDone: inout Set<StepKey>
    ) {
        let sym = rule[idx]

        if sym.isEpsilon || isMetaSymbol(sym) {
            if idx == 0 {
                let packed = SPPFNode<GrammarSlot>.packed(label: GrammarSlot(production: production, dot: 1), leftExtent: leftExtent, rightExtent: right, pivot: right)
                graph.add(packed)
                graph.addEdge(from: parent, to: packed)
            } else {
                attachSymbol(idx: idx - 1, rule: rule, production: production,
                             parent: parent, leftExtent: leftExtent, right: right,
                             grammar: grammar, graph: graph, stepsDone: &stepsDone)
            }
            return
        }

        for (childNode, newRight) in resolveCandidates(for: sym, right: right, grammar: grammar, graph: graph) {
            if idx > 0,
               newRight == leftExtent,
               !symbolsCanDeriveEmpty(Array(rule[..<idx]), grammar: grammar) {
                // The remaining prefix rule[0..<idx] can't possibly derive
                // empty, yet this candidate leaves it nothing to span — not
                // a valid split for this production.
                continue
            }

            switch idx {
            case 0:
                // p = 1: the single resolved symbol is the packed node's only child.
                guard newRight == leftExtent else { continue }
                let packed = SPPFNode<GrammarSlot>.packed(label: GrammarSlot(production: production, dot: 1), leftExtent: leftExtent, rightExtent: right, pivot: newRight)
                graph.add(packed)
                graph.addEdge(from: parent, to: packed)
                graph.addEdge(from: packed, to: childNode)

            case 1:
                // p = 2: the left part is the single symbol rule[0] —
                // attach it directly, no intermediate node needed.
                for (leftNode, leftNewRight) in resolveCandidates(for: rule[0], right: newRight, grammar: grammar, graph: graph) {
                    guard leftNewRight == leftExtent else { continue }
                    let packed = SPPFNode<GrammarSlot>.packed(label: GrammarSlot(production: production, dot: 2), leftExtent: leftExtent, rightExtent: right, pivot: newRight)
                    graph.add(packed)
                    graph.addEdge(from: parent, to: packed)
                    graph.addEdge(from: packed, to: leftNode)
                    graph.addEdge(from: packed, to: childNode)
                }

            default:
                // p > 2: the left part spans more than one symbol — attach
                // via an intermediate node representing rule[0..<idx], and
                // recursively expand that intermediate's own alternatives.
                let prefixSlot = GrammarSlot(production: production, dot: idx)
                let intNode = SPPFNode<GrammarSlot>.intermediate(label: prefixSlot, leftExtent: leftExtent, rightExtent: newRight)
                graph.add(intNode)

                let packed = SPPFNode<GrammarSlot>.packed(label: GrammarSlot(production: production, dot: idx + 1), leftExtent: leftExtent, rightExtent: right, pivot: newRight)
                graph.add(packed)
                graph.addEdge(from: parent, to: packed)
                graph.addEdge(from: packed, to: intNode)
                graph.addEdge(from: packed, to: childNode)

                let step = StepKey(production: production, dot: idx, leftExtent: leftExtent, right: newRight)
                if stepsDone.insert(step).inserted {
                    attachSymbol(idx: idx - 1, rule: rule, production: production,
                                 parent: intNode, leftExtent: leftExtent, right: newRight,
                                 grammar: grammar, graph: graph, stepsDone: &stepsDone)
                }
            }
        }
    }

    /// Every valid `(node, newLeftBoundary)` pair for `sym` ending at `right`:
    ///   - a terminal always resolves to exactly one leaf spanning `[right-1, right)`.
    ///   - a non-terminal resolves to one `.symbol` node per completed BSR
    ///     triple for that non-terminal ending at `right` — or, if none
    ///     exist but the non-terminal is nullable, a zero-width `.symbol`
    ///     node at `right` (mirrors the fact that a genuinely epsilon-only
    ///     completion never gets its own BSR triple; see `attachDerivations`).
    private func resolveCandidates(
        for sym: Symbol,
        right: Int,
        grammar: Grammar,
        graph: SPPFGraph<GrammarSlot>
    ) -> [(node: SPPFNode<GrammarSlot>, newLeft: Int)] {
        switch sym {
        case .terminal(let t):
            let childLeft = right - 1
            let leaf = SPPFNode<GrammarSlot>.leaf(label: terminalString(t), leftExtent: childLeft, rightExtent: right)
            graph.add(leaf)
            return [(leaf, childLeft)]

        case .nonTerminal(let nt):
            let matches = triples.filter {
                $0.slot.isCompleted && $0.slot.production.goal == nt && $0.rightExtent == right
            }
            if matches.isEmpty && grammar.nullableNonTerminals.contains(nt) {
                let node = SPPFNode<GrammarSlot>.symbol(label: nt.name, leftExtent: right, rightExtent: right)
                graph.add(node)
                return [(node, right)]
            }
            return matches.map { match in
                let node = SPPFNode<GrammarSlot>.symbol(label: nt.name, leftExtent: match.leftExtent, rightExtent: right)
                graph.add(node)
                return (node, match.leftExtent)
            }

        case .metaSymbol:
            // Callers filter meta symbols out via isMetaSymbol(_:) before
            // reaching here.
            fatalError("unreachable: meta symbols are handled by the isMetaSymbol(_:) check in attachSymbol")
        }
    }

    // MARK: - Helpers

    private func isMetaSymbol(_ symbol: Symbol) -> Bool {
        if case .metaSymbol = symbol { return true }
        return false
    }

    private func symbolsCanDeriveEmpty(_ symbols: [Symbol], grammar: Grammar) -> Bool {
        symbols.allSatisfy { symbol in
            switch symbol {
            case .nonTerminal(let nt): return grammar.nullableNonTerminals.contains(nt)
            case .terminal, .metaSymbol: return symbol.isEpsilon || isMetaSymbol(symbol)
            }
        }
    }

    private func terminalString(_ t: Terminal) -> String {
        switch t {
        case .string(let s): return s
        case .meta(let m): return m.rawValue
        case .regularExpression(let re): return re.pattern
        case .characterRange(let r): return "\(r.lowerBound)..\(r.upperBound)"
        case .stringList(let list): return list.joined(separator: "|")
        }
    }
}

// MARK: - Root lookup

public extension SPPFGraph where Label == GrammarSlot {
    /// The root symbol node for `startSymbol` spanning the whole input, if present.
    func root(startSymbol: String, inputLength: Int) -> SPPFNode<GrammarSlot>? {
        getAllNodes().first { node in
            if case let .symbol(label, l, r) = node {
                return label == startSymbol && l == 0 && r == inputLength
            }
            return false
        }
    }
}
