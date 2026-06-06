# RNGLR Parser — Technical Documentation

## Table of Contents

1. [Algorithm Overview](#1-algorithm-overview)
2. [Tokenizer Integration](#2-tokenizer-integration)
3. [Grammar Representation](#3-grammar-representation)
4. [Grammar Slots](#4-grammar-slots)
5. [LR Automaton Construction](#5-lr-automaton-construction)
6. [Graph Structured Stack (GSS)](#6-graph-structured-stack-gss)
7. [Binary Subset Representation (BSR)](#7-binary-subset-representation-bsr)
8. [Shared Packed Parse Forest (SPPF)](#8-shared-packed-parse-forest-sppf)
9. [Parser Driver](#9-parser-driver)
10. [Concrete Syntax Tree Enumeration](#10-concrete-syntax-tree-enumeration)
11. [Protocols and Public API](#11-protocols-and-public-api)
12. [Complexity Analysis](#12-complexity-analysis)
13. [Known Limitations and Future Work](#13-known-limitations-and-future-work)
14. [File Index](#14-file-index)

---

## 1. Algorithm Overview

The RNGLR algorithm (Scott & Johnstone, 2006) generalises Knuth's LR parsing by maintaining a **Graph Structured Stack (GSS)** instead of a single deterministic stack. This lets the parser explore all possible parser states simultaneously, handling ambiguous, left-recursive, and nullable grammars correctly.

The key innovation over earlier GLR algorithms is the **Right Nulled** extension: productions with nullable suffixes — e.g. `A → x B C` where `B` and `C` can derive ε — are handled by pre-computing extra reduce entries in the parse table (the "right-null" entries), so the parser never needs to re-examine nullable tails at runtime.

### Parse loop invariant

At each input position `i`, a **frontier** — a set of GSS nodes `(state, i)` — represents all live parser heads simultaneously:

1. **Reduce**: look up all reduce actions for the current token; pop GSS edges; GOTO; create/merge new GSS nodes; record completed slots in the BSR set.
2. **Shift**: advance each frontier node by one token, creating GSS nodes at position `i + 1`.
3. The frontier at `i + 1` is all nodes created by shifts.

Reduces may cascade: newly created GSS nodes may have their own reduce actions. A **worklist** plus a **processed set** prevents redundant re-processing while still propagating reductions through newly added edges.

---

## 2. Tokenizer Integration

### The token pipeline

```
Grammar.terminals: Set<Terminal>
        │
        ├─ symbol strings  ────▶  InputTokenizer(terminalSymbols:)
        │  (contain ≥1 non-word char)
        └─ keyword strings ────▶  InputTokenizer(reservedWords:)
           (purely [A-Za-z0-9_])
                │
                ▼
         source text  ──▶  [Token]  ──▶  tokenKey(_ token:)  ──▶  String keys
                                                                   == LR table keys
```

### Terminal classification

`RNGLRParser.grammarVocabulary()` iterates `grammar.terminals` (a `Set<Terminal>` derived from all `Production.rule` arrays) and classifies each `Terminal.string(s)` value:

| String contents | Bucket | `InputTokenizer` parameter | Emitted `TokenType` |
|---|---|---|---|
| ≥1 non-`[A-Za-z0-9_]` char | operators/punctuation | `terminalSymbols` | `.symbol(s)` |
| all `[A-Za-z0-9_]` chars | reserved words | `reservedWords` | `.keyword(s)` |

`Terminal.regularExpression`, `.characterRange`, and `.meta` cases are handled separately or ignored (meta-terminals like ε and $ are internal only).

### `tokenKey(_ token: Token) → String`

This function is the join point between the tokenizer and the LR table. It maps every `Token` to the surface string that appears as a key in `ACTION[state]`:

| `TokenType` | Key returned |
|---|---|
| `.symbol(s)` | `s` |
| `.literal(s)` | `s` |
| `.keyword(s)` | `s` |
| `.identifier(s)` | `s` |
| `.number(n)` | `n.description` |
| `.regex(s)` | `s` |
| `.eof` | `"$"` |
| `.comment` | `""` (filtered before parse loop) |
| `.invalid(e)` | `"\(e)"` (will be rejected by parser) |

The LR automaton stores exactly `Terminal.string(s)` → `s` as the action key (via `LRAutomaton.terminalKey(_:Terminal)`). Since `tokenKey()` returns the same string `s` for the corresponding token type, the lookup `ACTION[state][tokenKey(token)]` succeeds without any special-case bridging.

### EOF sentinel

`tokenize()` appends a single `Token(type: .eof, range: endIndex..<endIndex)` to the token array after filtering out any physical `¶` character. The parse loop checks `token.type == .eof` (not `token == .meta(.eof)`, which is a `Grammar.Terminal` value, not a `Tokenizer.Token`).

### Input length

The SPPF root is looked up as `sppf.root(startSymbol:inputLength:)`. `inputLength` is the count of real tokens — i.e. `tokens.filter { $0.type != .eof }.count` — not the total `tokens.count` which includes the sentinel.

---

## 3. Grammar Representation

Grammar types are provided by [hakkabon/Grammar](https://github.com/hakkabon/Grammar).

| Type | Definition | Notes |
|---|---|---|
| `NonTerminal` | `struct { name: String }` | Equatable, Hashable, Comparable |
| `Terminal` | `enum { .string(String) \| .characterRange \| .regularExpression \| .meta(MetaTerminal) }` | Rich terminal type |
| `MetaTerminal` | `enum { .eps \| .lambda \| .eof \| .eop \| .empty }` | Internal epsilon/EOF markers |
| `Symbol` | `enum { .terminal(Terminal) \| .nonTerminal(NonTerminal) \| .metaSymbol(MetaSymbol) }` | Unified symbol |
| `Production` | `struct { goal: NonTerminal; rule: [Symbol] }` | One production rule |
| `Grammar` | `struct { productions: [Production]; start: NonTerminal; nullableNonTerminals: Set<NonTerminal>; terminals: Set<Terminal> }` | Full grammar |

`Grammar.nullableNonTerminals` is computed at `init` time by a fixed-point algorithm. It is consumed by both the LR automaton (for right-null entries) and the SPPF builder (for zero-width symbol nodes).

`Grammar.terminals` returns every `Terminal` that appears in any production's `rule` array — this is the source of truth for configuring the tokenizer.

---

## 4. Grammar Slots

File: `Sources/RNGLR-Parser/Slot.swift`

A **grammar slot** `A → α • β` pairs a production with a dot position:

```swift
public struct GrammarSlot: Hashable {
    public let production: Production
    public let dot: Int          // 0 ≤ dot ≤ production.rule.count

    public var isCompleted: Bool { dot == production.rule.count }
    public var symbolAfterDot: Symbol? { … }
    public func advanced() -> GrammarSlot { … }
}
```

Slots serve three roles: LR(0) items during automaton construction, BSR triple labels (recording which production completed), and SPPF intermediate/packed-node labels (identifying partial derivations).

---

## 5. LR Automaton Construction

File: `Sources/RNGLR-Parser/LRAutomaton.swift`

### LR(0) automaton

1. **Augment**: add `__start__ → grammar.start`.
2. **Initial state**: closure of `{ __start__ → • S }`.
3. **Transitions**: for each symbol after a dot, collect advanced items; build a new state or reuse an existing one.
4. **Closure**: for `A → α • B β`, add `B → • γ` for every production of `B`.

States are keyed by their **kernel** (`Set<GrammarSlot>`) for deduplication.

### SLR(1) table filling

- **FOLLOW sets** are computed by a standard fixed-point over the grammar.
- For each completed item `A → α •` in state `s`: enter `reduce(prod)` into `ACTION[s][a]` for all `a ∈ FOLLOW(A)`.
- For each shift on terminal `t` to state `s'`: enter `shift(s')` into `ACTION[s][t]`.
- For non-terminal transitions: `GOTO[s][A] = s'`.

**GLR action sets**: `ACTION[s][t]` stores a `Set<LRAction>` (not a single value). Shift/reduce and reduce/reduce conflicts are not errors — they are explored concurrently by the GSS.

### RNGLR right-null extension

For every item `A → α • X β` in state `s` where the suffix `X β` is entirely nullable:

```swift
for item in state.closure where !item.isCompleted {
    let suffix = Array(prod.rule[item.dot...])
    guard isNullableSuffix(suffix) else { continue }
    for la in follow[prod.goal] ?? [] {
        action[state.id][la, default: []].insert(.reduce(prod))
    }
}
```

This pre-computes all right-null reduces, allowing the parser to apply a complete reduce from the state *before* consuming nullable tail symbols — the heart of the RNGLR correctness proof.

### Terminal key

`terminalKey(_ terminal: Terminal) → String` converts a `Grammar.Terminal` to the string used as the action-table key:

| `Terminal` | Key |
|---|---|
| `.string(s)` | `s` |
| `.characterRange(r)` | `"\(r.lowerBound)...\(r.upperBound)"` |
| `.regularExpression(re)` | `re.pattern` |
| `.meta(.eps / .empty / .lambda)` | `"ε"` |
| `.meta(.eof / .eop)` | `"$"` |

---

## 6. Graph Structured Stack (GSS)

File: `Sources/RNGLR-Parser/GSS.swift`

The GSS is a directed acyclic graph where:
- **Nodes** are `(state, inputPosition)` pairs — at most one node per pair.
- **Edges** point downward (top → bottom), labelled with an `SPPFNode?`.

Sharing at the same `(state, position)` merges parallel parse paths and bounds the total number of nodes to O(n²).

```swift
let node = gss.node(state: 3, position: 7)   // create or retrieve
let isNew = gss.addEdge(from: top, to: pred, label: sppfNode)
```

Edge equality is determined by `(from, to)` only — the label of the first edge is kept when a duplicate edge is attempted.

---

## 7. Binary Subset Representation (BSR)

File: `Sources/RNGLR-Parser/BSRSet.swift`

The BSR set stores triples `(slot, leftExtent, rightExtent)` meaning *"grammar slot `A → α •` was satisfied over input[l, r)"*. It is:

- **O(n²)** in total size.
- **Idempotent**: inserting the same triple twice is a no-op.
- **Complete**: every successful reduction records a triple; all parse trees can be recovered from the complete set.

Queries:

```swift
bsr.all                                // Set<BSRTriple> — all triples
bsr.completed(from: 2)                 // triples starting at position 2
bsr.triples(lhs: nt, from: 0, to: 5)  // for a specific NT and span
```

---

## 8. Shared Packed Parse Forest (SPPF)

Files: `Sources/RNGLR-Parser/SPPF.swift`, `BSRSet.swift` (builder)

The SPPF is built on demand from the BSR set via `BSRSet.buildSPPF(grammar:)`.

### Node kinds

| Kind | Meaning | Children |
|---|---|---|
| `.symbol(name, l, r)` | Non-terminal `name` spans [l, r) | ≥1 packed nodes |
| `.terminal(symbol, l, r)` | Token string spans [l, r) | None (leaf) |
| `.intermediate(slot, l, r)` | Binarised partial RHS | ≥1 packed nodes |
| `.packed(slot, pivot)` | One derivation alternative | ≤2 nodes |

### Binarisation

Productions with ≥3 RHS symbols are binarised so every internal node has at most two children:

```
symbol(A, 0, 3)
└── packed(A→X₁X₂X₃•, 0)
    ├── intermediate(A→X₁X₂•X₃, 0, 2)
    │   └── packed(A→X₁X₂•X₃, pivot)
    │       ├── terminal(X₁, 0, 1)
    │       └── terminal(X₂, 1, 2)
    └── terminal(X₃, 2, 3)
```

### Ambiguity

Multiple packed-node children on a symbol/intermediate node represent competing derivations:

```
symbol(E, 0, 5)
├── packed(E→E+E•, pivot=3)    ← (a+a)+a
└── packed(E→E+E•, pivot=1)    ← a+(a+a)
```

### Deduplication

`SPPFGraph.intern(_:)` returns the canonical node for any given `SPPFNode` identity, ensuring sharing across the forest.

### `ParseResult.hasAmbiguity`

```swift
sppf.allNodes.contains { node in
    sppf.children(of: node).filter { if case .packed = $0 { return true }; return false }.count > 1
}
```

---

## 9. Parser Driver

File: `Sources/RNGLR-Parser/RNGLRParser.swift`

### Initialisation

```swift
// Builds the LR automaton automatically:
let parser = RNGLRParser(grammar: grammar)

// With pre-built automaton (avoids rebuilding):
let auto = LRAutomaton(grammar: grammar)
auto.build()
let parser = RNGLRParser(grammar: grammar, automaton: auto)
```

### Parse loop

```
tokens = tokenize(source)    // InputTokenizer → [Token] + EOF sentinel
frontier = { GSS(state:0, pos:0) }

for i in 0 ..< tokens.count:
    termKey = tokenKey(tokens[i])

    REDUCE PHASE:
        reductions = { Descriptor(node, prod, i) | node ∈ frontier,
                       reduce(prod) ∈ ACTION[node.state][termKey] }
        while reductions ≠ ∅:
            desc = reductions.pop()
            processReduce(desc)   ← may add new descriptors

    if tokens[i].type == .eof:
        if any frontier node has accept ∈ ACTION[state]["$"]:
            return .success(bsr, buildSPPF())
        break

    SHIFT PHASE:
        for node ∈ frontier:
            if shift(s') ∈ ACTION[node.state][termKey]:
                create GSS edge: (s', i+1) ──SPPFNode.terminal(termKey, i, i+1)──▶ node
        frontier = all newly created nodes
```

### `processReduce`

For descriptor `(topNode, prod, rightExtent)`:

1. `popCount = effectivePopCount(prod)` — 0 for epsilon, `prod.rule.count` otherwise.
2. Enumerate all GSS paths of length `popCount` from `topNode` → `(predecessor, leftExtent, labels)`.
3. Record `(slot=A→α•, leftExtent, rightExtent)` in BSR.
4. `gotoState = GOTO[predecessor.state][prod.goal.name]`.
5. Create/reuse `GSS(gotoState, position)`.
6. Add edge from new node to predecessor.
7. **If edge is new**: seed new reduce descriptors for the new node with the current `termKey`.

Step 7 propagates reductions through newly-created edges without re-processing already-handled `(node, prod, extent)` triples.

### `effectivePopCount`

```swift
private func effectivePopCount(_ prod: Production) -> Int {
    if prod.rule.isEmpty { return 0 }
    let allEps = prod.rule.allSatisfy { if case .terminal(let t) = $0, case .meta(.eps) = t { return true }; return false }
    return allEps ? 0 : prod.rule.count
}
```

Epsilon productions (empty rule or sole `.meta(.eps)` symbol) pop 0 GSS edges.

---

## 10. Concrete Syntax Tree Enumeration

File: `Sources/RNGLR-Parser/RNGLRParser.swift` (class `CSTEnumerator`)

`CSTEnumerator` traverses the SPPF depth-first, returning one `[CSTNode]` list per complete parse tree.

### Cartesian product expansion

When an intermediate node has multiple packed children (ambiguity), the enumerator computes the cartesian product:

```swift
private func cartesianAppend(_ prefixes: [[CSTNode]], _ suffixes: [[CSTNode]]) -> [[CSTNode]] {
    var result: [[CSTNode]] = []
    for pre in prefixes { for suf in suffixes { result.append(pre + suf) } }
    return result
}
```

### Cycle detection

A `visited: inout Set<SPPFNode>` set tracks nodes currently on the DFS stack. If a node is encountered again before its subtree returns, that path is abandoned — preventing infinite loops on ε-cycle grammars like `A → A`.

### Complexity

The number of trees is exactly the number of distinct parse trees. For an ambiguous grammar this can be exponential. For `S → SS | a` on `n` tokens the count equals the (n−1)th Catalan number.

---

## 11. Protocols and Public API

### `Parser` (DeterministicParser.swift)

```swift
public protocol Parser {
    func syntaxTree(for string: String) throws -> ParseTree
}
```

`ParseTree = SyntaxTree<NonTerminal, Range<String.Index>>`

`RNGLRParser` implements this by calling `parse(_:)` and extracting the first tree from the SPPF.

### `GeneralizedParser` (GenerlizedParser.swift)

```swift
public protocol GeneralizedParser {
    func parse(_ string: String) throws -> ParseResult
}
```

`ParseResult` has two cases:
- `.success(bsr: BSRSet, sppf: SPPFGraph)` — parse accepted; full derivation record available.
- `.failure(position: Int, message: String)` — parse rejected; furthest position and reason.

The `throws` annotation signals that the tokenizer layer (not the GLR algorithm itself) may throw `ParseError` for lexically invalid input.

---

## 12. Complexity Analysis

| Phase | Time | Space |
|---|---|---|
| LR(0) automaton | O(\|G\|²) | O(\|G\|²) |
| FOLLOW sets | O(\|G\|²) | O(\|G\| · \|T\|) |
| Tokenisation | O(n) | O(n) |
| Parse (worst case) | O(n³) | O(n²) |
| Parse (deterministic) | O(n) | O(n) |
| BSR set | — | O(n²) |
| SPPF construction | O(n³) | O(n²) |
| CST enumeration | O(trees · n) | O(n) stack |

`n` = token count, `|G|` = grammar size, `|T|` = terminal count.

---

## 13. Known Limitations and Future Work

1. **SLR(1) tables only** — Some grammars need LALR(1) or LR(1) to avoid spurious conflicts. Performance degrades on larger conflict sets but correctness is preserved.
2. **`tokenize()` is eager** — The full token array is materialised before parsing. A streaming design using `ParserInput` would reduce peak memory for large inputs.
3. **No regex terminal matching at parse time** — `Terminal.regularExpression` values are registered but not used to classify tokens on-the-fly. A custom `TokenStream` subclass would be needed.
4. **CST materialises all trees** — For highly ambiguous grammars, memory usage can be exponential. A lazy `AsyncSequence` iterator is the planned fix.
5. **`syntaxTree(for:)` returns the first tree only** — The `Parser` protocol is a single-tree interface by definition; use `allSyntaxTrees(for:)` or work directly with the SPPF for multiple trees.
6. **No error recovery** — The parse stops at the first position where all frontier heads fail. Panic-mode recovery is a planned addition.

---

## 14. File Index

| File | Contents |
|---|---|
| `Sources/RNGLR-Parser/Slot.swift` | `GrammarSlot` — dotted LR(0) item |
| `Sources/RNGLR-Parser/GSS.swift` | `GSSNode`, `GSSEdge`, `GSS` |
| `Sources/RNGLR-Parser/SPPF.swift` | `SPPFNode`, `SPPFGraph` |
| `Sources/RNGLR-Parser/BSRSet.swift` | `BSRTriple`, `BSRSet`, SPPF builder |
| `Sources/RNGLR-Parser/LRAutomaton.swift` | `LRAction`, `ItemSet`, `LRAutomaton` |
| `Sources/RNGLR-Parser/RNGLRParser.swift` | `RNGLRParser`, `CSTNode`, `CSTEnumerator` |
| `Sources/RNGLR-Parser/Parser/DeterministicParser.swift` | `Parser` protocol, `ParseTree` typealias |
| `Sources/RNGLR-Parser/Parser/GenerlizedParser.swift` | `ParseResult`, `GeneralizedParser` protocol |
| `Sources/RNGLR-Parser/Parser/ParseError.swift` | `ParseError` enum |
| `Sources/RNGLR-Parser/Parser/Syntax-Tree/SyntaxTree.swift` | Generic `SyntaxTree<N,L>` |
| `Sources/RNGLR-Parser/Parser/Syntax-Tree/SyntaxTreePrinter.swift` | Terminal-colour pretty-printer |
| `Sources/RNGLR-Parser/Parser/Syntax-Tree/SyntaxTreeGraphviz.swift` | Graphviz `.dot` exporter |
| `Sources/demo/main.swift` | Seven illustrative examples |
| `Sources/demo/RunExample.swift` | Shared example harness |
| `Tests/RNGLR-ParserTests/RNGLRParserTests.swift` | XCTest suite (16 tests) |
| `Tests/RNGLR-ParserTests/RNGLRTests.swift` | Swift Testing suite (14 tests) |
