//
//  CalcParser.swift
//  RelationalAlgebra
//
//  Parses tuple or domain relational calculus typed by the user into the
//  calculus IR the rest of the app already speaks.
//
//  As with the algebra, the rule is "accept what the app prints": a formula
//  copied out of the Formula view — Unicode, plain text or LaTeX — parses back.
//  On top of that every glyph has a word, and two textbook conveniences are
//  read as what they abbreviate:
//
//      { t.name | Employee(t) ∧ t.salary > 50000 }
//      { t.name | Employee(t) and t.salary > 50000 }
//      { <n> | EXISTS s, d ( Employee(n, s, d) AND s > 50000 ) }
//      { t.name | t ∈ Employee ∧ ∃d ∈ Department ( d.id = t.dept_id ) }
//
//  `t ∈ R` is `R(t)`; `∃t ∈ R (φ)` is `∃t ( R(t) ∧ φ )`; `∀t ∈ R (φ)` is
//  `∀t ( R(t) → φ )`.
//
//  Whether the input is TRC or DRC is read off the formula — `t.name` is tuple
//  calculus, `Employee(n, s, d)` is domain calculus — and the editor's choice
//  only settles formulas that could be either, such as `{ t | R(t) }`.
//

import Foundation

// MARK: - Tokens

enum CalcTokenKind: Equatable {
    case identifier, number, string
    case leftBrace, rightBrace, bar, leftParen, rightParen, comma, dot
    case leftAngle, rightAngle
    case and, or, not, arrow, exists, forAll, member
    case comparison(String)
    case arithmetic(String)
    case ellipsis
    case setOperator(CalcSetOperator)
    case semicolon
    case eof
}

struct CalcToken: Equatable {
    var kind: CalcTokenKind
    var text: String
    var position: Int
    var quoted: Bool = false
    var startsLine: Bool = false

    static func == (lhs: CalcToken, rhs: CalcToken) -> Bool {
        lhs.kind == rhs.kind && lhs.text == rhs.text && lhs.position == rhs.position
    }
}

extension CalcTokenKind {
    /// Written out rather than derived; see `RAExpr.==`.
    static func == (lhs: CalcTokenKind, rhs: CalcTokenKind) -> Bool {
        switch (lhs, rhs) {
        case let (.comparison(a), .comparison(b)), let (.arithmetic(a), .arithmetic(b)):
            return a == b
        case let (.setOperator(a), .setOperator(b)):
            return a == b
        case (.identifier, .identifier), (.number, .number), (.string, .string),
             (.leftBrace, .leftBrace), (.rightBrace, .rightBrace), (.bar, .bar),
             (.leftParen, .leftParen), (.rightParen, .rightParen), (.comma, .comma),
             (.dot, .dot), (.leftAngle, .leftAngle), (.rightAngle, .rightAngle),
             (.and, .and), (.or, .or), (.not, .not), (.arrow, .arrow),
             (.exists, .exists), (.forAll, .forAll), (.member, .member),
             (.ellipsis, .ellipsis), (.semicolon, .semicolon), (.eof, .eof):
            return true
        case (.identifier, _), (.number, _), (.string, _), (.leftBrace, _), (.rightBrace, _),
             (.bar, _), (.leftParen, _), (.rightParen, _), (.comma, _), (.dot, _),
             (.leftAngle, _), (.rightAngle, _), (.and, _), (.or, _), (.not, _), (.arrow, _),
             (.exists, _), (.forAll, _), (.member, _), (.comparison, _), (.arithmetic, _),
             (.ellipsis, _), (.setOperator, _), (.semicolon, _), (.eof, _):
            return false
        }
    }
}

// MARK: - Lexer

struct CalcLexer {
    private let chars: [Character]
    private var index: Int

    init(_ chars: [Character], start: Int) {
        self.chars = chars
        self.index = start
    }

    static let glyphs: [Character: CalcTokenKind] = [
        "{": .leftBrace, "}": .rightBrace, "|": .bar, "(": .leftParen, ")": .rightParen,
        ",": .comma, "⟨": .leftAngle, "⟩": .rightAngle,
        "∧": .and, "∨": .or, "¬": .not, "~": .not, "→": .arrow,
        "∃": .exists, "∀": .forAll, "∈": .member, "…": .ellipsis, ";": .semicolon,
        "∪": .setOperator(.union), "∩": .setOperator(.intersect),
        "−": .setOperator(.difference),
        "≠": .comparison("≠"), "≤": .comparison("≤"), "≥": .comparison("≥"),
        "=": .comparison("="),
        "+": .arithmetic("+"), "*": .arithmetic("*"), "/": .arithmetic("/"),
        "%": .arithmetic("%")
    ]

    /// Words for glyphs. Lower-case; matched case-insensitively.
    static let words: [String: CalcTokenKind] = [
        "and": .and, "or": .or, "not": .not, "implies": .arrow,
        "exists": .exists, "forall": .forAll, "in": .member,
        "union": .setOperator(.union), "intersect": .setOperator(.intersect),
        "minus": .setOperator(.difference), "except": .setOperator(.difference)
    ]

    /// The commands the app's LaTeX export writes, and their common synonyms.
    static let latex: [String: CalcTokenKind] = [
        "exists": .exists, "forall": .forAll, "wedge": .and, "land": .and,
        "vee": .or, "lor": .or, "neg": .not, "lnot": .not,
        "rightarrow": .arrow, "to": .arrow, "implies": .arrow,
        "mid": .bar, "langle": .leftAngle, "rangle": .rightAngle, "in": .member,
        "neq": .comparison("≠"), "ne": .comparison("≠"),
        "leq": .comparison("≤"), "le": .comparison("≤"),
        "geq": .comparison("≥"), "ge": .comparison("≥"),
        "cup": .setOperator(.union), "cap": .setOperator(.intersect),
        "setminus": .setOperator(.difference), "ldots": .ellipsis
    ]

    static let subscriptDigits: [Character: Character] = [
        "₀": "0", "₁": "1", "₂": "2", "₃": "3", "₄": "4",
        "₅": "5", "₆": "6", "₇": "7", "₈": "8", "₉": "9"
    ]

    func tokenize() throws -> [CalcToken] {
        var copy = self
        return try copy.run()
    }

    private func peek(_ offset: Int = 0) -> Character? {
        index + offset < chars.count ? chars[index + offset] : nil
    }

    private mutating func run() throws -> [CalcToken] {
        var tokens: [CalcToken] = []
        while true {
            let gapStart = index
            skipWhitespaceAndComments()
            let newline = chars[gapStart..<index].contains("\n")
            guard let c = peek() else {
                tokens.append(CalcToken(kind: .eof, text: "", position: index))
                return tokens
            }
            var token = try scan(c)
            token.startsLine = newline
            tokens.append(token)
        }
    }

    private mutating func skipWhitespaceAndComments() {
        while let c = peek() {
            if c.isWhitespace {
                index += 1
            } else if c == "-", peek(1) == "-" {
                while let d = peek(), d != "\n" { index += 1 }
            } else if c == "\\", let next = peek(1), next == "," || next == ";" || next == " " {
                // LaTeX spacing: `\,` `\;` `\ `.
                index += 2
            } else {
                break
            }
        }
    }

    private mutating func scan(_ c: Character) throws -> CalcToken {
        let start = index
        func single(_ kind: CalcTokenKind, length: Int = 1) -> CalcToken {
            let text = String(chars[index..<index + length])
            index += length
            return CalcToken(kind: kind, text: text, position: start)
        }

        // Two- and three-character operators first.
        let two = peek(1).map { String([c, $0]) } ?? ""
        switch two {
        case "<=": return single(.comparison("≤"), length: 2)
        case ">=": return single(.comparison("≥"), length: 2)
        case "<>", "!=": return single(.comparison("≠"), length: 2)
        case "->", "=>": return single(.arrow, length: 2)
        case "||": return single(.arithmetic("||"), length: 2)
        case "&&": return single(.and, length: 2)
        default: break
        }
        if c == ".", peek(1) == ".", peek(2) == "." { return single(.ellipsis, length: 3) }
        if c == "<" { return single(.comparison("<")) }
        if c == ">" { return single(.comparison(">")) }
        if c == "-" { return single(.arithmetic("-")) }
        if c == "&" { return single(.and) }
        if c == "." {
            if let next = peek(1), next.isNumber { return scanNumber() }
            return single(.dot)
        }
        if let kind = CalcLexer.glyphs[c] { return single(kind) }
        if c == "'" { return try scanString() }
        if c == "\"" { return try scanQuotedIdentifier() }
        if c.isNumber { return scanNumber() }
        if c == "\\" { return try scanLatex() }
        if c.isLetter || c == "_" { return scanWord() }
        throw ParseError(message: "Unexpected character '\(c)'.", position: start)
    }

    private mutating func scanNumber() -> CalcToken {
        let start = index
        var text = ""
        var seenDot = false
        while let c = peek() {
            if c.isNumber {
                text.append(c)
            } else if c == ".", !seenDot, peek(1)?.isNumber == true {
                seenDot = true
                text.append(c)
            } else {
                break
            }
            index += 1
        }
        return CalcToken(kind: .number, text: text, position: start)
    }

    private mutating func scanString() throws -> CalcToken {
        let start = index
        index += 1
        var text = ""
        while let c = peek() {
            index += 1
            if c == "'" {
                if peek() == "'" { text.append("'"); index += 1; continue }
                return CalcToken(kind: .string, text: text, position: start)
            }
            text.append(c)
        }
        throw ParseError(message: "Unterminated string literal.", position: start)
    }

    private mutating func scanQuotedIdentifier() throws -> CalcToken {
        let start = index
        index += 1
        var text = ""
        while let c = peek() {
            index += 1
            if c == "\"" {
                return CalcToken(kind: .identifier, text: text, position: start, quoted: true)
            }
            text.append(c)
        }
        throw ParseError(message: "Unterminated quoted name.", position: start)
    }

    private mutating func scanWord() -> CalcToken {
        let start = index
        var text = ""
        while let c = peek() {
            if let digit = CalcLexer.subscriptDigits[c] {
                // `t₁` → `t1`, so a name is an ordinary identifier in SQL.
                text.append(digit)
                index += 1
            } else if c.isLetter || c.isNumber || c == "_" {
                text.append(c)
                index += 1
            } else if c == "\\", peek(1) == "_" {
                text.append("_")
                index += 2
            } else {
                break
            }
        }
        if let kind = CalcLexer.words[text.lowercased()] {
            return CalcToken(kind: kind, text: text, position: start)
        }
        return CalcToken(kind: .identifier, text: text, position: start)
    }

    private mutating func scanLatex() throws -> CalcToken {
        let start = index
        index += 1
        if let c = peek(), c == "{" || c == "}" {
            index += 1
            return CalcToken(kind: c == "{" ? .leftBrace : .rightBrace, text: "\\\(c)",
                             position: start)
        }
        var name = ""
        while let c = peek(), c.isLetter {
            name.append(c)
            index += 1
        }
        guard let kind = CalcLexer.latex[name] else {
            throw ParseError(message: "Unknown LaTeX command '\\\(name)'.", position: start)
        }
        return CalcToken(kind: kind, text: "\\" + name, position: start)
    }
}

// MARK: - Parser

final class CalcParser {
    private let tokens: [CalcToken]
    private var index = 0

    private init(tokens: [CalcToken]) {
        self.tokens = tokens
    }

    /// Lex + parse a whole calculus buffer: `CREATE TABLE …;` statements, any
    /// number of `Name = { … }` definitions, then the expression. When the
    /// buffer ends on a definition, that definition is the answer.
    static func parseScript(_ source: String, preferring preferred: CalcDialect) throws -> CalcScript {
        let chars = Array(source)
        let preludeEnd = try RAParser.endOfDeclarations(chars)
        let declarations = preludeEnd > 0
            ? try SQLParser.parseDeclarations(String(chars[0..<preludeEnd]))
            : []

        let parser = CalcParser(tokens: try CalcLexer(chars, start: preludeEnd).tokenize())
        var definitions: [CalcDefinition] = []
        var result: CalcExpression? = nil

        while true {
            while parser.current.kind == .semicolon { parser.advance() }
            if parser.current.kind == .eof { break }
            if result != nil {
                throw ParseError(message: "Only the last part may be an expression without a " +
                                          "name; write the earlier ones as Name = { … }.",
                                 position: parser.current.position)
            }
            if parser.startsDefinition {
                let name = parser.advance()
                parser.advance() // =
                if definitions.contains(where: { $0.name.caseInsensitiveCompare(name.text) == .orderedSame }) {
                    throw ParseError(message: "\(name.text) is defined twice.", position: name.position)
                }
                definitions.append(CalcDefinition(name: name.text,
                                                  expression: try parser.parseSetExpression()))
            } else {
                result = try parser.parseSetExpression()
            }
            guard [.semicolon, .eof].contains(parser.current.kind) || parser.current.startsLine else {
                throw ParseError(message: "Unexpected '\(parser.current.text)' after the expression.",
                                 position: parser.current.position)
            }
        }

        if result == nil, let last = definitions.popLast() {
            result = last.expression
        }
        guard let expression = result else {
            throw ParseError(message: "Empty expression.", position: preludeEnd)
        }
        var script = CalcScript(declarations: declarations, definitions: definitions,
                                expression: expression, dialect: preferred)
        script.dialect = try CalcParser.dialect(of: script, preferring: preferred)
        return script
    }

    // MARK: Token cursor

    private var current: CalcToken { tokens[index] }

    private func peekKind(_ offset: Int) -> CalcTokenKind {
        tokens[min(index + offset, tokens.count - 1)].kind
    }

    @discardableResult
    private func advance() -> CalcToken {
        let token = tokens[index]
        if index < tokens.count - 1 { index += 1 }
        return token
    }

    private var description: String {
        current.kind == .eof ? "end of input" : current.text
    }

    private func expect(_ kind: CalcTokenKind, _ what: String) throws -> CalcToken {
        guard current.kind == kind else {
            throw ParseError(message: "Expected \(what) but found '\(description)'.",
                             position: current.position)
        }
        return advance()
    }

    private func isWord(_ word: String) -> Bool {
        current.kind == .identifier && !current.quoted && current.text.uppercased() == word
    }

    /// `Name = {` — a definition rather than more expression.
    private var startsDefinition: Bool {
        current.kind == .identifier && peekKind(1) == .comparison("=") && peekKind(2) == .leftBrace
    }

    // MARK: Expressions and queries

    private func parseSetExpression() throws -> CalcExpression {
        var left = try parseQueryPrimary()
        while true {
            let op: CalcSetOperator
            if case let .setOperator(o) = current.kind {
                op = o
            } else if current.kind == .arithmetic("-") {
                op = .difference
            } else {
                return left
            }
            advance()
            left = .setOperation(op: op, left: left, right: try parseQueryPrimary())
        }
    }

    private func parseQueryPrimary() throws -> CalcExpression {
        if current.kind == .leftParen {
            advance()
            let inner = try parseSetExpression()
            _ = try expect(.rightParen, "')'")
            return inner
        }
        let open = try expect(.leftBrace, "'{' starting a set-builder expression")
        let (result, style) = try parseResultSpec()
        _ = try expect(.bar, "'|' after the result")
        let formula = try parseFormula()
        guard current.kind == .rightBrace else {
            throw ParseError(message: "Expected '}' closing the expression opened here but found " +
                                      "'\(description)'.",
                             position: current.kind == .eof ? open.position : current.position)
        }
        advance()
        return .query(CalcQuery(dialect: .trc, result: result, formula: formula,
                                resultStyle: style))
    }

    /// `t.name, t.salary → pay`, `⟨n, s⟩` or `<n, s>`, or a whole tuple `t`.
    private func parseResultSpec() throws -> ([ResultColumn], CalcResultStyle) {
        if current.kind == .leftAngle || current.kind == .comparison("<") {
            let closing: CalcTokenKind = current.kind == .leftAngle ? .rightAngle : .comparison(">")
            advance()
            let columns = try parseResultColumns()
            _ = try expect(closing, "'⟩' closing the result tuple")
            return (columns, .tuple)
        }
        return (try parseResultColumns(), .compact)
    }

    /// `term [→ name], …` — the rename arrow is how the app prints `AS`.
    private func parseResultColumns() throws -> [ResultColumn] {
        var columns: [ResultColumn] = []
        repeat {
            if current.kind == .comma { advance() }
            let term = try parseTerm()
            var name: String? = nil
            if current.kind == .arrow {
                advance()
                name = try expect(.identifier, "a column name after →").text
            }
            columns.append(ResultColumn(term: term, name: name))
        } while current.kind == .comma
        return columns
    }

    // MARK: Formulas

    private func parseFormula() throws -> CalcFormula {
        let left = try parseDisjunction()
        if current.kind == .arrow {
            advance()
            return .implies(left, try parseFormula())
        }
        return left
    }

    private func parseDisjunction() throws -> CalcFormula {
        var parts = [try parseConjunction()]
        while current.kind == .or {
            advance()
            parts.append(try parseConjunction())
        }
        return parts.count == 1 ? parts[0] : CalcFormula.disjunction(parts)
    }

    private func parseConjunction() throws -> CalcFormula {
        var parts = [try parseUnary()]
        while current.kind == .and {
            advance()
            parts.append(try parseUnary())
        }
        return parts.count == 1 ? parts[0] : CalcFormula.conjunction(parts)
    }

    private func parseUnary() throws -> CalcFormula {
        switch current.kind {
        case .not:
            advance()
            return .not(try parseUnary())
        case .exists, .forAll:
            return try parseQuantifier()
        default:
            return try parseAtom()
        }
    }

    /// `∃t, u ( φ )`, `∃t ∃u ( φ )`, or a range-restricted `∃t ∈ R ( φ )`.
    private func parseQuantifier() throws -> CalcFormula {
        let universal = advance().kind == .forAll
        var variables: [CalcVar] = []
        repeat {
            if current.kind == .comma { advance() }
            variables.append(CalcVar(name: try expect(.identifier, "a variable name").text,
                                     relation: nil))
        } while current.kind == .comma

        var range: String? = nil
        if current.kind == .member {
            advance()
            range = try expect(.identifier, "a relation name after ∈").text
        }

        let body: CalcFormula
        if current.kind == .leftParen {
            advance()
            body = try parseFormula()
            _ = try expect(.rightParen, "')' closing the quantifier's body")
        } else {
            body = try parseUnary()
        }

        guard let range else {
            return universal ? .forAll(variables, body) : .exists(variables, body)
        }
        let guards = variables.map { CalcFormula.relationAtom(relation: range, terms: [.variable($0)],
                                                              arityKnown: true) }
        return universal
            ? .forAll(variables, .implies(CalcFormula.conjunction(guards), body))
            : .exists(variables, CalcFormula.conjunction(guards + [body]))
    }

    private func parseAtom() throws -> CalcFormula {
        // A bracket may open a sub-formula or a term: `(a ∨ b)` or `(x + 1) > 2`.
        if current.kind == .leftParen {
            let save = index
            advance()
            if let inner = try? parseFormula(), current.kind == .rightParen {
                advance()
                if !current.kind.continuesTerm { return inner }
            }
            index = save
        }

        if isWord("TRUE") || isWord("FALSE"), !peekKind(1).continuesTerm {
            return .constant(advance().text.uppercased() == "TRUE")
        }

        let start = current
        let lhs = try parseTerm()

        if case let .comparison(op) = current.kind {
            advance()
            return .comparison(lhs: lhs, op: op, rhs: try parseTerm())
        }
        if isWord("LIKE") {
            advance()
            return .comparison(lhs: lhs, op: "LIKE", rhs: try parseTerm())
        }
        if current.kind == .not, peekKind(1) == .identifier,
           tokens[min(index + 1, tokens.count - 1)].text.uppercased() == "LIKE" {
            advance(); advance()
            return .comparison(lhs: lhs, op: "NOT LIKE", rhs: try parseTerm())
        }
        if isWord("IS") {
            advance()
            let negated = current.kind == .not
            if negated { advance() }
            guard isWord("NULL") else {
                throw ParseError(message: "Expected NULL after IS.", position: current.position)
            }
            advance()
            return .comparison(lhs: lhs, op: negated ? "IS NOT" : "IS", rhs: .literal("NULL"))
        }
        if current.kind == .member {
            advance()
            let relation = try expect(.identifier, "a relation name after ∈").text
            return .relationAtom(relation: relation, terms: [lhs], arityKnown: true)
        }
        if case let .application(name, args, false) = lhs {
            // `R(t)` or `R(x, y, …)`: an application standing alone is an atom.
            let complete = !(args.last.map(CalcParser.isEllipsis) ?? false)
            let terms = complete ? args : Array(args.dropLast())
            if terms.contains(where: CalcParser.isEllipsis) {
                throw ParseError(message: "… may only end an atom's list.", position: start.position)
            }
            return .relationAtom(relation: name, terms: terms, arityKnown: complete)
        }
        throw ParseError(message: "Expected a comparison or a relation atom such as R(t) after " +
                                  "'\(start.text)'.",
                         position: current.position)
    }

    private static func isEllipsis(_ term: CalcTerm) -> Bool {
        if case .opaque("…") = term { return true }
        return false
    }

    // MARK: Terms

    private func parseTerm() throws -> CalcTerm {
        var left = try parseProduct()
        while case let .arithmetic(op) = current.kind, ["+", "-", "||"].contains(op) {
            advance()
            left = .binaryOp(op: op, lhs: left, rhs: try parseProduct())
        }
        return left
    }

    private func parseProduct() throws -> CalcTerm {
        var left = try parseTermPrimary()
        while case let .arithmetic(op) = current.kind, ["*", "/", "%"].contains(op) {
            advance()
            left = .binaryOp(op: op, lhs: left, rhs: try parseTermPrimary())
        }
        return left
    }

    private func parseTermPrimary() throws -> CalcTerm {
        let token = current
        switch token.kind {
        case .number:
            advance()
            return .literal(token.text)
        case .arithmetic("-") where peekKind(1) == .number:
            advance()
            return .literal("-" + advance().text)
        case .string:
            advance()
            return .literal(SQLPrinter.stringLiteral(token.text))
        case .leftParen:
            advance()
            let inner = try parseTerm()
            _ = try expect(.rightParen, "')'")
            return inner
        case .identifier:
            break
        default:
            throw ParseError(message: "Expected a value, a variable or an attribute but found " +
                                      "'\(description)'.",
                             position: token.position)
        }

        advance()
        let upper = token.text.uppercased()
        if !token.quoted {
            if upper == "NULL" || upper == "TRUE" || upper == "FALSE" { return .literal(upper) }
            if ["DATE", "TIME", "TIMESTAMP"].contains(upper), current.kind == .string {
                return .literal(upper + " " + SQLPrinter.stringLiteral(advance().text))
            }
        }

        if current.kind == .leftParen {
            advance()
            var args: [CalcTerm] = []
            if current.kind != .rightParen {
                repeat {
                    if current.kind == .comma { advance() }
                    if current.kind == .ellipsis {
                        advance()
                        args.append(.opaque("…"))
                    } else {
                        args.append(try parseTerm())
                    }
                } while current.kind == .comma
            }
            _ = try expect(.rightParen, "')' closing the argument list")
            return .application(name: token.text, args: args, distinct: false)
        }
        if current.kind == .leftBrace {
            throw ParseError(message: "Aggregates such as \(token.text){ … } are not supported " +
                                      "in calculus input yet.",
                             position: token.position)
        }
        if current.kind == .dot {
            advance()
            let attribute = try expect(.identifier, "an attribute name after '.'").text
            return .attribute(CalcVar(name: token.text, relation: nil), attribute)
        }
        return .variable(CalcVar(name: token.text, relation: nil))
    }

    // MARK: Dialect

    /// TRC when attributes are reached by name, DRC when atoms are positional.
    /// A formula with neither — `{ t | R(t) }` — reads either way, and the
    /// editor's choice decides.
    static func dialect(of script: CalcScript, preferring preferred: CalcDialect) throws -> CalcDialect {
        var tuple = false
        var domain = false

        func visitTerm(_ term: CalcTerm) {
            switch term {
            case .attribute:
                tuple = true
            case let .application(_, args, _):
                args.forEach(visitTerm)
            case let .binaryOp(_, lhs, rhs):
                visitTerm(lhs); visitTerm(rhs)
            case .variable, .literal, .opaque:
                break
            }
        }
        func visitFormula(_ formula: CalcFormula) {
            switch formula {
            case let .relationAtom(_, terms, arityKnown):
                let positional = terms.count != 1 || !arityKnown
                    || terms.contains { if case .variable = $0 { return false } else { return true } }
                if positional { domain = true }
                terms.forEach(visitTerm)
            case let .comparison(lhs, _, rhs):
                visitTerm(lhs); visitTerm(rhs)
            case let .and(parts), let .or(parts):
                parts.forEach(visitFormula)
            case let .not(inner):
                visitFormula(inner)
            case let .exists(_, body), let .forAll(_, body):
                visitFormula(body)
            case let .implies(lhs, rhs):
                visitFormula(lhs); visitFormula(rhs)
            case let .predicate(_, terms):
                terms.forEach(visitTerm)
            case let .aggregateBinding(_, _, _, element, _, condition):
                if let element { visitTerm(element) }
                visitFormula(condition)
            case .constant:
                break
            }
        }
        func visitExpression(_ expression: CalcExpression) {
            switch expression {
            case let .query(query):
                query.result.forEach { visitTerm($0.term) }
                visitFormula(query.formula)
            case let .setOperation(_, left, right):
                visitExpression(left); visitExpression(right)
            }
        }

        script.definitions.forEach { visitExpression($0.expression) }
        visitExpression(script.expression)

        if tuple && domain {
            throw ParseError(message: "This mixes tuple calculus (t.attribute) with domain " +
                                      "calculus (positional atoms such as R(x, y)). Write it in " +
                                      "one or the other.",
                             position: 0)
        }
        if tuple { return .trc }
        if domain { return .drc }
        return preferred
    }
}

private extension CalcTokenKind {
    /// Whether this token could carry a term on — an operator after a closing
    /// bracket means the bracket held a term, not a formula.
    var continuesTerm: Bool {
        switch self {
        case .comparison, .arithmetic, .member: return true
        case .identifier: return false
        default: return false
        }
    }
}
