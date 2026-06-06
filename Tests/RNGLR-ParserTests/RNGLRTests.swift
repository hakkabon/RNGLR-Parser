import Testing
@testable import RNGLR_Parser
import Grammar
import Tokenizer

@Suite("RNGLR Parser — Swift Testing suite")
struct RNGLRTests {

    // MARK: - Helpers

    private func makeParser(_ bnf: String, start: String) throws -> (RNGLRParser, Grammar) {
        let grammar = try Grammar(bnf: bnf, start: start)
        return (RNGLRParser(grammar: grammar), grammar)
    }

    /// Parse `input`, return (treeCount, bsr).
    private func parseResult(_ bnf: String, start: String, input: String, tokenCount: Int)
    throws -> (treeCount: Int, bsr: BSRSet) {
        let (parser, _) = try makeParser(bnf, start: start)
        guard case .success(let bsr, let sppf) = try parser.parse(input),
              let root = sppf.root(startSymbol: start, inputLength: tokenCount) else {
            Issue.record("Parse failed for input: '\(input)'")
            return (0, BSRSet())
        }
        var visited = Set<SPPFNode>()
        let trees = CSTEnumerator(graph: sppf).trees(for: root, visited: &visited)
        return (trees.count, bsr)
    }

    // MARK: ── Tokenizer: tokenKey mapping ─────────────────────────────────────

    @Test("tokenKey: .symbol maps to its string payload")
    func tokenKeySymbol() throws {
        let (parser, _) = try makeParser("S ::= '+' \n", start: "S")
        let src = "+"
        let tok = Token(type: .symbol("+"), range: src.startIndex ..< src.endIndex)
        #expect(parser.tokenKey(tok) == "+")
    }

    @Test("tokenKey: .literal maps to its string payload")
    func tokenKeyLiteral() throws {
        let (parser, _) = try makeParser("S ::= 'id' \n", start: "S")
        let src = "id"
        let tok = Token(type: .literal("id"), range: src.startIndex ..< src.endIndex)
        #expect(parser.tokenKey(tok) == "id")
    }

    @Test("tokenKey: .eof maps to \"$\"")
    func tokenKeyEOF() throws {
        let (parser, _) = try makeParser("S ::= 'a' \n", start: "S")
        let src = ""
        let tok = Token(type: .eof, range: src.startIndex ..< src.endIndex)
        #expect(parser.tokenKey(tok) == "$")
    }

    // MARK: ── Tokenizer pipeline ──────────────────────────────────────────────

    @Test("Tokenize: correct count including EOF sentinel")
    func tokeniseCount() throws {
        let (parser, _) = try makeParser("""
            E ::= E '+' T
            E ::= T
            T ::= 'id'
            """, start: "E")
        let tokens = parser.tokenize("id + id")
        #expect(tokens.count == 4, "3 real tokens + 1 EOF")
    }

    @Test("Tokenize: operators become .symbol tokens")
    func tokeniseSymbols() throws {
        let (parser, _) = try makeParser("""
            E ::= E '+' T
            E ::= T
            T ::= T '*' F
            T ::= F
            F ::= 'id'
            """, start: "E")
        let types = parser.tokenize("id + id * id").map(\.type)
        #expect(types.contains(.symbol("+")))
        #expect(types.contains(.symbol("*")))
    }

    @Test("Tokenize: word terminals become .keyword tokens")
    func tokeniseKeywords() throws {
        let (parser, _) = try makeParser("""
            S ::= 'while' '(' 'x' ')' '{' 'y' '}'
            """, start: "S")
        let types = parser.tokenize("while ( x ) { y }").map(\.type)
        #expect(types.contains(.keyword("while")))
    }

    // MARK: ── Parse examples ─────────────────────────────────────────────────

    @Test("Unambiguous arithmetic: id + id * id → 1 tree")
    func arithmeticOneTree() throws {
        let (n, _) = try parseResult("""
            E ::= E '+' T
            E ::= T
            T ::= T '*' F
            T ::= F
            F ::= '(' E ')'
            F ::= 'id'
            """, start: "E", input: "id + id * id", tokenCount: 5)
        #expect(n == 1)
    }

    @Test("Ambiguous addition: a + a + a → 2 trees")
    func ambiguousTwoTrees() throws {
        let (n, _) = try parseResult("""
            E ::= E '+' E
            E ::= 'a'
            """, start: "E", input: "a + a + a", tokenCount: 5)
        #expect(n == 2)
    }

    @Test("Nullable: b (A → ε used)")
    func nullable() throws {
        let (parser, _) = try makeParser("""
            S ::= A B
            A ::= 'a'
            A ::= ε
            B ::= 'b'
            """, start: "S")
        let r1 = try parser.parse("a b")
        let r2 = try parser.parse("b")
        if case .failure = r1 { Issue.record("a b should succeed") }
        if case .failure = r2 { Issue.record("b should succeed (A → ε)") }
    }

    @Test("Catalan 3: S → SS | a, 3 tokens → 2 trees")
    func catalan3() throws {
        let (n, _) = try parseResult("""
            S ::= S S
            S ::= 'a'
            """, start: "S", input: "a a a", tokenCount: 3)
        #expect(n == 2)
    }

    @Test("Catalan 4: S → SS | a, 4 tokens → 5 trees")
    func catalan4() throws {
        let (n, _) = try parseResult("""
            S ::= S S
            S ::= 'a'
            """, start: "S", input: "a a a a", tokenCount: 4)
        #expect(n == 5)
    }

    @Test("Right-null suffix: all four nullable combinations")
    func rightNull() throws {
        let (parser, _) = try makeParser("""
            S ::= A B C
            A ::= 'a'
            B ::= 'b'
            B ::= ε
            C ::= 'c'
            C ::= ε
            """, start: "S")
        for input in ["a b c", "a b", "a c", "a"] {
            if case .failure(let pos, let msg) = try parser.parse(input) {
                Issue.record("'\(input)' failed at \(pos): \(msg)")
            }
        }
    }

    @Test("BSR set is non-empty on success")
    func bsrNonEmpty() throws {
        let (_, bsr) = try parseResult("""
            E ::= E '+' T
            E ::= T
            T ::= 'n'
            """, start: "E", input: "n + n", tokenCount: 3)
        #expect(bsr.count > 0)
    }

    @Test("SPPF root exists at correct input length")
    func sppfRoot() throws {
        let (parser, _) = try makeParser("S ::= 'x' 'y' \n", start: "S")
        guard case .success(_, let sppf) = try parser.parse("x y") else {
            Issue.record("Parse failed"); return
        }
        #expect(sppf.root(startSymbol: "S", inputLength: 2) != nil)
        #expect(sppf.root(startSymbol: "S", inputLength: 99) == nil)
    }

    @Test("ParseResult.hasAmbiguity is true for ambiguous grammar")
    func hasAmbiguity() throws {
        let (parser, _) = try makeParser("""
            E ::= E '+' E
            E ::= 'a'
            """, start: "E")
        let result = try parser.parse("a + a + a")
        #expect(result.hasAmbiguity == true)
    }

    @Test("ParseResult.hasAmbiguity is false for unambiguous grammar")
    func hasNoAmbiguity() throws {
        let (parser, _) = try makeParser("""
            E ::= E '+' T
            E ::= T
            T ::= 'a'
            """, start: "E")
        let result = try parser.parse("a + a + a")
        #expect(result.hasAmbiguity == false)
    }

    @Test("Mixed tokens: keywords and symbols in one input")
    func mixedTokens() throws {
        let (parser, _) = try makeParser("""
            S ::= 'while' '(' 'x' ')' '{' 'y' '}'
            """, start: "S")
        let result = try parser.parse("while ( x ) { y }")
        if case .failure = result { Issue.record("while statement should parse") }
    }
}
