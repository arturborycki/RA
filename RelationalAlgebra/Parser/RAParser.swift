//
//  RAParser.swift
//  RelationalAlgebra
//
//  Parses a relational-algebra expression typed by the user into an `RAExpr`.
//
//  The rule the grammar follows is "accept what the app prints": a formula
//  copied out of the Formula view — Unicode or LaTeX — parses back. On top of
//  that every glyph has an ASCII alias, because nobody can type σ on a phone:
//
//      π[name] ( σ[salary > 50000] ( Employee ) )
//      pi[name](sigma[salary > 50000](Employee))
//      \pi_{name}( \sigma_{salary > 50000}( Employee ) )
//
//  Subscripts are handed to the SQL expression parser, so a condition can use
//  anything a WHERE clause can — LIKE, BETWEEN, IN (…), CASE, arithmetic —
//  with the same error messages, offset to point into the RA text.
//
//  Precedence, loosest first: set operators (∪ ∩ −), then joins and products
//  (⋈ ⟕ ⟖ ⟗ ×), then the unary operators. All binary operators associate left.
//

import Foundation

enum RAUnaryOperator: Equatable {
    case selection, projection, rename, distinct, grouping, sort
}

enum RABinaryOperator: Equatable {
    case join, leftJoin, rightJoin, fullJoin, cross
    case union, intersect, difference, division

    var setOperator: SetOperator? {
        switch self {
        case .union:      return .union
        case .intersect:  return .intersect
        case .difference: return .except
        default:          return nil
        }
    }

    var joinKind: RAJoinKind? {
        switch self {
        case .join:      return .inner
        case .leftJoin:  return .left
        case .rightJoin: return .right
        case .fullJoin:  return .full
        default:         return nil
        }
    }
}

struct RAToken: Equatable {
    enum Kind: Equatable {
        case unary(RAUnaryOperator)
        case binary(RABinaryOperator)
        case identifier
        case leftParen
        case rightParen
        /// The raw text between `[…]` or `_{…}`, parsed later by whoever owns it.
        case subscriptText
        /// `=`, `←` or `:=` after a name: `R₁ = σ[…](Employee)`.
        case assign
        /// Separates statements, though a new line beginning `name =` does too.
        case semicolon
        case eof
    }
    var kind: Kind
    var text: String
    /// Character offset in the whole buffer. For a subscript, the offset of
    /// its first character, so errors inside it can be mapped back.
    var position: Int
    /// A double-quoted identifier — never read as an operator alias.
    var quoted: Bool = false
    /// The first token on its line, which is where a new statement may begin.
    var startsLine: Bool = false

    /// Written out rather than derived; see `RAExpr.==`.
    static func == (lhs: RAToken, rhs: RAToken) -> Bool {
        lhs.kind == rhs.kind && lhs.text == rhs.text
            && lhs.position == rhs.position && lhs.quoted == rhs.quoted
    }
}

extension RAToken.Kind {
    static func == (lhs: RAToken.Kind, rhs: RAToken.Kind) -> Bool {
        switch (lhs, rhs) {
        case let (.unary(a), .unary(b)):   return a == b
        case let (.binary(a), .binary(b)): return a == b
        case (.identifier, .identifier), (.leftParen, .leftParen),
             (.rightParen, .rightParen), (.subscriptText, .subscriptText),
             (.assign, .assign), (.semicolon, .semicolon), (.eof, .eof):
            return true
        case (.unary, _), (.binary, _), (.identifier, _), (.leftParen, _),
             (.rightParen, _), (.subscriptText, _), (.assign, _), (.semicolon, _), (.eof, _):
            return false
        }
    }
}

// MARK: - Lexer

struct RALexer {
    private let chars: [Character]
    private var index: Int

    init(_ chars: [Character], start: Int) {
        self.chars = chars
        self.index = start
    }

    static let glyphs: [Character: RAToken.Kind] = [
        "σ": .unary(.selection), "π": .unary(.projection), "ρ": .unary(.rename),
        "δ": .unary(.distinct), "γ": .unary(.grouping), "τ": .unary(.sort),
        "⋈": .binary(.join), "⟕": .binary(.leftJoin), "⟖": .binary(.rightJoin),
        "⟗": .binary(.fullJoin), "×": .binary(.cross),
        "∪": .binary(.union), "∩": .binary(.intersect),
        "−": .binary(.difference), "-": .binary(.difference), "÷": .binary(.division)
    ]

    /// Words that stand for a glyph. Lower-case; matched case-insensitively.
    static let aliases: [String: RAToken.Kind] = [
        "sigma": .unary(.selection), "select": .unary(.selection),
        "pi": .unary(.projection), "project": .unary(.projection),
        "rho": .unary(.rename), "rename": .unary(.rename),
        "delta": .unary(.distinct), "distinct": .unary(.distinct),
        "gamma": .unary(.grouping), "tau": .unary(.sort),
        "join": .binary(.join), "natjoin": .binary(.join),
        "ljoin": .binary(.leftJoin), "leftjoin": .binary(.leftJoin),
        "rjoin": .binary(.rightJoin), "rightjoin": .binary(.rightJoin),
        "fjoin": .binary(.fullJoin), "fulljoin": .binary(.fullJoin),
        "cross": .binary(.cross), "times": .binary(.cross),
        "union": .binary(.union), "intersect": .binary(.intersect),
        "minus": .binary(.difference), "except": .binary(.difference),
        "divide": .binary(.division)
    ]

    /// The commands the app's own LaTeX export writes.
    static let latexCommands: [String: RAToken.Kind] = [
        "sigma": .unary(.selection), "pi": .unary(.projection), "rho": .unary(.rename),
        "delta": .unary(.distinct), "gamma": .unary(.grouping), "tau": .unary(.sort),
        "bowtie": .binary(.join), "ltimes": .binary(.leftJoin), "rtimes": .binary(.rightJoin),
        "times": .binary(.cross), "cup": .binary(.union), "cap": .binary(.intersect),
        "setminus": .binary(.difference), "div": .binary(.division)
    ]

    func tokenize() throws -> [RAToken] {
        var copy = self
        return try copy.run()
    }

    private mutating func run() throws -> [RAToken] {
        var tokens: [RAToken] = []
        while true {
            let gapStart = index
            skipWhitespaceAndComments()
            guard index < chars.count else {
                tokens.append(RAToken(kind: .eof, text: "", position: index))
                return tokens
            }
            let start = index
            let c = chars[index]
            let firstNew = tokens.count
            defer {
                if tokens.count > firstNew, chars[gapStart..<start].contains("\n") {
                    tokens[firstNew].startsLine = true
                }
            }

            if let kind = RALexer.glyphs[c] {
                index += 1
                tokens.append(RAToken(kind: kind, text: String(c), position: start))
                if takesSubscript(kind), let sub = try scanSubscript() { tokens.append(sub) }
            } else if c == "\\" {
                let token = try scanLatexCommand()
                tokens.append(token)
                if takesSubscript(token.kind), let sub = try scanSubscript() { tokens.append(sub) }
            } else if c.isLetter || c == "_" {
                let token = scanWord()
                tokens.append(token)
                if takesSubscript(token.kind), let sub = try scanSubscript() { tokens.append(sub) }
            } else if c == "\"" {
                tokens.append(try scanQuotedIdentifier())
            } else if c == "=" || c == "←" {
                index += 1
                tokens.append(RAToken(kind: .assign, text: String(c), position: start))
            } else if c == ":", peek(1) == "=" {
                index += 2
                tokens.append(RAToken(kind: .assign, text: ":=", position: start))
            } else if c == ";" {
                index += 1
                tokens.append(RAToken(kind: .semicolon, text: ";", position: start))
            } else if c == "(" {
                index += 1
                tokens.append(RAToken(kind: .leftParen, text: "(", position: start))
            } else if c == ")" {
                index += 1
                tokens.append(RAToken(kind: .rightParen, text: ")", position: start))
            } else if c == "[" || c == "{" {
                throw ParseError(message: "A subscript must directly follow its operator, " +
                                          "as in σ[salary > 50000].",
                                 position: start)
            } else {
                throw ParseError(message: "Unexpected character '\(c)'.", position: start)
            }
        }
    }

    /// Which tokens may carry a subscript. Joins may, because ⋈[p] is a theta
    /// join; `×` and the set operators never do.
    private func takesSubscript(_ kind: RAToken.Kind) -> Bool {
        switch kind {
        case .unary:
            return true
        case let .binary(op):
            return op.joinKind != nil
        default:
            return false
        }
    }

    // MARK: Character helpers

    private func peek(_ offset: Int = 0) -> Character? {
        index + offset < chars.count ? chars[index + offset] : nil
    }

    private mutating func skipWhitespaceAndComments() {
        while let c = peek() {
            if c.isWhitespace {
                index += 1
            } else if c == "-" && peek(1) == "-" {
                while let d = peek(), d != "\n" { index += 1 }
            } else if c == "%" {
                // A LaTeX comment, which is also what a pasted export may hold.
                while let d = peek(), d != "\n" { index += 1 }
            } else {
                break
            }
        }
    }

    private mutating func scanWord() -> RAToken {
        let start = index
        var text = ""
        while let c = peek() {
            if c.isLetter || c.isNumber || c == "_" {
                text.append(c)
                index += 1
            } else if c == "\\", peek(1) == "_" {
                // `dept\_id`, as the LaTeX export escapes it.
                text.append("_")
                index += 2
            } else {
                break
            }
        }
        if let kind = RALexer.aliases[text.lowercased()] {
            return RAToken(kind: kind, text: text, position: start)
        }
        return RAToken(kind: .identifier, text: text, position: start)
    }

    private mutating func scanQuotedIdentifier() throws -> RAToken {
        let start = index
        index += 1
        var text = ""
        while let c = peek() {
            index += 1
            if c == "\"" {
                if peek() == "\"" { text.append("\""); index += 1; continue }
                return RAToken(kind: .identifier, text: text, position: start, quoted: true)
            }
            text.append(c)
        }
        throw ParseError(message: "Unterminated quoted name.", position: start)
    }

    private mutating func scanLatexCommand() throws -> RAToken {
        let start = index
        index += 1 // backslash
        var name = ""
        while let c = peek(), c.isLetter {
            name.append(c)
            index += 1
        }
        guard let kind = RALexer.latexCommands[name] else {
            throw ParseError(message: "Unknown LaTeX command '\\\(name)'.", position: start)
        }
        return RAToken(kind: kind, text: "\\" + name, position: start)
    }

    /// `[ … ]` or `_{ … }` directly after an operator, with nesting and quoted
    /// strings respected so `σ[name = ']']` and `σ[a IN (SELECT …)]` work.
    /// Returns nil when the operator has no subscript.
    private mutating func scanSubscript() throws -> RAToken? {
        // Spaces may separate the operator from its subscript; a newline may not
        // matter either, but anything else means there is no subscript.
        var probe = index
        while probe < chars.count, chars[probe].isWhitespace { probe += 1 }
        guard probe < chars.count else { return nil }

        let open: Character
        let close: Character
        if chars[probe] == "[" {
            open = "["; close = "]"
            probe += 1
        } else if chars[probe] == "_", probe + 1 < chars.count, chars[probe + 1] == "{" {
            open = "{"; close = "}"
            probe += 2
        } else if chars[probe] == "_" {
            throw ParseError(message: "Put the subscript in brackets: σ[…] or σ_{…}.",
                             position: probe)
        } else {
            return nil
        }

        let bodyStart = probe
        var depth = 1
        var quote: Character? = nil
        while probe < chars.count {
            let c = chars[probe]
            if let q = quote {
                if c == q { quote = nil }
            } else if c == "'" || c == "\"" {
                quote = c
            } else if c == open {
                depth += 1
            } else if c == close {
                depth -= 1
                if depth == 0 {
                    let raw = String(chars[bodyStart..<probe])
                    index = probe + 1
                    let text = open == "{" ? RALexer.unescapeLatex(raw) : raw
                    return RAToken(kind: .subscriptText, text: text, position: bodyStart)
                }
            }
            probe += 1
        }
        throw ParseError(message: "This subscript is never closed with '\(close)'.",
                         position: bodyStart - 1)
    }

    /// Undo the escaping the LaTeX export applies inside a subscript. Each
    /// replacement keeps the text the same length or shorter only where the
    /// export lengthened it, so positions inside stay close enough to point
    /// at the right place.
    static func unescapeLatex(_ text: String) -> String {
        [("\\_", "_"), ("\\%", "%"), ("\\&", "&"), ("\\#", "#"),
         ("\\to ", "→"), ("\\to", "→"), ("\\uparrow ", "↑"), ("\\downarrow ", "↓"),
         ("\\backslash ", "\\")]
            .reduce(text) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
    }
}

// MARK: - Parser

final class RAParser {
    private let tokens: [RAToken]
    private var index = 0

    private init(tokens: [RAToken]) {
        self.tokens = tokens
    }

    static func parse(_ source: String) throws -> RAExpr {
        try parseScript(source).expression
    }

    /// The `CREATE TABLE …;` statements at the top of a buffer, verbatim, or
    /// "" when there are none — what Prettify keeps as the user wrote it.
    static func declarationPrelude(_ source: String) -> String {
        let chars = Array(source)
        guard let end = try? endOfDeclarations(chars), end > 0 else { return "" }
        return String(chars[0..<end])
    }

    /// Lex + parse a whole RA buffer: any number of `CREATE TABLE …;`
    /// statements, any number of `name = expression` lines, then optionally
    /// one expression. Without one, the last name assigned is the answer —
    /// which is how the Steps view's derivation ends.
    static func parseScript(_ source: String) throws -> RAScript {
        let chars = RAParser.normalisingSubscriptDigits(Array(source))
        let preludeEnd = try RAParser.endOfDeclarations(chars)
        let declarations = preludeEnd > 0
            ? try SQLParser.parseDeclarations(String(chars[0..<preludeEnd]))
            : []

        let tokens = try RALexer(chars, start: preludeEnd).tokenize()
        let parser = RAParser(tokens: tokens)
        var assignments: [RAAssignment] = []
        var result: RAExpr? = nil

        while true {
            while parser.current.kind == .semicolon { parser.advance() }
            if parser.current.kind == .eof { break }
            if result != nil {
                throw ParseError(message: "Only the last line may be an expression without a " +
                                          "name; write the earlier ones as name = expression.",
                                 position: parser.current.position)
            }
            if parser.startsAssignment {
                let name = parser.advance()
                parser.advance() // = ← :=
                if assignments.contains(where: { $0.name.caseInsensitiveCompare(name.text) == .orderedSame }) {
                    throw ParseError(message: "\(name.text) is assigned twice.", position: name.position)
                }
                let expression = try parser.parseSetExpression()
                assignments.append(RAAssignment(name: name.text, expression: expression))
            } else {
                result = try parser.parseSetExpression()
            }
            // A statement ends at a semicolon, the end, or a new line; anything
            // else on the same line is a typo, not a second statement.
            guard parser.current.kind == .semicolon || parser.current.kind == .eof
                    || parser.current.startsLine else {
                throw ParseError(message: "Unexpected '\(parser.current.text)' after the expression.",
                                 position: parser.current.position)
            }
        }

        guard let expression = result ?? assignments.last.map({ RAExpr.relation($0.name) }) else {
            throw ParseError(message: "Empty expression.", position: preludeEnd)
        }
        return RAScript(declarations: declarations, expression: expression,
                        assignments: assignments)
    }

    /// `R₁` → `R1`, everywhere outside quotes, so the derivation's names are
    /// ordinary identifiers in SQL. One character for one, so every position
    /// an error reports still points at the right place.
    private static func normalisingSubscriptDigits(_ chars: [Character]) -> [Character] {
        let digits: [Character: Character] = [
            "₀": "0", "₁": "1", "₂": "2", "₃": "3", "₄": "4",
            "₅": "5", "₆": "6", "₇": "7", "₈": "8", "₉": "9"
        ]
        var quote: Character? = nil
        return chars.map { c in
            if let q = quote {
                if c == q { quote = nil }
                return c
            }
            if c == "'" || c == "\"" {
                quote = c
                return c
            }
            return digits[c] ?? c
        }
    }

    /// The offset just past the last `CREATE TABLE …;` at the top of the
    /// buffer, or 0 when there is none. Only the statement boundaries are found
    /// here; the SQL parser reads the statements themselves.
    static func endOfDeclarations(_ chars: [Character]) throws -> Int {
        var index = 0
        var end = 0
        while true {
            while index < chars.count, chars[index].isWhitespace { index += 1 }
            if index + 1 < chars.count, chars[index] == "-", chars[index + 1] == "-" {
                while index < chars.count, chars[index] != "\n" { index += 1 }
                continue
            }
            let word = String(chars[index..<min(index + 6, chars.count)])
            let after = index + 6 < chars.count ? chars[index + 6] : " "
            // `CreatedItems` is a relation, not a statement.
            guard word.uppercased() == "CREATE", !(after.isLetter || after.isNumber || after == "_")
            else { return end }
            let start = index
            var quote: Character? = nil
            while index < chars.count {
                let c = chars[index]
                if let q = quote {
                    if c == q { quote = nil }
                } else if c == "'" || c == "\"" {
                    quote = c
                } else if c == ";" {
                    break
                }
                index += 1
            }
            guard index < chars.count else {
                throw ParseError(message: "End each CREATE TABLE with ';' so the expression " +
                                          "after it can be found.",
                                 position: start)
            }
            index += 1
            end = index
        }
    }

    // MARK: Token cursor

    private var current: RAToken { tokens[index] }

    @discardableResult
    private func advance() -> RAToken {
        let token = tokens[index]
        if index < tokens.count - 1 { index += 1 }
        return token
    }

    /// `name =` — the start of a new statement rather than more expression.
    private var startsAssignment: Bool {
        current.kind == .identifier && index + 1 < tokens.count && tokens[index + 1].kind == .assign
    }

    private var currentDescription: String {
        current.kind == .eof ? "end of input" : current.text
    }

    // MARK: Grammar

    private func parseSetExpression() throws -> RAExpr {
        var left = try parseJoinExpression()
        while case let .binary(op) = current.kind, let setOp = op.setOperator {
            advance()
            let right = try parseJoinExpression()
            left = .setOperation(setOp, left: left, right: right)
        }
        return left
    }

    private func parseJoinExpression() throws -> RAExpr {
        var left = try parseUnary()
        while true {
            if case let .binary(op) = current.kind {
                if let kind = op.joinKind {
                    advance()
                    let condition = try parseOptionalCondition()
                    let right = try parseUnary()
                    left = .join(kind: kind, condition: condition, left: left, right: right)
                    continue
                }
                if op == .cross {
                    advance()
                    left = .cross(left: left, right: try parseUnary())
                    continue
                }
                if op == .division {
                    throw ParseError(message: "Division (÷) is not supported in RA input yet.",
                                     position: current.position)
                }
            }
            // `R x S`: between two operands an `x` can only be a product.
            if current.kind == .identifier, !current.quoted, current.text.lowercased() == "x",
               !startsAssignment {
                advance()
                left = .cross(left: left, right: try parseUnary())
                continue
            }
            return left
        }
    }

    private func parseUnary() throws -> RAExpr {
        guard case let .unary(op) = current.kind else { return try parsePrimary() }
        let opToken = advance()

        switch op {
        case .selection:
            let sub = try requireSubscript(after: opToken, example: "σ[salary > 50000](Employee)")
            let condition = try within(sub) { try SQLParser.parseStandaloneExpression($0) }
            return .selection(condition: condition, child: try parseUnary())

        case .projection:
            let sub = try requireSubscript(after: opToken, example: "π[name, salary](Employee)")
            let items = try within(sub) { try SQLParser.parseStandaloneSelectList($0) }
            return .projection(items: items, child: try parseUnary())

        case .rename:
            let sub = try requireSubscript(after: opToken, example: "ρ[E](Employee)")
            let (name, columns) = try within(sub) { try RAParser.parseRenameSubscript($0) }
            return .rename(name: name, columns: columns, child: try parseUnary())

        case .distinct:
            if current.kind == .subscriptText {
                throw ParseError(message: "δ takes no subscript.", position: current.position)
            }
            return .distinct(child: try parseUnary())

        case .grouping, .sort:
            throw ParseError(message: "\(opToken.text) is not supported in RA input yet.",
                             position: opToken.position)
        }
    }

    private func parsePrimary() throws -> RAExpr {
        switch current.kind {
        case .identifier:
            return .relation(advance().text)
        case .leftParen:
            advance()
            let inner = try parseSetExpression()
            guard current.kind == .rightParen else {
                throw ParseError(message: "Expected ')' but found '\(currentDescription)'.",
                                 position: current.position)
            }
            advance()
            return inner
        default:
            throw ParseError(message: "Expected a relation name or '(' but found " +
                                      "'\(currentDescription)'.",
                             position: current.position)
        }
    }

    // MARK: Subscripts

    private func parseOptionalCondition() throws -> Expression? {
        guard current.kind == .subscriptText else { return nil }
        let sub = advance()
        return try within(sub) { try SQLParser.parseStandaloneExpression($0) }
    }

    private func requireSubscript(after op: RAToken, example: String) throws -> RAToken {
        guard current.kind == .subscriptText else {
            throw ParseError(message: "\(op.text) needs a subscript, as in \(example).",
                             position: op.position)
        }
        return advance()
    }

    /// Run a sub-parser on a subscript's text, shifting any error position so
    /// it points into the RA buffer rather than into the subscript.
    private func within<T>(_ sub: RAToken, _ body: (String) throws -> T) throws -> T {
        do {
            return try body(sub.text)
        } catch let error as ParseError {
            throw ParseError(message: error.message, position: sub.position + error.position)
        } catch let error as LexError {
            throw ParseError(message: error.message, position: sub.position + error.position)
        }
    }

    /// `S` or `S(a, b, c)`.
    private static func parseRenameSubscript(_ text: String) throws -> (String, [String]) {
        let tokens = try Lexer(text).tokenize()
        var i = 0
        func token() -> Token { tokens[min(i, tokens.count - 1)] }

        guard token().kind == .identifier else {
            throw ParseError(message: "Expected a new relation name but found " +
                                      "'\(token().text)'.",
                             position: token().position)
        }
        let name = token().text
        i += 1

        var columns: [String] = []
        if token().kind == .leftParen {
            i += 1
            repeat {
                if token().kind == .comma { i += 1 }
                guard token().kind == .identifier else {
                    throw ParseError(message: "Expected an attribute name but found " +
                                              "'\(token().text)'.",
                                     position: token().position)
                }
                columns.append(token().text)
                i += 1
            } while token().kind == .comma
            guard token().kind == .rightParen else {
                throw ParseError(message: "Expected ')' closing the attribute list.",
                                 position: token().position)
            }
            i += 1
        } else if token().kind == .keyword, token().text.uppercased() == "AS" {
            throw ParseError(message: "Renaming single attributes (a → x) is not supported " +
                                      "yet; rename them all with ρ[S(a, b, …)].",
                             position: token().position)
        }

        guard token().kind == .eof else {
            throw ParseError(message: "Unexpected '\(token().text)' in the rename.",
                             position: token().position)
        }
        return (name, columns)
    }
}
