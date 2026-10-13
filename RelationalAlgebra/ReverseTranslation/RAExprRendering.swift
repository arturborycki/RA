//
//  RAExprRendering.swift
//  RelationalAlgebra
//
//  Writes a parsed algebra expression back out in the app's own notation.
//
//  Rather than a second renderer, the input tree is mapped onto `RANode` —
//  the tree the SQL → RA direction renders — so typed algebra comes back in
//  exactly the form the Formula view prints: same glyphs, same brackets, same
//  line breaking. That is also what makes Prettify safe: its output is the
//  printed form, which the parser is held to reading back.
//

import Foundation

extension RAExpr {
    /// The equivalent display tree. Conditions and projection items are
    /// printed by the SQL printer, which is what the forward direction's
    /// subscripts contain too.
    var node: RANode {
        let printer = SQLPrinter()
        switch self {
        case let .relation(name):
            return .relation(name: name, alias: nil)

        case let .selection(condition, child):
            return .selection(condition: printer.expression(condition), child: child.node)

        case let .projection(items, child):
            let attributes = items.map { item -> String in
                switch item {
                case .star:
                    return "*"
                case let .qualifiedStar(table):
                    return printer.identifier(table) + ".*"
                case let .expression(expression, alias):
                    return printer.expression(expression) + (alias.map { " → " + $0 } ?? "")
                }
            }
            return .projection(attributes: attributes, child: child.node)

        case let .rename(name, columns, child):
            if columns.isEmpty, case let .relation(table) = child {
                return .relation(name: table, alias: name)
            }
            let label = columns.isEmpty ? name : "\(name)(\(columns.joined(separator: ", ")))"
            return .rename(alias: label, child: child.node)

        case let .distinct(child):
            return .distinct(child: child.node)

        case let .join(kind, condition, left, right):
            let text = condition.map { printer.expression($0) }
            switch kind {
            case .inner: return .join(condition: text, left: left.node, right: right.node)
            case .left:  return .outerJoin(kind: .left, condition: text, left: left.node, right: right.node)
            case .right: return .outerJoin(kind: .right, condition: text, left: left.node, right: right.node)
            case .full:  return .outerJoin(kind: .full, condition: text, left: left.node, right: right.node)
            }

        case let .cross(left, right):
            return .cross(left: left.node, right: right.node)

        case let .setOperation(op, left, right):
            switch op {
            case .union:     return .union(left: left.node, right: right.node)
            case .intersect: return .intersect(left: left.node, right: right.node)
            case .except:    return .difference(left: left.node, right: right.node)
            }
        }
    }
}

extension RAScript {
    /// The script in the app's notation: the declarations as they were
    /// written, one line per assignment, then the expression laid out over
    /// several lines. An expression that only names the last assignment is
    /// left implicit, as it was when the buffer ended on that assignment.
    func prettyText(prelude: String) -> String {
        var sections: [String] = []
        let declarations = prelude.trimmingCharacters(in: .whitespacesAndNewlines)
        if !declarations.isEmpty { sections.append(declarations) }

        if !assignments.isEmpty {
            sections.append(assignments
                .map { "\($0.name) = \($0.expression.node.formula)" }
                .joined(separator: "\n"))
        }

        let namesLast: Bool
        if let last = assignments.last, case let .relation(name) = expression {
            namesLast = last.name.caseInsensitiveCompare(name) == .orderedSame
        } else {
            namesLast = false
        }
        if !namesLast { sections.append(expression.node.prettyFormula) }

        return sections.joined(separator: "\n\n")
    }
}
