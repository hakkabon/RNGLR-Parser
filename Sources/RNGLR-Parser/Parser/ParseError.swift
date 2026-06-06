//
//  ParseError.swift
//  CYK-Parser
//
//  Created by Ulf Akerstedt-Inoue on 2026/05/25.
//

import Foundation
import Grammar

enum ParseError: Error, CustomStringConvertible {
    case generationFailed(String)
    case unexpectedToken(token: String, state: Int)
    case unexpectedEOF(state: Int)
    case internalError(String)
    
    var description: String {
        switch self {
        case .generationFailed(let msg): return "Parser Generator Failed: \(msg)"
        case .unexpectedToken(let t, let s): return "Syntax Error: Unexpected token '\(t)' at state \(s)."
        case .unexpectedEOF(let s): return "Syntax Error: Unexpected End of File at state \(s)."
        case .internalError(let msg): return "Internal Parser Error: \(msg)"
        }
    }
}
