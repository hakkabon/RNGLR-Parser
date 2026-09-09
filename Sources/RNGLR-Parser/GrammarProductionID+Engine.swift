import Grammar

extension GrammarProductionID {
    init(goal: NonTerminal, symbols: [Symbol]) {
        self.init(rawValue: Self.productionKey(goal: goal, symbols: symbols))
    }

    private static func productionKey(goal: NonTerminal, symbols: [Symbol]) -> String {
        "production:\(frame(goal.name))->\(symbols.map { frame(symbolKey($0)) }.joined())"
    }

    private static func symbolKey(_ symbol: Symbol) -> String {
        switch symbol {
        case .terminal(let terminal): "terminal(\(terminalKey(terminal)))"
        case .nonTerminal(let nonterminal): "nonterminal(\(frame(nonterminal.name)))"
        case .metaSymbol(let meta): "meta(\(frame(meta.rawValue)))"
        }
    }

    private static func terminalKey(_ terminal: Terminal) -> String {
        switch terminal {
        case .string(let value): "string:\(frame(value))"
        case .stringList(let values): "list:" + values.map(frame).joined()
        case .characterRange(let range):
            "range:\(frame(String(range.lowerBound)))\(frame(String(range.upperBound)))"
        case .regularExpression(let expression): "regex:\(frame(expression.pattern))"
        case .meta(let value): "meta:\(frame(value.rawValue))"
        }
    }

    private static func frame(_ value: String) -> String { "\(value.utf8.count):\(value)" }
}
