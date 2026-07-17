//
//  SQLParser.swift
//  RelationalAlgebra
//
//  A small recursive-descent parser for the SELECT subset of SQL. It produces
//  a `SQLQuery` AST. Precedence climbing is used for boolean / comparison /
//  arithmetic expressions.
//

import Foundation

struct ParseError: Error, LocalizedError {
    let message: String
    let position: Int
    var errorDescription: String? { message }
}

final class SQLParser {
    private let tokens: [Token]
    private var index = 0

    init(tokens: [Token]) {
        self.tokens = tokens
    }

    /// Convenience: lex + parse a source string.
    static func parse(_ source: String) throws -> SQLQuery {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ParseError(message: "Empty query.", position: 0)
        }
        let tokens = try Lexer(trimmed).tokenize()
        let parser = SQLParser(tokens: tokens)
        let query = try parser.parseQuery()
        parser.consumeOptionalSemicolon()
        try parser.expectEnd()
        return query
    }

    // MARK: - Token cursor

    private var current: Token { tokens[index] }

    private func advance() -> Token {
        let t = tokens[index]
        if index < tokens.count - 1 { index += 1 }
        return t
    }

    private func check(kind: TokenKind) -> Bool { current.kind == kind }

    private func checkKeyword(_ word: String) -> Bool {
        current.kind == .keyword && current.text.uppercased() == word
    }

    @discardableResult
    private func matchKeyword(_ word: String) -> Bool {
        if checkKeyword(word) { _ = advance(); return true }
        return false
    }

    private func expectKeyword(_ word: String) throws {
        guard matchKeyword(word) else {
            throw ParseError(message: "Expected '\(word)' but found '\(currentDescription)'.",
                             position: current.position)
        }
    }

    private func expect(kind: TokenKind, _ label: String) throws -> Token {
        guard current.kind == kind else {
            throw ParseError(message: "Expected \(label) but found '\(currentDescription)'.",
                             position: current.position)
        }
        return advance()
    }

    private var currentDescription: String {
        current.kind == .eof ? "end of input" : current.text
    }

    private func consumeOptionalSemicolon() {
        if check(kind: .semicolon) { _ = advance() }
    }

    private func expectEnd() throws {
        guard check(kind: .eof) else {
            throw ParseError(message: "Unexpected trailing input: '\(currentDescription)'.",
                             position: current.position)
        }
    }

    // MARK: - Query (handles set operators)

    func parseQuery() throws -> SQLQuery {
        var left = try parseSelectAsQuery()
        while checkKeyword("UNION") || checkKeyword("INTERSECT") || checkKeyword("EXCEPT") {
            let opText = advance().text.uppercased()
            let all = matchKeyword("ALL")
            let right = try parseSelectAsQuery()
            let op = SetOperator(rawValue: opText)!
            left = .setOperation(op, left: left, right: right, all: all)
        }
        return left
    }

    private func parseSelectAsQuery() throws -> SQLQuery {
        // Allow a parenthesised query: ( SELECT ... )
        if check(kind: .leftParen) {
            let save = index
            _ = advance()
            if checkKeyword("SELECT") {
                let inner = try parseQuery()
                _ = try expect(kind: .rightParen, "')'")
                return inner
            }
            index = save
        }
        return .select(try parseSelect())
    }

    // MARK: - SELECT block

    private func parseSelect() throws -> SelectStatement {
        try expectKeyword("SELECT")
        var stmt = SelectStatement()

        if matchKeyword("DISTINCT") {
            stmt.distinct = true
        } else {
            _ = matchKeyword("ALL")
        }

        stmt.projections = try parseSelectList()

        try expectKeyword("FROM")
        stmt.from = [try parseTableRef()]
        // Comma-separated tables become cross products (implicit joins).
        while check(kind: .comma) {
            _ = advance()
            stmt.from.append(try parseTableRef())
        }

        stmt.joins = try parseJoins()

        if matchKeyword("WHERE") {
            stmt.whereClause = try parseExpression()
        }

        if matchKeyword("GROUP") {
            try expectKeyword("BY")
            stmt.groupBy = try parseExpressionList()
            if matchKeyword("HAVING") {
                stmt.having = try parseExpression()
            }
        }

        if matchKeyword("ORDER") {
            try expectKeyword("BY")
            stmt.orderBy = try parseOrderList()
        }

        if matchKeyword("LIMIT") {
            let tok = try expect(kind: .number, "a number after LIMIT")
            stmt.limit = Int(tok.text)
        }

        return stmt
    }

    private func parseSelectList() throws -> [SelectItem] {
        var items: [SelectItem] = []
        items.append(try parseSelectItem())
        while check(kind: .comma) {
            _ = advance()
            items.append(try parseSelectItem())
        }
        return items
    }

    private func parseSelectItem() throws -> SelectItem {
        // `*`
        if check(kind: .star) {
            _ = advance()
            return .star
        }
        // `table.*`
        if check(kind: .identifier), tokens[index + 1].kind == .dot, tokens[index + 2].kind == .star {
            let table = advance().text
            _ = advance() // dot
            _ = advance() // star
            return .qualifiedStar(table)
        }

        let expr = try parseExpression()
        var alias: String? = nil
        if matchKeyword("AS") {
            alias = try expect(kind: .identifier, "an alias name").text
        } else if check(kind: .identifier) {
            // Implicit alias: SELECT price total
            alias = advance().text
        }
        return .expression(expr, alias: alias)
    }

    // MARK: - FROM / JOIN

    private func parseTableRef() throws -> TableRef {
        // Derived table: ( SELECT ... ) alias
        if check(kind: .leftParen) {
            _ = advance()
            let sub = try parseQuery()
            _ = try expect(kind: .rightParen, "')'")
            let alias = try parseOptionalAlias()
            return .derived(sub, alias: alias)
        }
        let name = try expect(kind: .identifier, "a table name").text
        let alias = try parseOptionalAlias()
        return .named(name: name, alias: alias)
    }

    private func parseOptionalAlias() throws -> String? {
        if matchKeyword("AS") {
            return try expect(kind: .identifier, "an alias name").text
        }
        if check(kind: .identifier) {
            return advance().text
        }
        return nil
    }

    private func parseJoins() throws -> [Join] {
        var joins: [Join] = []
        while true {
            let kind: JoinKind
            if matchKeyword("CROSS") {
                try expectKeyword("JOIN")
                kind = .cross
            } else if matchKeyword("INNER") {
                try expectKeyword("JOIN")
                kind = .inner
            } else if matchKeyword("LEFT") {
                _ = matchKeyword("OUTER")
                try expectKeyword("JOIN")
                kind = .left
            } else if matchKeyword("RIGHT") {
                _ = matchKeyword("OUTER")
                try expectKeyword("JOIN")
                kind = .right
            } else if matchKeyword("FULL") {
                _ = matchKeyword("OUTER")
                try expectKeyword("JOIN")
                kind = .full
            } else if matchKeyword("JOIN") {
                kind = .inner
            } else {
                break
            }

            let table = try parseTableRef()
            var on: Expression? = nil
            var using: [String] = []
            if matchKeyword("ON") {
                on = try parseExpression()
            } else if matchKeyword("USING") {
                _ = try expect(kind: .leftParen, "'('")
                using.append(try expect(kind: .identifier, "a column name").text)
                while check(kind: .comma) {
                    _ = advance()
                    using.append(try expect(kind: .identifier, "a column name").text)
                }
                _ = try expect(kind: .rightParen, "')'")
            }
            joins.append(Join(kind: kind, table: table, on: on, using: using))
        }
        return joins
    }

    private func parseOrderList() throws -> [OrderItem] {
        var items: [OrderItem] = []
        repeat {
            let expr = try parseExpression()
            var descending = false
            if matchKeyword("DESC") { descending = true }
            else { _ = matchKeyword("ASC") }
            items.append(OrderItem(expression: expr, descending: descending))
        } while consumeCommaIfPresent()
        return items
    }

    private func consumeCommaIfPresent() -> Bool {
        if check(kind: .comma) { _ = advance(); return true }
        return false
    }

    private func parseExpressionList() throws -> [Expression] {
        var list: [Expression] = [try parseExpression()]
        while consumeCommaIfPresent() {
            list.append(try parseExpression())
        }
        return list
    }

    // MARK: - Expressions (precedence climbing)

    func parseExpression() throws -> Expression {
        try parseOr()
    }

    private func parseOr() throws -> Expression {
        var left = try parseAnd()
        while matchKeyword("OR") {
            let right = try parseAnd()
            left = .binary(op: "OR", lhs: left, rhs: right)
        }
        return left
    }

    private func parseAnd() throws -> Expression {
        var left = try parseNot()
        while matchKeyword("AND") {
            let right = try parseNot()
            left = .binary(op: "AND", lhs: left, rhs: right)
        }
        return left
    }

    private func parseNot() throws -> Expression {
        if matchKeyword("NOT") {
            let operand = try parseNot()
            return .unary(op: "NOT", operand: operand)
        }
        return try parseComparison()
    }

    private func parseComparison() throws -> Expression {
        let left = try parseAdditive()

        // IS [NOT] NULL
        if checkKeyword("IS") {
            _ = advance()
            let negated = matchKeyword("NOT")
            try expectKeyword("NULL")
            return .isNull(left, negated: negated)
        }

        // [NOT] BETWEEN lo AND hi
        // [NOT] IN (...)
        // [NOT] LIKE pattern
        var negated = false
        if checkKeyword("NOT") &&
            (peekKeyword(offset: 1, "BETWEEN") || peekKeyword(offset: 1, "IN") || peekKeyword(offset: 1, "LIKE")) {
            _ = advance()
            negated = true
        }

        if matchKeyword("BETWEEN") {
            let lower = try parseAdditive()
            try expectKeyword("AND")
            let upper = try parseAdditive()
            return .between(value: left, lower: lower, upper: upper, negated: negated)
        }

        if matchKeyword("IN") {
            _ = try expect(kind: .leftParen, "'(' after IN")
            if checkKeyword("SELECT") || (check(kind: .leftParen)) {
                let sub = try parseQuery()
                _ = try expect(kind: .rightParen, "')'")
                return .inSubquery(value: left, query: sub, negated: negated)
            }
            var list: [Expression] = [try parseExpression()]
            while consumeCommaIfPresent() { list.append(try parseExpression()) }
            _ = try expect(kind: .rightParen, "')'")
            return .inList(value: left, list: list, negated: negated)
        }

        if matchKeyword("LIKE") {
            let pattern = try parseAdditive()
            let op = negated ? "NOT LIKE" : "LIKE"
            return .binary(op: op, lhs: left, rhs: pattern)
        }

        // Standard comparison operators.
        if check(kind: .op), isComparisonOperator(current.text) {
            let op = advance().text
            let right = try parseAdditive()
            return .binary(op: op, lhs: left, rhs: right)
        }

        return left
    }

    private func isComparisonOperator(_ s: String) -> Bool {
        ["=", "<>", "!=", "<", ">", "<=", ">="].contains(s)
    }

    private func parseAdditive() throws -> Expression {
        var left = try parseMultiplicative()
        while check(kind: .op), ["+", "-", "||"].contains(current.text) {
            let op = advance().text
            let right = try parseMultiplicative()
            left = .binary(op: op, lhs: left, rhs: right)
        }
        return left
    }

    private func parseMultiplicative() throws -> Expression {
        var left = try parseUnary()
        while (check(kind: .star)) || (check(kind: .op) && ["/", "%"].contains(current.text)) {
            let op = check(kind: .star) ? "*" : current.text
            _ = advance()
            let right = try parseUnary()
            left = .binary(op: op, lhs: left, rhs: right)
        }
        return left
    }

    private func parseUnary() throws -> Expression {
        if check(kind: .op), current.text == "-" {
            _ = advance()
            let operand = try parseUnary()
            return .unary(op: "-", operand: operand)
        }
        if check(kind: .op), current.text == "+" {
            _ = advance()
            return try parseUnary()
        }
        return try parsePrimary()
    }

    private func parsePrimary() throws -> Expression {
        // Parenthesised expression or subquery.
        if check(kind: .leftParen) {
            _ = advance()
            if checkKeyword("SELECT") {
                let sub = try parseQuery()
                _ = try expect(kind: .rightParen, "')'")
                return .subquery(sub)
            }
            let inner = try parseExpression()
            _ = try expect(kind: .rightParen, "')'")
            return .paren(inner)
        }

        switch current.kind {
        case .number:
            return .numberLiteral(advance().text)
        case .string:
            return .stringLiteral(advance().text)
        case .star:
            _ = advance()
            return .star
        case .keyword:
            let upper = current.text.uppercased()
            if upper == "TRUE" { _ = advance(); return .boolLiteral(true) }
            if upper == "FALSE" { _ = advance(); return .boolLiteral(false) }
            if upper == "NULL" { _ = advance(); return .nullLiteral }
            if upper == "EXISTS" {
                _ = advance()
                _ = try expect(kind: .leftParen, "'(' after EXISTS")
                let sub = try parseQuery()
                _ = try expect(kind: .rightParen, "')'")
                return .exists(query: sub, negated: false)
            }
            if ["COUNT", "SUM", "AVG", "MIN", "MAX"].contains(upper) {
                return try parseFunctionCall(name: advance().text)
            }
            throw ParseError(message: "Unexpected keyword '\(current.text)' in expression.",
                             position: current.position)
        case .identifier:
            let name = advance().text
            // Function call: name(...)
            if check(kind: .leftParen) {
                return try parseFunctionCall(name: name, alreadyConsumedName: true)
            }
            // Qualified column: table.column
            if check(kind: .dot) {
                _ = advance()
                if check(kind: .star) {
                    _ = advance()
                    return .column(table: name, name: "*")
                }
                let col = try expect(kind: .identifier, "a column name after '.'").text
                return .column(table: name, name: col)
            }
            return .column(table: nil, name: name)
        default:
            throw ParseError(message: "Unexpected token '\(currentDescription)' in expression.",
                             position: current.position)
        }
    }

    /// Parses `name ( [DISTINCT] args )`. When called from the keyword branch
    /// the name has been consumed and the `(` is current.
    private func parseFunctionCall(name: String, alreadyConsumedName: Bool = false) throws -> Expression {
        _ = try expect(kind: .leftParen, "'(' after function name")
        let distinct = matchKeyword("DISTINCT")
        var args: [Expression] = []
        if check(kind: .star) {
            _ = advance()
            args = [.star]
        } else if !check(kind: .rightParen) {
            args.append(try parseExpression())
            // Accept comma-separated args, and also the SQL `FROM` / `FOR`
            // separators used by SUBSTRING / TRIM / EXTRACT-style functions,
            // e.g. SUBSTRING(c_phone FROM 1 FOR 2).
            while true {
                if consumeCommaIfPresent() {
                    args.append(try parseExpression())
                } else if checkKeyword("FROM") || checkKeyword("FOR") {
                    _ = advance()
                    args.append(try parseExpression())
                } else {
                    break
                }
            }
        }
        _ = try expect(kind: .rightParen, "')'")
        return .function(name: name.uppercased(), args: args, distinct: distinct)
    }

    private func peekKeyword(offset: Int, _ word: String) -> Bool {
        let i = index + offset
        guard i < tokens.count else { return false }
        return tokens[i].kind == .keyword && tokens[i].text.uppercased() == word
    }
}
