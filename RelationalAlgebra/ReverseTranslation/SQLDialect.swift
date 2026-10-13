//
//  SQLDialect.swift
//  RelationalAlgebra
//
//  The engines the generated SQL is written for, and the one rewrite that
//  tells them apart.
//
//  Almost everything the app generates runs unchanged on both — CI runs every
//  golden case on each to keep it that way. The exception is a sub-query that
//  refers to a row two or more levels out, which is how ∀ comes out of the
//  calculus:
//
//      SELECT … FROM Student AS s
//      WHERE NOT EXISTS (SELECT * FROM Course AS c
//                        WHERE NOT EXISTS (SELECT * FROM Enrolled AS e
//                                          WHERE e.sid = s.sid …))   ← two levels out
//
//  DuckDB runs that. DataFusion rejects it ("No field named s.sid", checked on
//  DataFusion 55), but runs the same query with `s` ranged again one level down
//  and equated to the original, so every reference is to the level directly
//  above:
//
//      WHERE NOT EXISTS (SELECT * FROM Course AS c, Student AS s2
//                        WHERE s2.sid = s.sid AND s2.name = s.name
//                          AND NOT EXISTS (… e.sid = s2.sid …))
//

import Foundation

enum SQLDialect: String, CaseIterable, Identifiable {
    case duckdb = "DuckDB"
    case datafusion = "DataFusion"

    var id: String { rawValue }

    /// Whether a sub-query may refer to a row more than one level out.
    var allowsDeepCorrelation: Bool { self == .duckdb }
}

/// Rewrites deep correlation away, for DataFusion.
struct SQLDecorrelation {
    /// A relation's columns, which the re-ranged row is equated on.
    let columnsOf: (String) -> [String]?
    let names: NameAllocator

    /// The query with every sub-query referring at most one level out, and
    /// whether anything had to change.
    func rewrite(_ query: SQLQuery) throws -> (SQLQuery, Bool) {
        var changed = false
        let result = try rewrite(query, outer: [:], changed: &changed)
        return (result, changed)
    }

    // MARK: - Queries

    /// `outer` maps the aliases of the level directly above to their relations.
    private func rewrite(_ query: SQLQuery, outer: [String: String],
                         changed: inout Bool) throws -> SQLQuery {
        switch query {
        case let .select(stmt):
            return .select(try rewrite(stmt, outer: outer, changed: &changed))
        case let .setOperation(op, left, right, all):
            return .setOperation(op, left: try rewrite(left, outer: outer, changed: &changed),
                                 right: try rewrite(right, outer: outer, changed: &changed), all: all)
        case let .with(ctes, body):
            var rewritten: [CommonTableExpression] = []
            for var cte in ctes {
                cte.query = try rewrite(cte.query, outer: [:], changed: &changed)
                rewritten.append(cte)
            }
            return .with(ctes: rewritten, body: try rewrite(body, outer: outer, changed: &changed))
        }
    }

    private func rewrite(_ statement: SelectStatement, outer: [String: String],
                         changed: inout Bool) throws -> SelectStatement {
        var stmt = statement
        var own = SQLDecorrelation.aliases(of: stmt)
        guard var condition = stmt.whereClause else { return stmt }

        // A sub-query of this level that mentions a row of the level above
        // refers two levels out. Range that row again here, equal to the
        // original, and point the sub-query at the copy.
        var copies: [String: String] = [:]
        var equalities: [Expression] = []
        for subquery in SQLDecorrelation.subqueries(in: condition) {
            // SQL names are case-insensitive: `FROM S` is read by `s.sid`.
            for alias in SQLDecorrelation.qualifiers(in: subquery)
            where outer[alias.lowercased()] != nil && copies[alias.lowercased()] == nil {
                let relation = outer[alias.lowercased()]!
                guard let columns = columnsOf(relation) else {
                    throw TranslationError(message: "DataFusion cannot run a sub-query that refers " +
                                                    "to \(alias) two levels out. Rewriting it needs " +
                                                    "\(relation)'s columns: declare them with CREATE " +
                                                    "TABLE above the formula, or choose DuckDB.")
                }
                let copy = names.fresh(for: relation)
                copies[alias.lowercased()] = copy
                own[copy.lowercased()] = relation
                stmt.from.append(.named(name: relation, alias: copy))
                equalities += columns.map {
                    Expression.binary(op: "=", lhs: .column(table: copy, name: $0),
                                      rhs: .column(table: alias, name: $0))
                }
            }
        }
        if !copies.isEmpty {
            changed = true
            condition = SQLDecorrelation.renaming(condition, copies, insideSubqueriesOnly: true)
            condition = equalities.reversed().reduce(condition) {
                .binary(op: "AND", lhs: $1, rhs: $0)
            }
        }

        // Then the same, one level further down.
        stmt.whereClause = try mapSubqueries(condition) { query in
            try rewrite(query, outer: own, changed: &changed)
        }
        return stmt
    }

    // MARK: - Expression walking

    private static func aliases(of stmt: SelectStatement) -> [String: String] {
        var map: [String: String] = [:]
        for ref in stmt.from + stmt.joins.map(\.table) {
            if case let .named(name, alias) = ref { map[(alias ?? name).lowercased()] = name }
        }
        return map
    }

    /// The sub-queries directly inside a condition (not nested in each other).
    private static func subqueries(in expression: Expression) -> [SQLQuery] {
        switch expression {
        case let .exists(query, _), let .subquery(query):
            return [query]
        case let .inSubquery(value, query, _):
            return subqueries(in: value) + [query]
        case let .quantifiedComparison(value, _, _, query):
            return subqueries(in: value) + [query]
        case let .binary(_, lhs, rhs):
            return subqueries(in: lhs) + subqueries(in: rhs)
        case let .unary(_, operand), let .paren(operand):
            return subqueries(in: operand)
        default:
            return []
        }
    }

    /// Every qualifier mentioned anywhere in a query, sub-queries included.
    private static func qualifiers(in query: SQLQuery) -> Set<String> {
        switch query {
        case let .select(stmt):
            var found = Set<String>()
            let projected = stmt.projections.compactMap { item -> Expression? in
                if case let .expression(e, _) = item { return e }
                return nil
            }
            for expression in [stmt.whereClause].compactMap({ $0 }) + projected {
                found.formUnion(qualifiers(in: expression))
            }
            return found
        case let .setOperation(_, left, right, _):
            return qualifiers(in: left).union(qualifiers(in: right))
        case let .with(_, body):
            return qualifiers(in: body)
        }
    }

    private static func qualifiers(in expression: Expression) -> Set<String> {
        var found = Set<String>()
        _ = expression.mappingColumns { table, name in
            if let table { found.insert(table) }
            return .column(table: table, name: name)
        }
        for query in subqueries(in: expression) {
            found.formUnion(qualifiers(in: query))
        }
        return found
    }

    /// Re-point qualifiers, in sub-queries only when asked — the level that
    /// holds the copy still means the original in its own conditions.
    private static func renaming(_ expression: Expression, _ map: [String: String],
                                 insideSubqueriesOnly: Bool) -> Expression {
        let mapped = insideSubqueriesOnly ? expression : expression.mappingColumns { table, name in
            .column(table: table.map { map[$0.lowercased()] ?? $0 }, name: name)
        }
        return mapSubqueriesUnchecked(mapped) { renaming($0, map) }
    }

    private static func renaming(_ query: SQLQuery, _ map: [String: String]) -> SQLQuery {
        switch query {
        case var .select(stmt):
            stmt.whereClause = stmt.whereClause.map { renaming($0, map, insideSubqueriesOnly: false) }
            stmt.projections = stmt.projections.map {
                if case let .expression(e, alias) = $0 {
                    return .expression(renaming(e, map, insideSubqueriesOnly: false), alias: alias)
                }
                return $0
            }
            return .select(stmt)
        case let .setOperation(op, left, right, all):
            return .setOperation(op, left: renaming(left, map), right: renaming(right, map), all: all)
        case let .with(ctes, body):
            return .with(ctes: ctes, body: renaming(body, map))
        }
    }

    private func mapSubqueries(_ expression: Expression,
                               _ transform: (SQLQuery) throws -> SQLQuery) throws -> Expression {
        switch expression {
        case let .exists(query, negated):
            return .exists(query: try transform(query), negated: negated)
        case let .subquery(query):
            return .subquery(try transform(query))
        case let .inSubquery(value, query, negated):
            return .inSubquery(value: try mapSubqueries(value, transform),
                               query: try transform(query), negated: negated)
        case let .quantifiedComparison(value, op, quantifier, query):
            return .quantifiedComparison(value: try mapSubqueries(value, transform), op: op,
                                         quantifier: quantifier, query: try transform(query))
        case let .binary(op, lhs, rhs):
            return .binary(op: op, lhs: try mapSubqueries(lhs, transform),
                           rhs: try mapSubqueries(rhs, transform))
        case let .unary(op, operand):
            return .unary(op: op, operand: try mapSubqueries(operand, transform))
        case let .paren(inner):
            return .paren(try mapSubqueries(inner, transform))
        default:
            return expression
        }
    }

    private static func mapSubqueriesUnchecked(_ expression: Expression,
                                               _ transform: (SQLQuery) -> SQLQuery) -> Expression {
        switch expression {
        case let .exists(query, negated):
            return .exists(query: transform(query), negated: negated)
        case let .subquery(query):
            return .subquery(transform(query))
        case let .inSubquery(value, query, negated):
            return .inSubquery(value: mapSubqueriesUnchecked(value, transform),
                               query: transform(query), negated: negated)
        case let .quantifiedComparison(value, op, quantifier, query):
            return .quantifiedComparison(value: mapSubqueriesUnchecked(value, transform), op: op,
                                         quantifier: quantifier, query: transform(query))
        case let .binary(op, lhs, rhs):
            return .binary(op: op, lhs: mapSubqueriesUnchecked(lhs, transform),
                           rhs: mapSubqueriesUnchecked(rhs, transform))
        case let .unary(op, operand):
            return .unary(op: op, operand: mapSubqueriesUnchecked(operand, transform))
        case let .paren(inner):
            return .paren(mapSubqueriesUnchecked(inner, transform))
        default:
            return expression
        }
    }
}
