import Foundation

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
}

/// Interns graph nodes by grammar/state/span identity. Surviving nodes retain
/// their class identity across edits; affected nodes and their parents do not.
public final class RNGLRReuseArena<Payload> {
    private var nodes: [RNGLRReusableNodeID: RNGLRReusableNode<Payload>] = [:]
    public init() {}
    public var count: Int { nodes.count }
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
}

/// GSS topology and packed-forest topology have distinct arenas, but consume
/// the same stable-token edit evidence.
public final class RNGLRIncrementalWorkspace<GSSPayload, ForestPayload> {
    public let graph = RNGLRReuseArena<GSSPayload>()
    public let forest = RNGLRReuseArena<ForestPayload>()
    public init() {}
    public func invalidate(tokens changed: Set<RNGLRStableTokenID>) ->
        (graph: RNGLRReuseEvidence, forest: RNGLRReuseEvidence) {
        (graph.invalidate(tokens: changed), forest.invalidate(tokens: changed))
    }
}
