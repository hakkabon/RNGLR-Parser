//
//  Definitions.swift
//  Grammar-Tool
//
//  Created by Ulf Akerstedt-Inoue on 2026/01/18.
//  Copyright © 2026 hakkabon software. All rights reserved.
//

import Foundation
import ArgumentParser

/// Notation is either one of { bnf | ebnf | gen | wsn } or a
/// custom format using `custom(String)`.
enum Notation: ExpressibleByArgument {
    case bnf
    case ebnf
    case gen
    case wsn
    case custom(String)
    
    init(argument: String) {
        if argument == "bnf" {
            self = .bnf
        } else if argument == "ebnf" {
            self = .ebnf
        } else if argument == "gen" {
            self = .gen
        } else if argument == "wsn" {
            self = .wsn
        } else  {
            self = .custom(argument)
        }
    }
}

/// Parsing method to be applied to input supplied by user.
enum Method: String, ExpressibleByArgument, CaseIterable {
    case cyk, earley, glr
}

/// Parsing method to be applied to input supplied by user.
enum Analysis: String, ExpressibleByArgument, CaseIterable {
    case tree, graph, sppf
}

/// Source input is either a command line argument or a file containing the input to be parsed.
/// Use `Source` together with `transform: Source.init` for its argument.
enum Source {
    case arg(String)
    case url(URL)
    
    init(_ string: String) {
        if string.isEmpty {
            self = .arg(string)
        } else if FileManager.default.fileExists(atPath: string) {
            self = .url(URL(fileURLWithPath: string))
        } else {
            self = .arg(string)
        }
    }
}

struct DisplayOptions: OptionSet {
    let rawValue: Int

    static let syntax = DisplayOptions(rawValue: 1 << 0)
    static let pretty = DisplayOptions(rawValue: 1 << 1)
    static let railroad = DisplayOptions(rawValue: 1 << 2)
    
    static let all: DisplayOptions = [.syntax, .pretty, .railroad]

    // This is required to allow ArgumentParser to initialize the OptionSet
    public init(rawValue: Int) {
        self.rawValue = rawValue
    }
}

extension DisplayOptions: ExpressibleByArgument {
    
    public init(argument: String) {
        let parts = argument.split(separator: ",").map { $0.lowercased() }
        var result: DisplayOptions = []
        
        for part in parts {
            switch part.lowercased() {
            case "syntax": result.insert(.syntax)
            case "pretty": result.insert(.pretty)
            case "railroad": result.insert(.railroad)
            default:
                break
            }
        }
        self = result
    }
}

extension DisplayOptions: ExpressibleByArrayLiteral {

    public init(arrayLiteral elements: DisplayOptions...) {
        self.rawValue = elements.reduce(0) { $0 | $1.rawValue }
    }
}

extension DisplayOptions: CustomStringConvertible {

    public var description: String {
        let options: [(Self, String)] = [
            (.syntax, "syntax"),
            (.pretty, "pretty"),
            (.railroad, "railroad")
        ]
        let activeOptions = options.compactMap { (option, name) in
            self.contains(option) ? name : nil
        }
        return "[" + activeOptions.joined(separator: ", ") + "]"
    }
}

enum SortOption: String, ExpressibleByArgument, CaseIterable {
    case ascend, decend
}
