import Foundation
import Grammar
import IncrementalParsing
import Parser

/// A live RNGLR document that resumes the native graph-structured stack at
/// the first changed token and preserves dependency-independent GSS and BSR
/// identities. The restart boundary contains only shift edges; reductions
/// selected by the previous lookahead are deliberately replayed.
public final class RNGLRIncrementalSession: @unchecked Sendable {
    private static let eofIdentity = RNGLRStableTokenID("rnglr:eof-boundary")
    private struct LiveToken: Equatable {
        let key: String
        let identity: RNGLRStableTokenID
    }

    private var parser: RNGLRParser
    private let lock = NSLock()
    private let workspace = RNGLRIncrementalWorkspace<String, String>()
    private var tokens: [LiveToken] = []
    private var boundaries: [[RNGLRParser.BoundaryEdge]] = []
    private var lastResult: ParseResult<GrammarSlot>?
    private var nextIdentity: UInt64 = 0
    private var hasBaseline = false

    public init(parser: RNGLRParser) { self.parser = parser }

    public convenience init(grammar: Grammar) {
        self.init(parser: RNGLRParser(grammar: grammar))
    }

    /// Parses source while retaining the maximal identical token prefix.
    /// Supplied identities describe non-EOF tokens; omitting them makes the
    /// session align unchanged prefix and suffix terminals automatically.
    public func parse(
        _ source: String,
        tokenIdentities supplied: [RNGLRStableTokenID]? = nil
    ) throws -> RNGLRIncrementalParseResult {
        lock.lock()
        defer { lock.unlock() }

        let nativeTokens = parser.tokenize(source)
        let keys = nativeTokens.dropLast().map(parser.tokenKey)
        if let supplied {
            guard supplied.count == keys.count else {
                throw RNGLRIncrementalSessionError.tokenIdentityCountMismatch(
                    expected: keys.count, actual: supplied.count)
            }
            guard Set(supplied).count == supplied.count else {
                throw RNGLRIncrementalSessionError.duplicateTokenIdentity
            }
        }
        let nextTokens = makeTokens(keys: keys, supplied: supplied)
        let prefix = hasBaseline ? commonPrefix(tokens, nextTokens) : 0
        let unchanged = hasBaseline && prefix == tokens.count
            && nextTokens.count == tokens.count

        if unchanged, let lastResult {
            let evidence = IncrementalExecutionEvidence(
                strategy: .incremental,
                measurements: [
                    .init(dimension: .gssNodes, reused: workspace.graph.count,
                          rebuilt: 0, removed: 0,
                          strategy: "live-rnglr-prefix-resumption"),
                    .init(dimension: .forestNodes, reused: workspace.forest.count,
                          rebuilt: 0, removed: 0,
                          strategy: "bsr-dependency-invalidation"),
                    .init(dimension: .tokens, reused: nextTokens.count,
                          rebuilt: 0, removed: 0,
                          strategy: "stable-token-prefix"),
                ])
            return .init(result: lastResult, restartTokenIndex: nextTokens.count,
                         evidence: evidence)
        }

        let previousCount = tokens.count
        let invalidation: RNGLRWorkspaceInvalidation
        if !hasBaseline {
            _ = workspace.bind(to: parser.incrementalArtifactIdentity,
                               grammar: parser.grammar)
            invalidation = .init(
                graph: .init(invalidated: [], retained: []),
                forest: .init(invalidated: [], retained: []))
        } else {
            var changed = Set(tokens.dropFirst(prefix).map(\.identity))
            // EOF reductions and completions are replayed on every edit.
            changed.insert(Self.eofIdentity)
            invalidation = workspace.invalidateWithEvidence(tokens: changed)
        }

        let restartIndex: Int
        let execution: RNGLRParser.Execution
        if hasBaseline, prefix > 0, prefix < boundaries.count {
            restartIndex = prefix
            execution = parser.resume(tokens: nativeTokens, at: restartIndex,
                                      boundary: boundaries[restartIndex])
        } else {
            restartIndex = 0
            execution = parser.resume(tokens: nativeTokens, at: 0, boundary: [])
        }

        var nextBoundaries = execution.boundaries
        if hasBaseline, restartIndex > 0 {
            for index in 0..<min(restartIndex, boundaries.count, nextBoundaries.count) {
                nextBoundaries[index] = boundaries[index]
            }
        }
        tokens = nextTokens
        boundaries = nextBoundaries
        lastResult = execution.result
        let wasIncremental = hasBaseline
        hasBaseline = true

        let rebuilt = recordLiveState(tokens: nextTokens,
                                      retainedGraph: invalidation.graph.retained,
                                      retainedForest: invalidation.forest.retained)
        let evidence = IncrementalExecutionEvidence(
            strategy: wasIncremental ? .incremental : .full,
            measurements: [
                .init(dimension: .gssNodes,
                      reused: wasIncremental ? invalidation.graph.retained.count : 0,
                      rebuilt: rebuilt.graph,
                      removed: invalidation.graph.invalidated.count,
                      strategy: "live-rnglr-prefix-resumption"),
                .init(dimension: .forestNodes,
                      reused: wasIncremental ? invalidation.forest.retained.count : 0,
                      rebuilt: rebuilt.forest,
                      removed: invalidation.forest.invalidated.count,
                      strategy: "bsr-dependency-invalidation"),
                .init(dimension: .tokens,
                      reused: wasIncremental ? prefix : 0,
                      rebuilt: nextTokens.count - (wasIncremental ? prefix : 0),
                      removed: wasIncremental ? max(0, previousCount - prefix) : 0,
                      strategy: "stable-token-prefix"),
            ])
        return .init(result: execution.result, restartTokenIndex: restartIndex,
                     evidence: evidence)
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        tokens = []; boundaries = []; lastResult = nil
        workspace.graph.removeAll(); workspace.forest.removeAll()
        nextIdentity = 0; hasBaseline = false
    }

    /// Activates a verified grammar delta in the live document session.
    /// Grammar-state-dependent GSS boundaries are replayed; forest nodes with
    /// no dependency on invalidated productions remain interned.
    @discardableResult
    public func transition(
        to grammar: Grammar,
        change: GrammarChangeSet
    ) -> RNGLRGrammarTransition {
        lock.lock()
        defer { lock.unlock() }
        let nextParser = RNGLRParser(grammar: grammar)
        let transition = workspace.transition(
            to: nextParser.incrementalArtifactIdentity,
            targetGrammar: grammar, change: change)
        parser = nextParser
        boundaries = []
        lastResult = nil
        if change.requiresRetokenization || !transition.appliedIncrementally {
            tokens = []
            nextIdentity = 0
            hasBaseline = false
        }
        return transition
    }

    private func makeTokens(keys: [String], supplied: [RNGLRStableTokenID]?) -> [LiveToken] {
        if let supplied { return zip(keys, supplied).map(LiveToken.init) }
        let prefix = zip(tokens.map(\.key), keys).prefix { $0 == $1 }.count
        let maximumSuffix = min(tokens.count, keys.count) - prefix
        let suffix = zip(tokens.map(\.key).reversed(), keys.reversed())
            .prefix(maximumSuffix).prefix { $0 == $1 }.count
        return keys.indices.map { index in
            let identity: RNGLRStableTokenID
            if index < prefix {
                identity = tokens[index].identity
            } else if index >= keys.count - suffix {
                let oldIndex = tokens.count - (keys.count - index)
                identity = tokens[oldIndex].identity
            } else {
                identity = .init("rnglr-token-\(nextIdentity)")
                nextIdentity += 1
            }
            return LiveToken(key: keys[index], identity: identity)
        }
    }

    private func commonPrefix(_ old: [LiveToken], _ new: [LiveToken]) -> Int {
        zip(old, new).prefix { $0 == $1 }.count
    }

    private func recordLiveState(
        tokens: [LiveToken],
        retainedGraph: Set<RNGLRReusableNodeID>,
        retainedForest: Set<RNGLRReusableNodeID>
    ) -> (graph: Int, forest: Int) {
        var rebuiltGraph = 0
        for node in parser.liveGSSNodes {
            let id = RNGLRReusableNodeID("\(node.state)@\(node.inputPosition)")
            var dependencies = Set(tokens.prefix(node.inputPosition).map(\.identity))
            // State at a boundary may contain reductions selected by that
            // boundary's lookahead, which the native restart reconstructs.
            if node.inputPosition < tokens.count {
                dependencies.insert(tokens[node.inputPosition].identity)
            } else {
                dependencies.insert(Self.eofIdentity)
            }
            let outgoing = Set(node.edges.map {
                RNGLRReusableNodeID("\($0.to.state)@\($0.to.inputPosition)")
            })
            if !retainedGraph.contains(id) { rebuiltGraph += 1 }
            _ = workspace.graph.replace(
                id: id, payload: id.rawValue,
                tokenDependencies: dependencies, outgoing: outgoing)
        }

        var rebuiltForest = 0
        for triple in parser.liveBSRTriples {
            let production = GrammarProductionID(triple.slot.production)
            let id = RNGLRReusableNodeID(
                "\(production.rawValue)|\(triple.leftExtent)|\(triple.rightExtent)")
            let upper = min(triple.rightExtent, tokens.count)
            // A nullable completion has no tokens in its own span, but still
            // depends on the lookahead and prefix that made it reachable.
            var dependencies = Set(tokens.prefix(upper).map(\.identity))
            if upper < tokens.count {
                dependencies.insert(tokens[upper].identity)
            } else {
                dependencies.insert(Self.eofIdentity)
            }
            if !retainedForest.contains(id) { rebuiltForest += 1 }
            _ = workspace.forest.replace(
                id: id, payload: id.rawValue,
                tokenDependencies: dependencies,
                productionDependencies: [production])
        }
        return (rebuiltGraph, rebuiltForest)
    }
}

public struct RNGLRIncrementalParseResult {
    public let result: ParseResult<GrammarSlot>
    public let restartTokenIndex: Int
    public let evidence: IncrementalExecutionEvidence
}

public enum RNGLRIncrementalSessionError: Error, Hashable, Sendable {
    case tokenIdentityCountMismatch(expected: Int, actual: Int)
    case duplicateTokenIdentity
}
