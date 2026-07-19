//
//  SPPFGraphviz.swift
//  RNGLR-Parser
//
//  Created by Ulf Akerstedt-Inoue on 2026/05/30.
//  Copyright © 2026 hakkabon software. All rights reserved.
//
// Graphviz DOT rendering for the Shared Packed Parse Forest (SPPF).
//

import Foundation
import Grammar
import Parser

// SPPF structure recap
// ─────────────────────
//   Symbol / Intermediate nodes  ──(solid)──▶  Packed nodes
//   Packed nodes                 ──(dashed)──▶  Symbol / Intermediate / Leaf nodes
//
// Node visual conventions follow Scott & Johnstone (2006) and the standard SPPF
// literature, extended with colour to make ambiguity immediately visible:
//
//   Kind           Shape        Fill colour      Border
//   ─────────────  ───────────  ───────────────  ──────────────────────────────────
//   Symbol         ellipse      #dce8f5 (blue)   double when ambiguous (>1 packed child)
//   Leaf           rectangle    #d5e8d4 (green)  single
//   Intermediate   note         #fff2cc (yellow) single
//   Packed         diamond      #f8cecc (pink)   single
//
// Edge conventions:
//   symbol / intermediate  →  packed   : solid black
//   packed                 →  child    : dashed, labelled with pivot index
//
// The `graphviz` property on `SPPFGraph<GrammarSlot>` returns the complete DOT source.
// `SPPFGraph<GrammarSlot>.writeDot(to:)` saves it to a file.
// `SPPFGraph<GrammarSlot>.renderPDF(to:)` renders to PDF via the `dot` command-line tool.

extension SPPFGraph where Label == GrammarSlot {

    /// The complete Graphviz DOT source for this SPPF.
    ///
    /// The generated graph is a `digraph` that faithfully represents the sharing
    /// structure of the SPPF: every node appears exactly once, and edges mirror
    /// `SPPFGraph.getChildren(of:)`.
    ///
    /// Usage
    /// ─────
    /// ```swift
    /// let result = try parser.parse("id + id * id")
    /// if result.isSuccessful, let sppf = result.sppfGraph {
    ///     print(sppf.graphviz)
    ///     // — or —
    ///     try sppf.writeDot(to: URL(fileURLWithPath: "sppf.dot"))
    /// }
    /// ```
    public var graphviz: String {
        SPPFDotRenderer(graph: self).render()
    }

    // MARK: File output

    /// Write the DOT source to `url`, creating or overwriting the file.
    ///
    /// - Parameter url: Destination path (typically with `.dot` extension).
    /// - Throws: `CocoaError` if the file cannot be written.
    public func writeDot(to url: URL) throws {
        try graphviz.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Render the SPPF to a PDF file by invoking the `dot` command-line tool
    /// (`graphviz` package).
    ///
    /// Prerequisites: Graphviz must be installed (`brew install graphviz` on macOS).
    ///
    /// - Parameters:
    ///   - url:       Destination PDF path.
    ///   - dotPath:   Full path to the `dot` binary (default: `/usr/local/bin/dot`
    ///                or `/opt/homebrew/bin/dot` on Apple Silicon).
    /// - Throws: Any error from writing the temporary DOT file or from the
    ///           `dot` process itself.
    public func renderPDF(to url: URL, dotPath: String? = nil) throws {
        // Write DOT to a temp file alongside the output PDF.
        let tmpDot = url.deletingPathExtension().appendingPathExtension("dot")
        try writeDot(to: tmpDot)

        // Resolve the dot binary.
        let dot = dotPath ?? Self.findDotBinary()

        // Invoke: dot -Tpdf <tmpDot> -o <url>
        let process = Process()
        process.executableURL = URL(fileURLWithPath: dot)
        process.arguments     = ["-Tpdf", tmpDot.path, "-o", url.path]

        let errPipe = Pipe()
        process.standardError = errPipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errMsg  = String(data: errData, encoding: .utf8) ?? "(unknown error)"
            throw SPPFGraphvizError.dotProcessFailed(errMsg)
        }
    }

    /// Search common installation prefixes for the `dot` binary.
    private static func findDotBinary() -> String {
        let candidates = [
            "/opt/homebrew/bin/dot",   // Apple Silicon Homebrew
            "/usr/local/bin/dot",      // Intel Homebrew / manual install
            "/usr/bin/dot",            // Linux system package
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
               ?? "/usr/local/bin/dot"
    }
}

// MARK: - Error type

/// Errors that can arise during Graphviz rendering.
public enum SPPFGraphvizError: Error, CustomStringConvertible {
    case dotProcessFailed(String)

    public var description: String {
        switch self {
        case .dotProcessFailed(let msg):
            return "dot process failed: \(msg)"
        }
    }
}

// MARK: - Internal renderer

/// All rendering logic lives here, keeping `SPPFGraph` clean.
private struct SPPFDotRenderer {

    let graph: SPPFGraph<GrammarSlot>

    // MARK: - Stable node ordering

    /// Assign a deterministic integer ID to every node.
    /// Sorting by `description` ensures the same input always produces the same DOT.
    private func buildNodeIndex() -> [SPPFNode<GrammarSlot>: Int] {
        let sorted = graph.getAllNodes()
            .sorted { $0.stableKey < $1.stableKey }
        return Dictionary(uniqueKeysWithValues: sorted.enumerated().map { ($1, $0) })
    }

    // MARK: - Top-level render

    func render() -> String {
        let index  = buildNodeIndex()
        var lines  = [String]()

        lines.append("digraph SPPF {")
        lines.append("    // Graph-level attributes")
        lines.append("    graph [rankdir=TB fontname=\"Helvetica\" fontsize=12 bgcolor=\"#ffffff\"]")
        lines.append("    node  [fontname=\"Helvetica\" fontsize=11]")
        lines.append("    edge  [fontname=\"Helvetica\" fontsize=9]")
        lines.append("")

        // Emit node declarations, grouped by kind for readability.
        lines.append("    // ── Symbol nodes (non-terminals) ─────────────────────────────")
        for node in symbolNodes(index) { lines.append("    \(node)") }
        lines.append("")

        lines.append("    // ── Leaf nodes (terminals) ───────────────────────────────────")
        for node in leafNodes(index) { lines.append("    \(node)") }
        lines.append("")

        lines.append("    // ── Intermediate nodes ───────────────────────────────────────")
        for node in intermediateNodes(index) { lines.append("    \(node)") }
        lines.append("")

        lines.append("    // ── Packed nodes ─────────────────────────────────────────────")
        for node in packedNodes(index) { lines.append("    \(node)") }
        lines.append("")

        // Emit edges.
        lines.append("    // ── Edges ─────────────────────────────────────────────────────")
        for edge in allEdges(index) { lines.append("    \(edge)") }

        lines.append("}")
        return lines.joined(separator: "\n")
    }

    // MARK: - Node declarations by kind

    private func symbolNodes(_ index: [SPPFNode<GrammarSlot>: Int]) -> [String] {
        graph.getAllNodes()
            .filter { if case .symbol = $0 { return true }; return false }
            .sorted { $0.stableKey < $1.stableKey }
            .map { node -> String in
                guard case .symbol(let name, let l, let r) = node,
                      let id = index[node] else { return "" }
                // Double border when ambiguous (> 1 packed child = multiple derivations).
                let isAmbiguous = graph.getChildren(of: node)
                    .filter { if case .packed = $0 { return true }; return false }
                    .count > 1
                let border = isAmbiguous ? "peripheries=2 " : ""
                let label  = dotLabel("\(name)\n[\(l), \(r))")
                return "n\(id) [\(border)shape=ellipse style=filled fillcolor=\"#dce8f5\" label=\(label)]"
            }
            .filter { !$0.isEmpty }
    }

    private func leafNodes(_ index: [SPPFNode<GrammarSlot>: Int]) -> [String] {
        graph.getAllNodes()
            .filter { if case .leaf = $0 { return true }; return false }
            .sorted { $0.stableKey < $1.stableKey }
            .map { node -> String in
                guard case .leaf(let sym, let l, let r) = node,
                      let id = index[node] else { return "" }
                let display = sym.isEmpty ? "ε" : sym
                let label   = dotLabel("\(display)\n[\(l), \(r))")
                return "n\(id) [shape=rectangle style=filled fillcolor=\"#d5e8d4\" label=\(label)]"
            }
            .filter { !$0.isEmpty }
    }

    private func intermediateNodes(_ index: [SPPFNode<GrammarSlot>: Int]) -> [String] {
        graph.getAllNodes()
            .filter { if case .intermediate = $0 { return true }; return false }
            .sorted { $0.stableKey < $1.stableKey }
            .map { node -> String in
                guard case .intermediate(let slot, let l, let r) = node,
                      let id = index[node] else { return "" }
                let label = dotLabel("\(slot.dotLabel)\n[\(l), \(r))")
                return "n\(id) [shape=note style=filled fillcolor=\"#fff2cc\" label=\(label)]"
            }
            .filter { !$0.isEmpty }
    }

    private func packedNodes(_ index: [SPPFNode<GrammarSlot>: Int]) -> [String] {
        graph.getAllNodes()
            .filter { if case .packed = $0 { return true }; return false }
            .sorted { $0.stableKey < $1.stableKey }
            .map { node -> String in
                guard case .packed(let slot, _, _, let pivot) = node,
                      let id = index[node] else { return "" }
                let label = dotLabel("\(slot.dotLabel)\nk=\(pivot)")
                return "n\(id) [shape=diamond style=filled fillcolor=\"#f8cecc\" label=\(label)]"
            }
            .filter { !$0.isEmpty }
    }

    // MARK: - Edge declarations

    private func allEdges(_ index: [SPPFNode<GrammarSlot>: Int]) -> [String] {
        var result = [String]()

        for parent in graph.getAllNodes().sorted(by: { $0.stableKey < $1.stableKey }) {
            guard let parentID = index[parent] else { continue }
            let children = graph.getChildren(of: parent).sorted { $0.stableKey < $1.stableKey }
            guard !children.isEmpty else { continue }

            for child in children {
                guard let childID = index[child] else { continue }

                switch parent {
                case .symbol, .intermediate:
                    // Symbol / intermediate → packed: solid black arrow
                    result.append("n\(parentID) -> n\(childID) [style=solid arrowhead=normal]")

                case .packed(_, _, _, let pivot):
                    // Packed → child: dashed, label shows pivot
                    result.append("n\(parentID) -> n\(childID) [style=dashed label=\"\(pivot)\" arrowhead=open]")

                case .leaf:
                    // Leaf nodes are leaves — should have no children,
                    // but emit a plain edge if they ever do.
                    result.append("n\(parentID) -> n\(childID)")
                }
            }
        }
        return result
    }

    // MARK: - DOT string escaping

    /// Wrap `text` in a DOT label that is safe for inclusion in a double-quoted
    /// string attribute.  Unicode characters (→, •) pass through unchanged since
    /// Graphviz uses UTF-8 by default.
    ///
    /// Characters that must be escaped inside a DOT quoted string:
    ///   `"` → `\"`    `\` → `\\`    `<` → `\<`    `>` → `\>`
    ///
    /// We keep newlines as literal `\n` (the DOT newline escape), NOT as a real
    /// newline character, so multi-line labels render correctly inside the node.
    private func dotLabel(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "<",  with: "\\<")
            .replacingOccurrences(of: ">",  with: "\\>")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }
}

// MARK: - Stable sort key for SPPFNode

extension SPPFNode where Label == GrammarSlot {
    /// A lexicographically-sortable string key for deterministic node ordering.
    /// Using `description` directly works but may be unstable if descriptions
    /// share a prefix, so we prefix with a kind tag.
    fileprivate var stableKey: String {
        switch self {
        case .leaf(let s, let l, let r):            return "0t_\(s)_\(l)_\(r)"
        case .symbol(let n, let l, let r):          return "1s_\(n)_\(l)_\(r)"
        case .intermediate(let sl, let l, let r):   return "2i_\(sl.stableKey)_\(l)_\(r)"
        case .packed(let sl, let l, let r, let k):  return "3p_\(sl.stableKey)_\(k)_\(l)_\(r)"
        }
    }
}

// MARK: - DOT-safe slot label

extension GrammarSlot {
    /// A compact slot label suitable for a DOT node label.
    /// Uses the Unicode bullet (•) and arrow (→), which Graphviz renders correctly.
    fileprivate var dotLabel: String {
        var parts = production.rule.map { sym -> String in
            switch sym {
            case .terminal(let t):
                switch t {
                case .string(let s):              return s.isEmpty ? "ε" : s
                case .meta(let m):                return m.rawValue
                case .regularExpression(let re):  return "/\(re.pattern)/"
                case .characterRange(let r):      return "\(r.lowerBound)..\(r.upperBound)"
                case .stringList(let list):       return list.joined(separator: "|")
                }
            case .nonTerminal(let nt):            return nt.name
            case .metaSymbol(let ms):             return "\(ms)"
            }
        }
        parts.insert("•", at: dot)
        return "\(production.goal.name) \u{2192} \(parts.joined(separator: " "))"
    }

    /// Stable sort key for a GrammarSlot (used by SPPFNode.stableKey).
    fileprivate var stableKey: String {
        // The goal and dot position alone collide for different productions
        // (for example E → T and E → E + T at dot 0), leaving Set iteration
        // to decide their output order. Include the RHS to form a total key.
        let rule = production.rule.map { String(describing: $0) }.joined(separator: "_")
        return "\(production.goal.name)_\(rule)_\(dot)"
    }
}
