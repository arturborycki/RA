//
//  SQLPrinter.swift
//  RelationalAlgebra
//
//  Prints a `SQLQuery` as formatted SQL text.
//
//  The app never needed this going forwards — it only ever read SQL — but every
//  translation *into* SQL ends here. The output is meant to be pasted into
//  DuckDB or DataFusion and run, so it sticks to syntax both accept:
//
//    · one clause per line; derived tables and WITH bodies indented;
//    · parentheses only where precedence needs them, so a tree built without
//      `.paren` nodes still prints correctly;
//    · identifiers quoted only when they would not otherwise read as one.
//
//  Whatever this prints, `SQLParser` must parse back to a query that prints the
//  same way — the tests hold it to that over every sample.
//

import Foundation

struct SQLPrinter {
    var indentUnit = "  "

    /// The whole query, ending in a semicolon.
    func print(_ query: SQLQuery) -> String {
        lines(query).joined(separator: "\n") + ";"
    }

    // MARK: - Queries

    private func indent(_ lines: [String]) -> [String] {
        lines.map { indentUnit + $0 }
    }

    func lines(_ query: SQLQuery) -> [String] {
        switch query {
        case let .select(stmt):
            return lines(stmt)

        case let .setOperation(op, left, right, all):
            let keyword = op.rawValue + (all ? " ALL" : "")
            return operandLines(left, parentOp: op, isLeft: true)
                + [keyword]
                + operandLines(right, parentOp: op, isLeft: false)

        case let .with(ctes, body):
            let recursive = ctes.contains { $0.isRecursive } ? "RECURSIVE " : ""
            var out: [String] = []
            for (i, cte) in ctes.enumerated() {
                let columns = cte.columns.isEmpty
                    ? "" : "(" + cte.columns.map(identifier).joined(separator: ", ") + ")"
                let head = (i == 0 ? "WITH \(recursive)" : "") + identifier(cte.name) + columns + " AS ("
                out.append(head)
                out += indent(lines(cte.query))
                out.append(i == ctes.count - 1 ? ")" : "),")
            }
            return out + lines(body)
        }
    }

    /// An operand of a set operation, parenthesised unless it reads the same
    /// without: a plain SELECT, or a left operand of the same operator, which
    /// is how a left-associative chain is written.
    private func operandLines(_ query: SQLQuery, parentOp: SetOperator, isLeft: Bool) -> [String] {
        switch query {
        case .select:
            return lines(query)
        case let .setOperation(op, _, _, _) where isLeft && op == parentOp:
            return lines(query)
        default:
            return ["("] + indent(lines(query)) + [")"]
        }
    }

    private func lines(_ stmt: SelectStatement) -> [String] {
        var out: [String] = []
        let items = stmt.projections.map(selectItem).joined(separator: ", ")
        out.append("SELECT " + (stmt.distinct ? "DISTINCT " : "") + items)

        if !stmt.from.isEmpty {
            out += prefixed("FROM ", tableList(stmt.from))
        }
        for join in stmt.joins {
            out += joinLines(join)
        }
        if let condition = stmt.whereClause {
            let conjuncts = SQLPrinter.conjuncts(condition)
            out.append("WHERE " + expression(conjuncts[0], minimum: Precedence.and))
            for conjunct in conjuncts.dropFirst() {
                out.append(indentUnit + "AND " + expression(conjunct, minimum: Precedence.and))
            }
        }
        if !stmt.groupBy.isEmpty {
            let keys = stmt.groupBy.map { expression($0) }.joined(separator: ", ")
            if let modifier = stmt.groupByModifier {
                out.append("GROUP BY \(modifier) (\(keys))")
            } else {
                out.append("GROUP BY " + keys)
            }
        }
        if let having = stmt.having {
            out.append("HAVING " + expression(having))
        }
        if !stmt.orderBy.isEmpty {
            out.append("ORDER BY " + stmt.orderBy.map(orderItem).joined(separator: ", "))
        }
        if let limit = stmt.limit {
            out.append("LIMIT \(limit)")
        }
        if let offset = stmt.offset {
            out.append("OFFSET \(offset)")
        }
        return out
    }

    /// `head` glued onto the first line of a block of lines.
    private func prefixed(_ head: String, _ block: [String]) -> [String] {
        guard let first = block.first else { return [head] }
        return [head + first] + block.dropFirst()
    }

    /// Comma-separated FROM entries. A derived table spans several lines, so
    /// the list is built line-wise rather than joined.
    private func tableList(_ refs: [TableRef]) -> [String] {
        var out: [String] = []
        for (i, ref) in refs.enumerated() {
            var block = tableRef(ref)
            if i < refs.count - 1 { block[block.count - 1] += "," }
            if out.isEmpty {
                out = block
            } else {
                // Continue on the last line when it is short, as `FROM a, b`.
                let last = out.removeLast()
                out += prefixed(last + " ", block)
            }
        }
        return out
    }

    private func tableRef(_ ref: TableRef) -> [String] {
        switch ref {
        case let .named(name, alias):
            return [identifier(name) + (alias.map { " AS " + identifier($0) } ?? "")]
        case let .derived(query, alias):
            let tail = ")" + (alias.map { " AS " + identifier($0) } ?? "")
            return ["("] + indent(lines(query)) + [tail]
        }
    }

    private func joinLines(_ join: Join) -> [String] {
        var keyword: String
        switch join.kind {
        case .inner: keyword = "JOIN"
        case .left:  keyword = "LEFT JOIN"
        case .right: keyword = "RIGHT JOIN"
        case .full:  keyword = "FULL JOIN"
        case .cross: keyword = "CROSS JOIN"
        }
        if join.natural { keyword = "NATURAL " + keyword }

        var block = prefixed(keyword + " ", tableRef(join.table))
        if let on = join.on {
            block[block.count - 1] += " ON " + expression(on)
        } else if !join.using.isEmpty {
            block[block.count - 1] += " USING (" + join.using.map(identifier).joined(separator: ", ") + ")"
        }
        return block
    }

    private func selectItem(_ item: SelectItem) -> String {
        switch item {
        case .star:
            return "*"
        case let .qualifiedStar(table):
            return identifier(table) + ".*"
        case let .expression(expr, alias):
            return expression(expr) + (alias.map { " AS " + identifier($0) } ?? "")
        }
    }

    private func orderItem(_ item: OrderItem) -> String {
        var text = expression(item.expression)
        if item.descending { text += " DESC" }
        if let nullsFirst = item.nullsFirst { text += nullsFirst ? " NULLS FIRST" : " NULLS LAST" }
        return text
    }

    /// A sub-query inside an expression, on one line — `x IN (SELECT …)`.
    private func inline(_ query: SQLQuery) -> String {
        lines(query).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
    }

    // MARK: - Expressions

    /// Binding strength, loosest first.
    enum Precedence {
        static let or = 1
        static let and = 2
        static let not = 3
        static let comparison = 4
        static let additive = 5
        static let multiplicative = 6
        static let unary = 7
        static let primary = 8
    }

    private static func precedence(ofBinary op: String) -> Int {
        switch op.uppercased() {
        case "OR":                          return Precedence.or
        case "AND":                         return Precedence.and
        case "+", "-", "||":                return Precedence.additive
        case "*", "/", "%":                 return Precedence.multiplicative
        default:                            return Precedence.comparison // = < LIKE …
        }
    }

    private static func precedence(of expr: Expression) -> Int {
        switch expr {
        case let .binary(op, _, _):
            return precedence(ofBinary: op)
        case let .unary(op, _):
            return op.uppercased() == "NOT" ? Precedence.not : Precedence.unary
        case .between, .inList, .inSubquery, .quantifiedComparison, .isNull:
            return Precedence.comparison
        case let .exists(_, negated):
            return negated ? Precedence.not : Precedence.primary
        default:
            return Precedence.primary
        }
    }

    /// The top-level conjuncts of an AND chain, so WHERE can put one per line.
    static func conjuncts(_ expr: Expression) -> [Expression] {
        if case let .binary(op, lhs, rhs) = expr, op.uppercased() == "AND" {
            return conjuncts(lhs) + conjuncts(rhs)
        }
        return [expr]
    }

    /// `expr`, parenthesised if it binds more loosely than `minimum` requires.
    func expression(_ expr: Expression, minimum: Int = 0) -> String {
        let text = bare(expr)
        return SQLPrinter.precedence(of: expr) < minimum ? "(" + text + ")" : text
    }

    private func bare(_ expr: Expression) -> String {
        switch expr {
        case let .column(table, name):
            let column = name == "*" ? "*" : identifier(name)
            return table.map { identifier($0) + "." + column } ?? column
        case let .numberLiteral(value):
            return value
        case let .stringLiteral(value):
            return SQLPrinter.stringLiteral(value)
        case let .boolLiteral(value):
            return value ? "TRUE" : "FALSE"
        case .nullLiteral:
            return "NULL"
        case .star:
            return "*"

        case let .binary(op, lhs, rhs):
            let p = SQLPrinter.precedence(ofBinary: op)
            // AND and OR are associative; every other operator here is either
            // left-associative or not associative at all, so a right operand
            // of equal strength needs parentheses: a - (b - c).
            let associative = p == Precedence.and || p == Precedence.or
            let rightMinimum = associative ? p : p + 1
            let leftMinimum = p == Precedence.comparison ? p + 1 : p
            return expression(lhs, minimum: leftMinimum) + " \(op) "
                + expression(rhs, minimum: rightMinimum)

        case let .unary(op, operand):
            if op.uppercased() == "NOT" {
                return "NOT " + expression(operand, minimum: Precedence.not)
            }
            return op + expression(operand, minimum: Precedence.unary)

        case let .function(name, args, distinct):
            let inner = args.map { expression($0) }.joined(separator: ", ")
            return "\(name)(\(distinct ? "DISTINCT " : "")\(inner))"

        case let .between(value, lower, upper, negated):
            let operand = Precedence.additive
            return expression(value, minimum: operand) + (negated ? " NOT BETWEEN " : " BETWEEN ")
                + expression(lower, minimum: operand) + " AND " + expression(upper, minimum: operand)

        case let .inList(value, list, negated):
            return expression(value, minimum: Precedence.additive) + (negated ? " NOT IN (" : " IN (")
                + list.map { expression($0) }.joined(separator: ", ") + ")"

        case let .inSubquery(value, query, negated):
            return expression(value, minimum: Precedence.additive) + (negated ? " NOT IN (" : " IN (")
                + inline(query) + ")"

        case let .quantifiedComparison(value, op, quantifier, query):
            return expression(value, minimum: Precedence.additive)
                + " \(op) \(quantifier.rawValue) (" + inline(query) + ")"

        case let .exists(query, negated):
            return (negated ? "NOT " : "") + "EXISTS (" + inline(query) + ")"

        case let .isNull(inner, negated):
            return expression(inner, minimum: Precedence.additive) + (negated ? " IS NOT NULL" : " IS NULL")

        case let .list(items):
            return items.map { expression($0) }.joined(separator: ", ")

        case let .subquery(query):
            return "(" + inline(query) + ")"

        case let .paren(inner):
            return "(" + expression(inner) + ")"

        case let .caseExpression(operand, cases, elseResult):
            var text = "CASE"
            if let operand { text += " " + expression(operand) }
            for clause in cases {
                text += " WHEN " + expression(clause.condition) + " THEN " + expression(clause.result)
            }
            if let elseResult { text += " ELSE " + expression(elseResult) }
            return text + " END"

        case let .cast(inner, type):
            return "CAST(" + expression(inner) + " AS \(type))"

        case let .window(function, partitionBy, orderBy, frame):
            var parts: [String] = []
            if !partitionBy.isEmpty {
                parts.append("PARTITION BY " + partitionBy.map { expression($0) }.joined(separator: ", "))
            }
            if !orderBy.isEmpty {
                parts.append("ORDER BY " + orderBy.map(orderItem).joined(separator: ", "))
            }
            if let frame { parts.append(frame) }
            return expression(function) + " OVER (" + parts.joined(separator: " ") + ")"

        case let .typedLiteral(type, value):
            return "\(type) " + SQLPrinter.stringLiteral(value)

        case let .interval(value, unit):
            let literal = "INTERVAL " + SQLPrinter.stringLiteral(value)
            return unit.isEmpty ? literal : literal + " " + unit
        }
    }

    // MARK: - Lexical

    static func stringLiteral(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    /// A name as SQL must spell it: bare when it is an ordinary identifier,
    /// double-quoted when it is a reserved word or holds anything unusual.
    func identifier(_ name: String) -> String {
        let isPlain = name.first.map { $0.isASCII && ($0.isLetter || $0 == "_") } ?? false
            && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
        if isPlain && !SQLKeyword.all.contains(name.uppercased()) {
            return name
        }
        return "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
