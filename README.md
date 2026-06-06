# RNGLR Parser

A Swift implementation of the **Right Nulled Generalised LR (RNGLR)** parsing algorithm (Scott & Johnstone, 2006), extended with a full tokenizer pipeline powered by the [GrammarTokenizer](https://github.com/hakkabon/GrammarTokenizer) package.

The parser handles **all context-free grammars** — including ambiguous, left-recursive, and nullable ones — in worst-case *O(n³)* time while running in linear time on deterministic grammars. Grammar types are provided by the [Grammar](https://github.com/hakkabon/Grammar) package.

---

## Features

| Feature | Description |
|---|---|
| **Full GLR parsing** | All CFGs including ambiguous and left-recursive |
| **RNGLR right-null extension** | Nullable suffix productions handled correctly |
| **InputTokenizer integration** | Grammar terminals auto-configure the tokenizer |
| **BSR set** | Compact O(n²) internal record of all derivations |
| **SPPF graph** | Shared Packed Parse Forest derived on demand |
| **CST enumeration** | All concrete syntax trees from the SPPF |
| **Ambiguity detection** | `ParseResult.hasAmbiguity` flag |
| **Grammar package** | BNF/EBNF grammar import via `Grammar(bnf:start:)` |

---

## Token Pipeline

```
Source string
    │
    ▼
InputTokenizer          ← configured from grammar.terminals
    │  symbols:  { "+", "*", "(", ")", ... }   — operator strings
    │  keywords: { "id", "while", "if", ... }  — word terminals
    │
    ▼  [Token]
tokenKey(_ token:) → String
    │  .symbol("+")    → "+"
    │  .literal("id")  → "id"
    │  .keyword("if")  → "if"
    │  .identifier("x")→ "x"
    │  .eof            → "$"
    │
    ▼  String keys
LR ACTION/GOTO tables
    │  (keyed by the same surface strings)
    │
    ▼
GSS  +  BSR set  →  SPPF graph  →  CSTEnumerator
```

The grammar's `Terminal.string(s)` values become the LR-table keys during automaton construction.  
`tokenKey()` maps every `Token` to the same string, ensuring the two sides converge without any special-case logic.

---

## Quick Start

```swift
import RNGLR_Parser
import Grammar

// 1. Build a grammar from BNF
let grammar = try Grammar(bnf: """
    E ::= E '+' T
    E ::= T
    T ::= T '*' F
    T ::= F
    F ::= '(' E ')'
    F ::= 'id'
    """, start: "E")

// 2. Create the parser (automaton built automatically)
let parser = RNGLRParser(grammar: grammar)

// 3. Parse source text directly — tokenised internally
let result = try parser.parse("id + id * id")

switch result {
case .success(let bsr, let sppf):
    print("BSR triples: \(bsr.count)")
    print("Ambiguous: \(result.hasAmbiguity)")

    // Enumerate all parse trees
    let root = sppf.root(startSymbol: "E", inputLength: 5)!
    var visited = Set<SPPFNode>()
    let trees = CSTEnumerator(graph: sppf).trees(for: root, visited: &visited)
    print("Trees: \(trees.count)")     // 1 for this unambiguous grammar

case .failure(let pos, let msg):
    print("Parse failed at \(pos): \(msg)")
}
```

---

## Package Integration

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/hakkabon/RNGLR-Parser.git",       branch: "main"),
    .package(url: "https://github.com/hakkabon/Grammar.git",            branch: "main"),
    .package(url: "https://github.com/hakkabon/GrammarTokenizer.git",   branch: "main"),
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "RNGLR-Parser",  package: "RNGLR-Parser"),
        .product(name: "Grammar",       package: "Grammar"),
        .product(name: "Tokenizer",     package: "GrammarTokenizer"),
    ]),
]
```

---

## Architecture

```
Grammar (hakkabon/Grammar)
  └── Production  (goal: NonTerminal, rule: [Symbol])
  └── Terminal    (.string | .characterRange | .regularExpression | .meta)
  └── NonTerminal (name: String)

GrammarTokenizer (hakkabon/GrammarTokenizer)
  └── InputTokenizer  — TokenStream subclass; symbols + keywords from grammar
  └── Token           — (type: TokenType, range: Range<String.Index>)
  └── TokenType       — .symbol | .literal | .keyword | .identifier | .number | .eof | …

RNGLR-Parser (this package)
  └── GrammarSlot     — (Production, dot: Int) — LR(0) item
  └── LRAutomaton     — SLR(1) ACTION/GOTO tables + RNGLR right-null extension
  └── GSS             — Graph Structured Stack
  └── BSRSet          — Binary Subset Representation
  └── SPPFGraph       — Shared Packed Parse Forest
  └── RNGLRParser     — Parser driver: tokenises + drives GLR loop
  └── CSTEnumerator   — Enumerates all parse trees from SPPF
```

---

## Terminal Classification

`RNGLRParser` splits `grammar.terminals` into two buckets for `InputTokenizer`:

| Bucket | Criterion | Example terminals | Tokenizer result |
|---|---|---|---|
| `terminalSymbols` | Contains any non-`[A-Za-z0-9_]` character | `"+"`, `"*"`, `"()"`, `"::="` | `.symbol("+")`  |
| `reservedWords`   | Purely alphanumeric/underscore | `"id"`, `"while"`, `"true"` | `.keyword("id")` |

Both `.keyword` and `.identifier` tokens map to their string payload via `tokenKey()`, so unregistered identifiers (like `x` in `x + y`) also match correctly when they appear as grammar terminals.

---

## Outputs: BSR Set vs SPPF

### BSR Set (primary record)
Stores triples `(slot, l, r)` — *"grammar slot `A → α •` was completed over input[l, r)"*.

```swift
bsr.all                                // complete set of triples
bsr.completed(from: 2)                 // triples starting at position 2
bsr.triples(lhs: nt, from: 0, to: 3)  // for a specific non-terminal and span
```

### SPPF Graph (derived)
Four node kinds:

| Node | Meaning |
|---|---|
| `symbol(name, l, r)` | Non-terminal `name` spans input[l, r) |
| `terminal(symbol, l, r)` | Token string spans input[l, r) |
| `intermediate(slot, l, r)` | Binarised partial RHS |
| `packed(slot, pivot)` | One derivation alternative (ambiguity branch) |

Multiple packed children on a symbol/intermediate node = ambiguity.

---

## Running the Demo

```bash
swift run demo
```

Seven examples: unambiguous arithmetic, ambiguous addition (2 trees), nullable, Catalan (2 & 5 trees), right-null suffix (4 variants), left-recursive, and mixed keyword/symbol tokens.

---

## Running the Tests

```bash
swift test
```

The test suite covers: `tokenKey()` mapping for all `TokenType` cases, tokenizer pipeline (count, symbol/keyword split), nullable detection (direct and transitive), arithmetic (success, 1-tree, failure), ambiguity (2-tree and single-token), epsilon, right-null suffix (all four combinations), Catalan n=3 and n=4, BSR counts, SPPF root, `GrammarSlot` description, left-recursive grammar, parse failures, `hasAmbiguity` flag, and mixed keyword/symbol input.

---

## References

- Scott, E. & Johnstone, A. (2006). *Right Nulled GLR Parsers*. ACM TOPLAS 28(4), 577–618.
- Tomita, M. (1986). *Efficient Parsing for Natural Language*. Kluwer Academic.
- Scott, E. & Johnstone, A. (2013). *GLL Parse-Tree Generation*. SCP 78(10).
