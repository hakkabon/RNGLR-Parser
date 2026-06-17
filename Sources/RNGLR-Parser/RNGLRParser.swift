//
//  RNGLRParser.swift
//  RNGLR-Parser
//
//  Created by Ulf Akerstedt-Inoue on 2026/05/22.
//  Copyright © 2026 hakkabon software. All rights reserved.
//

import Foundation
import Grammar
import Tokenizer

// MARK: - Descriptor

/// A pending parse action: reduce production `prod` for GSS node `node`,
/// where the RHS started at `extent`.
private struct Descriptor: Hashable {
    let node:   GSSNode
    let prod:   Production
    let extent: Int   // left extent of the completed RHS
}

// RNGLR parser driver aligned with the GrammarTokenizer package.
//
// Token pipeline
// ──────────────
//   Grammar (BNF/EBNF string)
//     └─▶ Grammar.terminals  ──▶  InputTokenizer (symbols + keywords derived from grammar)
//                                       └─▶ [Token]  ──▶  tokenKey(_ token:) -> String
//                                                               └─▶  LR ACTION table lookup
//
// The LR table is keyed on plain Swift strings that are equal to the string
// payload of each Grammar Terminal:
//   Terminal.string("id")  -> key "id"
//   Terminal.string("+")   -> key "+"
// The tokenizer maps source text to the *same* strings via tokenKey():
//   Token(.literal("id"))   -> "id"
//   Token(.symbol("+"))     -> "+"
//   Token(.identifier("x")) -> "x"
//   Token(.eof)             -> "$"
//
// This makes the two sides converge without any special-case logic.
//
// Algorithm (Scott & Johnstone, "Right Nulled GLR Parsers", 2006):
//
//  For each input position i:
//    1. SHIFT all active parser heads (GSS nodes at frontier i).
//    2. REDUCE: process all reduce actions for every active head.
//       Reducing pops k frames from the GSS (k = |rhs|), finds the
//       predecessor state, performs GOTO, and merges into an existing
//       GSS node or creates a new one.
//    3. Right-null reduces: apply reduces for productions whose nullable
//       suffix is consumed without advancing the input position.
//    4. Record every completed slot in the BSR set.
//
// Key data structures:
//   • `frontier`:     current set of active GSS node tops at position i
//   • `reductions`:   worklist of pending (gssNode, production) reduce actions
//   • `gss`:          the Graph Structured Stack
//   • `bsr`:          the BSR set

public final class RNGLRParser: Parser, GeneralizedParser {

    private let grammar:   Grammar
    private let automaton: LRAutomaton

    // Persistent GSS and BSR – reset on each parse() call.
    private let gss: GSS    = GSS()
    private let bsr: BSRSet = BSRSet()

    // MARK: - Initialisation

    /// Convenience initialiser: builds the LR automaton automatically.
    public init(grammar: Grammar) {
        self.grammar   = grammar
        let auto       = LRAutomaton(grammar: grammar)
        auto.build()
        self.automaton = auto
    }

    /// Initialise with a pre-built automaton (avoids rebuilding for repeated parses).
    public init(grammar: Grammar, automaton: LRAutomaton) {
        self.grammar   = grammar
        self.automaton = automaton
    }

    // MARK: - Parser protocol

    public func syntaxTree(for string: String) throws -> ParseTree {
        switch try parse(string) {
        case .success(let bsr, let sppf):
            return buildParseTree(bsr: bsr, sppf: sppf)
        case .failure(_, let msg):
            throw ParseError.generationFailed(msg)
        }
    }

    public func allSyntaxTrees(for string: String) throws -> [ParseTree] {
        switch try parse(string) {
        case .success(_, let sppf):
            return buildAllParseTrees(sppf: sppf)
        case .failure(_, let msg):
            throw ParseError.generationFailed(msg)
        }
    }

    // MARK: - GeneralizedParser protocol

    /// Parse `source` text using the tokenizer derived from the grammar's
    /// terminal vocabulary, then run the RNGLR algorithm.
    ///
    /// Returns `.success(bsr:sppf:)` on acceptance or `.failure(position:message:)`.
    /// Throws `ParseError` only for tokenizer-level failures (e.g. unrecognised characters
    /// that cannot be represented as any valid terminal).
    public func parse(_ source: String) throws -> ParseResult {
        gss.reset()
        bsr.reset()

        // ── 1. Tokenise ──────────────────────────────────────────────────────
        let tokens = tokenize(source)
        let n      = tokens.count  // includes the trailing .eof sentinel

        guard n > 0 else {
            // Empty source with an ε-only grammar is valid; the frontier check
            // below handles the actual accept/reject decision.
            return .success(bsr: bsr, sppf: SPPFGraph())
        }

        // ── 2. Parse ─────────────────────────────────────────────────────────
        var frontier: Set<GSSNode> = [gss.node(state: 0, position: 0)]

        for i in 0..<n {
            let token   = tokens[i]
            let termKey = tokenKey(token)   // String key into the ACTION table

            // ── REDUCE phase ────────────────────────────────────────────────
            var reductions:         [Descriptor]    = []
            var processedReductions: Set<Descriptor> = []

            for node in frontier {
                let acts = automaton.actions(state: node.state, terminal: termKey)
                for act in acts {
                    if case .reduce(let prod) = act {
                        let d = Descriptor(node: node, prod: prod, extent: i)
                        if processedReductions.insert(d).inserted {
                            reductions.append(d)
                        }
                    }
                }
            }

            while let desc = reductions.popLast() {
                processReduce(
                    desc:       desc,
                    position:   i,
                    termKey:    termKey,
                    frontier:   &frontier,
                    reductions: &reductions,
                    processed:  &processedReductions
                )
            }

            // ── Accept check on EOF sentinel ─────────────────────────────────
            if token.type == .eof {
                for node in frontier {
                    let acts = automaton.actions(state: node.state, terminal: "$")
                    if acts.contains(.accept) {
                        // inputLength == n - 1: exclude the synthetic EOF token
                        let sppf = bsr.buildSPPF(grammar: grammar)
                        return .success(bsr: bsr, sppf: sppf)
                    }
                }
                // Reached EOF without finding an accept — parse failed.
                break
            }

            // ── SHIFT phase ──────────────────────────────────────────────────
            var nextFrontier: Set<GSSNode> = []
            for node in frontier {
                let acts = automaton.actions(state: node.state, terminal: termKey)
                for act in acts {
                    if case .shift(let nextState) = act {
                        // Terminal SPPF leaf carries the display string of the token.
                        let termNode = SPPFNode.terminal(
                            symbol:      termKey,
                            leftExtent:  i,
                            rightExtent: i + 1
                        )
                        let newNode = gss.node(state: nextState, position: i + 1)
                        gss.addEdge(from: newNode, to: node, label: termNode)
                        nextFrontier.insert(newNode)
                    }
                }
            }

            frontier = nextFrontier
            if frontier.isEmpty && i < n - 1 {
                return .failure(
                    position: i,
                    message:  "Unexpected token '\(termKey)' (\(token.type)) at position \(i)"
                )
            }
        }

        return .failure(position: n - 1, message: "Parse did not reach accept state")
    }

    // MARK: - Tokenisation

    /// Build an `InputTokenizer` whose vocabulary is derived from the grammar's
    /// terminal set, then materialise the full token list including an EOF sentinel.
    ///
    /// Terminal classification strategy
    /// ──────────────────────────────────
    /// `Grammar.terminals` is a `Set<Terminal>` whose `.string(s)` cases carry
    /// the exact surface strings the grammar expects (e.g. `"+"`, `"id"`, `"while"`).
    ///
    /// We split them into two buckets for the tokenizer:
    ///  • `terminalSymbols` — strings that contain at least one non-alphanumeric,
    ///    non-underscore character (operators, punctuation, multi-char symbols).
    ///  • `reservedWords`   — purely alphabetic/digit/underscore strings that
    ///    should be emitted as `.keyword` rather than `.identifier`.
    ///
    /// This ensures the tokenizer emits `.symbol("+")` for `+` and
    /// `.keyword("while")` for `while`, both of which `tokenKey()` maps back
    /// to their surface string, matching the LR-table keys exactly.
    public func tokenize(_ source: String) -> [Token] {
        let (symbols, keywords) = grammarVocabulary()
        let tokenizer = InputTokenizer(
            source,
            terminalSymbols: symbols,
            reservedWords:   keywords
        )
        var tokens = tokenizer.tokenize()

        // Ensure there is always exactly one EOF sentinel at the end.
        // The tokenizer may produce a .symbol("¶") or .eof; normalise to .eof.
        tokens = tokens.filter {
            if case .symbol("¶") = $0.type { return false }
            return true
        }
        // Append a proper .eof token so the parse loop has a clean sentinel.
        let endIdx = source.endIndex
        tokens.append(Token(type: .eof, range: endIdx ..< endIdx))
        return tokens
    }

    /// Extract the operator/symbol strings and reserved-word strings from the grammar.
    private func grammarVocabulary() -> (symbols: Set<String>, keywords: Set<String>) {
        var symbols:  Set<String> = []
        var keywords: Set<String> = []

        for terminal in grammar.terminals {
            switch terminal {
            case .string(let s) /*where !s.isEmpty */:
                if isSymbolString(s) {
                    symbols.insert(s)
                } else {
                    keywords.insert(s)
                }
            case .regularExpression:
                // Regex terminals are matched at token-classification time,
                // not by the symbol trie — nothing to register here.
                break
            case .characterRange:
                // Character ranges are handled by the tokenizer natively.
                break
            case .meta:
                // ε / $ are internal meta-terminals; never registered as operators.
                break
            }
        }
        return (symbols, keywords)
    }

    /// Returns `true` if any character in `s` is not a word character
    /// (`[A-Za-z0-9_]`), meaning `s` should be treated as an operator symbol.
    private func isSymbolString(_ s: String) -> Bool {
        let wordChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        return s.unicodeScalars.contains { !wordChars.contains($0) }
    }

    // MARK: - Token → Action-table key

    /// Map a `Token` produced by `InputTokenizer` to the string key used in
    /// the LR ACTION table.
    ///
    /// The mapping mirrors `LRAutomaton.terminalKey(_:Terminal)`:
    ///
    ///   Token type           LR key
    ///   ─────────────────    ──────────────────────────────────────────────
    ///   .symbol(s)           s        (e.g. "+", "::=", "(")
    ///   .literal(s)          s        (e.g. "id", "abc"  — quoted in grammar)
    ///   .keyword(s)          s        (e.g. "if", "while" — reserved words)
    ///   .identifier(s)       s        (unquoted names — may match grammar NTs)
    ///   .number(.decimal(n)) "\(n)"   (integer literals)
    ///   .regex(s)            s        (regex literal body)
    ///   .eof                 "$"      (end-of-input sentinel)
    ///   .comment             (skip)   (never reaches the parse loop)
    ///   .invalid             s        (pass through; parser will reject)
    ///
    public func tokenKey(_ token: Token) -> String {
        switch token.type {
        case .symbol(let s):      return s
        case .literal(let s):     return s
        case .keyword(let s):     return s
        case .identifier(let s):  return s
        case .number(let n):      return n.description
        case .regex(let s):       return s
        case .eof:                return "$"
        case .char:               return ""   // irrelevant
        case .comment:            return ""   // filtered before reaching parse loop
        case .invalid(let e):     return "\(e)"
        }
    }

    // MARK: - Core Reduce

    /// Apply one reduce descriptor: pop `prod.rule.count` edges from the GSS,
    /// find the predecessor, GOTO, create/merge a GSS node, record in BSR.
    private func processReduce(
        desc:       Descriptor,
        position:   Int,
        termKey:    String,          // String key for the current look-ahead token
        frontier:   inout Set<GSSNode>,
        reductions: inout [Descriptor],
        processed:  inout Set<Descriptor>
    ) {
        let (topNode, prod, rightExtent) = (desc.node, desc.prod, desc.extent)
        let completedSlot = GrammarSlot(production: prod, dot: prod.rule.count)
        let popCount      = effectivePopCount(prod)

        for (predecessor, leftExtent, _) in gssPathsOfLength(from: topNode, length: popCount) {
            bsr.add(slot: completedSlot, leftExtent: leftExtent, rightExtent: rightExtent)

            guard let gotoState = automaton.gotoState(
                from:         predecessor.state,
                nonTerminal:  prod.goal.name
            ) else { continue }

            let newNode = gss.node(state: gotoState, position: position)
            let symNode = SPPFNode.symbol(
                name:        prod.goal.name,
                leftExtent:  leftExtent,
                rightExtent: rightExtent
            )
            let isNew = gss.addEdge(from: newNode, to: predecessor, label: symNode)

            frontier.insert(newNode)

            if isNew {
                let acts = automaton.actions(state: gotoState, terminal: termKey)
                for act in acts {
                    if case .reduce(let newProd) = act {
                        let d = Descriptor(node: newNode, prod: newProd, extent: position)
                        if processed.insert(d).inserted {
                            reductions.append(d)
                        }
                    }
                }
            }
        }
    }

    /// Number of GSS edges to pop for `prod`.
    /// Epsilon productions (empty rule or sole `.meta(.eps)` symbol) pop 0 edges.
    private func effectivePopCount(_ prod: Production) -> Int {
        if prod.rule.isEmpty { return 0 }
        let allEps = prod.rule.allSatisfy { sym in
            if case .terminal(let t) = sym, case .meta(.eps) = t { return true }
            return false
        }
        return allEps ? 0 : prod.rule.count
    }

    // MARK: - GSS Path Enumeration

    /// Enumerate all paths of `length` edges from `start` in the GSS.
    /// Returns `(predecessorNode, leftExtent, edgeLabels)` for each path.
    /// For length == 0 (epsilon), returns the node itself at its input position.
    private func gssPathsOfLength(
        from   start:  GSSNode,
        length:        Int
    ) -> [(GSSNode, Int, [SPPFNode?])] {
        if length == 0 { return [(start, start.inputPosition, [])] }

        var results: [(GSSNode, Int, [SPPFNode?])] = []
        func dfs(node: GSSNode, remaining: Int, labels: [SPPFNode?]) {
            if remaining == 0 {
                results.append((node, node.inputPosition, labels))
                return
            }
            for edge in node.edges {
                dfs(node: edge.to, remaining: remaining - 1, labels: labels + [edge.label])
            }
        }
        dfs(node: start, remaining: length, labels: [])
        return results
    }

    // MARK: - SyntaxTree construction helpers

    private func buildParseTree(bsr: BSRSet, sppf: SPPFGraph) -> ParseTree {
        let startName = grammar.start.name
        guard let root = sppf.root(startSymbol: startName, inputLength: sppf.allNodes.count) else {
            return .empty
        }
        let enumerator = CSTEnumerator(graph: sppf)
        var visited = Set<SPPFNode>()
        let trees = enumerator.trees(for: root, visited: &visited)
        return trees.first.flatMap { cstNodes in
            cstNodes.first.map { cstToParseTree($0) }
        } ?? .empty
    }

    private func buildAllParseTrees(sppf: SPPFGraph) -> [ParseTree] {
        let startName = grammar.start.name
        guard let root = sppf.root(startSymbol: startName, inputLength: sppf.allNodes.count) else {
            return []
        }
        let enumerator = CSTEnumerator(graph: sppf)
        var visited = Set<SPPFNode>()
        let allTrees = enumerator.trees(for: root, visited: &visited)
        return allTrees.compactMap { cstNodes in
            cstNodes.first.map { cstToParseTree($0) }
        }
    }

    private func cstToParseTree(_ node: CSTNode) -> ParseTree {
        switch node {
        case .terminal:
            return .empty   // leaf: no String.Index range available from token index
        case .nonTerminal(let sym, _, let children, _):
            let nt = NonTerminal(name: sym)
            return .node(nt, children: children.map { cstToParseTree($0) })
        }
    }
}

// MARK: - Concrete Syntax Tree Enumeration

/// A concrete syntax tree node — one unambiguous derivation.
public indirect enum CSTNode {
    case terminal(symbol: String, extent: ClosedRange<Int>)
    case nonTerminal(
        symbol:     String,
        production: Production,
        children:   [CSTNode],
        extent:     ClosedRange<Int>
    )
}

extension CSTNode: CustomStringConvertible {
    public var description: String { prettyPrint(indent: 0) }

    private func prettyPrint(indent: Int) -> String {
        let pad = String(repeating: "  ", count: indent)
        switch self {
        case .terminal(let s, let ext):
            return "\(pad)Terminal[\(s)] @ \(ext.lowerBound)..\(ext.upperBound)"
        case .nonTerminal(let s, _, let children, let ext):
            let childStr = children
                .map { $0.prettyPrint(indent: indent + 1) }
                .joined(separator: "\n")
            return "\(pad)\(s) @ \(ext.lowerBound)..\(ext.upperBound)\n\(childStr)"
        }
    }
}

// MARK: - CSTEnumerator

/// Enumerate all concrete syntax trees from an SPPF graph.
/// Handles ambiguity by exploring all packed-node alternatives.
/// Cycle detection prevents infinite loops on grammars with ε cycles.
public final class CSTEnumerator {
    private let graph: SPPFGraph

    public init(graph: SPPFGraph) { self.graph = graph }

    /// Returns every parse tree rooted at `node` as a flat list of `CSTNode` forests.
    public func trees(for node: SPPFNode,
                      visited: inout Set<SPPFNode>) -> [[CSTNode]] {
        guard visited.insert(node).inserted else { return [] }
        defer { visited.remove(node) }

        switch node {
        case .terminal(let s, let l, let r):
            return [[.terminal(symbol: s, extent: l...r)]]

        case .symbol(let name, let l, let r):
            var allTrees: [[CSTNode]] = []
            for pack in graph.children(of: node) {
                guard case .packed(let slot, _) = pack else { continue }
                for childList in childrenOfPacked(pack, visited: &visited) {
                    let cst = CSTNode.nonTerminal(
                        symbol:     name,
                        production: slot.production,
                        children:   childList,
                        extent:     l...r
                    )
                    allTrees.append([cst])
                }
            }
            return allTrees

        case .intermediate:
            var allChildren: [[CSTNode]] = [[]]
            for pack in graph.children(of: node) {
                allChildren = cartesianAppend(allChildren,
                                              childrenOfPacked(pack, visited: &visited))
            }
            return allChildren

        case .packed:
            return childrenOfPacked(node, visited: &visited)
        }
    }

    private func childrenOfPacked(_ pack: SPPFNode,
                                   visited: inout Set<SPPFNode>) -> [[CSTNode]] {
        var result: [[CSTNode]] = [[]]
        for child in graph.children(of: pack) {
            result = cartesianAppend(result, trees(for: child, visited: &visited))
        }
        return result
    }

    private func cartesianAppend(_ prefixes: [[CSTNode]],
                                  _ suffixes: [[CSTNode]]) -> [[CSTNode]] {
        guard !suffixes.isEmpty else { return prefixes }
        var result: [[CSTNode]] = []
        for pre in prefixes {
            for suf in suffixes { result.append(pre + suf) }
        }
        return result
    }
}
