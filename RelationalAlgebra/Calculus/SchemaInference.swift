//
//  SchemaInference.swift
//  RelationalAlgebra
//
//  Reconstructs what it can of each relation's attribute list from the query
//  alone. Evidence is gathered in descending order of trust:
//
//    1. a CTE's select list or explicit column list   → exact, in order
//    2. a derived table's select list                 → exact, in order
//    3. qualified references (`e.salary`)             → first-appearance order
//    4. `USING (a, b)`                                → both sides have a and b
//    5. unqualified references, when exactly one relation is in scope
//
//  Declared `CREATE TABLE` DDL — the only fully trustworthy source, and the one
//  that makes DRC exact rather than approximate — is not parsed yet; it lands
//  with the DRC phase, at which point it takes precedence over everything here.
//
//  A reference that cannot be resolved is reported, never guessed: attributing
//  an ambiguous column to the wrong relation produces a wrong formula.
//

import Foundation

struct SchemaInference {

    struct Result {
        var schema: QuerySchema
        var diagnostics: [CalcDiagnostic]
    }

    static func infer(_ query: SQLQuery) -> Result {
        let engine = SchemaInferenceEngine()
        engine.walk(query, scope: Scope())
        return Result(schema: engine.schema, diagnostics: engine.diagnostics.deduplicated)
    }
}

/// The relations visible at one nesting level, plus the enclosing level so that
/// a correlated sub-query can still see the outer query's aliases.
struct Scope {
    /// alias (or bare table name) → relation name.
    private(set) var bindings: [(name: String, relation: String)] = []
    /// The enclosing scope, for correlated references.
    private var parent: [(name: String, relation: String)] = []

    init() {}

    init(nestedIn outer: Scope) {
        parent = outer.bindings + outer.parent
    }

    mutating func bind(name: String, to relation: String) {
        bindings.append((name: name, relation: relation))
    }

    /// Resolve a qualifier (`e` in `e.salary`) to a relation name, looking in
    /// this scope first and then outwards.
    func relation(forQualifier qualifier: String) -> String? {
        let all = bindings + parent
        return all.first { $0.name.caseInsensitiveCompare(qualifier) == .orderedSame }?.relation
    }

    /// The relations of this level only — an unqualified column belongs to the
    /// innermost level that has exactly one candidate.
    var localRelations: [String] {
        var seen = Set<String>()
        return bindings.compactMap { seen.insert($0.relation.lowercased()).inserted ? $0.relation : nil }
    }
}

final class SchemaInferenceEngine {
    private(set) var schema = QuerySchema()
    private(set) var diagnostics: [CalcDiagnostic] = []

    // MARK: Query walking

    func walk(_ query: SQLQuery, scope: Scope) {
        switch query {
        case let .select(stmt):
            walkSelect(stmt, outer: scope)
        case let .setOperation(_, left, right, _):
            walk(left, scope: scope)
            walk(right, scope: scope)
        case let .with(ctes, body):
            for cte in ctes {
                walk(cte.query, scope: scope)
                declareCTE(cte)
            }
            walk(body, scope: scope)
        }
    }

    private func declareCTE(_ cte: CommonTableExpression) {
        let columns: [String]? = cte.columns.isEmpty ? outputColumns(of: cte.query) : cte.columns
        guard let columns else {
            schema.touch(cte.name)
            return
        }
        schema.declare(RelationSchema(name: cte.name, attributes: columns,
                                      source: .cte, arityKnown: true))
    }

    private func walkSelect(_ stmt: SelectStatement, outer: Scope) {
        var scope = Scope(nestedIn: outer)

        for table in stmt.from { bind(table, into: &scope) }
        for join in stmt.joins { bind(join.table, into: &scope) }

        // USING (a, b) gives every relation on both sides those attributes.
        for join in stmt.joins where !join.using.isEmpty {
            for relation in scope.localRelations {
                for column in join.using { schema.record(attribute: column, on: relation) }
            }
        }

        for item in stmt.projections {
            switch item {
            case .star, .qualifiedStar:
                break // `*` names no new attribute; it enumerates known ones.
            case let .expression(expr, _):
                collect(expr, scope: scope)
            }
        }
        if let whereClause = stmt.whereClause { collect(whereClause, scope: scope) }
        if let having = stmt.having { collect(having, scope: scope) }
        for join in stmt.joins { if let on = join.on { collect(on, scope: scope) } }
        for expr in stmt.groupBy { collect(expr, scope: scope) }
        for item in stmt.orderBy { collect(item.expression, scope: scope) }
    }

    private func bind(_ table: TableRef, into scope: inout Scope) {
        switch table {
        case let .named(name, alias):
            schema.touch(name)
            scope.bind(name: alias ?? name, to: name)
            if let alias, alias != name { scope.bind(name: name, to: name) }
        case let .derived(query, alias):
            walk(query, scope: scope)
            let relationName = alias ?? "(sub-query)"
            if let columns = outputColumns(of: query) {
                schema.declare(RelationSchema(name: relationName, attributes: columns,
                                              source: .derived, arityKnown: true))
            } else {
                schema.touch(relationName)
            }
            scope.bind(name: relationName, to: relationName)
        }
    }

    // MARK: Expression walking

    private func collect(_ expr: Expression, scope: Scope) {
        switch expr {
        case let .column(table, name):
            record(column: name, qualifier: table, scope: scope)

        case let .binary(_, lhs, rhs):
            collect(lhs, scope: scope); collect(rhs, scope: scope)
        case let .unary(_, operand):
            collect(operand, scope: scope)
        case let .paren(inner):
            collect(inner, scope: scope)
        case let .function(_, args, _):
            args.forEach { collect($0, scope: scope) }
        case let .between(value, lower, upper, _):
            [value, lower, upper].forEach { collect($0, scope: scope) }
        case let .inList(value, list, _):
            collect(value, scope: scope); list.forEach { collect($0, scope: scope) }
        case let .inSubquery(value, query, _):
            collect(value, scope: scope); walk(query, scope: scope)
        case let .exists(query, _):
            walk(query, scope: scope)
        case let .quantifiedComparison(value, _, _, query):
            collect(value, scope: scope); walk(query, scope: scope)
        case let .isNull(inner, _):
            collect(inner, scope: scope)
        case let .list(items):
            items.forEach { collect($0, scope: scope) }
        case let .subquery(query):
            walk(query, scope: scope)
        case let .caseExpression(operand, cases, elseResult):
            if let operand { collect(operand, scope: scope) }
            for clause in cases {
                collect(clause.condition, scope: scope)
                collect(clause.result, scope: scope)
            }
            if let elseResult { collect(elseResult, scope: scope) }
        case let .cast(expression, _):
            collect(expression, scope: scope)
        case let .window(function, partitionBy, orderBy, _):
            collect(function, scope: scope)
            partitionBy.forEach { collect($0, scope: scope) }
            orderBy.forEach { collect($0.expression, scope: scope) }

        case .numberLiteral, .stringLiteral, .boolLiteral, .nullLiteral, .star,
             .typedLiteral, .interval:
            break
        }
    }

    private func record(column: String, qualifier: String?, scope: Scope) {
        if let qualifier {
            if let relation = scope.relation(forQualifier: qualifier) {
                schema.record(attribute: column, on: relation)
            } else {
                // A qualifier naming nothing in scope is a query bug, not ours
                // to resolve — record it under its own name so the reference at
                // least renders, and say so.
                schema.record(attribute: column, on: qualifier)
                diagnostics.append(.annotated(
                    "\(qualifier).\(column)",
                    "'\(qualifier)' does not name a table or alias in scope; treated as a relation."))
            }
            return
        }

        let candidates = scope.localRelations
        if candidates.count == 1 {
            schema.record(attribute: column, on: candidates[0])
        } else if candidates.count > 1 {
            diagnostics.append(.annotated(
                column,
                "'\(column)' is unqualified with \(candidates.count) relations in scope, " +
                "so it could not be attributed to one. Qualify it (table.\(column)) to place it."))
        }
    }

    // MARK: Output columns of a sub-query

    /// The column names a query publishes, when they can all be named. `nil`
    /// when the select list contains a `*` we cannot expand, since a partial
    /// list would be a wrong arity rather than an incomplete one.
    private func outputColumns(of query: SQLQuery) -> [String]? {
        switch query {
        case let .select(stmt):
            var names: [String] = []
            for item in stmt.projections {
                switch item {
                case .star, .qualifiedStar:
                    return nil
                case let .expression(expr, alias):
                    names.append(alias ?? expr.attributeName)
                }
            }
            return names.isEmpty ? nil : names
        case let .setOperation(_, left, _, _):
            return outputColumns(of: left)
        case let .with(_, body):
            return outputColumns(of: body)
        }
    }
}
