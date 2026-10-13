//
//  RAExpr.swift
//  RelationalAlgebra
//
//  The relational-algebra tree the RA *input* parser produces.
//
//  It is a second tree beside `RANode` on purpose. `RANode` is the output of
//  the SQL → RA translator and stores its conditions as pre-rendered strings,
//  which is all a renderer needs. Going the other way, RA → SQL, needs the
//  conditions' structure — to qualify attributes, to merge a σ into a WHERE —
//  so the leaves here are the SQL parser's own `Expression` and `SelectItem`.
//  (The subscripts are parsed by the SQL expression parser, which is why that
//  is free.)
//

import Foundation

enum RAJoinKind: Equatable {
    case inner
    case left
    case right
    case full
}

indirect enum RAExpr: Equatable {
    /// A base relation by name.
    case relation(String)
    /// σ[condition](child)
    case selection(condition: Expression, child: RAExpr)
    /// π[items](child). An item may carry a rename: `π[salary * 12 → annual]`.
    case projection(items: [SelectItem], child: RAExpr)
    /// ρ[name](child), or ρ[name(a, b, …)](child) to rename the attributes too.
    case rename(name: String, columns: [String], child: RAExpr)
    /// δ(child)
    case distinct(child: RAExpr)
    /// ⋈[condition], ⟕, ⟖, ⟗ — a natural join when `condition` is nil.
    case join(kind: RAJoinKind, condition: Expression?, left: RAExpr, right: RAExpr)
    /// ×
    case cross(left: RAExpr, right: RAExpr)
    /// ∪, ∩, −
    case setOperation(SetOperator, left: RAExpr, right: RAExpr)
}

/// What the RA editor holds: optional table declarations, then one expression.
struct RAScript: Equatable {
    var declarations: [TableDeclaration]
    var expression: RAExpr
}

extension RAExpr {
    /// Every base relation the expression reads, in first-mention order.
    var relationNames: [String] {
        var seen: [String] = []
        func visit(_ node: RAExpr) {
            switch node {
            case let .relation(name):
                if !seen.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                    seen.append(name)
                }
            case let .selection(_, child), let .projection(_, child),
                 let .rename(_, _, child), let .distinct(child):
                visit(child)
            case let .join(_, _, left, right), let .cross(left, right),
                 let .setOperation(_, left, right):
                visit(left)
                visit(right)
            }
        }
        visit(self)
        return seen
    }
}
