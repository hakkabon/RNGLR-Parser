import Foundation
import IncrementalParsing

public extension ReuseDimension {
    static let gssNodes = Self(rawValue: "gssNodes")
}

public struct RNGLRStableTokenID: Hashable, Sendable {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

public struct RNGLRReusableNodeID: Hashable, Sendable {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

public final class RNGLRReusableNode<Payload> {
    public let id: RNGLRReusableNodeID
    public private(set) var payload: Payload
    public private(set) var tokenDependencies: Set<RNGLRStableTokenID>
    public private(set) var outgoing: Set<RNGLRReusableNodeID>

    fileprivate init(id: RNGLRReusableNodeID, payload: Payload,
                     tokenDependencies: Set<RNGLRStableTokenID>, outgoing: Set<RNGLRReusableNodeID>) {
        self.id = id; self.payload = payload
        self.tokenDependencies = tokenDependencies; self.outgoing = outgoing
    }

    fileprivate func update(payload: Payload, tokenDependencies: Set<RNGLRStableTokenID>,
                            outgoing: Set<RNGLRReusableNodeID>) {
        self.payload = payload; self.tokenDependencies = tokenDependencies; self.outgoing = outgoing
    }
}

public struct RNGLRReuseEvidence: Sendable {
    public let invalidated: Set<RNGLRReusableNodeID>
    public let retained: Set<RNGLRReusableNodeID>

    fileprivate func measurement(
        dimension: ReuseDimension,
        rebuilt: Int,
        strategy: String
    ) -> ReuseMeasurement {
        precondition(rebuilt >= 0, "rebuilt node count cannot be negative")
        return .init(
            dimension: dimension,
            reused: retained.count,
            rebuilt: rebuilt,
            removed: invalidated.count,
            strategy: strategy)
    }
}

public struct RNGLRWorkspaceInvalidation: Sendable {
    public let graph: RNGLRReuseEvidence
    public let forest: RNGLRReuseEvidence

    public func executionEvidence(
        rebuiltGraphNodes: Int,
        rebuiltForestNodes: Int
    ) -> IncrementalExecutionEvidence {
        .init(
            strategy: .incremental,
            measurements: [
                graph.measurement(
                    dimension: .gssNodes,
                    rebuilt: rebuiltGraphNodes,
                    strategy: "gss-dependency-invalidation"),
                forest.measurement(
                    dimension: .forestNodes,
                    rebuilt: rebuiltForestNodes,
                    strategy: "sppf-dependency-invalidation"),
            ])
    }
}

/// Interns graph nodes by grammar/state/span identity. Surviving nodes retain
/// their class identity across edits; affected nodes and their parents do not.
public final class RNGLRReuseArena<Payload> {
    private var nodes: [RNGLRReusableNodeID: RNGLRReusableNode<Payload>] = [:]
    public init() {}
    public var count: Int { nodes.count }
    public var nodeIDs: Set<RNGLRReusableNodeID> { Set(nodes.keys) }
    public subscript(id: RNGLRReusableNodeID) -> RNGLRReusableNode<Payload>? { nodes[id] }

    @discardableResult
    public func intern(id: RNGLRReusableNodeID, payload: @autoclosure () -> Payload,
                       tokenDependencies: Set<RNGLRStableTokenID> = [],
                       outgoing: Set<RNGLRReusableNodeID> = []) -> RNGLRReusableNode<Payload> {
        if let existing = nodes[id] { return existing }
        let node = RNGLRReusableNode(id: id, payload: payload(),
                                    tokenDependencies: tokenDependencies, outgoing: outgoing)
        nodes[id] = node
        return node
    }

    @discardableResult
    public func replace(id: RNGLRReusableNodeID, payload: Payload,
                        tokenDependencies: Set<RNGLRStableTokenID> = [],
                        outgoing: Set<RNGLRReusableNodeID> = []) -> RNGLRReusableNode<Payload> {
        if let existing = nodes[id] {
            existing.update(payload: payload, tokenDependencies: tokenDependencies, outgoing: outgoing)
            return existing
        }
        return intern(id: id, payload: payload, tokenDependencies: tokenDependencies, outgoing: outgoing)
    }

    @discardableResult
    public func invalidate(tokens changed: Set<RNGLRStableTokenID>) -> RNGLRReuseEvidence {
        var invalid = Set(nodes.values.lazy.filter {
            !$0.tokenDependencies.isDisjoint(with: changed)
        }.map(\.id))
        var grew = true
        while grew {
            grew = false
            for node in nodes.values where !invalid.contains(node.id) && !node.outgoing.isDisjoint(with: invalid) {
                if invalid.insert(node.id).inserted { grew = true }
            }
        }
        for id in invalid { nodes.removeValue(forKey: id) }
        return .init(invalidated: invalid, retained: Set(nodes.keys))
    }

    public func removeAll() { nodes.removeAll() }
}

/// GSS topology and packed-forest topology have distinct arenas, but consume
/// the same stable-token edit evidence.
public final class RNGLRIncrementalWorkspace<GSSPayload, ForestPayload> {
    public let graph = RNGLRReuseArena<GSSPayload>()
    public let forest = RNGLRReuseArena<ForestPayload>()
    public private(set) var artifactIdentity: IncrementalArtifactIdentity?
    public init() {}

    /// Establishes the grammar/automaton identity for both native arenas.
    /// Rebinding to a different artifact invalidates graph and forest together.
    @discardableResult
    public func bind(
        to artifact: IncrementalArtifactIdentity
    ) -> IncrementalExecutionEvidence? {
        if let current = artifactIdentity, current == artifact { return nil }
        let graphRemoved = graph.count
        let forestRemoved = forest.count
        let wasBound = artifactIdentity != nil
        graph.removeAll()
        forest.removeAll()
        artifactIdentity = artifact
        let measurements = [
            ReuseMeasurement(
                dimension: .gssNodes, reused: 0, rebuilt: 0,
                removed: graphRemoved, strategy: "gss-dependency-invalidation"),
            ReuseMeasurement(
                dimension: .forestNodes, reused: 0, rebuilt: 0,
                removed: forestRemoved, strategy: "sppf-dependency-invalidation"),
        ]
        if wasBound {
            return .init(
                strategy: .fallback,
                fallback: .incompatibleArtifact,
                measurements: measurements)
        }
        return .init(strategy: .full, measurements: measurements)
    }

    public func invalidate(tokens changed: Set<RNGLRStableTokenID>) ->
        (graph: RNGLRReuseEvidence, forest: RNGLRReuseEvidence) {
        (graph.invalidate(tokens: changed), forest.invalidate(tokens: changed))
    }

    public func invalidateWithEvidence(
        tokens changed: Set<RNGLRStableTokenID>
    ) -> RNGLRWorkspaceInvalidation {
        let invalidation = invalidate(tokens: changed)
        return .init(graph: invalidation.graph, forest: invalidation.forest)
    }

    public func reset() {
        graph.removeAll()
        forest.removeAll()
        artifactIdentity = nil
    }
}
