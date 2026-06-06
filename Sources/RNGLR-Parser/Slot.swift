//
//  Slot.swift
//  RNGLRParser
//
//  Created by Ulf Akerstedt-Inoue on 2026/05/22.
//  Ported to use the Grammar package (hakkabon/Grammar) — NonTerminal / Terminal / Production types.
//

import Foundation
import Grammar

/// A *grammar slot* — a production with a dot position.
/// `A → α • β`  where `dot` is the index into `production.rule` before which the dot sits.
///
///   dot == 0              →  `A → • α β`   (initial item)
///   dot == rule.count     →  `A → α β •`   (completed item)
public struct GrammarSlot {
    public let production: Production
    public let dot: Int

    public init(production: Production, dot: Int) {
        self.production = production
        self.dot = dot
    }

    /// True when the dot is past the last symbol (item is completed).
    public var isCompleted: Bool { dot == production.rule.count }

    /// The symbol immediately after the dot, if any.
    public var symbolAfterDot: Symbol? {
        guard dot < production.rule.count else { return nil }
        return production.rule[dot]
    }

    /// Return a new slot with the dot advanced by one position.
    public func advanced() -> GrammarSlot {
        precondition(!isCompleted, "Cannot advance a completed slot")
        return GrammarSlot(production: production, dot: dot + 1)
    }
}

// MARK: - Equatable / Hashable

extension GrammarSlot: Equatable {
    public static func == (lhs: GrammarSlot, rhs: GrammarSlot) -> Bool {
        lhs.production == rhs.production && lhs.dot == rhs.dot
    }
}

extension GrammarSlot: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(production)
        hasher.combine(dot)
    }
}

// MARK: - CustomStringConvertible

extension GrammarSlot: CustomStringConvertible {
    public var description: String {
        var parts = production.rule.map(\.description)
        parts.insert("•", at: dot)
        return "\(production.goal.name) → \(parts.joined(separator: " "))"
    }
}
