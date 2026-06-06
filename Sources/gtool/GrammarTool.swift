//
//  GrammarTool.swift
//  Grammar-Parser
//
//  Created by Ulf Akerstedt-Inoue on 2024/03/16.
//  Copyright © 2024 hakkabon software. All rights reserved.
//

import Foundation
import ArgumentParser


@main
struct GrammarTool: ParsableCommand {
    
    static let configuration = CommandConfiguration(
        commandName: "gtool",
        abstract: "A utility for analyzing BNF grammars.",
        version: "0.0.1",
        subcommands: [
            Parse.self
        ],
        defaultSubcommand: Parse.self
    )
}

struct Options: ParsableArguments {

    @Argument(help: "Grammar file name.", transform: URL.init(fileURLWithPath:))
    var grammar: URL
    
    @Option(name: [.short, .long], help: "Start rule of grammmar, except for '.gen' grammars which contain a start declaration.")
    var start: String = ""

    mutating func validate() throws {
        // Verify the grammar file actually exists.
        guard FileManager.default.fileExists(atPath: grammar.path) else {
            throw ValidationError("Grammar file does not exist at \(grammar.path)")
        }
        
        // Verify that the grammar has a start rule specified when necessary.
        switch Notation(argument: grammar.pathExtension) {
        case .bnf, .ebnf, .wsn, .custom:
            if start.isEmpty {
                throw ValidationError("Start rule '\(start)' must be non-empty")
            }
        case .gen:  // start rule is provided inside the grammar file.
            break
        }
    }
}
