import XCTest
@testable import RNGLR_Parser
import Grammar
import Tokenizer
import Parser

final class RNGLRParserTests: XCTestCase {

    // MARK: - Helper

    func makeParser(_ bnf: String, start: String) throws -> RNGLRParser {
        let grammar = try Grammar(bnf: bnf, start: start)
        return RNGLRParser(grammar: grammar)
    }

    func parse(_ parser: RNGLRParser, _ input: String) -> ParseResult<GrammarSlot> {
        (try? parser.parse(input)) ?? ParseResult(isSuccessful: false, bsr: Set(), sppfGraph: nil)
    }

    /// Number of derivations for `input`, via the shared tree-builder.
    func treeCount(_ parser: RNGLRParser, _ input: String, startSymbol: String) -> Int? {
        let result = parse(parser, input)
        guard result.isSuccessful, let sppf = result.sppfGraph else { return nil }
        let ranges = parser.tokenize(input).filter { $0.type != .eof }.map(\.range)
        return sppf.buildAllParseTrees(startSymbol: startSymbol, ranges: ranges, string: input).count
    }

    // MARK: ── 1. tokenKey mapping ─────────────────────────────────────────────

    func testTokenKeySymbol() throws {
        let parser = try makeParser("S ::= '+' \n", start: "S")
        let src    = "+"
        let endIdx = src.endIndex
        let tok    = Token(type: .symbol("+"), range: src.startIndex ..< endIdx)
        XCTAssertEqual(parser.tokenKey(tok), "+")
    }

    func testTokenKeyLiteral() throws {
        let parser = try makeParser("S ::= 'id' \n", start: "S")
        let src    = "id"
        let tok    = Token(type: .literal("id"), range: src.startIndex ..< src.endIndex)
        XCTAssertEqual(parser.tokenKey(tok), "id")
    }

    func testTokenKeyIdentifier() throws {
        let parser = try makeParser("S ::= 'x' \n", start: "S")
        let src    = "x"
        let tok    = Token(type: .identifier("x"), range: src.startIndex ..< src.endIndex)
        XCTAssertEqual(parser.tokenKey(tok), "x")
    }

    func testTokenKeyKeyword() throws {
        let parser = try makeParser("S ::= 'while' \n", start: "S")
        let src    = "while"
        let tok    = Token(type: .keyword("while"), range: src.startIndex ..< src.endIndex)
        XCTAssertEqual(parser.tokenKey(tok), "while")
    }

    func testTokenKeyEOF() throws {
        let parser = try makeParser("S ::= 'a' \n", start: "S")
        let src    = ""
        let tok    = Token(type: .eof, range: src.startIndex ..< src.endIndex)
        XCTAssertEqual(parser.tokenKey(tok), "$")
    }

    // MARK: ── 2. Tokenizer pipeline ───────────────────────────────────────────

    func testTokenizeProducesCorrectCount() throws {
        let parser = try makeParser("""
            E ::= E '+' T
            E ::= T
            T ::= 'id'
            """, start: "E")
        let tokens = parser.tokenize("id + id")
        // 3 real tokens + 1 EOF sentinel
        XCTAssertEqual(tokens.count, 4)
        // Last token is EOF
        if case .eof = tokens.last?.type { } else {
            XCTFail("Last token should be .eof")
        }
    }

    func testTokenizeSymbolsSplit() throws {
        // '+' and '*' should appear as .symbol tokens
        let parser = try makeParser("""
            E ::= E '+' T
            E ::= T
            T ::= T '*' F
            T ::= F
            F ::= 'id'
            """, start: "E")
        let tokens = parser.tokenize("id + id * id")
        let types = tokens.map(\.type)
        XCTAssertTrue(types.contains(.symbol("+")), "'+' should be a symbol token")
        XCTAssertTrue(types.contains(.symbol("*")), "'*' should be a symbol token")
    }

    func testTokenizeKeywordSplit() throws {
        // 'while' is a word terminal — should become a keyword token
        let parser = try makeParser("""
            S ::= 'while' '(' 'x' ')' '{' 'y' '}'
            """, start: "S")
        let tokens = parser.tokenize("while ( x ) { y }")
        let types = tokens.map(\.type)
        XCTAssertTrue(types.contains(.keyword("while")), "'while' should be a keyword token")
    }

    func testTokenizeEmptyString() throws {
        let parser = try makeParser("S ::= 'a' \n", start: "S")
        let tokens = parser.tokenize("")
        // Only the EOF sentinel
        XCTAssertEqual(tokens.count, 1)
        if case .eof = tokens[0].type { } else { XCTFail("Should be .eof") }
    }

    // MARK: ── 3. Nullable detection ───────────────────────────────────────────

    func testNullableDetection() throws {
        let grammar = try Grammar(bnf: """
            S ::= A B
            A ::= 'a'
            A ::= ε
            B ::= 'b'
            B ::= ε
            """, start: "S")
        let nullable = grammar.nullableNonTerminals
        XCTAssertTrue(nullable.contains(NonTerminal(name: "A")))
        XCTAssertTrue(nullable.contains(NonTerminal(name: "B")))
        XCTAssertTrue(nullable.contains(NonTerminal(name: "S")),
                      "S is nullable because both A and B can derive ε")
    }

    func testNullableTransitive() throws {
        let grammar = try Grammar(bnf: """
            A ::= B B
            B ::= ε
            """, start: "A")
        XCTAssertTrue(grammar.nullableNonTerminals.contains(NonTerminal(name: "A")))
    }

    // MARK: ── 4. Unambiguous arithmetic ──────────────────────────────────────

    func testArithmeticSuccess() throws {
        let parser = try makeParser("""
            E ::= E '+' T
            E ::= T
            T ::= T '*' F
            T ::= F
            F ::= '(' E ')'
            F ::= 'id'
            """, start: "E")
        let result = parse(parser, "id + id * id")
        guard result.isSuccessful, let sppf = result.sppfGraph else {
            return XCTFail("Expected parse success")
        }
        XCTAssertGreaterThan(result.bsr.count, 0)
        XCTAssertNotNil(sppf.root(startSymbol: "E", inputLength: 5))
    }

    func testArithmeticOneTree() throws {
        let parser = try makeParser("""
            E ::= E '+' T
            E ::= T
            T ::= T '*' F
            T ::= F
            F ::= '(' E ')'
            F ::= 'id'
            """, start: "E")
        guard let count = treeCount(parser, "id + id", startSymbol: "E") else {
            return XCTFail("Parse failed")
        }
        XCTAssertEqual(count, 1, "Unambiguous grammar: exactly 1 tree")
    }

    func testArithmeticFailure() throws {
        let parser = try makeParser("""
            E ::= E '+' T
            E ::= T
            T ::= F
            F ::= 'id'
            """, start: "E")
        if parse(parser, "id + +").isSuccessful {
            XCTFail("Expected parse failure")
        }
    }

    // MARK: ── 5. Ambiguous grammar ────────────────────────────────────────────

    func testAmbiguousTwoTrees() throws {
        let parser = try makeParser("""
            E ::= E '+' E
            E ::= 'a'
            """, start: "E")
        guard let count = treeCount(parser, "a + a + a", startSymbol: "E") else {
            return XCTFail("Parse failed")
        }
        XCTAssertEqual(count, 2)
    }

    func testAmbiguousSingleTokenOneTree() throws {
        let parser = try makeParser("""
            E ::= E '+' E
            E ::= 'a'
            """, start: "E")
        guard let count = treeCount(parser, "a", startSymbol: "E") else {
            return XCTFail("Parse failed")
        }
        XCTAssertEqual(count, 1)
    }

    // MARK: ── 6. Epsilon / nullable ───────────────────────────────────────────

    func testEpsilonAB() throws {
        let parser = try makeParser("""
            S ::= A B
            A ::= 'a'
            A ::= ε
            B ::= 'b'
            """, start: "S")
        XCTAssertParseSucceeds(parser, "a b")   // A→a, B→b
        XCTAssertParseSucceeds(parser, "b")     // A→ε
    }

    func testEpsilonOnly() throws {
        let parser = try makeParser("S ::= ε \n", start: "S")
        XCTAssertParseSucceeds(parser, "")
    }

    // MARK: ── 7. RNGLR right-null suffix ─────────────────────────────────────

    func testRightNullSuffix() throws {
        let parser = try makeParser("""
            S ::= A B C
            A ::= 'a'
            B ::= 'b'
            B ::= ε
            C ::= 'c'
            C ::= ε
            """, start: "S")
        XCTAssertParseSucceeds(parser, "a b c")
        XCTAssertParseSucceeds(parser, "a b")
        XCTAssertParseSucceeds(parser, "a c")
        XCTAssertParseSucceeds(parser, "a")       // pure right-null
    }

    func testMiddleNullable() throws {
        let parser = try makeParser("""
            S ::= A B C
            A ::= 'x'
            B ::= 'y'
            B ::= ε
            C ::= 'z'
            """, start: "S")
        XCTAssertParseSucceeds(parser, "x y z")
        XCTAssertParseSucceeds(parser, "x z")
    }

    // MARK: ── 8. Catalan ambiguity ────────────────────────────────────────────

    func testCatalan3() throws {
        let parser = try makeParser("""
            S ::= S S
            S ::= 'a'
            """, start: "S")
        guard let count = treeCount(parser, "a a a", startSymbol: "S") else {
            return XCTFail("Parse failed")
        }
        XCTAssertEqual(count, 2, "Catalan(2) = 2")
    }

    func testCatalan4() throws {
        let parser = try makeParser("""
            S ::= S S
            S ::= 'a'
            """, start: "S")
        guard let count = treeCount(parser, "a a a a", startSymbol: "S") else {
            return XCTFail("Parse failed")
        }
        XCTAssertEqual(count, 5, "Catalan(3) = 5")
    }

    // MARK: ── 9. BSR triple count ─────────────────────────────────────────────

    func testBSRSingleToken() throws {
        let parser = try makeParser("S ::= 'a' \n", start: "S")
        let result = parse(parser, "a")
        guard result.isSuccessful else {
            return XCTFail("Parse failed")
        }
        XCTAssertEqual(result.bsr.count, 1)
    }

    func testBSRNonEmpty() throws {
        let parser = try makeParser("""
            E ::= E '+' T
            E ::= T
            T ::= 'n'
            """, start: "E")
        let result = parse(parser, "n + n")
        guard result.isSuccessful else {
            return XCTFail("Parse failed")
        }
        XCTAssertGreaterThan(result.bsr.count, 0)
    }

    // MARK: ── 10. SPPF graph ──────────────────────────────────────────────────

    func testSPPFRootExists() throws {
        let parser = try makeParser("S ::= 'x' 'y' \n", start: "S")
        let result = parse(parser, "x y")
        guard result.isSuccessful, let sppf = result.sppfGraph else {
            return XCTFail("Parse failed")
        }
        XCTAssertNotNil(sppf.root(startSymbol: "S", inputLength: 2))
    }

    func testSPPFRootWrongLength() throws {
        let parser = try makeParser("S ::= 'x' \n", start: "S")
        let result = parse(parser, "x")
        guard result.isSuccessful, let sppf = result.sppfGraph else {
            return XCTFail("Parse failed")
        }
        XCTAssertNil(sppf.root(startSymbol: "S", inputLength: 99))
    }

    // MARK: ── 11. GrammarSlot description ────────────────────────────────────

    func testSlotDescription() throws {
        let grammar = try Grammar(bnf: "S ::= 'a' 'b' 'c' \n", start: "S")
        guard let prod = grammar.productions.first(where: { $0.goal.name == "S" }) else {
            return XCTFail("No production for S")
        }
        let slot = GrammarSlot(production: prod, dot: 1)
        XCTAssertTrue(slot.description.contains("•"))
        XCTAssertFalse(slot.isCompleted)
        XCTAssertTrue(GrammarSlot(production: prod, dot: prod.rule.count).isCompleted)
    }

    // MARK: ── 12. Left-recursive grammar ─────────────────────────────────────

    func testLeftRecursive() throws {
        let parser = try makeParser("""
            S ::= S 'a'
            S ::= 'a'
            """, start: "S")
        XCTAssertParseSucceeds(parser, "a")
        XCTAssertParseSucceeds(parser, "a a")
        XCTAssertParseSucceeds(parser, "a a a")
    }

    // MARK: ── 13. Parse failure cases ────────────────────────────────────────

    func testEmptyNonNullable() throws {
        let parser = try makeParser("S ::= 'a' \n", start: "S")
        if parse(parser, "").isSuccessful { XCTFail("Should fail on empty input") }
    }

    func testExtraToken() throws {
        let parser = try makeParser("S ::= 'a' \n", start: "S")
        if parse(parser, "a a").isSuccessful { XCTFail("Extra token should fail") }
    }

    func testUnknownToken() throws {
        let parser = try makeParser("S ::= 'a' 'b' \n", start: "S")
        if parse(parser, "a z").isSuccessful { XCTFail("Unknown terminal should fail") }
    }

    // MARK: ── 14. ParseResult.hasAmbiguity ───────────────────────────────────

    func testHasAmbiguityTrue() throws {
        let parser = try makeParser("""
            E ::= E '+' E
            E ::= 'a'
            """, start: "E")
        let result = parse(parser, "a + a + a")
        XCTAssertTrue(result.hasAmbiguity, "Ambiguous grammar should report hasAmbiguity = true")
    }

    func testHasAmbiguityFalse() throws {
        let parser = try makeParser("""
            E ::= E '+' T
            E ::= T
            T ::= 'a'
            """, start: "E")
        let result = parse(parser, "a + a + a")
        XCTAssertFalse(result.hasAmbiguity, "Unambiguous grammar should report hasAmbiguity = false")
    }

    // MARK: ── 15. BNF grammar builder ────────────────────────────────────────

    func testBNFBuilder() throws {
        let grammar = try Grammar(bnf: """
            E ::= E '+' T
            E ::= T
            T ::= 'n'
            """, start: "E")
        let names = Set(grammar.productions.map { $0.goal.name })
        XCTAssertTrue(names.contains("E"))
        XCTAssertTrue(names.contains("T"))
        XCTAssertEqual(grammar.start, NonTerminal(name: "E"))
    }

    // MARK: ── 16. Mixed alphanumeric tokens ──────────────────────────────────

    func testMixedKeywordAndSymbol() throws {
        let parser = try makeParser("""
            S ::= 'while' '(' 'x' ')' '{' 'y' '}'
            """, start: "S")
        XCTAssertParseSucceeds(parser, "while ( x ) { y }")
    }

    func testNumberToken() throws {
        // Grammar with a numeric literal terminal
        let parser = try makeParser("""
            S ::= 'n'
            """, start: "S")
        // "42" tokenises as .number(.decimal(42)) -> tokenKey -> "42"
        // Grammar terminal is 'n' which maps to "n", not "42"
        // So this should FAIL — verifying the tokenizer doesn't confuse 42 with 'n'
        if parse(parser, "42").isSuccessful {
            XCTFail("'42' should not match terminal 'n'")
        }
    }
}

// MARK: - Assertion helper

private func XCTAssertParseSucceeds(
    _ parser:  RNGLRParser,
    _ input:   String,
    file:      StaticString = #file,
    line:      UInt         = #line
) {
    let result = (try? parser.parse(input)) ?? ParseResult(isSuccessful: false, bsr: Set(), sppfGraph: nil)
    if !result.isSuccessful {
        XCTFail("Expected success but parse failed", file: file, line: line)
    }
}
