//
//  SyntaxTreePrinter.swift
//  GrammarParsing
//
//  Created by Ulf Akerstedt-Inoue on 2023/09/06.
//  Copyright © 2023 hakkabon software. All rights reserved.
//

import Foundation
import Grammar
import TerminalColors

struct SyntaxTreePrinter {
    // ANSI Terminal Colors
    private static let branchColor = TerminalColor(fg: .blue)
    private static let leafColor = TerminalColor(fg: .green)
    private static let nodeColor = TerminalColor(.bold)
    private static let emptyColor = TerminalColor(fg: .gray, .dim)
    
    static func print<N, L>(_ tree: SyntaxTree<N, L>, indentation: String = "", isLast: Bool = true) -> String {
        switch tree {
        case .empty:
            return "\(indentation)\("<Empty>", color: emptyColor)\n"
            
        case .leaf(let value):
            return "\(indentation)\("\(value)", color: leafColor)\n"
            
        case .node(let value, let children):
            var result = "\(indentation)\("\(value)", color: nodeColor)\n"
            
            for (index, child) in children.enumerated() {
                let isLastChild = index == children.count - 1
                result += printChildren(child, prefix: indentation, isLast: isLastChild)
            }
            return result
        }
    }

    /// Generates a visual tree structure string from the SyntaxTree
    static func printChildren<N, L>(_ tree: SyntaxTree<N, L>, prefix: String = "", isLast: Bool = true) -> String {
        
        let marker = isLast ? "└── " : "├── "
        let currentPrefix = "\(prefix, color: branchColor)\(marker, color: branchColor)"
        
        switch tree {
        case .empty:
            return "\(currentPrefix)\("<Empty>", color: emptyColor)\n"
            
        case .leaf(let value):
            return "\(currentPrefix)\("\(value)", color: leafColor)\n"
            
        case .node(let value, let children):
            var result = "\(currentPrefix)\("\(value)", color: nodeColor)\n"
            
            // Prepare prefix for children
            // If this is the last node, the vertical bar "│" stops here.
            // Otherwise, it continues down to connect to the next sibling.
            let childPrefix = prefix + (isLast ? "    " : "\("│   ", color: branchColor)")
            
            for (index, child) in children.enumerated() {
                let isLastChild = index == children.count - 1
                result += printChildren(child, prefix: childPrefix, isLast: isLastChild)
            }
            return result
        }
    }
}
