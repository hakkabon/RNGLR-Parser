//
//  GeneralizedParser.swift
//  RNGLR-Parser
//
//  Created by Ulf Akerstedt-Inoue on 2023/08/11.
//  Copyright © 2023 hakkabon software. All rights reserved.
//

import Foundation
import Grammar

/// The outcome of a parse attempt.
public enum ParseResult {
    /// Parse succeeded; the BSR set and SPPF graph are available.
    case success(bsr: BSRSet, sppf: SPPFGraph)

    /// Parse failed; `position` is the index of the token at which the
    /// parse stalled and `message` describes the cause.
    case failure(position: Int, message: String)
}

extension ParseResult {
    /// `true` when the SPPF contains at least one symbol node with more than
    /// one packed-node child (= at least one ambiguous derivation).
    public var hasAmbiguity: Bool {
        guard case .success(_, let sppf) = self else { return false }
        return sppf.allNodes.contains { node in
            sppf.children(of: node).filter {
                if case .packed = $0 { return true }
                return false
            }.count > 1
        }
    }
}

/// A parser that can parse ambiguous context-free grammars and retrieve
/// every possible syntax tree via the BSR set / SPPF graph.
public protocol GeneralizedParser {

    /// Run the parse and return the full derivation record.
    ///
    /// - Parameter string: Raw source text to parse.
    /// - Returns: `.success(bsr:sppf:)` when the source is in the language,
    ///            `.failure(position:message:)` otherwise.
    /// - Throws: `ParseError` for tokenizer-level failures (unrecognised
    ///           characters that cannot be classified as any known terminal).
    func parse(_ string: String) throws -> ParseResult
}
