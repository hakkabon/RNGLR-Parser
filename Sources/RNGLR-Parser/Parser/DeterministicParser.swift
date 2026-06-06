//
//  DeterministicParser.swift
//  RNGLR-Parser
//
//  Created by Ulf Akerstedt-Inoue on 2023/08/11.
//  Copyright © 2023 hakkabon software. All rights reserved.
//

import Foundation
import Grammar

/// A syntax tree with non-terminal keys and string range leafs.
public typealias ParseTree = SyntaxTree<NonTerminal, Range<String.Index>>

/// A parser checks if an input string is in a language, and if so,
/// generates a syntax tree explaining how the input string was derived
/// from the grammar of the language.
public protocol Parser {

    /// Creates a syntax tree explaining how the input string was derived
    /// from the grammar.
    ///
    /// - Parameter string: Input word for which a parse tree should be generated.
    /// - Returns: A syntax tree rooted at the grammar's start symbol.
    /// - Throws: `ParseError` if the string is not in the language.
    func syntaxTree(for string: String) throws -> ParseTree
}

public extension Parser {
    /// Returns `true` if the recognised language contains `string`.
    func recognizes(_ string: String) -> Bool {
        return (try? self.syntaxTree(for: string)) != nil
    }
}
