//
//  GSS.swift
//  RNGLRParser
//
//  Created by Ulf Akerstedt-Inoue on 2026/05/22.
//  Ported to use the Grammar package (hakkabon/Grammar).
//
// Graph Structured Stack for GLR parsing.
//
// A GSS node represents a unique (state, input-position) pair.
// GSS edges carry the SPPF node produced when the edge was created.
// Multiple active tops (frontiers) are maintained simultaneously, one per
// live parser head.  Sharing at the same (state, position) naturally merges
// paths and prevents exponential blowup.

import Foundation
import Grammar
import Parser

// MARK: - GSS Node

/// A node in the Graph Structured Stack.
/// Identity is determined solely by (state, inputPosition).
public final class GSSNode: Hashable {
    public let state: Int
    public let inputPosition: Int

    /// Outgoing edges toward the bottom of the stack (downward).
    public private(set) var edges: [GSSEdge] = []

    init(state: Int, inputPosition: Int) {
        self.state         = state
        self.inputPosition = inputPosition
    }

    /// Add an edge to `target`, labelled with `sppfNode`.
    /// Returns `true` if this is a new edge (not already present).
    @discardableResult
    func addEdge(to target: GSSNode, label: SPPFNode<GrammarSlot>?) -> Bool {
        let edge = GSSEdge(from: self, to: target, label: label)
        if edges.contains(edge) { return false }
        edges.append(edge)
        return true
    }

    // MARK: Hashable / Equatable — identity by (state, position)
    public static func == (lhs: GSSNode, rhs: GSSNode) -> Bool {
        lhs.state == rhs.state && lhs.inputPosition == rhs.inputPosition
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(state)
        hasher.combine(inputPosition)
    }
}

extension GSSNode: CustomStringConvertible {
    public var description: String { "GSS(\(state), \(inputPosition))" }
}

// MARK: - GSS Edge

/// A directed edge in the Graph Structured Stack.
/// Edges point *downward* (from top toward bottom of the stack).
public struct GSSEdge: Hashable {
    public let from: GSSNode        // node closer to stack top
    public let to: GSSNode          // node closer to stack bottom
    public let label: SPPFNode<GrammarSlot>?     // SPPF node produced when this frame was pushed

    /// Equality ignores `label`: only the (from, to) pair determines identity,
    /// so duplicate edges are detected correctly; the label of the first edge is kept.
    public static func == (lhs: GSSEdge, rhs: GSSEdge) -> Bool {
        lhs.from === rhs.from && lhs.to === rhs.to
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(from))
        hasher.combine(ObjectIdentifier(to))
    }
}

// MARK: - GSS (the whole structure)

/// Manages the collection of all GSS nodes, keyed by (state, position).
/// Provides the node-creation / edge-creation primitives used by the parser.
public final class GSS {
    private var nodes: [NodeKey: GSSNode] = [:]

    private struct NodeKey: Hashable {
        let state: Int
        let position: Int
    }

    /// Returns an existing node for (state, position) or creates a new one.
    public func node(state: Int, position: Int) -> GSSNode {
        let key = NodeKey(state: state, position: position)
        if let existing = nodes[key] { return existing }
        let n = GSSNode(state: state, inputPosition: position)
        nodes[key] = n
        return n
    }

    /// Convenience: create an edge and return whether it was newly added.
    @discardableResult
    public func addEdge(from: GSSNode, to: GSSNode, label: SPPFNode<GrammarSlot>?) -> Bool {
        from.addEdge(to: to, label: label)
    }

    /// All currently-alive nodes (useful for iterating the frontier).
    public var allNodes: [GSSNode] { Array(nodes.values) }

    public func reset() { nodes.removeAll() }
}
