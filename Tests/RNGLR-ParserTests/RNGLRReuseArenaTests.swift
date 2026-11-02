import XCTest
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
}
