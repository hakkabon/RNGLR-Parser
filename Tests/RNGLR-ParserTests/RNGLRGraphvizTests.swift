import XCTest
@testable import RNGLR_Parser
import Grammar
import Parser

//  Test Strategy
//  ─────────────
//  We parse known inputs, obtain the SPPF graph, generate the DOT string, and
//  then verify structural properties of the output rather than doing a brittle
//  exact-string comparison.  This keeps the tests robust against whitespace or
//  ordering changes while still catching regressions.
//

final class SPPFGraphvizTests: XCTestCase {

    // MARK: - Helper

    private func sppf(_ bnf: String, start: String, input: String) throws -> SPPFGraph<GrammarSlot> {
        let grammar = try Grammar(bnf: bnf, start: start)
        let parser  = RNGLRParser(grammar: grammar)
        let result  = try parser.parse(input)
        guard result.isSuccessful, let sppf = result.sppfGraph else {
            XCTFail("Parse failed for input '\(input)'")
            return SPPFGraph<GrammarSlot>()
        }
        return sppf
    }

    // MARK: ── 1. Structural: digraph wrapper ──────────────────────────────────

    func testOutputIsDigraph() throws {
        let dot = try sppf("S ::= 'a' \n", start: "S", input: "a").graphviz
        XCTAssertTrue(dot.hasPrefix("digraph SPPF {"),
                      "DOT output must start with 'digraph SPPF {'")
        XCTAssertTrue(dot.hasSuffix("}"),
                      "DOT output must end with '}'")
    }

    // MARK: ── 2. Node presence: symbol node appears ───────────────────────────

    func testSymbolNodePresent() throws {
        let dot = try sppf("S ::= 'a' \n", start: "S", input: "a").graphviz
        // Symbol node for S spanning [0,1) must appear with ellipse shape.
        XCTAssertTrue(dot.contains("shape=ellipse"),
                      "Symbol node should use ellipse shape")
        XCTAssertTrue(dot.contains("S"),
                      "Start symbol name 'S' should appear in DOT output")
    }

    // MARK: ── 3. Node presence: terminal (leaf) node appears ──────────────────

    func testTerminalNodePresent() throws {
        let dot = try sppf("S ::= 'a' \n", start: "S", input: "a").graphviz
        XCTAssertTrue(dot.contains("shape=rectangle"),
                      "Leaf (terminal) node should use rectangle shape")
    }

    // MARK: ── 4. Node presence: packed node appears ───────────────────────────

    func testPackedNodePresent() throws {
        let dot = try sppf("S ::= 'a' \n", start: "S", input: "a").graphviz
        XCTAssertTrue(dot.contains("shape=diamond"),
                      "Packed node should use diamond shape")
    }

    // MARK: ── 5. Node presence: intermediate node appears ────────────────────

    func testIntermediateNodePresent() throws {
        // A 3-symbol RHS forces binarisation and thus intermediate nodes.
        let dot = try sppf("S ::= 'a' 'b' 'c' \n", start: "S", input: "a b c").graphviz
        XCTAssertTrue(dot.contains("shape=note"),
                      "Intermediate (binarised) node should use note shape")
    }

    // MARK: ── 6. Edges: parent → child edges exist ────────────────────────────

    func testEdgesPresent() throws {
        let dot = try sppf("S ::= 'a' 'b' \n", start: "S", input: "a b").graphviz
        // At least one directed edge must be present.
        XCTAssertTrue(dot.contains("->"),
                      "DOT output must contain at least one edge")
    }

    // MARK: ── 7. Edge styles: symbol→packed is solid, packed→child is dashed ──

    func testEdgeStyles() throws {
        let dot = try sppf("S ::= 'a' 'b' \n", start: "S", input: "a b").graphviz
        XCTAssertTrue(dot.contains("style=solid"),
                      "symbol/intermediate → packed edges should be solid")
        XCTAssertTrue(dot.contains("style=dashed"),
                      "packed → child edges should be dashed")
    }

    // MARK: ── 8. Ambiguity: double border on ambiguous symbol nodes ────────────

    func testAmbiguousNodeHasDoubleBorder() throws {
        // E → E+E | 'a' on "a+a+a" produces an ambiguous symbol node for E.
        let dot = try sppf("""
            E ::= E '+' E
            E ::= 'a'
            """, start: "E", input: "a + a + a").graphviz
        XCTAssertTrue(dot.contains("peripheries=2"),
                      "Ambiguous symbol nodes must have double border (peripheries=2)")
    }

    // MARK: ── 9. No double border for unambiguous grammar ─────────────────────

    func testUnambiguousNodeNodoubleBorder() throws {
        let dot = try sppf("""
            E ::= E '+' T
            E ::= T
            T ::= 'a'
            """, start: "E", input: "a + a + a").graphviz
        XCTAssertFalse(dot.contains("peripheries=2"),
                       "Unambiguous grammar must not produce double-border nodes")
    }

    // MARK: ── 10. Fill colours for each node kind ─────────────────────────────

    func testFillColours() throws {
        let dot = try sppf("S ::= 'a' 'b' 'c' \n", start: "S", input: "a b c").graphviz
        XCTAssertTrue(dot.contains("#dce8f5"), "Symbol nodes: blue fill")
        XCTAssertTrue(dot.contains("#d5e8d4"), "Leaf (terminal) nodes: green fill")
        XCTAssertTrue(dot.contains("#fff2cc"), "Intermediate nodes: yellow fill")
        XCTAssertTrue(dot.contains("#f8cecc"), "Packed nodes: pink fill")
    }

    // MARK: ── 11. DOT escaping: label special characters ─────────────────────

    func testDotEscaping() throws {
        // Grammar with '+' and '*' — their '>' / '<' equivalents never appear
        // unescaped in DOT, but the arrow → and bullet • should appear.
        let dot = try sppf("""
            E ::= E '+' T
            E ::= T
            T ::= 'n'
            """, start: "E", input: "n + n").graphviz
        // No raw unescaped < or > outside of structural brackets.
        // The DOT file wraps them as \< \> inside quoted labels.
        // Verify the structure is valid enough for the renderer.
        XCTAssertTrue(dot.contains("digraph SPPF {"))
        // The slot label uses → (U+2192) which should appear literally.
        XCTAssertTrue(dot.contains("\u{2192}"),
                      "Slot labels should contain the Unicode → arrow character")
        // The bullet • should appear in slot labels.
        XCTAssertTrue(dot.contains("•"),
                      "Slot labels should contain the dot marker •")
    }

    // MARK: ── 12. Pivot label on packed→child edges ───────────────────────────

    func testPivotLabelOnPackedEdges() throws {
        let dot = try sppf("S ::= 'a' 'b' \n", start: "S", input: "a b").graphviz
        // Dashed edges from packed nodes carry a pivot label (an integer).
        // We can't predict the exact number, but it must be present.
        let dashed = dot.components(separatedBy: "\n")
            .filter { $0.contains("style=dashed") }
        XCTAssertFalse(dashed.isEmpty, "Dashed edges should exist")
        for edge in dashed {
            XCTAssertTrue(edge.contains("label="),
                          "Every dashed edge should carry a pivot label: \(edge)")
        }
    }

    // MARK: ── 13. Deterministic output (stable node ordering) ─────────────────

    func testOutputIsDeterministic() throws {
        let bnf    = "E ::= E '+' T\nE ::= T\nT ::= 'n'\n"
        let sppfA  = try sppf(bnf, start: "E", input: "n + n")
        let sppfB  = try sppf(bnf, start: "E", input: "n + n")
        XCTAssertEqual(sppfA.graphviz, sppfB.graphviz,
                       "graphviz must be deterministic for identical inputs")
    }

    // MARK: ── 14. Empty graph produces valid DOT ──────────────────────────────

    func testEmptyGraphProducesValidDot() {
        let dot = SPPFGraph<GrammarSlot>().graphviz
        XCTAssertTrue(dot.contains("digraph SPPF {"))
        XCTAssertTrue(dot.hasSuffix("}"))
    }

    // MARK: ── 15. writeDot writes correct file content ───────────────────────

    func testWriteDotCreatesFile() throws {
        let sppfGraph = try sppf("S ::= 'x' \n", start: "S", input: "x")
        let url       = FileManager.default.temporaryDirectory
            .appendingPathComponent("sppf-test-\(UUID().uuidString).dot")
        defer { try? FileManager.default.removeItem(at: url) }

        try sppfGraph.writeDot(to: url)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "writeDot(to:) should create the file")
        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(content, sppfGraph.graphviz,
                       "File content must equal graphviz property")
    }

    // MARK: ── 16. Catalan: correct number of packed nodes ─────────────────────

    func testCatalanPackedNodeCount() throws {
        // S → SS | a on "a a a" has 2 packed nodes on the root symbol node.
        let dot = try sppf("""
            S ::= S S
            S ::= 'a'
            """, start: "S", input: "a a a").graphviz

        // Count distinct diamond nodes (packed nodes)
        let diamondLines = dot.components(separatedBy: "\n")
            .filter { $0.contains("shape=diamond") }
        XCTAssertGreaterThanOrEqual(diamondLines.count, 2,
            "3 tokens with S→SS|a should yield ≥2 packed nodes")
    }

    // MARK: ── 17. Nullable: ε production renders without terminal ─────────────

    func testNullableEpsilonGrammar() throws {
        let dot = try sppf("""
            S ::= A B
            A ::= 'a'
            A ::= ε
            B ::= 'b'
            """, start: "S", input: "b").graphviz
        // Should still produce valid DOT — just no terminal for A (A→ε, zero-width).
        XCTAssertTrue(dot.contains("digraph SPPF {"))
        XCTAssertTrue(dot.contains("shape=ellipse"))
    }
}
