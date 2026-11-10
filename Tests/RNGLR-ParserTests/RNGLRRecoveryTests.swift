import Grammar
import Parser
@testable import RNGLR_Parser
import XCTest

final class RNGLRRecoveryTests: XCTestCase {
    func testRecoveryBuildsNativeForest() throws {
        let grammar = try Grammar(
            bnf: "S ::= 'begin' 'name' ';' 'end' '.'\n", start: "S")
        let parser = RNGLRParser(grammar: grammar)

        let result = try parser.parseRecovering(
            "begin name end",
            insertionCandidates: [";", "."],
            policy: .init(maximumEditCost: 2, maximumExploredStates: 100))

        XCTAssertEqual(result.status, .recovered)
        XCTAssertEqual(result.recoveryEdits.count, 2)
        XCTAssertTrue(result.parseResult?.isSuccessful == true)
        XCTAssertNotNil(result.parseResult?.sppfGraph)
    }

    func testRecoveryHonorsBudget() throws {
        let grammar = try Grammar(bnf: "S ::= 'a' 'b'\n", start: "S")
        let result = try RNGLRParser(grammar: grammar).parseRecovering(
            "x y z", insertionCandidates: ["a", "b"],
            policy: .init(maximumEditCost: 3, maximumExploredStates: 3))

        XCTAssertEqual(result.status, .rejected)
        XCTAssertTrue(result.reachedSearchLimit)
        XCTAssertEqual(result.exploredStates, 3)
    }

    func testRecoveryResumesRetainedSearch() throws {
        let grammar = try Grammar(
            bnf: "S ::= 'begin' 'name' ';' 'end' '.'\n", start: "S")
        let parser = RNGLRParser(grammar: grammar)
        let session = GeneralizedRecoverySearchSession<String>()
        let limited = try parser.parseRecovering(
            "begin name end", insertionCandidates: [";", "."],
            policy: .init(maximumEditCost: 2, maximumExploredStates: 3),
            searchSession: session)
        XCTAssertTrue(limited.reachedSearchLimit)

        let resumed = try parser.parseRecovering(
            "begin name end", insertionCandidates: [";", "."],
            policy: .init(maximumEditCost: 2, maximumExploredStates: 100),
            searchSession: session)
        XCTAssertEqual(resumed.status, .recovered)
        XCTAssertEqual(resumed.quality.editCost, 2)
        XCTAssertEqual(resumed.quality.resumedStates, 3)
    }
}
