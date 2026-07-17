//
//  ExpressionRendering.swift
//  RelationalAlgebra
//
//  Renders `Expression` values back into compact, human-readable predicate
//  strings for use inside σ / θ subscripts, and helpers for pulling attribute
//  names out of SELECT items.
//

import Foundation

extension Expression {

    /// Render this expression as a condition/attribute string.
    var rendered: String {
        switch self {
        case let .column(table, name):
            if let table { return "\(table).\(name)" }
            return name
        case let .numberLiteral(value):
            return value
        case let .stringLiteral(value):
            return "'\(value)'"
        case let .boolLiteral(value):
            return value ? "TRUE" : "FALSE"
        case .nullLiteral:
            return "NULL"
        case .star:
            return "*"
        case let .binary(op, lhs, rhs):
            return "\(lhs.rendered) \(op) \(rhs.rendered)"
        case let .unary(op, operand):
            if op == "-" { return "-\(operand.rendered)" }
            return "\(op) \(operand.rendered)"
        case let .function(name, args, distinct):
            let inner = args.map { $0.rendered }.joined(separator: ", ")
            return distinct ? "\(name)(DISTINCT \(inner))" : "\(name)(\(inner))"
        case let .between(value, lower, upper, negated):
            let kw = negated ? "NOT BETWEEN" : "BETWEEN"
            return "\(value.rendered) \(kw) \(lower.rendered) AND \(upper.rendered)"
        case let .inList(value, list, negated):
            let kw = negated ? "NOT IN" : "IN"
            let items = list.map { $0.rendered }.joined(separator: ", ")
            return "\(value.rendered) \(kw) (\(items))"
        case let .inSubquery(value, _, negated):
            let kw = negated ? "NOT IN" : "IN"
            return "\(value.rendered) \(kw) (…)"
        case let .exists(_, negated):
            return "\(negated ? "NOT " : "")EXISTS (…)"
        case let .isNull(expr, negated):
            return "\(expr.rendered) IS \(negated ? "NOT " : "")NULL"
        case let .list(items):
            return items.map { $0.rendered }.joined(separator: ", ")
        case .subquery:
            return "(…)"
        case let .paren(inner):
            return "(\(inner.rendered))"
        case let .caseExpression(operand, cases, elseResult):
            var s = "CASE"
            if let operand { s += " \(operand.rendered)" }
            for clause in cases {
                s += " WHEN \(clause.condition.rendered) THEN \(clause.result.rendered)"
            }
            if let elseResult { s += " ELSE \(elseResult.rendered)" }
            s += " END"
            return s
        case let .cast(expression, type):
            return "CAST(\(expression.rendered) AS \(type))"
        case let .window(function, partitionBy, orderBy, frame):
            var parts: [String] = []
            if !partitionBy.isEmpty {
                parts.append("PARTITION BY " + partitionBy.map { $0.rendered }.joined(separator: ", "))
            }
            if !orderBy.isEmpty {
                let keys = orderBy.map { "\($0.expression.rendered)\($0.descending ? " DESC" : "")" }
                parts.append("ORDER BY " + keys.joined(separator: ", "))
            }
            if let frame { parts.append(frame) }
            return "\(function.rendered) OVER (\(parts.joined(separator: " ")))"
        case let .typedLiteral(type, value):
            return "\(type) '\(value)'"
        case let .interval(value, unit):
            return unit.isEmpty ? "INTERVAL '\(value)'" : "INTERVAL '\(value)' \(unit)"
        }
    }

    /// A best-effort attribute name for this expression when it appears in a
    /// projection without an explicit alias.
    var attributeName: String {
        switch self {
        case let .column(_, name):
            return name
        case let .function(name, args, _):
            let inner = args.map { $0.rendered }.joined(separator: ", ")
            return "\(name)(\(inner))"
        default:
            return rendered
        }
    }
}

extension SelectItem {
    /// The attribute label to place inside a π subscript.
    var attributeLabel: String {
        switch self {
        case .star:
            return "*"
        case let .qualifiedStar(table):
            return "\(table).*"
        case let .expression(expr, alias):
            if let alias {
                // Show `expr → alias` so the rename is visible in the projection.
                let base = expr.attributeName
                return base == alias ? alias : "\(base) → \(alias)"
            }
            return expr.attributeName
        }
    }

    /// Whether this item is an aggregate function call (COUNT/SUM/AVG/MIN/MAX).
    var isAggregate: Bool {
        if case let .expression(expr, _) = self {
            return expr.containsAggregate
        }
        return false
    }
}

extension Expression {
    /// Aggregate functions that, when present in the SELECT list, imply a
    /// grouping (γ) operator.
    static let aggregateFunctions: Set<String> = [
        "COUNT", "SUM", "AVG", "MIN", "MAX",
        "STDDEV", "STDDEV_SAMP", "STDDEV_POP",
        "VARIANCE", "VAR_SAMP", "VAR_POP",
        "APPROX_COUNT_DISTINCT", "COUNT_BIG"
    ]

    var containsAggregate: Bool {
        switch self {
        case let .function(name, args, _):
            if Expression.aggregateFunctions.contains(name.uppercased()) { return true }
            // A non-aggregate function may still wrap an aggregate argument.
            return args.contains { $0.containsAggregate }
        case let .binary(_, lhs, rhs):
            return lhs.containsAggregate || rhs.containsAggregate
        case let .unary(_, operand):
            return operand.containsAggregate
        case let .paren(inner):
            return inner.containsAggregate
        case let .cast(expression, _):
            return expression.containsAggregate
        case let .caseExpression(operand, cases, elseResult):
            if operand?.containsAggregate == true { return true }
            if cases.contains(where: { $0.condition.containsAggregate || $0.result.containsAggregate }) {
                return true
            }
            return elseResult?.containsAggregate == true
        case .window:
            // Window aggregates do NOT collapse rows, so they don't imply γ.
            return false
        default:
            return false
        }
    }
}
