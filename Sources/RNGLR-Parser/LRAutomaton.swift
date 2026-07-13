//
//  LRAutomaton.swift
//  RNGLRParser
//
//  Created by Ulf Akerstedt-Inoue on 2026/05/22.
//  Ported to use the Grammar package (hakkabon/Grammar).
//
// Constructs the canonical LR(0) automaton and the RNGLR ACTION/GOTO tables.
//
// RNGLR uses the standard LR(1) table but adds one critical extension:
//   • On a reduce action for a production with a nullable SUFFIX,
//     all intermediate dot positions (the "right-nulled" positions) are
//     also entered as reduce entries. This lets the GSS pop the correct
//     number of stack frames without re-parsing nullable tails.
//
// SLR(1) lookaheads are used here (sufficient for the RNGLR correctness proof).
// Genuine conflicts are flagged rather than silently resolved.

import Foundation
import Grammar

// MARK: - Action

/// The four possible entries in an ACTION table cell.
public enum LRAction: Hashable, CustomStringConvertible {
    case shift(Int)              // shift and go to state N
    case reduce(Production)      // reduce by production P
    case accept                  // accept the input
    case error                   // no valid action

    public var description: String {
        switch self {
        case .shift(let s):   return "s\(s)"
        case .reduce(let p):  return "r[\(p)]"
        case .accept:         return "acc"
        case .error:          return "err"
        }
    }
}

// MARK: - Item Set (LR(0) state)

struct ItemSet: Hashable {
    let id: Int
    let kernel: Set<GrammarSlot>   // items that define this state (before closure)
    var closure: Set<GrammarSlot>  // full closure

    static func == (lhs: ItemSet, rhs: ItemSet) -> Bool { lhs.kernel == rhs.kernel }
    func hash(into hasher: inout Hasher) { hasher.combine(kernel) }
}

// MARK: - LR Automaton

/// Builds the LR(0) automaton and SLR(1)-based RNGLR parse tables.
public final class LRAutomaton {

    // MARK: Public outputs

    /// Total number of states.
    public private(set) var stateCount: Int = 0

    /// ACTION[state][terminal] → set of actions  (GLR: sets, not single values)
    /// Terminal keys: actual terminal strings + "$" for end-of-input.
    public private(set) var action: [[String: Set<LRAction>]] = []

    /// GOTO[state][nonTerminal] → next state  (-1 == error)
    public private(set) var goto: [[String: Int]] = []

    /// Every grammar terminal that isn't `.string` — i.e. a `.regularExpression`,
    /// `.characterRange`, or `.stringList` terminal, ordinarily one resolved
    /// from a `lexical { }` declaration — paired with the same `terminalKey(_:)`
    /// string its ACTION-table entries are actually stored under.
    ///
    /// `terminalKey(_:)` on a pattern terminal returns the *pattern's own*
    /// text (a regex's source, a range's bounds, ...), not anything a
    /// concrete token could ever equal — so `action[state][someToken]` can
    /// never find these entries by a direct string lookup, regardless of
    /// whether the token actually satisfies the pattern. `resolveActionKey(forToken:)`
    /// is the bridge: it's what actually calls `Terminal.matches(_:)`.
    ///
    /// Sorted by key for deterministic iteration (`grammar.terminals` is a
    /// `Set`, unordered) — this does not by itself resolve genuine ambiguity
    /// between two pattern terminals that could both match the same token
    /// (e.g. a `Digit` range and a `NUM` regex both accepting a single "5");
    /// disambiguating that is a lexer-classification concern (see the Lexer
    /// package's priority-tagged token classes), not something this fallback
    /// can decide on its own.
    private var patternTerminals: [(terminal: Terminal, key: String)] = []

    private let grammar: Grammar
    private var states: [ItemSet] = []
    private var kernelToState: [Set<GrammarSlot>: Int] = [:]

    // SLR(1) FOLLOW sets (terminal strings + "$")
    private var follow: [NonTerminal: Set<String>] = [:]

    // Nullable set (derived from grammar.nullableNonTerminals)
    private var nullable: Set<NonTerminal> { grammar.nullableNonTerminals }

    public init(grammar: Grammar) {
        self.grammar = grammar
        self.patternTerminals = grammar.terminals
            .compactMap { terminal -> (Terminal, String)? in
                switch terminal {
                case .string, .meta:
                    return nil
                case .characterRange, .stringList, .regularExpression:
                    return (terminal, LRAutomaton.terminalKey(terminal))
                }
            }
            .sorted { $0.1 < $1.1 }
    }

    // MARK: - Build

    /// Build the LR(0) automaton and fill the parse tables.
    public func build() {
        computeFollow()
        buildAutomaton()
        buildTables()
    }

    // MARK: - FOLLOW sets (SLR(1))

    private func computeFollow() {
        for p in grammar.productions {
            follow[p.goal] = []
        }
        // Start symbol gets "$" in its FOLLOW set
        follow[grammar.start, default: []].insert("$")

        var changed = true
        while changed {
            changed = false
            for p in grammar.productions {
                for (i, sym) in p.rule.enumerated() {
                    guard case .nonTerminal(let nt) = sym else { continue }

                    // Everything in FIRST(β) \ {ε} goes into FOLLOW(nt)
                    let beta = Array(p.rule[(i + 1)...])
                    let firstBeta = firstOfSequence(beta)
                    let terminals = firstBeta.filter { $0 != "ε" }
                    let before = follow[nt]?.count ?? 0
                    follow[nt, default: []].formUnion(terminals)

                    // If ε ∈ FIRST(β), FOLLOW(lhs) ⊆ FOLLOW(nt)
                    if firstBeta.contains("ε") {
                        follow[nt, default: []].formUnion(follow[p.goal] ?? [])
                    }
                    if (follow[nt]?.count ?? 0) != before { changed = true }
                }
            }
        }
    }

    /// FIRST set of a sequence of symbols; result uses terminal strings + "ε".
    private func firstOfSequence(_ symbols: [Symbol]) -> Set<String> {
        var result: Set<String> = []
        for sym in symbols {
            let f = firstOfSymbol(sym)
            result.formUnion(f.filter { $0 != "ε" })
            if !f.contains("ε") { return result }
        }
        result.insert("ε")
        return result
    }

    private func firstOfSymbol(_ sym: Symbol) -> Set<String> {
        switch sym {
        case .terminal(let t):
            if case .meta(.eps) = t { return ["ε"] }
            if case .meta(.empty) = t { return ["ε"] }
            return [terminalKey(t)]
        case .nonTerminal(let nt):
            return firstOfNT(nt)
        case .metaSymbol:
            return ["ε"]
        }
    }

    private var firstCache: [NonTerminal: Set<String>] = [:]
    private func firstOfNT(_ nt: NonTerminal) -> Set<String> {
        if let cached = firstCache[nt] { return cached }
        firstCache[nt] = []  // break cycles
        var result: Set<String> = []
        for p in productions(for: nt) {
            if isEpsilonProduction(p) { result.insert("ε"); continue }
            result.formUnion(firstOfSequence(p.rule))
        }
        firstCache[nt] = result
        return result
    }

    // MARK: - LR(0) Automaton Construction

    private func buildAutomaton() {
        // Augmented start: __start__ → S
        let augNT = NonTerminal(name: "__start__")
        let augProd = Production(goal: augNT, rule: [.nonTerminal(grammar.start)])
        let initSlot  = GrammarSlot(production: augProd, dot: 0)
        _ = makeState(kernel: [initSlot])  // state 0

        var worklist = [0]
        while let sid = worklist.popLast() {
            let state = states[sid]
            var bySymbol: [Symbol: Set<GrammarSlot>] = [:]
            for item in state.closure {
                if let sym = item.symbolAfterDot {
                    bySymbol[sym, default: []].insert(item.advanced())
                }
            }
            for (_, kernelItems) in bySymbol {
                let newState = makeState(kernel: kernelItems)
                if newState.id == states.count - 1 {
                    worklist.append(newState.id)
                }
            }
        }
        stateCount = states.count
    }

    @discardableResult
    private func makeState(kernel: Set<GrammarSlot>) -> ItemSet {
        if let existing = kernelToState[kernel] { return states[existing] }
        let id = states.count
        var s = ItemSet(id: id, kernel: kernel, closure: [])
        s.closure = closure(of: kernel)
        states.append(s)
        kernelToState[kernel] = id
        return s
    }

    private func closure(of items: Set<GrammarSlot>) -> Set<GrammarSlot> {
        var result = items
        var worklist = Array(items)
        while let item = worklist.popLast() {
            guard let sym = item.symbolAfterDot,
                  case .nonTerminal(let nt) = sym else { continue }
            for p in productions(for: nt) {
                let slot = GrammarSlot(production: p, dot: 0)
                if result.insert(slot).inserted {
                    worklist.append(slot)
                }
            }
        }
        return result
    }

    // MARK: - Table Construction (SLR(1) + RNGLR right-null extension)

    private func buildTables() {
        action = Array(repeating: [:], count: stateCount)
        goto   = Array(repeating: [:], count: stateCount)

        for state in states {
            // Transitions → shifts and GOTOs
            var bySymbol: [Symbol: Set<GrammarSlot>] = [:]
            for item in state.closure {
                if let sym = item.symbolAfterDot {
                    bySymbol[sym, default: []].insert(item.advanced())
                }
            }
            for (sym, kernelItems) in bySymbol {
                guard let targetID = kernelToState[kernelItems] else { continue }
                switch sym {
                case .terminal(let t):
                    let key = terminalKey(t)
                    if key != "ε" {
                        action[state.id][key, default: []].insert(.shift(targetID))
                    }
                case .nonTerminal(let nt):
                    goto[state.id][nt.name] = targetID
                case .metaSymbol:
                    break
                }
            }

            // Completed items → reduces (SLR lookahead)
            for item in state.closure where item.isCompleted {
                let prod = item.production
                if prod.goal.name == "__start__" {
                    action[state.id]["$", default: []].insert(.accept)
                    continue
                }
                let lookaheads = follow[prod.goal] ?? []
                for la in lookaheads {
                    action[state.id][la, default: []].insert(.reduce(prod))
                }
            }

            // RNGLR right-null extension:
            // For every item  A → α • X β  where β is entirely nullable,
            // also add reduce(A → α X β) on FOLLOW(A) from the current state.
            for item in state.closure where !item.isCompleted {
                let prod = item.production
                let suffix = Array(prod.rule[item.dot...])
                guard !suffix.isEmpty, isNullableSuffix(suffix) else { continue }
                let lookaheads = follow[prod.goal] ?? []
                for la in lookaheads {
                    action[state.id][la, default: []].insert(.reduce(prod))
                }
            }
        }
    }

    /// Returns true iff every symbol in `suffix` can derive ε.
    private func isNullableSuffix(_ suffix: [Symbol]) -> Bool {
        return suffix.allSatisfy { sym in
            switch sym {
            case .terminal(let t):
                if case .meta(.eps) = t   { return true }
                if case .meta(.empty) = t { return true }
                return false
            case .nonTerminal(let nt):
                return nullable.contains(nt)
            case .metaSymbol:
                return true
            }
        }
    }

    // MARK: - Accessors

    /// Returns the set of valid actions for (state, terminal).
    public func actions(state: Int, terminal: String) -> Set<LRAction> {
        action[state][terminal] ?? []
    }

    /// Resolves a token's own literal text (`tokenKey(_:)` on the `RNGLRParser`
    /// side) to the key its matching ACTION-table entry is actually stored
    /// under, for use with `actions(state:terminal:)`.
    ///
    /// For an ordinary `.string` grammar terminal (an operator, keyword, or
    /// punctuation) `terminalKey(_:)` already equals the token's own text, so
    /// this returns `token` unchanged and the fast, direct dictionary lookup
    /// in `actions(state:terminal:)` still does all the work.
    ///
    /// For a `.regularExpression`/`.characterRange`/`.stringList` grammar
    /// terminal (e.g. one resolved from a `lexical { }` declaration, such as
    /// `NUM : /[0-9]+/`), `terminalKey(_:)` instead returns the *pattern's*
    /// own text (`"[0-9]+"`), which a concrete token's literal text
    /// (`"42"`) can never equal by construction — a plain dictionary lookup
    /// keyed by the token's text would silently miss those entries no matter
    /// how the token was actually classified upstream. This checks `token`
    /// against every such pattern terminal with `Terminal.matches(_:)` (the
    /// asymmetric pattern-vs-lexeme check — see the Grammar package) and, on
    /// a match, returns *that pattern's* key instead, since that's what its
    /// entries were filed under.
    ///
    /// Note: if more than one pattern terminal could match the same token
    /// (e.g. both a character-range terminal and a broader regex terminal
    /// accept a single digit), the first match in `patternTerminals`'
    /// (deterministic, sorted-by-key) order wins. That's a coarse tie-break,
    /// not a real disambiguation — a grammar that depends on picking the
    /// *correct* one of several overlapping lexical terminals needs that
    /// decided upstream, by the lexer's own classification/priority rules,
    /// not here.
    public func resolveActionKey(forToken token: String) -> String {
        for (terminal, key) in patternTerminals where terminal.matches(.string(token)) {
            return key
        }
        return token
    }

    /// Returns the goto state after reducing to `nonTerminal` from `state`.
    public func gotoState(from state: Int, nonTerminal: String) -> Int? {
        goto[state][nonTerminal]
    }

    // MARK: - Grammar helpers

    /// All productions whose LHS is `nt`.
    private func productions(for nt: NonTerminal) -> [Production] {
        grammar.productions.filter { $0.goal == nt }
    }

    /// Returns true if the production derives only ε.
    private func isEpsilonProduction(_ p: Production) -> Bool {
        if p.rule.isEmpty { return true }
        return p.rule.allSatisfy { sym in
            switch sym {
            case .terminal(let t):
                if case .meta(.eps) = t   { return true }
                if case .meta(.empty) = t { return true }
                return false
            default: return false
            }
        }
    }

    /// Convert a `Terminal` value to the string key used in the action table.
    private static func terminalKey(_ terminal: Terminal) -> String {
        switch terminal {
        case .string(let s):             return s
        case .characterRange(let r):     return "\(r.lowerBound)...\(r.upperBound)"
        case .stringList(let list):      return list.joined(separator: "|")
        case .regularExpression(let re): return re.pattern
        case .meta(let m):
            switch m {
            case .eps, .empty, .lambda:  return "ε"
            case .eof, .eop:             return "$"
            }
        }
    }
}
