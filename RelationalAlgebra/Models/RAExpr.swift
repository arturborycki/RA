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

extension RAExpr {
    /// Written out rather than derived, for the reason given on `CalcTerm.==`:
    /// a synthesised `==` on a recursive enum is what the Xcode 16.4 frontend
    /// walks into a "circular reference" on, with no source location. The
    /// non-matching cases are listed rather than defaulted so a new case is a
    /// compile error here instead of a silently unequal pair.
    static func == (lhs: RAExpr, rhs: RAExpr) -> Bool {
        switch (lhs, rhs) {
        case let (.relation(a), .relation(b)):
            return a == b
        case let (.selection(aCond, aChild), .selection(bCond, bChild)):
            return aCond == bCond && aChild == bChild
        case let (.projection(aItems, aChild), .projection(bItems, bChild)):
            return aItems == bItems && aChild == bChild
        case let (.rename(aName, aCols, aChild), .rename(bName, bCols, bChild)):
            return aName == bName && aCols == bCols && aChild == bChild
        case let (.distinct(a), .distinct(b)):
            return a == b
        case let (.join(aKind, aCond, aLeft, aRight), .join(bKind, bCond, bLeft, bRight)):
            return aKind == bKind && aCond == bCond && aLeft == bLeft && aRight == bRight
        case let (.cross(aLeft, aRight), .cross(bLeft, bRight)):
            return aLeft == bLeft && aRight == bRight
        case let (.setOperation(aOp, aLeft, aRight), .setOperation(bOp, bLeft, bRight)):
            return aOp == bOp && aLeft == bLeft && aRight == bRight
        case (.relation, _), (.selection, _), (.projection, _), (.rename, _),
             (.distinct, _), (.join, _), (.cross, _), (.setOperation, _):
            return false
        }
    }
}

/// What the RA editor holds: optional table declarations, then one expression.
struct RAScript: Equatable {
    var declarations: [TableDeclaration]
    var expression: RAExpr

    static func == (lhs: RAScript, rhs: RAScript) -> Bool {
        lhs.declarations == rhs.declarations && lhs.expression == rhs.expression
    }
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
