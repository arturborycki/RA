//
//  SyntaxHighlighter.swift
//  RelationalAlgebra
//
//  Classifies the editor's text for colouring: keywords, operators, tables,
//  columns, calculus variables, literals and comments.
//
//  It runs on every keystroke over text that is usually mid-edit and does not
//  parse, so it never uses the real lexers — they throw at the first stray
//  character. It scans tolerantly instead and classifies each word by what
//  surrounds it: `Employee` after FROM is a table, `e.salary` is a variable or
//  alias and a column, `R(t)` in the calculus is a relation atom. That is a
//  heuristic, not a parse, and it only has to be right often enough to help.
//
//  Pure Foundation, so the classification is unit-tested; the colours live
//  with the view.
//

import Foundation

enum SyntaxClass: Equatable {
    case keyword
    /// σ ⋈ ∃ ∧ = — operators and connectives, glyph or word.
    case symbol
    /// A table, a named result, or an alias standing for one.
    case relation
    case column
    /// A calculus variable: a tuple in TRC, a value in DRC.
    case variable
    case string
    case number
    case comment
}

struct SyntaxToken: Equatable {
    let range: Range<String.Index>
    let kind: SyntaxClass
}

enum SyntaxHighlighter {

    static func tokens(in text: String, language: InputLanguage) -> [SyntaxToken] {
        let raw = scan(text)
        guard language != .sql else { return classifySQL(raw) }

        // A CREATE TABLE prelude reads as SQL whatever the editor holds.
        let preludeLength = RAParser.declarationPrelude(text).count
        let preludeEnd = text.index(text.startIndex, offsetBy: preludeLength)
        let prelude = raw.filter { $0.range.lowerBound < preludeEnd }
        let body = raw.filter { $0.range.lowerBound >= preludeEnd }
        switch language {
        case .sql:       return classifySQL(raw)
        case .ra:        return classifySQL(prelude) + classifyAlgebra(body)
        case .trc, .drc: return classifySQL(prelude) + classifyCalculus(body)
        }
    }

    /// Each classified piece of `text` with its class — what the tests read.
    static func classes(in text: String, language: InputLanguage) -> [(String, SyntaxClass)] {
        tokens(in: text, language: language).map { (String(text[$0.range]), $0.kind) }
    }

    /// The range to mark for an error reported at character `offset`: the
    /// word there, or the last visible character when the error is at the end.
    static func errorRange(in text: String, at offset: Int) -> Range<String.Index>? {
        guard !text.isEmpty, offset >= 0 else { return nil }
        if offset >= text.count {
            guard let last = text.lastIndex(where: { !$0.isWhitespace }) else { return nil }
            return last..<text.index(after: last)
        }
        let start = text.index(text.startIndex, offsetBy: offset)
        let isWord: (Character) -> Bool = { $0.isLetter || $0.isNumber || $0 == "_" }
        guard isWord(text[start]) else { return start..<text.index(after: start) }
        var end = start
        while end < text.endIndex, isWord(text[end]) { end = text.index(after: end) }
        return start..<end
    }

    // MARK: - Scanning

    struct Raw {
        enum Kind { case word, quoted, number, string, comment, symbol, latex }
        let kind: Kind
        let range: Range<String.Index>
        let text: String
        /// The first token on its line.
        let startsLine: Bool
    }

    static func scan(_ text: String) -> [Raw] {
        var out: [Raw] = []
        var i = text.startIndex
        var newline = true

        func peek(_ offset: Int) -> Character? {
            var j = i
            for _ in 0..<offset {
                guard j < text.endIndex else { return nil }
                j = text.index(after: j)
            }
            return j < text.endIndex ? text[j] : nil
        }
        func emit(_ kind: Raw.Kind, from start: String.Index) {
            out.append(Raw(kind: kind, range: start..<i, text: String(text[start..<i]),
                           startsLine: newline))
            newline = false
        }
        func advance(_ n: Int = 1) {
            for _ in 0..<n where i < text.endIndex { i = text.index(after: i) }
        }

        while i < text.endIndex {
            let c = text[i]
            let start = i
            if c.isNewline {
                newline = true
                advance()
            } else if c.isWhitespace {
                advance()
            } else if c == "-", peek(1) == "-" {
                while i < text.endIndex, !text[i].isNewline { advance() }
                emit(.comment, from: start)
            } else if c == "/", peek(1) == "*" {
                advance(2)
                while i < text.endIndex, !(text[i] == "*" && peek(1) == "/") { advance() }
                advance(2)
                emit(.comment, from: start)
            } else if c == "'" {
                advance()
                while i < text.endIndex {
                    if text[i] == "'" {
                        if peek(1) == "'" { advance(2); continue }
                        advance()
                        break
                    }
                    advance()
                }
                emit(.string, from: start)
            } else if c == "\"" {
                advance()
                while i < text.endIndex, text[i] != "\"" { advance() }
                advance()
                emit(.quoted, from: start)
            } else if c.isNumber && !isSubscriptDigit(c) {
                while i < text.endIndex, text[i].isNumber || (text[i] == "." && peek(1)?.isNumber == true) {
                    advance()
                }
                emit(.number, from: start)
            } else if c.isLetter && !isGlyph(c) || c == "_" {
                while i < text.endIndex {
                    let d = text[i]
                    if (d.isLetter && !isGlyph(d)) || d.isNumber || d == "_" {
                        advance()
                    } else if d == "\\", peek(1) == "_" {
                        advance(2)
                    } else {
                        break
                    }
                }
                emit(.word, from: start)
            } else if c == "\\" {
                advance()
                if let d = peek(0), d == "{" || d == "}" || d == "_" || d == "," {
                    advance()
                    emit(.symbol, from: start)
                } else {
                    while i < text.endIndex, text[i].isLetter { advance() }
                    emit(.latex, from: start)
                }
            } else {
                let two = peek(1).map { String([c, $0]) } ?? ""
                if c == ".", peek(1) == ".", peek(2) == "." {
                    advance(3)
                } else if ["<=", ">=", "<>", "!=", "->", "=>", ":=", "||", "&&"].contains(two) {
                    advance(2)
                } else {
                    advance()
                }
                emit(.symbol, from: start)
            }
        }
        return out
    }

    /// Greek operator letters are letters to Unicode, but glyphs to us.
    private static func isGlyph(_ c: Character) -> Bool {
        ["σ", "π", "ρ", "γ", "τ", "δ"].contains(c)
    }

    private static func isSubscriptDigit(_ c: Character) -> Bool {
        ("₀"..."₉").contains(c)
    }

    // MARK: - Shared vocabulary

    static let operatorSymbols: Set<String> = [
        "=", "<", ">", "<=", ">=", "<>", "!=", "≠", "≤", "≥", "+", "-", "*", "/", "%", "||",
        "σ", "π", "ρ", "⋈", "⟕", "⟖", "⟗", "×", "∪", "∩", "−", "÷", "γ", "τ", "δ",
        "∃", "∀", "∧", "∨", "¬", "→", "←", "∈", "⟨", "⟩", "{", "}", "|", "…", "...",
        "↑", "↓", "->", "=>", ":=", "&&", "&", "~", "[", "]", "\\{", "\\}"
    ]

    static let sqlKeywords: Set<String> = SQLKeyword.all.union([
        "CREATE", "TABLE", "NATURAL", "OFFSET", "FETCH", "RECURSIVE", "OVER", "PARTITION",
        "ROLLUP", "CUBE", "GROUPING", "SETS", "ANY", "SOME", "NULLS", "FIRST", "LAST", "NEXT",
        "ROWS", "ROW", "ONLY", "CAST", "DATE", "TIME", "TIMESTAMP", "INTERVAL", "IF",
        "PRIMARY", "FOREIGN", "KEY", "REFERENCES", "UNIQUE", "CHECK", "CONSTRAINT",
        "INT", "INTEGER", "BIGINT", "SMALLINT", "VARCHAR", "CHAR", "TEXT", "DECIMAL",
        "NUMERIC", "REAL", "FLOAT", "DOUBLE", "PRECISION", "BOOLEAN", "BOOL", "DAY", "MONTH",
        "YEAR", "HOUR", "MINUTE", "SECOND"
    ])

    /// Words that keep a FROM list going rather than ending it.
    private static let joinWords: Set<String> = [
        "INNER", "LEFT", "RIGHT", "FULL", "OUTER", "CROSS", "NATURAL", "JOIN", "AS"
    ]

    private static func symbolToken(_ token: Raw) -> SyntaxToken? {
        operatorSymbols.contains(token.text) ? SyntaxToken(range: token.range, kind: .symbol) : nil
    }

    private static func literalToken(_ token: Raw) -> SyntaxToken? {
        switch token.kind {
        case .string:  return SyntaxToken(range: token.range, kind: .string)
        case .number:  return SyntaxToken(range: token.range, kind: .number)
        case .comment: return SyntaxToken(range: token.range, kind: .comment)
        case .latex:   return SyntaxToken(range: token.range, kind: .symbol)
        case .symbol:  return symbolToken(token)
        case .word, .quoted: return nil
        }
    }

    private static func isWord(_ token: Raw?) -> Bool {
        guard let token else { return false }
        return token.kind == .word || token.kind == .quoted
    }

    private static func isSymbol(_ token: Raw?, _ text: String) -> Bool {
        token?.kind == .symbol && token?.text == text
    }

    // MARK: - SQL

    static func classifySQL(_ raw: [Raw]) -> [SyntaxToken] {
        let relations = sqlRelations(raw)
        var out: [SyntaxToken] = []
        var inTableDefinition = false
        var definitionDepth = 0
        var depth = 0
        var entryStart = false

        for (i, token) in raw.enumerated() {
            if let literal = literalToken(token) { out.append(literal) }
            if token.kind == .symbol {
                if token.text == "(" {
                    depth += 1
                    if inTableDefinition && depth == definitionDepth { entryStart = true }
                } else if token.text == ")" {
                    if inTableDefinition && depth == definitionDepth { inTableDefinition = false }
                    depth -= 1
                } else if token.text == ",", inTableDefinition, depth == definitionDepth {
                    entryStart = true
                }
                continue
            }
            guard isWord(token) else { continue }

            let upper = token.text.uppercased()
            let next = i + 1 < raw.count ? raw[i + 1] : nil
            let previous = i > 0 ? raw[i - 1] : nil
            let kind: SyntaxClass

            // CREATE TABLE R ( name TYPE, … ): the first word of each entry is
            // a column, whatever its spelling.
            if inTableDefinition, depth == definitionDepth, entryStart, token.kind == .word,
               !["PRIMARY", "FOREIGN", "UNIQUE", "CHECK", "CONSTRAINT", "KEY"].contains(upper) {
                kind = .column
            } else if token.kind == .word && sqlKeywords.contains(upper) {
                kind = .keyword
                if upper == "TABLE" { inTableDefinition = true; definitionDepth = depth + 1 }
            } else if isSymbol(previous, ".") {
                kind = .column
            } else if isSymbol(next, ".") || relations.contains(token.text.lowercased()) {
                kind = .relation
            } else if isSymbol(next, "(") {
                kind = .keyword     // a function
            } else {
                kind = .column
            }
            entryStart = false
            out.append(SyntaxToken(range: token.range, kind: kind))
        }
        return out
    }

    /// The names that are tables or stand for them: what follows FROM, JOIN or
    /// TABLE, the aliases after those, and CTE names (`name AS (`).
    private static func sqlRelations(_ raw: [Raw]) -> Set<String> {
        var relations = Set<String>()
        var depth = 0
        var fromDepth = -1
        var expectTable = false
        var expectAlias = false

        for (i, token) in raw.enumerated() {
            if token.kind == .symbol {
                switch token.text {
                case "(":
                    depth += 1
                    expectTable = false
                    expectAlias = false
                case ")":
                    depth -= 1
                    if depth < fromDepth { fromDepth = -1 }
                    // `(SELECT …) AS t` in a FROM list: the derived table's alias.
                    expectAlias = depth == fromDepth
                case "," where depth == fromDepth:
                    expectTable = true
                    expectAlias = false
                default:
                    expectAlias = false
                }
                continue
            }
            guard isWord(token) else { expectAlias = false; continue }
            let upper = token.text.uppercased()
            let lower = token.text.lowercased()

            // `name AS (` — a common table expression.
            if i + 2 < raw.count, raw[i + 1].text.uppercased() == "AS", isSymbol(raw[i + 2], "(") {
                relations.insert(lower)
                continue
            }
            if token.kind == .word && sqlKeywords.contains(upper) {
                if upper == "FROM" {
                    fromDepth = depth
                    expectTable = true
                } else if ["JOIN", "TABLE", "INTO", "UPDATE"].contains(upper) {
                    expectTable = true
                } else if !joinWords.contains(upper) {
                    if depth == fromDepth { fromDepth = -1 }
                    expectTable = false
                    expectAlias = false
                }
                if upper != "AS" { expectAlias = false }
                continue
            }
            if expectTable {
                relations.insert(lower)
                expectTable = false
                expectAlias = true
            } else if expectAlias {
                relations.insert(lower)
                expectAlias = false
            }
        }
        return relations
    }

    // MARK: - Relational algebra

    static func classifyAlgebra(_ raw: [Raw]) -> [SyntaxToken] {
        var out: [SyntaxToken] = []
        var depth = 0
        /// The operator whose subscript is open, and whether its first word has gone.
        var opener: String? = nil
        var firstWordSeen = false
        var lastOperator: String? = nil

        for (i, token) in raw.enumerated() {
            let next = i + 1 < raw.count ? raw[i + 1] : nil
            let previous = i > 0 ? raw[i - 1] : nil
            if let literal = literalToken(token) { out.append(literal) }

            if token.kind == .symbol {
                if token.text == "[" {
                    if depth == 0 { opener = lastOperator; firstWordSeen = false }
                    depth += 1
                } else if token.text == "]" {
                    depth = max(0, depth - 1)
                    if depth == 0 { opener = nil }
                } else if operatorSymbols.contains(token.text) && depth == 0 {
                    lastOperator = token.text
                }
                continue
            }
            if token.kind == .latex { lastOperator = token.text; continue }
            guard isWord(token) else { continue }
            let upper = token.text.uppercased()
            let lower = token.text.lowercased()
            let kind: SyntaxClass

            if depth > 0 {
                // Inside a subscript: an SQL condition or attribute list —
                // except ρ's, whose first word is the new relation name.
                let renaming = opener == "ρ" || opener == "rho" || opener == "rename" || opener == "\\rho"
                if renaming && !firstWordSeen {
                    kind = .relation
                } else if token.kind == .word && sqlKeywords.contains(upper) {
                    kind = .keyword
                } else if isSymbol(previous, ".") {
                    kind = .column
                } else if isSymbol(next, ".") {
                    kind = .relation
                } else if isSymbol(next, "(") && !renaming {
                    kind = .keyword
                } else {
                    kind = .column
                }
                firstWordSeen = true
            } else if token.kind == .word && RALexer.aliases[lower] != nil {
                kind = .symbol
                lastOperator = lower
            } else if token.kind == .word && lower == "x" && !isSymbol(next, "=") {
                kind = .symbol
            } else {
                // An operand: a relation, or a named result being assigned.
                kind = .relation
            }
            out.append(SyntaxToken(range: token.range, kind: kind))
        }
        return out
    }

    // MARK: - Relational calculus

    private static let annotationWords: Set<String> = [
        "SORT", "BY", "LIMIT", "OFFSET", "APPLIED", "TO", "ASC", "DESC", "NULLS", "FIRST", "LAST"
    ]
    private static let calculusKeywords: Set<String> = [
        "LIKE", "IS", "NULL", "TRUE", "FALSE", "DISTINCT", "DATE", "TIME", "TIMESTAMP"
    ]

    static func classifyCalculus(_ raw: [Raw]) -> [SyntaxToken] {
        var out: [SyntaxToken] = []
        /// Between ∃ / ∀ and the body: `∃d, e ( … )` — those words are variables,
        /// even though a bracket follows.
        var quantifying = false
        for (i, token) in raw.enumerated() {
            if let literal = literalToken(token) { out.append(literal) }
            let lowered = token.text.lowercased()
            if ["∃", "∀", "\\exists", "\\forall", "exists", "forall"].contains(lowered) {
                quantifying = true
                if !isWord(token) { continue }
            } else if !isWord(token) {
                if token.text != "," { quantifying = false }
                continue
            } else if quantifying {
                // `∃d in Department ( … )`: `in` ends the list and is read below.
                if lowered == "in" {
                    quantifying = false
                } else {
                    out.append(SyntaxToken(range: token.range, kind: .variable))
                    continue
                }
            }
            guard isWord(token) else { continue }
            let next = i + 1 < raw.count ? raw[i + 1] : nil
            let afterNext = i + 2 < raw.count ? raw[i + 2] : nil
            let previous = i > 0 ? raw[i - 1] : nil
            let upper = token.text.uppercased()
            let kind: SyntaxClass

            if token.kind == .word && CalcLexer.words[token.text.lowercased()] != nil {
                kind = .symbol
            } else if token.kind == .word
                        && (annotationWords.contains(upper) || calculusKeywords.contains(upper)) {
                kind = .keyword
            } else if isSymbol(next, "{") || isSymbol(next, "\\{") {
                kind = .keyword        // an aggregate: COUNT{ … }
            } else if isSymbol(previous, ".") {
                kind = .column
            } else if isSymbol(next, "(")
                        || isSymbol(previous, "∈")
                        || (isWord(previous) && previous?.text.lowercased() == "in")
                        || (token.startsLine && isSymbol(next, "=") && isSymbol(afterNext, "{")) {
                kind = .relation       // an atom, a range, or a definition
            } else {
                kind = .variable
            }
            out.append(SyntaxToken(range: token.range, kind: kind))
        }
        return out
    }
}
