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

    /// Convenience: lex + parse a source string down to its query.
    static func parse(_ source: String) throws -> SQLQuery {
        try parseScript(source).query
    }

    /// Lex + parse a whole buffer: any number of `CREATE TABLE` statements
    /// followed by the query they describe. Declaring the tables is what lets
    /// the domain calculus write a positional atom with a trustworthy arity.
    static func parseScript(_ source: String) throws -> SQLScript {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ParseError(message: "Empty query.", position: 0)
        }
        let tokens = try Lexer(trimmed).tokenize()
        let parser = SQLParser(tokens: tokens)
        let declarations = try parser.parseTableDeclarations()
        let query = try parser.parseQuery()
        parser.consumeOptionalSemicolon()
        try parser.expectEnd()
        return SQLScript(declarations: declarations, query: query)
    }

    // MARK: - CREATE TABLE

    private func parseTableDeclarations() throws -> [TableDeclaration] {
        var declarations: [TableDeclaration] = []
        while checkIdentifierKeyword("CREATE") || checkKeyword("CREATE") {
            declarations.append(try parseTableDeclaration())
            consumeOptionalSemicolon()
        }
        return declarations
    }

    private func parseTableDeclaration() throws -> TableDeclaration {
        _ = advance() // CREATE
        guard matchIdentifierKeyword("TABLE") || matchKeyword("TABLE") else {
            throw ParseError(message: "Only CREATE TABLE is supported here.",
                             position: current.position)
        }
        // `IF NOT EXISTS` is noise for our purposes.
        if matchKeyword("IF") {
            _ = matchKeyword("NOT")
            _ = matchKeyword("EXISTS")
        }
        let name = try expect(kind: .identifier, "a table name").text
        _ = try expect(kind: .leftParen, "'(' after the table name")

        var columns: [String] = []
        repeat {
            if check(kind: .rightParen) { break }
            if let column = try parseColumnDefinition() {
                columns.append(column)
            }
        } while consumeCommaIfPresent()

        _ = try expect(kind: .rightParen, "')' closing the column list")
        return TableDeclaration(name: name, columns: columns)
    }

    /// One entry in a column list: a column definition, whose name we keep, or
    /// a table constraint, which names no column of its own. Types, defaults and
    /// inline constraints are skipped wholesale — only names and order matter.
    private func parseColumnDefinition() throws -> String? {
        let isConstraint = ["PRIMARY", "FOREIGN", "UNIQUE", "CHECK", "CONSTRAINT", "KEY", "INDEX"]
            .contains { checkIdentifierKeyword($0) || checkKeyword($0) }
        let name = isConstraint ? nil : (check(kind: .identifier) ? advance().text : nil)
        skipToEndOfColumnEntry()
        return name
    }

    /// Advance to the comma or `)` that ends this entry, stepping over nested
    /// parentheses so that `DECIMAL(10, 2)` and `REFERENCES D(id)` do not end it.
    private func skipToEndOfColumnEntry() {
        var depth = 0
        while !check(kind: .eof) {
            if depth == 0, check(kind: .comma) || check(kind: .rightParen) { return }
            if check(kind: .leftParen) { depth += 1 }
            if check(kind: .rightParen) { depth -= 1 }
            _ = advance()
        }
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

    /// Some SQL words are contextual (OVER, PARTITION, ROLLUP, FETCH, …). We
    /// keep them as ordinary identifiers and match them by spelling where the
    /// grammar expects them, so they remain usable as column names elsewhere.
    private func checkIdentifierKeyword(_ word: String) -> Bool {
        current.kind == .identifier && current.text.uppercased() == word
    }

    @discardableResult
    private func matchIdentifierKeyword(_ word: String) -> Bool {
        if checkIdentifierKeyword(word) { _ = advance(); return true }
        return false
    }

    private func peekKind(_ offset: Int) -> TokenKind {
        let i = index + offset
        return i < tokens.count ? tokens[i].kind : .eof
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
        if checkKeyword("WITH") {
            return try parseWith()
        }
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

    /// `WITH [RECURSIVE] name [(cols)] AS ( query ) [, …] <body>`
    private func parseWith() throws -> SQLQuery {
        _ = advance() // WITH
        _ = matchIdentifierKeyword("RECURSIVE")
        var ctes: [CommonTableExpression] = []
        repeat {
            let name = try expect(kind: .identifier, "a CTE name").text
            var columns: [String] = []
            if check(kind: .leftParen) {
                _ = advance()
                columns.append(try expect(kind: .identifier, "a column name").text)
                while consumeCommaIfPresent() {
                    columns.append(try expect(kind: .identifier, "a column name").text)
                }
                _ = try expect(kind: .rightParen, "')'")
            }
            try expectKeyword("AS")
            _ = try expect(kind: .leftParen, "'(' before the CTE query")
            let query = try parseQuery()
            _ = try expect(kind: .rightParen, "')'")
            ctes.append(CommonTableExpression(name: name, columns: columns, query: query))
        } while consumeCommaIfPresent()

        let body = try parseQuery()
        return .with(ctes: ctes, body: body)
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
            let (cols, modifier) = try parseGroupByList()
            stmt.groupBy = cols
            stmt.groupByModifier = modifier
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
            // Optional `LIMIT offset, count` or `OFFSET n` — consume leniently.
            if consumeCommaIfPresent(), check(kind: .number) { stmt.limit = Int(advance().text) }
        }
        if matchIdentifierKeyword("OFFSET") {
            if check(kind: .number) { _ = advance() }
            _ = matchIdentifierKeyword("ROWS") || matchIdentifierKeyword("ROW")
        }
        // `FETCH FIRST n ROWS ONLY`
        if matchIdentifierKeyword("FETCH") {
            _ = matchIdentifierKeyword("FIRST") || matchIdentifierKeyword("NEXT")
            if check(kind: .number) { stmt.limit = Int(advance().text) }
            _ = matchIdentifierKeyword("ROWS") || matchIdentifierKeyword("ROW")
            _ = matchIdentifierKeyword("ONLY")
        }

        return stmt
    }

    /// GROUP BY list, possibly `ROLLUP(...)`, `CUBE(...)`, or `GROUPING SETS(...)`.
    private func parseGroupByList() throws -> ([Expression], String?) {
        if matchIdentifierKeyword("ROLLUP") {
            return (try parseParenExpressionList(), "ROLLUP")
        }
        if matchIdentifierKeyword("CUBE") {
            return (try parseParenExpressionList(), "CUBE")
        }
        if checkIdentifierKeyword("GROUPING"), peekKind(1) == .identifier,
           tokens[index + 1].text.uppercased() == "SETS" {
            _ = advance() // GROUPING
            _ = advance() // SETS
            _ = try expect(kind: .leftParen, "'(' after GROUPING SETS")
            var all: [Expression] = []
            repeat {
                if check(kind: .leftParen) {
                    _ = advance()
                    if !check(kind: .rightParen) {
                        all.append(try parseExpression())
                        while consumeCommaIfPresent() { all.append(try parseExpression()) }
                    }
                    _ = try expect(kind: .rightParen, "')'")
                } else {
                    all.append(try parseExpression())
                }
            } while consumeCommaIfPresent()
            _ = try expect(kind: .rightParen, "')'")
            return (all, "GROUPING SETS")
        }
        return (try parseExpressionList(), nil)
    }

    private func parseParenExpressionList() throws -> [Expression] {
        _ = try expect(kind: .leftParen, "'('")
        var list: [Expression] = [try parseExpression()]
        while consumeCommaIfPresent() { list.append(try parseExpression()) }
        _ = try expect(kind: .rightParen, "')'")
        return list
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
            // Optional `NULLS FIRST` / `NULLS LAST` — accepted and ignored.
            if matchIdentifierKeyword("NULLS") {
                _ = matchIdentifierKeyword("FIRST") || matchIdentifierKeyword("LAST")
            }
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

        // Standard comparison operators, optionally quantified over a
        // sub-query: `x > ALL (…)`, `x > ANY (…)`, `x > SOME (…)`.
        if check(kind: .op), isComparisonOperator(current.text) {
            let op = advance().text
            if let quantifier = matchSubqueryQuantifier() {
                _ = try expect(kind: .leftParen, "'(' after \(quantifier.rawValue)")
                let sub = try parseQuery()
                _ = try expect(kind: .rightParen, "')'")
                return .quantifiedComparison(value: left, op: op,
                                             quantifier: quantifier, query: sub)
            }
            let right = try parseAdditive()
            return .binary(op: op, lhs: left, rhs: right)
        }

        return left
    }

    /// Consume `ALL`, `ANY` or `SOME` when it directly precedes a sub-query.
    /// `ALL` is a reserved word (`UNION ALL`); `ANY` and `SOME` are contextual,
    /// so they stay ordinary identifiers and are matched by spelling — that
    /// keeps them usable as column names everywhere else.
    private func matchSubqueryQuantifier() -> SubqueryQuantifier? {
        guard peekKind(1) == .leftParen else { return nil }
        if matchKeyword("ALL")            { return .all }
        if matchIdentifierKeyword("ANY")  { return .any }
        if matchIdentifierKeyword("SOME") { return .any }
        return nil
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
            if upper == "CASE" { return try parseCase() }
            if upper == "EXISTS" {
                _ = advance()
                _ = try expect(kind: .leftParen, "'(' after EXISTS")
                let sub = try parseQuery()
                _ = try expect(kind: .rightParen, "')'")
                return .exists(query: sub, negated: false)
            }
            if ["COUNT", "SUM", "AVG", "MIN", "MAX"].contains(upper) {
                let f = try parseFunctionCall(name: advance().text)
                return try maybeWindow(f)
            }
            throw ParseError(message: "Unexpected keyword '\(current.text)' in expression.",
                             position: current.position)
        case .identifier:
            let upper = current.text.uppercased()
            // Typed literals: DATE '…', TIMESTAMP '…', TIME '…'
            if ["DATE", "TIMESTAMP", "TIME"].contains(upper), peekKind(1) == .string {
                _ = advance()
                let value = advance().text
                return .typedLiteral(type: upper, value: value)
            }
            // INTERVAL '90' DAY (or INTERVAL 90 DAY)
            if upper == "INTERVAL", peekKind(1) == .string || peekKind(1) == .number {
                _ = advance()
                let value = advance().text
                var unit = ""
                if check(kind: .identifier) { unit = advance().text }
                return .interval(value: value, unit: unit)
            }
            // CAST(expr AS type)
            if upper == "CAST", peekKind(1) == .leftParen {
                return try parseCastExpression()
            }

            let name = advance().text
            // Function call: name(...), possibly a window function.
            if check(kind: .leftParen) {
                let f = try parseFunctionCall(name: name, alreadyConsumedName: true)
                return try maybeWindow(f)
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

    /// `CASE [operand] WHEN cond THEN result … [ELSE result] END`
    private func parseCase() throws -> Expression {
        _ = advance() // CASE
        var operand: Expression? = nil
        if !checkKeyword("WHEN") {
            operand = try parseExpression() // simple CASE form
        }
        var clauses: [WhenClause] = []
        while matchKeyword("WHEN") {
            let condition = try parseExpression()
            try expectKeyword("THEN")
            let result = try parseExpression()
            clauses.append(WhenClause(condition: condition, result: result))
        }
        var elseResult: Expression? = nil
        if matchKeyword("ELSE") {
            elseResult = try parseExpression()
        }
        try expectKeyword("END")
        return .caseExpression(operand: operand, cases: clauses, elseResult: elseResult)
    }

    /// `CAST ( expr AS type )` — the CAST identifier is current on entry.
    private func parseCastExpression() throws -> Expression {
        _ = advance() // CAST
        _ = try expect(kind: .leftParen, "'(' after CAST")
        let expression = try parseExpression()
        try expectKeyword("AS")
        let type = try parseTypeName()
        _ = try expect(kind: .rightParen, "')'")
        return .cast(expression: expression, type: type)
    }

    /// A (possibly parameterised) SQL type name, e.g. `decimal(15, 2)`,
    /// `varchar(20)`, `double precision`, `date`.
    private func parseTypeName() throws -> String {
        guard current.kind == .identifier || current.kind == .keyword else {
            throw ParseError(message: "Expected a type name but found '\(currentDescription)'.",
                             position: current.position)
        }
        var name = advance().text
        // Multi-word type names (e.g. "double precision").
        while check(kind: .identifier) {
            name += " " + advance().text
        }
        // Parameters: (p) or (p, s).
        if check(kind: .leftParen) {
            _ = advance()
            var params: [String] = []
            if check(kind: .number) { params.append(advance().text) }
            while consumeCommaIfPresent() {
                if check(kind: .number) { params.append(advance().text) }
            }
            _ = try expect(kind: .rightParen, "')'")
            name += "(\(params.joined(separator: ", ")))"
        }
        return name
    }

    /// If the just-parsed function is followed by `OVER (…)`, wrap it as a
    /// window function; otherwise return it unchanged.
    private func maybeWindow(_ function: Expression) throws -> Expression {
        guard checkIdentifierKeyword("OVER") else { return function }
        _ = advance() // OVER
        _ = try expect(kind: .leftParen, "'(' after OVER")

        var partitionBy: [Expression] = []
        if matchIdentifierKeyword("PARTITION") {
            try expectKeyword("BY")
            partitionBy = try parseExpressionList()
        }

        var orderBy: [OrderItem] = []
        if matchKeyword("ORDER") {
            try expectKeyword("BY")
            orderBy = try parseOrderList()
        }

        // Frame clause (ROWS/RANGE BETWEEN …): captured verbatim.
        var frame: String? = nil
        if !check(kind: .rightParen) {
            var raw = ""
            while !check(kind: .rightParen) && !check(kind: .eof) {
                raw += (raw.isEmpty ? "" : " ") + advance().text
            }
            frame = raw.isEmpty ? nil : raw
        }
        _ = try expect(kind: .rightParen, "')'")
        return .window(function: function, partitionBy: partitionBy, orderBy: orderBy, frame: frame)
    }

    private func peekKeyword(offset: Int, _ word: String) -> Bool {
        let i = index + offset
        guard i < tokens.count else { return false }
        return tokens[i].kind == .keyword && tokens[i].text.uppercased() == word
    }
}
