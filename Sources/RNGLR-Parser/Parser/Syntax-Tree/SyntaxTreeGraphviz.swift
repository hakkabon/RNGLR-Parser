//
//  SyntaxTreeGraphviz.swift
//  GrammarParsing
//
//  Created by Ulf Akerstedt-Inoue on 2023/09/06.
//  Copyright © 2023 hakkabon software. All rights reserved.
//

import Foundation

extension SyntaxTree {

    public typealias UniqueNode = Unique<Node>
    public typealias UniqueLeaf = Unique<Leaf>

    public var graphviz: String {
        var id = 0

        let uniqueKeyTree = self.mapNodes { node -> UniqueNode in
            let uniqueElement = UniqueNode(node, id)
            id += 1
            return uniqueElement
        }.mapLeafs { leaf -> UniqueLeaf in
            let uniqueLeaf = UniqueLeaf(leaf, id)
            id += 1
            return uniqueLeaf
        }

        func generateDescription(_ tree: SyntaxTree< UniqueNode, UniqueLeaf >) -> String {
            switch tree {
            case .leaf(let leaf):
                let (id, leafElement) = (leaf.id, leaf.node)
                let leafDescription = "\(leafElement)"
                    .literalEscaped
                    .replacingOccurrences(of: "\"", with: "\\\"")
                return "node\(id) [label=\"\(leafDescription)\" shape=box]"
                
            case .node(let key, children: let children):
                let (id, element) = (key.id, key.node)
                let childrenDescriptions = children.map(generateDescription).filter{!$0.isEmpty}.joined(separator: "\n")
                let childrenPointers = children.compactMap{ node -> Int? in
                    if let id = node.root?.id {
                        return id
                    } else if let id = node.leaf?.id {
                        return id
                    } else {
                        return nil
                    }
                }.map{"node\(id) -> node\($0)"}.joined(separator: "\n")
                
                var result = "node\(id) [label=\"\(element)\"]"
                if !childrenPointers.isEmpty {
                    result += "\n\(childrenPointers)"
                }
                if !childrenDescriptions.isEmpty {
                    result += "\n\(childrenDescriptions)"
                }
                
                return result

            case .empty:
                return ""
            }
        }
        
        func allLeafIDs(_ tree: SyntaxTree< UniqueNode, UniqueLeaf >) -> [Int] {
            switch tree {
            case .leaf(let leaf):
                return [leaf.id]
            case .node(_, children: let children):
                return children.flatMap(allLeafIDs)
            case .empty:
                return []
            }
        }
        
        return """
        digraph {
            \(generateDescription(uniqueKeyTree).replacingOccurrences(of: "\n", with: "\n\t"))
        }
        """
    }
}

/// Node with an id that is needed in abscence of Tuples with auto hash code,
/// which still is missing in the latest version of Swift, as of writing 5.9.
public struct Unique<Node: Equatable> {
    public let node: Node
    public let id: Int

    public init(_ node: Node, _ id: Int) {
        self.id = id
        self.node = node
    }
}

extension Unique: Equatable {

    public static func == (lhs: Unique, rhs: Unique) -> Bool {
        return lhs.node == rhs.node && lhs.id == rhs.id
    }
}

extension Unique: Hashable {
    
    public func hash(into hasher: inout Hasher) {
        // hasher.combine(node) Node does not conform to Hashable - well, not needed, use the id only.
        hasher.combine(id)
    }
}

extension Unique: Comparable {

    public static func < (lhs: Unique, rhs: Unique) -> Bool {
        return lhs.id != rhs.id ? lhs.id < rhs.id : lhs.id < rhs.id
    }
}
