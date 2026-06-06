//
//  SPPF.swift
//  RNGLRParser
//
//  Created by Ulf Akerstedt-Inoue on 2026/05/22.
//  Ported to use the Grammar package (hakkabon/Grammar).
//
// Shared Packed Parse Forest nodes.
//
// The BSR set (Scott & Johnstone 2013) is the primary internal record of the parse.
// It stores triples  (slot, i, j)  meaning:
//   "grammar slot  A → α •  was completed spanning input[i..<j]"
//
// The SPPF is derived from the BSR set on demand.  SPPF nodes are:
//   • Symbol nodes    (A, i, j)   — non-terminal A spans input[i..<j]
//   • Terminal nodes  (t, i, j)   — terminal t spans input[i..<j]
//   • Intermediate   (slot, i, j) — partial RHS spanning input[i..<j]
//   • Packed nodes   (slot, k)    — one derivation alternative within a parent

import Foundation
import Grammar

// MARK: - SPPF Node

/// Discriminated union for all four SPPF node kinds.
public indirect enum SPPFNode: Hashable {

    /// A terminal leaf:  token `t` spanning [leftExtent, rightExtent)
    case terminal(symbol: String, leftExtent: Int, rightExtent: Int)

    /// A non-terminal symbol node:  `A` spanning [leftExtent, rightExtent)
    case symbol(name: String, leftExtent: Int, rightExtent: Int)

    /// An intermediate (binarised) node for a partial RHS:
    ///   `slot` has dot > 1 and dot < |rhs|, spanning [leftExtent, rightExtent)
    case intermediate(slot: GrammarSlot, leftExtent: Int, rightExtent: Int)

    /// A packed node — one alternative derivation.
    /// Always a child of either a symbol or intermediate node.
    ///   `slot`  is the completed or intermediate grammar slot
    ///   `pivot` is the split point in the input
    case packed(slot: GrammarSlot, pivot: Int)

    // MARK: Extent accessors (packed nodes have no extent of their own)

    public var leftExtent: Int? {
        switch self {
        case .terminal(_, let l, _):      return l
        case .symbol(_, let l, _):        return l
        case .intermediate(_, let l, _):  return l
        case .packed:                     return nil
        }
    }

    public var rightExtent: Int? {
        switch self {
        case .terminal(_, _, let r):      return r
        case .symbol(_, _, let r):        return r
        case .intermediate(_, _, let r):  return r
        case .packed:                     return nil
        }
    }
}

extension SPPFNode: CustomStringConvertible {
    public var description: String {
        switch self {
        case .terminal(let s, let l, let r):       return "Term(\(s),\(l),\(r))"
        case .symbol(let n, let l, let r):         return "Sym(\(n),\(l),\(r))"
        case .intermediate(let sl, let l, let r):  return "Int(\(sl),\(l),\(r))"
        case .packed(let sl, let k):               return "Pack(\(sl),k=\(k))"
        }
    }
}

// MARK: - SPPF Graph

/// The full SPPF graph: nodes plus their children lists.
/// Children of a symbol/intermediate node are packed nodes;
/// children of a packed node are at most two symbol/intermediate/terminal nodes.
public final class SPPFGraph {
    /// All nodes, keyed for deduplication.
    private var nodeSet: Set<SPPFNode> = []

    /// Children of each node (ordered; packed nodes have 1–2 children).
    private var childrenMap: [SPPFNode: [SPPFNode]] = [:]

    // MARK: Node access / creation

    /// Returns the canonical (shared) node, creating it if needed.
    @discardableResult
    public func intern(_ node: SPPFNode) -> SPPFNode {
        if let existing = nodeSet.member(node) { return existing }
        nodeSet.insert(node)
        return node
    }

    /// Add `child` as a child of `parent` (deduplicating).
    public func addChild(_ child: SPPFNode, to parent: SPPFNode) {
        if childrenMap[parent] == nil { childrenMap[parent] = [] }
        guard !childrenMap[parent]!.contains(child) else { return }
        childrenMap[parent]!.append(child)
    }

    /// Children of `node`.
    public func children(of node: SPPFNode) -> [SPPFNode] {
        childrenMap[node] ?? []
    }

    /// All nodes in the graph.
    public var allNodes: Set<SPPFNode> { nodeSet }

    // MARK: Root access

    /// The root symbol node for the start symbol over the whole input.
    public func root(startSymbol: String, inputLength: Int) -> SPPFNode? {
        let candidate = SPPFNode.symbol(name: startSymbol, leftExtent: 0, rightExtent: inputLength)
        return nodeSet.member(candidate)
    }
}

// MARK: - Set member-lookup helper

extension Set {
    /// Returns the actual stored element equal to `member`, or nil.
    func member(_ element: Element) -> Element? {
        guard let idx = firstIndex(of: element) else { return nil }
        return self[idx]
    }
}
