//
//  main.swift
//  demo
//
//  Entry point — runs illustrative RNGLR parser examples.
//  Grammars are built from BNF strings; source text is tokenised automatically
//  by the RNGLRParser using the InputTokenizer derived from grammar.terminals.
//

import Foundation
import RNGLR_Parser
import Grammar

// MARK: - BNF helper

func grammar(_ bnf: String, start: String) -> Grammar {
    do { return try Grammar(bnf: bnf, start: start) }
    catch { fatalError("Grammar parse error: \(error)") }
}

// MARK: ── Example 1: Unambiguous arithmetic ───────────────────────────────────

func runArithmetic() {
    runExample(
        name: "Unambiguous Arithmetic:  id + id * id",
        grammar: grammar("""
            E ::= E '+' T
            E ::= T
            T ::= T '*' F
            T ::= F
            F ::= '(' E ')'
            F ::= 'id'
            """, start: "E"),
        input: "id + id * id"
    )
}

// MARK: ── Example 2: Ambiguous addition ──────────────────────────────────────

func runAmbiguous() {
    runExample(
        name: "Ambiguous Grammar:  a + a + a  (2 trees)",
        grammar: grammar("""
            E ::= E '+' E
            E ::= 'a'
            """, start: "E"),
        input: "a + a + a"
    )
}

// MARK: ── Example 3: Nullable non-terminal ───────────────────────────────────

func runNullable() {
    runExample(
        name: "Nullable:  b  (A → ε used)",
        grammar: grammar("""
            S ::= A B
            A ::= 'a'
            A ::= ε
            B ::= 'b'
            """, start: "S"),
        input: "b"
    )
}

// MARK: ── Example 4: Catalan (highly ambiguous) ───────────────────────────────

func runCatalan() {
    runExample(
        name: "Highly Ambiguous  S → SS | a:  a a a  (Catalan(2) = 2 trees)",
        grammar: grammar("""
            S ::= S S
            S ::= 'a'
            """, start: "S"),
        input: "a a a"
    )
}

// MARK: ── Example 5: Right-null suffix ───────────────────────────────────────

func runRightNull() {
    let g = grammar("""
        S ::= A B C
        A ::= 'a'
        B ::= 'b'
        B ::= ε
        C ::= 'c'
        C ::= ε
        """, start: "S")

    runExample(name: "Right-null suffix:  a b c  (all present)",    grammar: g, input: "a b c")
    runExample(name: "Right-null suffix:  a b    (C → ε)",          grammar: g, input: "a b")
    runExample(name: "Right-null suffix:  a c    (B → ε)",          grammar: g, input: "a c")
    runExample(name: "Right-null suffix:  a      (B → ε, C → ε)",   grammar: g, input: "a")
}

// MARK: ── Example 6: Left-recursive grammar ──────────────────────────────────

func runLeftRecursion() {
    runExample(
        name: "Left-recursive  S → Sa | a:  a a a",
        grammar: grammar("""
            S ::= S 'a'
            S ::= 'a'
            """, start: "S"),
        input: "a a a"
    )
}

// MARK: ── Example 7: Mixed alphanumeric tokens ────────────────────────────────

func runMixedTokens() {
    // Exercises the tokenizer's keyword bucket vs identifier bucket distinction.
    runExample(
        name: "Mixed tokens:  while ( x ) { y }",
        grammar: grammar("""
            Stmt   ::= 'while' '(' 'x' ')' '{' 'y' '}'
            """, start: "Stmt"),
        input: "while ( x ) { y }"
    )
}

// MARK: ── Run all ─────────────────────────────────────────────────────────────

print("RNGLR Parser — Swift Implementation")
print("Algorithm: Scott & Johnstone, \"Right Nulled GLR Parsers\" (2006)")
print("Tokenizer: hakkabon/GrammarTokenizer — InputTokenizer")
print("Grammar:   hakkabon/Grammar")

runArithmetic()
runAmbiguous()
runNullable()
//runCatalan()
runRightNull()
runLeftRecursion()
runMixedTokens()

print("\n" + String(repeating: "═", count: 68))
print("  Done.")
print(String(repeating: "═", count: 68))
