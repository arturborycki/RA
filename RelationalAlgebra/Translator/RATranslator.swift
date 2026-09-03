//
//  RATranslator.swift
//  RelationalAlgebra
//
//  Turns a parsed `SQLQuery` into a relational-algebra expression, recording an
//  ordered list of derivation steps. Each step binds its result to a name
//  (R₁, R₂, …) and is written as a single operator applied to previously-named
//  results — so no line repeats the whole nested formula.
//
//  Evaluation follows the standard logical processing order of SQL:
//
//     FROM / JOIN  →  WHERE  →  GROUP BY  →  HAVING  →  SELECT  →  DISTINCT  →  ORDER BY
//

import Foundation

struct RATranslator {
    func translate(_ query: SQLQuery) -> RATranslation {
        let builder = RABuilder()
        let (node, ref) = builder.build(query)
        // If nothing but a base relation was produced, show it as a single line.
        if builder.steps.isEmpty {
            builder.emitIdentity(node: node, ref: ref)
        }
        return RATranslation(steps: builder.steps,
                             finalExpression: node,
                             finalName: builder.steps.last?.resultName ?? ref,
                             diagnostics: builder.diagnostics.deduplicated)
    }
}

/// Accumulates named derivation steps while walking the query.
final class RABuilder {
    private(set) var steps: [RAStep] = []
    /// What the algebra could not express exactly. The calculus side has had
    /// this since P1; without it an approximation on this side was invisible.
    private(set) var diagnostics: [CalcDiagnostic] = []
    private var counter = 0

    // MARK: Step emission

    /// Bind `rhs` to a fresh name (or `name`, e.g. a CTE name) and record a step.
    @discardableResult
    private func emit(name: String? = nil, title: String, clause: String,
                      explanation: String, node: RANode, rhs: String) -> String {
        counter += 1
        let resultName = name ?? "R\(subscriptNumber(counter))"
        steps.append(RAStep(index: counter, resultName: resultName, title: title,
                            clause: clause, explanation: explanation,
                            definition: "\(resultName) = \(rhs)", expression: node))
        return resultName
    }

    /// Emit a trivial "starting relation" line when a query has no operators.
    func emitIdentity(node: RANode, ref: String) {
        emit(title: "Base relation", clause: "FROM",
             explanation: "The query returns the relation as-is.",
             node: node, rhs: ref)
    }

    // MARK: - Query dispatch

    /// Returns the RA node plus the reference string to use for its result
    /// (a base-table name, or a step name like "R₃").
    func build(_ query: SQLQuery) -> (RANode, String) {
        switch query {
        case let .select(stmt):
            return buildSelect(stmt)
        case let .setOperation(op, left, right, all):
            return buildSetOperation(op, left: left, right: right, all: all)
        case let .with(ctes, body):
            for cte in ctes {
                if cte.isRecursive {
                    diagnostics.append(.annotated(
                        "WITH RECURSIVE \(cte.name)",
                        "A recursive CTE is a least fixed point, which the relational algebra " +
                        "cannot express — transitive closure is the standard example. Only the " +
                        "non-recursive reading is shown below."))
                }
                let (node, ref) = build(cte.query)
                let named = RANode.rename(alias: cte.name, child: node)
                emit(name: cte.name, title: "Common table expression (\(RASymbol.rename))",
                     clause: "WITH \(cte.name)",
                     explanation: "Define the CTE '\(cte.name)'. It is referenced as a relation below.",
                     node: named, rhs: ref)
            }
            return build(body)
        }
    }

    // MARK: - Set operations

    private func buildSetOperation(_ op: SetOperator, left: SQLQuery, right: SQLQuery,
                                   all: Bool) -> (RANode, String) {
        let (leftNode, leftRef) = build(left)
        let (rightNode, rightRef) = build(right)

        let node: RANode
        let glyph: String
        let title: String
        let explanation: String
        switch op {
        case .union:
            node = .union(left: leftNode, right: rightNode)
            glyph = RASymbol.union
            title = "Union (\(RASymbol.union))"
            explanation = "Combine the rows of both sub-queries. " +
                (all ? "UNION ALL keeps duplicates." : "UNION removes duplicate rows.")
        case .intersect:
            node = .intersect(left: leftNode, right: rightNode)
            glyph = RASymbol.intersect
            title = "Intersection (\(RASymbol.intersect))"
            explanation = "Keep only rows that appear in both sub-queries."
        case .except:
            node = .difference(left: leftNode, right: rightNode)
            glyph = RASymbol.difference
            title = "Difference (\(RASymbol.difference))"
            explanation = "Keep rows from the first sub-query that are not in the second."
        }

        var resultNode = node
        var ref = emit(title: title, clause: op.rawValue + (all ? " ALL" : ""),
                       explanation: explanation, node: resultNode,
                       rhs: "\(leftRef) \(glyph) \(rightRef)")

        if op == .union && !all {
            resultNode = .distinct(child: resultNode)
            ref = emit(title: "Duplicate elimination (\(RASymbol.distinct))", clause: "UNION",
                       explanation: "UNION removes duplicate rows, expressed as δ.",
                       node: resultNode, rhs: "\(RASymbol.distinct) ( \(ref) )")
        }
        return (resultNode, ref)
    }

    // MARK: - SELECT

    private func buildSelect(_ stmt: SelectStatement) -> (RANode, String) {
        // 1. FROM / JOIN
        var (node, ref) = buildFrom(stmt)

        // 2. WHERE
        if let whereClause = stmt.whereClause {
            let cond = whereClause.rendered
            node = .selection(condition: cond, child: node)
            ref = emit(title: "Selection (\(RASymbol.selection))", clause: "WHERE",
                       explanation: "Keep only the rows satisfying the WHERE predicate.",
                       node: node, rhs: "\(RASymbol.selection)[\(cond)] ( \(ref) )")
        }

        // 3. GROUP BY / aggregation
        let aggregates = collectAggregates(stmt)
        let rawGrouping = stmt.groupBy.map { $0.rendered }
        var grouping = rawGrouping
        if let modifier = stmt.groupByModifier, !rawGrouping.isEmpty {
            grouping = ["\(modifier)(\(rawGrouping.joined(separator: ", ")))"]
        }
        if !grouping.isEmpty || !aggregates.isEmpty {
            node = .group(grouping: grouping, aggregates: aggregates, child: node)
            let sub = groupSubscript(grouping: grouping, aggregates: aggregates)
            let g = grouping.isEmpty ? "the whole relation as one group" : grouping.joined(separator: ", ")
            let a = aggregates.isEmpty ? "" : " computing \(aggregates.joined(separator: ", "))"
            ref = emit(title: "Grouping (\(RASymbol.group))", clause: "GROUP BY",
                       explanation: "Group rows by \(g)\(a).",
                       node: node, rhs: "\(RASymbol.group)[\(sub)] ( \(ref) )")
        }

        // 4. HAVING
        if let having = stmt.having {
            let cond = having.rendered
            node = .selection(condition: cond, child: node)
            ref = emit(title: "Selection (\(RASymbol.selection))", clause: "HAVING",
                       explanation: "Filter groups using the HAVING predicate.",
                       node: node, rhs: "\(RASymbol.selection)[\(cond)] ( \(ref) )")
        }

        // 5. SELECT list → projection (skip for bare `SELECT *`)
        if let attributes = projectionAttributes(stmt) {
            node = .projection(attributes: attributes, child: node)
            let renaming = stmt.projections.contains(where: hasAlias) ? ", renaming where AS is used" : ""
            ref = emit(title: "Projection (\(RASymbol.projection))", clause: "SELECT",
                       explanation: "Keep only the selected columns\(renaming).",
                       node: node, rhs: "\(RASymbol.projection)[\(attributes.joined(separator: ", "))] ( \(ref) )")
        }

        // 6. DISTINCT
        if stmt.distinct {
            node = .distinct(child: node)
            ref = emit(title: "Duplicate elimination (\(RASymbol.distinct))", clause: "DISTINCT",
                       explanation: "Remove duplicate rows from the result.",
                       node: node, rhs: "\(RASymbol.distinct) ( \(ref) )")
        }

        // 7. ORDER BY
        if !stmt.orderBy.isEmpty {
            let keys = stmt.orderBy.map(\.rendered)
            node = .sort(keys: keys, child: node)
            ref = emit(title: "Sort (\(RASymbol.sort))", clause: "ORDER BY",
                       explanation: "Order the result by \(keys.joined(separator: ", ")). " +
                        "(Sorting is an extension to the classical relational algebra.)",
                       node: node, rhs: "\(RASymbol.sort)[\(keys.joined(separator: ", "))] ( \(ref) )")
        }

        // 8. LIMIT / OFFSET / FETCH FIRST
        if stmt.limit != nil || stmt.offset != nil {
            node = .limit(count: stmt.limit, offset: stmt.offset, child: node)
            let sub = RANode.limitSubscript(count: stmt.limit, offset: stmt.offset)
            ref = emit(title: "Row limit (\(RASymbol.limit))", clause: "LIMIT",
                       explanation: "Keep \(sub) of the ordered result. Row limiting depends on " +
                        "an order, so like sorting it is an extension to the classical " +
                        "set-based algebra rather than one of its operators.",
                       node: node, rhs: "\(RASymbol.limit)[\(sub)] ( \(ref) )")
        }

        return (node, ref)
    }

    // MARK: - FROM / JOIN

    private func buildFrom(_ stmt: SelectStatement) -> (RANode, String) {
        var (node, ref) = relation(stmt.from[0])

        // Additional comma-separated tables → cross products.
        for table in stmt.from.dropFirst() {
            let (rn, rref) = relation(table)
            node = .cross(left: node, right: rn)
            ref = emit(title: "Cartesian product (\(RASymbol.cross))", clause: "FROM",
                       explanation: "Form the cartesian product with \(rref) (comma join).",
                       node: node, rhs: "\(ref) \(RASymbol.cross) \(rref)")
        }

        // Explicit JOINs.
        for join in stmt.joins {
            let (rn, rref) = relation(join.table)
            let cond = joinCondition(join)
            let condSub = cond.map { "[\($0)]" } ?? ""
            switch join.kind {
            case .cross:
                node = .cross(left: node, right: rn)
                ref = emit(title: "Cartesian product (\(RASymbol.cross))", clause: "CROSS JOIN",
                           explanation: "Cross join with \(rref).",
                           node: node, rhs: "\(ref) \(RASymbol.cross) \(rref)")
            case .inner:
                node = .join(condition: cond, left: node, right: rn)
                // A bare ⋈ with no subscript *is* the natural join, so the node
                // needs nothing special — only the wording does.
                let what = join.natural ? "Natural join" : "Inner join"
                let over = join.natural
                    ? " over every column they share"
                    : (cond.map { " on \($0)" } ?? "")
                ref = emit(title: "\(what) (\(RASymbol.join))",
                           clause: join.natural ? "NATURAL JOIN" : "JOIN",
                           explanation: "\(what) with \(rref)\(over).",
                           node: node, rhs: "\(ref) \(RASymbol.join)\(condSub) \(rref)")
            case .left:
                node = .outerJoin(kind: .left, condition: cond, left: node, right: rn)
                ref = emit(title: "Left outer join (\(RASymbol.leftJoin))", clause: "LEFT JOIN",
                           explanation: "Left outer join with \(rref)\(cond.map { " on \($0)" } ?? "").",
                           node: node, rhs: "\(ref) \(RASymbol.leftJoin)\(condSub) \(rref)")
            case .right:
                node = .outerJoin(kind: .right, condition: cond, left: node, right: rn)
                ref = emit(title: "Right outer join (\(RASymbol.rightJoin))", clause: "RIGHT JOIN",
                           explanation: "Right outer join with \(rref)\(cond.map { " on \($0)" } ?? "").",
                           node: node, rhs: "\(ref) \(RASymbol.rightJoin)\(condSub) \(rref)")
            case .full:
                node = .outerJoin(kind: .full, condition: cond, left: node, right: rn)
                ref = emit(title: "Full outer join (\(RASymbol.fullJoin))", clause: "FULL JOIN",
                           explanation: "Full outer join with \(rref)\(cond.map { " on \($0)" } ?? "").",
                           node: node, rhs: "\(ref) \(RASymbol.fullJoin)\(condSub) \(rref)")
            }
        }

        return (node, ref)
    }

    /// A table reference → (node, reference string). Base tables reference their
    /// own name; derived tables reference the sub-query's final result.
    private func relation(_ table: TableRef) -> (RANode, String) {
        switch table {
        case let .named(name, alias):
            return (.relation(name: name, alias: alias), name)
        case let .derived(query, alias):
            let (node, ref) = build(query)
            if let alias {
                return (.rename(alias: alias, child: node), ref)
            }
            return (node, ref)
        }
    }

    private func joinCondition(_ join: Join) -> String? {
        if let on = join.on { return on.rendered }
        if !join.using.isEmpty { return "USING (" + join.using.joined(separator: ", ") + ")" }
        return nil
    }

    // MARK: - Helpers

    private func groupSubscript(grouping: [String], aggregates: [String]) -> String {
        let g = grouping.joined(separator: ", ")
        let a = aggregates.joined(separator: ", ")
        if g.isEmpty { return a }
        if a.isEmpty { return g }
        return "\(g); \(a)"
    }

    private func collectAggregates(_ stmt: SelectStatement) -> [String] {
        var result: [String] = []
        for item in stmt.projections {
            if case let .expression(expr, alias) = item, expr.containsAggregate {
                let base = expr.rendered
                result.append(alias.map { "\(base) → \($0)" } ?? base)
            }
        }
        return result
    }

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

    /// Render an integer using Unicode subscript digits (1 → ₁).
    private func subscriptNumber(_ n: Int) -> String {
        let subs: [Character] = ["₀", "₁", "₂", "₃", "₄", "₅", "₆", "₇", "₈", "₉"]
        return String(String(n).compactMap { c in c.wholeNumberValue.map { subs[$0] } })
    }
}
