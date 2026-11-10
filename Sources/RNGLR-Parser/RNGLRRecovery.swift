import Foundation
import Grammar
import Parser

/// Recovery output for RNGLR. The repaired source is explicit because this
/// engine's public entry point owns tokenization from source text.
public struct RNGLRRecoveryResult {
    public let status: ParseStatus
    public let parseResult: ParseResult<GrammarSlot>?
    public let repairedSource: String?
    public let diagnostics: [ParseDiagnostic]
    public let recoveryEdits: [RecoveryEdit]
    public let exploredStates: Int
    public let reachedSearchLimit: Bool
    public let quality: GeneralizedRepairQuality
}

public extension RNGLRParser {
    /// Runs the same bounded minimum-edit policy used by Earley, retrying the
    /// native RNGLR parser so a successful repair retains a genuine GSS-derived
    /// BSR and SPPF.
    func parseRecovering(
        _ source: String,
        insertionCandidates: [String]? = nil,
        policy: GeneralizedRecoveryPolicy = .init(),
        searchSession: GeneralizedRecoverySearchSession<String>? = nil
    ) throws -> RNGLRRecoveryResult {
        let accepted = try parse(source)
        if accepted.isSuccessful {
            return .init(
                status: .accepted, parseResult: accepted, repairedSource: source,
                diagnostics: [], recoveryEdits: [], exploredStates: 1,
                reachedSearchLimit: false,
                quality: .init(
                    editCost: 0, insertionCount: 0, deletionCount: 0,
                    exploredStates: 1, reachedSearchLimit: false))
        }

        let sourceTokens = tokenize(source).filter {
            if case .eof = $0.type { return false }
            return true
        }
        let input = sourceTokens.map(tokenKey)
        let defaults = grammar.terminals.compactMap { terminal -> String? in
            guard case .string(let value) = terminal, !value.isEmpty else { return nil }
            return value
        }.sorted()
        let candidates = insertionCandidates ?? defaults
        let recognize: ([String]) -> Bool = { elements in
            (try? self.parse(elements.joined(separator: " ")).isSuccessful) == true
        }
        let repair = searchSession.map {
            $0.recover(input, insertionCandidates: candidates,
                       policy: policy, recognizes: recognize)
        } ?? GeneralizedRecoverySearch<String>().recover(
            input, insertionCandidates: candidates, policy: policy,
            recognizes: recognize)

        guard let repairedInput = repair.repairedInput else {
            return .init(
                status: .rejected, parseResult: nil, repairedSource: nil,
                diagnostics: [ParseDiagnostic(
                    reason: .noViableAlternative,
                    message: repair.reachedSearchLimit
                        ? "Generalized recovery exhausted its search budget."
                        : "No repair was found within the configured edit cost.",
                    tokenIndex: input.count,
                    source: source)],
                recoveryEdits: [], exploredStates: repair.exploredStates,
                reachedSearchLimit: repair.reachedSearchLimit,
                quality: repair.quality)
        }

        var ranges = sourceTokens.map(\.range)
        var diagnostics: [ParseDiagnostic] = []
        var edits: [RecoveryEdit] = []
        for edit in repair.edits {
            switch edit {
            case .insert(let value, let position):
                let boundary = position < ranges.count
                    ? ranges[position].lowerBound : source.endIndex
                ranges.insert(boundary..<boundary, at: position)
                let terminal = Terminal(string: value)
                diagnostics.append(ParseDiagnostic(
                    severity: .warning, reason: .missingToken,
                    message: "Inserted missing \(terminal.description).",
                    range: boundary..<boundary, expected: [terminal],
                    tokenIndex: position, source: source))
                edits.append(.insert(terminal: terminal, atToken: position))
            case .delete(let value, let position):
                let range = ranges.remove(at: position)
                let terminal = Terminal(string: value)
                diagnostics.append(ParseDiagnostic(
                    severity: .warning, reason: .extraToken,
                    message: "Deleted unexpected \(terminal.description).",
                    range: range, found: terminal, tokenIndex: position,
                    source: source))
                edits.append(.delete(terminal: terminal, atToken: position))
            }
        }

        let repairedSource = repairedInput.joined(separator: " ")
        let recovered = try parse(repairedSource)
        return .init(
            status: .recovered, parseResult: recovered,
            repairedSource: repairedSource, diagnostics: diagnostics,
            recoveryEdits: edits, exploredStates: repair.exploredStates,
            reachedSearchLimit: false, quality: repair.quality)
    }
}
