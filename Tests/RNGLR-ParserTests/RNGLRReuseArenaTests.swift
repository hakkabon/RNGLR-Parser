import XCTest
import IncrementalParsing
import Grammar
@testable import RNGLR_Parser

final class RNGLRReuseArenaTests: XCTestCase {
    func testLiveSessionResumesGSSAndMatchesCleanRNGLRParse() throws {
        let grammar = try Grammar(bnf: """
            S ::= 'a' X 'c'
            X ::= 'b' | 'd'
            """, start: "S")
        let session = RNGLRIncrementalSession(grammar: grammar)
        XCTAssertTrue(try session.parse("a b c").result.isSuccessful)

        let incremental = try session.parse("a d c")
        let clean = try RNGLRParser(grammar: grammar).parse("a d c")

        XCTAssertTrue(incremental.result.isSuccessful)
        XCTAssertEqual(incremental.restartTokenIndex, 1)
        XCTAssertEqual(incremental.result.bsr, clean.bsr)
        XCTAssertEqual(
            try incremental.result.sppfGraph?.portableSnapshot(),
            try clean.sppfGraph?.portableSnapshot())
        XCTAssertGreaterThan(
            incremental.evidence.measurements.first {
                $0.dimension == .gssNodes
            }?.reused ?? 0, 0)
        XCTAssertGreaterThan(
            incremental.evidence.measurements.first {
                $0.dimension == .forestNodes
            }?.rebuilt ?? 0, 0)
    }

    func testLiveSessionReusesWholeResultForUnchangedInput() throws {
        let grammar = try Grammar(bnf: "S ::= 'a' 'b'", start: "S")
        let session = RNGLRIncrementalSession(grammar: grammar)
        _ = try session.parse("a b")
        let repeated = try session.parse("a b")
        XCTAssertEqual(repeated.restartTokenIndex, 2)
        XCTAssertEqual(
            repeated.evidence.measurements.first { $0.dimension == .tokens }?.reused,
            2)
        XCTAssertEqual(
            repeated.evidence.measurements.first { $0.dimension == .gssNodes }?.rebuilt,
            0)
    }

    func testLiveSessionRecoversAfterRejectedEdit() throws {
        let grammar = try Grammar(bnf: "S ::= 'a' X; X ::= 'b' | 'c'", start: "S")
        let session = RNGLRIncrementalSession(grammar: grammar)
        XCTAssertTrue(try session.parse("a b").result.isSuccessful)
        XCTAssertFalse(try session.parse("a nope").result.isSuccessful)
        let repaired = try session.parse("a c")
        let clean = try RNGLRParser(grammar: grammar).parse("a c")
        XCTAssertEqual(repaired.result.bsr, clean.bsr)
        XCTAssertEqual(repaired.result.isSuccessful, clean.isSuccessful)
    }

    func testLiveSessionValidatesExternalTokenIdentities() throws {
        let grammar = try Grammar(bnf: "S ::= 'a'", start: "S")
        let session = RNGLRIncrementalSession(grammar: grammar)
        XCTAssertThrowsError(try session.parse("a", tokenIdentities: []))
        XCTAssertThrowsError(try session.parse(
            "a a", tokenIdentities: [.init("same"), .init("same")]))
    }

    func testRetainsIndependentGraphAndForestObjectIdentity() {
        let workspace = RNGLRIncrementalWorkspace<String, String>()
        let changed = RNGLRStableTokenID("changed"), stable = RNGLRStableTokenID("stable")
        let oldHead = workspace.graph.intern(id: .init("head:0"), payload: "head", tokenDependencies: [changed])
        let stableHead = workspace.graph.intern(id: .init("head:9"), payload: "head", tokenDependencies: [stable])
        let packed = workspace.forest.intern(id: .init("packed:9"), payload: "packed", tokenDependencies: [stable])
        let evidence = workspace.invalidate(tokens: [changed])
        XCTAssertTrue(evidence.graph.invalidated.contains(oldHead.id))
        XCTAssertTrue(workspace.graph[stableHead.id] === stableHead)
        XCTAssertTrue(workspace.forest[packed.id] === packed)
    }

    func testArtifactReplacementInvalidatesGraphAndForestTogether() {
        let workspace = RNGLRIncrementalWorkspace<String, String>()
        let first = IncrementalArtifactIdentity(
            id: "rnglr.automaton", revision: 1, fingerprint: "first")
        let second = IncrementalArtifactIdentity(
            id: "rnglr.automaton", revision: 2, fingerprint: "second")
        XCTAssertEqual(workspace.bind(to: first)?.strategy, .full)
        _ = workspace.graph.intern(id: .init("head"), payload: "head")
        _ = workspace.forest.intern(id: .init("packed"), payload: "packed")

        let fallback = workspace.bind(to: second)
        XCTAssertEqual(fallback?.strategy, .fallback)
        XCTAssertEqual(fallback?.fallback?.code, "incompatibleArtifact")
        XCTAssertEqual(
            fallback?.measurements.first { $0.dimension == .gssNodes }?.removed,
            1)
        XCTAssertEqual(
            fallback?.measurements.first { $0.dimension == .forestNodes }?.removed,
            1)
        XCTAssertEqual(workspace.graph.count, 0)
        XCTAssertEqual(workspace.forest.count, 0)
    }

    func testParserArtifactIdentityIsStableAndAutomatonSensitive() throws {
        let first = RNGLRParser(grammar: try Grammar(bnf: "S ::= 'a'", start: "S"))
        let equivalent = RNGLRParser(grammar: try Grammar(bnf: "S ::= 'a'", start: "S"))
        let changed = RNGLRParser(grammar: try Grammar(bnf: "S ::= 'b'", start: "S"))

        XCTAssertEqual(first.incrementalArtifactIdentity, equivalent.incrementalArtifactIdentity)
        XCTAssertNotEqual(
            first.incrementalArtifactIdentity.fingerprint,
            changed.incrementalArtifactIdentity.fingerprint)
    }

    func testNativeGraphAndForestRebuildMatchCleanWorkspace() {
        let artifact = IncrementalArtifactIdentity(
            id: "rnglr.automaton", revision: 1, fingerprint: "stable")
        let changed = RNGLRStableTokenID("changed")
        let stable = RNGLRStableTokenID("stable")
        let workspace = RNGLRIncrementalWorkspace<String, String>()
        _ = workspace.bind(to: artifact)

        let changedHead = workspace.graph.intern(
            id: .init("head:changed"), payload: "old-head",
            tokenDependencies: [changed])
        let parentHead = workspace.graph.intern(
            id: .init("head:parent"), payload: "old-parent",
            outgoing: [changedHead.id])
        let stableHead = workspace.graph.intern(
            id: .init("head:stable"), payload: "stable-head",
            tokenDependencies: [stable])
        let changedLeaf = workspace.forest.intern(
            id: .init("leaf:changed"), payload: "old-leaf",
            tokenDependencies: [changed])
        let packed = workspace.forest.intern(
            id: .init("packed:root"), payload: "old-packed",
            outgoing: [changedLeaf.id])
        let stableLeaf = workspace.forest.intern(
            id: .init("leaf:stable"), payload: "stable-leaf",
            tokenDependencies: [stable])

        let invalidation = workspace.invalidateWithEvidence(tokens: [changed])
        XCTAssertTrue(workspace.graph[stableHead.id] === stableHead)
        XCTAssertTrue(workspace.forest[stableLeaf.id] === stableLeaf)
        XCTAssertEqual(invalidation.graph.invalidated, [changedHead.id, parentHead.id])
        XCTAssertEqual(invalidation.forest.invalidated, [changedLeaf.id, packed.id])

        _ = workspace.graph.intern(
            id: changedHead.id, payload: "new-head",
            tokenDependencies: [.init("replacement")])
        _ = workspace.graph.intern(
            id: parentHead.id, payload: "new-parent",
            outgoing: [changedHead.id])
        _ = workspace.forest.intern(
            id: changedLeaf.id, payload: "new-leaf",
            tokenDependencies: [.init("replacement")])
        _ = workspace.forest.intern(
            id: packed.id, payload: "new-packed",
            outgoing: [changedLeaf.id])

        let clean = RNGLRIncrementalWorkspace<String, String>()
        _ = clean.bind(to: artifact)
        _ = clean.graph.intern(
            id: changedHead.id, payload: "new-head",
            tokenDependencies: [.init("replacement")])
        _ = clean.graph.intern(
            id: parentHead.id, payload: "new-parent",
            outgoing: [changedHead.id])
        _ = clean.graph.intern(
            id: stableHead.id, payload: "stable-head",
            tokenDependencies: [stable])
        _ = clean.forest.intern(
            id: changedLeaf.id, payload: "new-leaf",
            tokenDependencies: [.init("replacement")])
        _ = clean.forest.intern(
            id: packed.id, payload: "new-packed",
            outgoing: [changedLeaf.id])
        _ = clean.forest.intern(
            id: stableLeaf.id, payload: "stable-leaf",
            tokenDependencies: [stable])

        XCTAssertEqual(workspace.graph.nodeIDs, clean.graph.nodeIDs)
        XCTAssertEqual(workspace.forest.nodeIDs, clean.forest.nodeIDs)
        for id in clean.graph.nodeIDs {
            XCTAssertEqual(workspace.graph[id]?.payload, clean.graph[id]?.payload)
        }
        for id in clean.forest.nodeIDs {
            XCTAssertEqual(workspace.forest[id]?.payload, clean.forest[id]?.payload)
        }

        let evidence = invalidation.executionEvidence(
            rebuiltGraphNodes: 2, rebuiltForestNodes: 2)
        XCTAssertEqual(evidence.strategy, .incremental)
        XCTAssertEqual(
            evidence.measurements.first { $0.dimension == .gssNodes }?.reused,
            1)
        XCTAssertEqual(
            evidence.measurements.first { $0.dimension == .forestNodes }?.reused,
            1)
    }

    func testGrammarTransitionDropsGSSButRetainsUnrelatedForest() throws {
        let old = try Grammar(bnf: """
            S ::= B
            B ::= 'b'
            U ::= 'u'
            """, start: "S")
        let changed = try Grammar(bnf: """
            S ::= B
            B ::= 'b' | 'other'
            U ::= 'u'
            """, start: "S")
        let workspace = RNGLRIncrementalWorkspace<String, String>()
        let first = IncrementalArtifactIdentity(
            id: "rnglr.automaton", revision: 1, fingerprint: "automaton-1")
        let second = IncrementalArtifactIdentity(
            id: "rnglr.automaton", revision: 2, fingerprint: "automaton-2")
        _ = workspace.bind(to: first, grammar: old)

        let head = workspace.graph.intern(id: .init("head"), payload: "head")
        let affected = workspace.forest.intern(
            id: .init("B"), payload: "B",
            productionDependencies: [GrammarProductionID(old.productions[1])])
        let stable = workspace.forest.intern(
            id: .init("U"), payload: "U",
            productionDependencies: [GrammarProductionID(old.productions[2])])

        let transition = workspace.transition(
            to: second,
            targetGrammar: changed,
            change: old.changeSet(to: changed),
            rebuiltGraphNodes: 1,
            rebuiltForestNodes: 2)

        XCTAssertTrue(transition.appliedIncrementally)
        XCTAssertTrue(transition.invalidation.graph.invalidated.contains(head.id))
        XCTAssertTrue(transition.invalidation.forest.invalidated.contains(affected.id))
        XCTAssertTrue(workspace.forest[stable.id] === stable)
        XCTAssertEqual(transition.evidence.strategy, .incremental)
    }

    func testGrammarTransitionFailsClosedEvenWhenArtifactIdentityIsUnchanged() throws {
        let old = try Grammar(bnf: "S ::= 'a'", start: "S")
        let unrelated = try Grammar(bnf: "S ::= 'b'", start: "S")
        let workspace = RNGLRIncrementalWorkspace<String, String>()
        let artifact = IncrementalArtifactIdentity(
            id: "rnglr.automaton", revision: 1, fingerprint: "automaton")
        _ = workspace.bind(to: artifact, grammar: old)
        _ = workspace.graph.intern(id: .init("head"), payload: "head")
        _ = workspace.forest.intern(id: .init("forest"), payload: "forest")

        let transition = workspace.transition(
            to: artifact,
            targetGrammar: old,
            change: old.changeSet(to: unrelated))

        XCTAssertFalse(transition.appliedIncrementally)
        XCTAssertEqual(transition.evidence.strategy, .fallback)
        XCTAssertEqual(workspace.graph.count, 0)
        XCTAssertEqual(workspace.forest.count, 0)
    }
}
