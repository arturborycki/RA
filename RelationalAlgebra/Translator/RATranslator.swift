//
//  RATranslator.swift
//  RelationalAlgebra
//
//  Turns a parsed `SQLQuery` into a relational-algebra expression, recording an
//  ordered list of derivation steps along the way. The evaluation order follows
//  the standard logical processing order of SQL:
//
//     FROM / JOIN  →  WHERE  →  GROUP BY  →  HAVING  →  SELECT  →  DISTINCT  →  ORDER BY
//

import Foundation

struct RATranslator {

    func translate(_ query: SQLQuery) -> RATranslation {
        var steps: [RAStep] = []
        let expr = build(query, steps: &steps)
        // Re-number in case nested translation pushed steps out of order.
        let renumbered = steps.enumerated().map { pair in
            RAStep(index: pair.offset + 1,
                   title: pair.element.title,
                   clause: pair.element.clause,
                   explanation: pair.element.explanation,
                   expression: pair.element.expression)
        }
        return RATranslation(steps: renumbered, finalExpression: expr)
    }

    // MARK: - Query dispatch

    private func build(_ query: SQLQuery, steps: inout [RAStep]) -> RANode {
        switch query {
        case let .select(stmt):
            return buildSelect(stmt, steps: &steps)
        case let .setOperation(op, left, right, all):
            return buildSetOperation(op, left: left, right: right, all: all, steps: &steps)
        }
    }

    private func buildSetOperation(_ op: SetOperator, left: SQLQuery, right: SQLQuery,
                                   all: Bool, steps: inout [RAStep]) -> RANode {
        // Build both sides first (their steps are appended in order).
        var leftSteps: [RAStep] = []
        let leftExpr = build(left, steps: &leftSteps)
        var rightSteps: [RAStep] = []
        let rightExpr = build(right, steps: &rightSteps)

        steps.append(contentsOf: leftSteps)
        steps.append(contentsOf: rightSteps)

        let combined: RANode
        let title: String
        let explanation: String
        switch op {
        case .union:
            combined = .union(left: leftExpr, right: rightExpr)
            title = "Union (\(RASymbol.union))"
            explanation = "Combine the rows of both sub-queries. " +
                (all ? "UNION ALL keeps duplicates." : "UNION removes duplicate rows.")
        case .intersect:
            combined = .intersect(left: leftExpr, right: rightExpr)
            title = "Intersection (\(RASymbol.intersect))"
            explanation = "Keep only rows that appear in both sub-queries."
        case .except:
            combined = .difference(left: leftExpr, right: rightExpr)
            title = "Difference (\(RASymbol.difference))"
            explanation = "Keep rows from the first sub-query that are not in the second."
        }

        var result = combined
        // UNION defaults to distinct; UNION ALL keeps duplicates (no δ).
        addStep(&steps, title: title, clause: op.rawValue + (all ? " ALL" : ""),
                explanation: explanation, expression: result)

        if op == .union && !all {
            result = .distinct(child: result)
            addStep(&steps, title: "Duplicate elimination (\(RASymbol.distinct))",
                    clause: "UNION",
                    explanation: "UNION removes duplicate rows, expressed as δ.",
                    expression: result)
        }
        return result
    }

    // MARK: - SELECT

    private func buildSelect(_ stmt: SelectStatement, steps: inout [RAStep]) -> RANode {
        // 1. FROM / JOIN
        var current = buildFrom(stmt, steps: &steps)

        // 2. WHERE
        if let whereClause = stmt.whereClause {
            current = .selection(condition: whereClause.rendered, child: current)
            addStep(&steps, title: "Selection (\(RASymbol.selection))", clause: "WHERE",
                    explanation: "Keep only the rows satisfying the WHERE predicate.",
                    expression: current)
        }

        // 3. GROUP BY / aggregation
        let aggregates = collectAggregates(stmt)
        let grouping = stmt.groupBy.map { $0.rendered }
        let needsGrouping = !grouping.isEmpty || !aggregates.isEmpty
        if needsGrouping {
            current = .group(grouping: grouping, aggregates: aggregates, child: current)
            let g = grouping.isEmpty ? "the whole relation as one group" : grouping.joined(separator: ", ")
            let a = aggregates.isEmpty ? "" : " computing \(aggregates.joined(separator: ", "))"
            addStep(&steps, title: "Grouping (\(RASymbol.group))", clause: "GROUP BY",
                    explanation: "Group rows by \(g)\(a).",
                    expression: current)
        }

        // 4. HAVING
        if let having = stmt.having {
            current = .selection(condition: having.rendered, child: current)
            addStep(&steps, title: "Selection (\(RASymbol.selection))", clause: "HAVING",
                    explanation: "Filter groups using the HAVING predicate.",
                    expression: current)
        }

        // 5. SELECT list → projection (skip for `SELECT *` with no rename)
        if let attributes = projectionAttributes(stmt) {
            current = .projection(attributes: attributes, child: current)
            addStep(&steps, title: "Projection (\(RASymbol.projection))", clause: "SELECT",
                    explanation: "Keep only the selected columns\(stmt.projections.contains(where: hasAlias) ? ", renaming where AS is used" : "").",
                    expression: current)
        }

        // 6. DISTINCT
        if stmt.distinct {
            current = .distinct(child: current)
            addStep(&steps, title: "Duplicate elimination (\(RASymbol.distinct))", clause: "DISTINCT",
                    explanation: "Remove duplicate rows from the result.",
                    expression: current)
        }

        // 7. ORDER BY
        if !stmt.orderBy.isEmpty {
            let keys = stmt.orderBy.map { item in
                "\(item.expression.rendered) \(item.descending ? "↓" : "↑")"
            }
            current = .sort(keys: keys, child: current)
            addStep(&steps, title: "Sort (\(RASymbol.sort))", clause: "ORDER BY",
                    explanation: "Order the result by \(keys.joined(separator: ", ")). " +
                        "(Sorting is an extension to the classical relational algebra.)",
                    expression: current)
        }

        return current
    }

    // MARK: - FROM / JOIN construction

    private func buildFrom(_ stmt: SelectStatement, steps: inout [RAStep]) -> RANode {
        var current = relationNode(from: stmt.from[0], steps: &steps)

        if stmt.from.isEmpty == false {
            addStep(&steps, title: "Base relation", clause: "FROM",
                    explanation: "Start from \(describe(stmt.from[0])).",
                    expression: current)
        }

        // Additional comma-separated tables → cross products.
        for table in stmt.from.dropFirst() {
            let rhs = relationNode(from: table, steps: &steps)
            current = .cross(left: current, right: rhs)
            addStep(&steps, title: "Cartesian product (\(RASymbol.cross))", clause: "FROM",
                    explanation: "Form the cartesian product with \(describe(table)) (comma join).",
                    expression: current)
        }

        // Explicit JOINs.
        for join in stmt.joins {
            let rhs = relationNode(from: join.table, steps: &steps)
            let condition = joinCondition(join)
            switch join.kind {
            case .cross:
                current = .cross(left: current, right: rhs)
                addStep(&steps, title: "Cartesian product (\(RASymbol.cross))", clause: "CROSS JOIN",
                        explanation: "Cross join with \(describe(join.table)).",
                        expression: current)
            case .inner:
                current = .join(condition: condition, left: current, right: rhs)
                addStep(&steps, title: "Join (\(RASymbol.join))", clause: "JOIN",
                        explanation: "Inner join with \(describe(join.table))\(condition.map { " on \($0)" } ?? "").",
                        expression: current)
            case .left:
                current = .outerJoin(kind: .left, condition: condition, left: current, right: rhs)
                addStep(&steps, title: "Left outer join (\(RASymbol.leftJoin))", clause: "LEFT JOIN",
                        explanation: "Left outer join with \(describe(join.table))\(condition.map { " on \($0)" } ?? "").",
                        expression: current)
            case .right:
                current = .outerJoin(kind: .right, condition: condition, left: current, right: rhs)
                addStep(&steps, title: "Right outer join (\(RASymbol.rightJoin))", clause: "RIGHT JOIN",
                        explanation: "Right outer join with \(describe(join.table))\(condition.map { " on \($0)" } ?? "").",
                        expression: current)
            case .full:
                current = .outerJoin(kind: .full, condition: condition, left: current, right: rhs)
                addStep(&steps, title: "Full outer join (\(RASymbol.fullJoin))", clause: "FULL JOIN",
                        explanation: "Full outer join with \(describe(join.table))\(condition.map { " on \($0)" } ?? "").",
                        expression: current)
            }
        }

        return current
    }

    private func relationNode(from table: TableRef, steps: inout [RAStep]) -> RANode {
        switch table {
        case let .named(name, alias):
            return .relation(name: name, alias: alias)
        case let .derived(query, alias):
            var subSteps: [RAStep] = []
            let sub = build(query, steps: &subSteps)
            steps.append(contentsOf: subSteps)
            if let alias {
                return .rename(alias: alias, child: sub)
            }
            return sub
        }
    }

    private func joinCondition(_ join: Join) -> String? {
        if let on = join.on { return on.rendered }
        if !join.using.isEmpty { return "USING (" + join.using.joined(separator: ", ") + ")" }
        return nil
    }

    // MARK: - Helpers

    private func collectAggregates(_ stmt: SelectStatement) -> [String] {
        var result: [String] = []
        for item in stmt.projections {
            if case let .expression(expr, alias) = item, expr.containsAggregate {
                let base = expr.rendered
                if let alias { result.append("\(base) → \(alias)") }
                else { result.append(base) }
            }
        }
        return result
    }

    /// The attribute list for the final projection, or `nil` when the query is
    /// a bare `SELECT *` (in which case no π is needed).
    private func projectionAttributes(_ stmt: SelectStatement) -> [String]? {
        if stmt.projections.count == 1, case .star = stmt.projections[0] {
            return nil
        }
        return stmt.projections.map { $0.attributeLabel }
    }

    private func hasAlias(_ item: SelectItem) -> Bool {
        if case let .expression(_, alias) = item { return alias != nil }
        return false
    }

    private func describe(_ table: TableRef) -> String {
        switch table {
        case let .named(name, alias):
            if let alias, alias != name { return "\(name) (aliased \(alias))" }
            return name
        case let .derived(_, alias):
            if let alias { return "sub-query (aliased \(alias))" }
            return "sub-query"
        }
    }

    private func addStep(_ steps: inout [RAStep], title: String, clause: String,
                         explanation: String, expression: RANode) {
        steps.append(RAStep(index: steps.count + 1, title: title, clause: clause,
                            explanation: explanation, expression: expression))
    }
}
