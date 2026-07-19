//
//  Parse.swift
//  Grammar-Tool
//
//  Created by Ulf Akerstedt-Inoue on 2024/03/16.
//  Copyright © 2024 hakkabon software. All rights reserved.
//

import Foundation
import ArgumentParser
import Grammar
import RNGLR_Parser
import Parser
import ShellOut

///  Parses any input sentence based on its given grammar specification.
///  It renders the result as a syntax tree, a DOT parse-tree diagram,
///  or the full SPPF graph in DOT format.

extension GrammarTool {

    struct Parse: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Generate parse tree of input applied to given grammar.")

        @OptionGroup var options: Options

        @Option(name: [.short, .long], help: "Input to be parsed using the grammar.", transform: Source.init)
        var input: Source = Source("")

        @Option(name: [.long, .short], help: "Use { tree | graph | sppf } to display result of parse.")
        var analysis: Analysis = .tree

        mutating func run() throws {

            let grammar: Grammar = switch Notation(argument: options.grammar.pathExtension) {
            case .bnf:    try Grammar(bnf:  try String(contentsOf: options.grammar), start: options.start)
            case .ebnf:   try Grammar(ebnf: try String(contentsOf: options.grammar), start: options.start)
            case .gen:    try Grammar(gen:  try String(contentsOf: options.grammar))
            case .wsn:    try Grammar(wsn:  try String(contentsOf: options.grammar), start: options.start)
            case .custom: try Grammar(bnf:  try String(contentsOf: options.grammar), start: options.start)
            }

            let parser = RNGLRParser(grammar: grammar)

            switch input {
            case .arg(let inputString):
                guard !inputString.isEmpty else { return }
                try runAnalysis(analysis, parser: parser, input: inputString, grammar: grammar)

            case .url(let url):
                let content = try String(contentsOf: url)
                try runAnalysis(analysis, parser: parser, input: content, grammar: grammar)
            }
        }

        private func runAnalysis(_ analysis: Analysis, parser: RNGLRParser, input: String, grammar: Grammar) throws {

            switch analysis {

            case .tree:
                let tree = try parser.syntaxTree(for: input).mapLeafs { String(input[$0]) }
                print(tree)

            case .trees:
                let trees = try parser.allSyntaxTrees(for: input)
                for tree in trees {
                    let parsetree = tree.mapLeafs{ String(input[$0]) }
                    print("\(parsetree)")
                }

            case .graph:
                let tree = try parser.syntaxTree(for: input).mapLeafs { String(input[$0]) }
                let dotSource = tree.graphviz
                try shellOut(to: ["echo '\(dotSource)' | dot -Tpdf > parse-tree.pdf", "open parse-tree.pdf"])

            case .sppf:
                let result = try parser.parse(input)

                if !result.isSuccessful {
                    print("Parse FAILED: input not recognized by the grammar.")
                } else if let sppf = result.sppfGraph {
                    let tokenCount = parser.tokenize(input)
                        .filter { $0.type != .eof }
                        .count

                    print("Parse succeeded.")
                    print("  Ambiguous : \(result.hasAmbiguity)")
                    print("  BSR triples: \(result.bsr.count)")

                    if sppf.root(startSymbol: grammar.start.name, inputLength: tokenCount) != nil {
                        let ranges = parser.tokenize(input)
                            .filter { $0.type != .eof }
                            .map(\.range)
                        let trees = sppf.buildAllParseTrees(startSymbol: grammar.start.name, ranges: ranges, string: input)
                        print("  Parse trees: \(trees.count)")
                    }

                    // Write DOT and render PDF.
                    let dotURL = URL(fileURLWithPath: "sppf.dot")
                    let pdfURL = URL(fileURLWithPath: "sppf.pdf")
                    try sppf.writeDot(to: dotURL)
                    print("  DOT file: \(dotURL.path)")

                    // Try to render, but don't hard-fail if dot isn't installed.
                    do {
                        try sppf.renderPDF(to: pdfURL)
                        print("  PDF file: \(pdfURL.path)")
                        try shellOut(to: "open \(pdfURL.path)")
                    } catch SPPFGraphvizError.dotProcessFailed(let msg) {
                        print("  Warning: dot rendering failed — \(msg)")
                        print("  Run manually:  dot -Tpdf sppf.dot -o sppf.pdf")
                    } catch {
                        print("  Warning: could not open PDF — \(error)")
                    }
                }
            }
        }
    }
}
