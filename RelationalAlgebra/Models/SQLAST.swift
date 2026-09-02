//
//  SQLAST.swift
//  RelationalAlgebra
//
//  Abstract syntax tree produced by the SQL parser. The tree is deliberately
//  small — it covers the SELECT surface of SQL that maps cleanly onto the
//  classical relational-algebra operators (selection, projection, joins,
//  grouping, set operations, sort and duplicate elimination).
//

import Foundation

/// A parsed SQL query. A query is either a single `SELECT` block or two blocks
/// combined with a set operator (`UNION`, `INTERSECT`, `EXCEPT`).
indirect enum SQLQuery: Equatable {
    case select(SelectStatement)
    case setOperation(SetOperator, left: SQLQuery, right: SQLQuery, all: Bool)
    /// `WITH cte1 AS (…), cte2 AS (…) <body>` — common table expressions.
    case with(ctes: [CommonTableExpression], body: SQLQuery)
}

/// A single named sub-query in a `WITH` clause.
struct CommonTableExpression: Equatable {
    var name: String
    var columns: [String]
    var query: SQLQuery
}

enum SetOperator: String, Equatable {
    case union = "UNION"
    case intersect = "INTERSECT"
    case except = "EXCEPT"
}

/// A single `SELECT ... FROM ...` block.
struct SelectStatement: Equatable {
    var distinct: Bool = false
    var projections: [SelectItem] = []
    var from: [TableRef] = []
    var joins: [Join] = []
    var whereClause: Expression? = nil
    var groupBy: [Expression] = []
    /// `ROLLUP` / `CUBE` / `GROUPING SETS`, when the GROUP BY uses one.
    var groupByModifier: String? = nil
    var having: Expression? = nil
    var orderBy: [OrderItem] = []
    var limit: Int? = nil
}

/// One entry in the `SELECT` list.
enum SelectItem: Equatable {
    /// `SELECT *`
    case star
    /// `SELECT table.*`
    case qualifiedStar(String)
    /// `SELECT expr [AS alias]`
    case expression(Expression, alias: String?)
}

/// A table reference appearing in `FROM` or a `JOIN`.
indirect enum TableRef: Equatable {
    case named(name: String, alias: String?)
    case derived(SQLQuery, alias: String?)
}

enum JoinKind: String, Equatable {
    case inner = "INNER"
    case left = "LEFT"
    case right = "RIGHT"
    case full = "FULL"
    case cross = "CROSS"
}

struct Join: Equatable {
    var kind: JoinKind
    var table: TableRef
    /// `ON` predicate. `nil` for `CROSS JOIN` or a natural/comma join.
    var on: Expression?
    /// `USING (a, b)` column list, when present.
    var using: [String]
}

struct OrderItem: Equatable {
    var expression: Expression
    var descending: Bool
}

/// A scalar / boolean expression. Kept intentionally generic — the translator
/// pretty-prints expressions back to (near) SQL for use inside σ / θ conditions.
indirect enum Expression: Equatable {
    case column(table: String?, name: String)
    case numberLiteral(String)
    case stringLiteral(String)
    case boolLiteral(Bool)
    case nullLiteral
    case star
    case binary(op: String, lhs: Expression, rhs: Expression)
    case unary(op: String, operand: Expression)
    case function(name: String, args: [Expression], distinct: Bool)
    case between(value: Expression, lower: Expression, upper: Expression, negated: Bool)
    case inList(value: Expression, list: [Expression], negated: Bool)
    case inSubquery(value: Expression, query: SQLQuery, negated: Bool)
    /// `x > ALL (…)` / `x > ANY (…)`. These lower directly to ∀ and ∃, which is
    /// most of why they are worth parsing at all.
    case quantifiedComparison(value: Expression, op: String,
                              quantifier: SubqueryQuantifier, query: SQLQuery)
    case exists(query: SQLQuery, negated: Bool)
    case isNull(Expression, negated: Bool)
    case list([Expression])
    case subquery(SQLQuery)
    case paren(Expression)
    /// `CASE [operand] WHEN … THEN … [ELSE …] END`
    case caseExpression(operand: Expression?, cases: [WhenClause], elseResult: Expression?)
    /// `CAST(expr AS type)`
    case cast(expression: Expression, type: String)
    /// A window function: `func(args) OVER (PARTITION BY … ORDER BY … frame)`
    case window(function: Expression, partitionBy: [Expression], orderBy: [OrderItem], frame: String?)
    /// A typed literal such as `DATE '1998-12-01'` or `TIMESTAMP '…'`.
    case typedLiteral(type: String, value: String)
    /// `INTERVAL '90' DAY`
    case interval(value: String, unit: String)
}

/// Whether a sub-query comparison must hold for every row or for some row.
/// `SOME` is a synonym for `ANY` in standard SQL.
enum SubqueryQuantifier: String, Equatable {
    case all = "ALL"
    case any = "ANY"
}

/// One `WHEN condition THEN result` branch of a CASE expression.
struct WhenClause: Equatable {
    var condition: Expression
    var result: Expression
}
