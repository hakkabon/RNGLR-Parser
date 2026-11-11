import Foundation
import IncrementalParsing
import Grammar

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
    public private(set) var productionDependencies: Set<GrammarProductionID>

    fileprivate init(id: RNGLRReusableNodeID, payload: Payload,
                     tokenDependencies: Set<RNGLRStableTokenID>,
                     outgoing: Set<RNGLRReusableNodeID>,
                     productionDependencies: Set<GrammarProductionID>) {
        self.id = id; self.payload = payload
        self.tokenDependencies = tokenDependencies; self.outgoing = outgoing
        self.productionDependencies = productionDependencies
    }

    fileprivate func update(payload: Payload, tokenDependencies: Set<RNGLRStableTokenID>,
                            outgoing: Set<RNGLRReusableNodeID>,
                            productionDependencies: Set<GrammarProductionID>) {
        self.payload = payload; self.tokenDependencies = tokenDependencies; self.outgoing = outgoing
        self.productionDependencies = productionDependencies
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

public struct RNGLRGrammarTransition: Sendable {
    public let invalidation: RNGLRWorkspaceInvalidation
    public let evidence: IncrementalExecutionEvidence
    public let appliedIncrementally: Bool
    public let convergence: GrammarEngineTransition?
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
                       outgoing: Set<RNGLRReusableNodeID> = [],
                       productionDependencies: Set<GrammarProductionID> = []) -> RNGLRReusableNode<Payload> {
        if let existing = nodes[id] { return existing }
        let node = RNGLRReusableNode(id: id, payload: payload(),
                                    tokenDependencies: tokenDependencies, outgoing: outgoing,
                                    productionDependencies: productionDependencies)
        nodes[id] = node
        return node
    }

    @discardableResult
    public func replace(id: RNGLRReusableNodeID, payload: Payload,
                        tokenDependencies: Set<RNGLRStableTokenID> = [],
                        outgoing: Set<RNGLRReusableNodeID> = [],
                        productionDependencies: Set<GrammarProductionID> = []) -> RNGLRReusableNode<Payload> {
        if let existing = nodes[id] {
            existing.update(
                payload: payload, tokenDependencies: tokenDependencies,
                outgoing: outgoing,
                productionDependencies: productionDependencies)
            return existing
        }
        return intern(
            id: id, payload: payload, tokenDependencies: tokenDependencies,
            outgoing: outgoing,
            productionDependencies: productionDependencies)
    }

    @discardableResult
    public func invalidate(tokens changed: Set<RNGLRStableTokenID>) -> RNGLRReuseEvidence {
        let seeds = Set(nodes.values.lazy.filter {
            !$0.tokenDependencies.isDisjoint(with: changed)
        }.map(\.id))
        return invalidate(seedNodes: seeds)
    }

    @discardableResult
    public func invalidate(
        productions changed: Set<GrammarProductionID>
    ) -> RNGLRReuseEvidence {
        let seeds = Set(nodes.values.lazy.filter {
            !$0.productionDependencies.isDisjoint(with: changed)
        }.map(\.id))
        return invalidate(seedNodes: seeds)
    }

    @discardableResult
    public func invalidateAll() -> RNGLRReuseEvidence {
        let invalidated = Set(nodes.keys)
        nodes.removeAll()
        return .init(invalidated: invalidated, retained: [])
    }

    private func invalidate(
        seedNodes: Set<RNGLRReusableNodeID>
    ) -> RNGLRReuseEvidence {
        var invalid = seedNodes
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
    public private(set) var grammarFingerprint: String?
    public init() {}

    /// Establishes the grammar/automaton identity for both native arenas.
    /// Rebinding to a different artifact invalidates graph and forest together.
    @discardableResult
    public func bind(
        to artifact: IncrementalArtifactIdentity
    ) -> IncrementalExecutionEvidence? {
        bind(to: artifact, grammarFingerprint: nil)
    }

    /// Binds both the automaton identity and the source grammar fingerprint,
    /// enabling a later verified grammar-delta transition.
    @discardableResult
    public func bind(
        to artifact: IncrementalArtifactIdentity,
        grammar: Grammar
    ) -> IncrementalExecutionEvidence? {
        bind(
            to: artifact,
            grammarFingerprint: grammar.incrementalSemanticFingerprint)
    }

    private func bind(
        to artifact: IncrementalArtifactIdentity,
        grammarFingerprint newGrammarFingerprint: String?
    ) -> IncrementalExecutionEvidence? {
        if let current = artifactIdentity, current == artifact {
            if let newGrammarFingerprint { grammarFingerprint = newGrammarFingerprint }
            return nil
        }
        let graphRemoved = graph.count
        let forestRemoved = forest.count
        let wasBound = artifactIdentity != nil
        graph.removeAll()
        forest.removeAll()
        artifactIdentity = artifact
        grammarFingerprint = newGrammarFingerprint
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

    /// Applies a verified grammar delta. GSS nodes are conservatively dropped
    /// because regenerated automaton state numbers have no stable mapping;
    /// production-independent SPPF nodes may survive.
    public func transition(
        to artifact: IncrementalArtifactIdentity,
        targetGrammar: Grammar,
        change: GrammarChangeSet,
        rebuiltGraphNodes: Int = 0,
        rebuiltForestNodes: Int = 0
    ) -> RNGLRGrammarTransition {
        let sourceArtifact = artifactIdentity
        let targetFingerprint = targetGrammar.incrementalSemanticFingerprint
        let grammarMeasurement = ReuseMeasurement(
            dimension: .grammarProductions,
            reused: change.retainedProductionIDs.count,
            rebuilt: change.addedProductionIDs.count,
            removed: change.removedProductionIDs.count,
            strategy: "structural-grammar-delta")
        guard grammarFingerprint == change.sourceFingerprint,
              targetFingerprint == change.targetFingerprint else {
            let graphIDs = graph.nodeIDs
            let forestIDs = forest.nodeIDs
            let wasBound = artifactIdentity != nil
            graph.removeAll()
            forest.removeAll()
            artifactIdentity = artifact
            grammarFingerprint = targetFingerprint
            let measurements = [
                ReuseMeasurement(
                    dimension: .gssNodes, reused: 0, rebuilt: rebuiltGraphNodes,
                    removed: graphIDs.count,
                    strategy: "gss-dependency-invalidation"),
                ReuseMeasurement(
                    dimension: .forestNodes, reused: 0, rebuilt: rebuiltForestNodes,
                    removed: forestIDs.count,
                    strategy: "sppf-dependency-invalidation"),
            ]
            let evidence = wasBound
                ? IncrementalExecutionEvidence(
                    strategy: .fallback,
                    fallback: .incompatibleArtifact,
                    measurements: measurements + [grammarMeasurement])
                : IncrementalExecutionEvidence(
                    strategy: .full,
                    measurements: measurements + [grammarMeasurement])
            return .init(
                invalidation: .init(
                    graph: .init(invalidated: graphIDs, retained: []),
                    forest: .init(invalidated: forestIDs, retained: [])),
                evidence: evidence,
                appliedIncrementally: false,
                convergence: sourceArtifact.flatMap { source in
                    guard source != artifact, evidence.strategy == .fallback else {
                        return nil
                    }
                    return GrammarEngineTransition(
                        engineID: "rnglr", sourceArtifact: source,
                        targetArtifact: artifact, appliedIncrementally: false,
                        requiresRetokenization: change.requiresRetokenization,
                        evidence: evidence)
                })
        }

        let invalidation = RNGLRWorkspaceInvalidation(
            graph: graph.invalidateAll(),
            forest: forest.invalidate(
                productions: change.invalidatedProductionIDSet))
        artifactIdentity = artifact
        grammarFingerprint = targetFingerprint
        let workspaceEvidence = invalidation.executionEvidence(
            rebuiltGraphNodes: rebuiltGraphNodes,
            rebuiltForestNodes: rebuiltForestNodes)
        let evidence = IncrementalExecutionEvidence(
            strategy: .incremental,
            measurements: workspaceEvidence.measurements + [grammarMeasurement])
        return .init(
            invalidation: invalidation,
            evidence: evidence,
            appliedIncrementally: true,
            convergence: sourceArtifact.flatMap { source in
                guard source != artifact else { return nil }
                return GrammarEngineTransition(
                    engineID: "rnglr", sourceArtifact: source,
                    targetArtifact: artifact, appliedIncrementally: true,
                    requiresRetokenization: change.requiresRetokenization,
                    evidence: evidence)
            })
    }

    public func reset() {
        graph.removeAll()
        forest.removeAll()
        artifactIdentity = nil
        grammarFingerprint = nil
    }
}
