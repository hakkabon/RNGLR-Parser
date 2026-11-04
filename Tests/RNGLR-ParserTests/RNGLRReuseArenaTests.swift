import XCTest
import IncrementalParsing
import Grammar
@testable import RNGLR_Parser

final class RNGLRReuseArenaTests: XCTestCase {
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
}
