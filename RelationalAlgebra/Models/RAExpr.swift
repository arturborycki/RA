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
    /// γ[keys; aggregates](child)
    case grouping(keys: [Expression], aggregates: [SelectItem], child: RAExpr)
    /// τ[keys](child)
    case sort(keys: [OrderItem], child: RAExpr)
    /// LIMIT[count offset n](child)
    case limit(count: Int?, offset: Int?, child: RAExpr)
    /// R ÷ S: the R-only attributes of the rows of R that pair with every row of S.
    case division(left: RAExpr, right: RAExpr)
}

extension RAExpr {
    /// Written out rather than derived, for the reason given on `CalcTerm.==`:
    /// a synthesised `==` on a recursive enum is what the Xcode 16.4 frontend
    /// walks into a "circular reference" on, with no source location.
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
        case let (.grouping(aKeys, aAggs, aChild), .grouping(bKeys, bAggs, bChild)):
            return aKeys == bKeys && aAggs == bAggs && aChild == bChild
        case let (.sort(aKeys, aChild), .sort(bKeys, bChild)):
            return aKeys == bKeys && aChild == bChild
        case let (.limit(aCount, aOffset, aChild), .limit(bCount, bOffset, bChild)):
            return aCount == bCount && aOffset == bOffset && aChild == bChild
        case let (.division(aLeft, aRight), .division(bLeft, bRight)):
            return aLeft == bLeft && aRight == bRight
        // A default rather than every non-matching pair: with twelve cases the
        // exhaustive list is more than the compiler will check in reasonable
        // time. A new case still needs its own matching line above.
        default:
            return false
        }
    }
}

/// `R₁ = σ[…](Employee)` — a named intermediate result, as the Steps view
/// writes a derivation.
struct RAAssignment: Equatable {
    var name: String
    var expression: RAExpr

    static func == (lhs: RAAssignment, rhs: RAAssignment) -> Bool {
        lhs.name == rhs.name && lhs.expression == rhs.expression
    }
}

/// What the RA editor holds: optional table declarations, any number of named
/// results, then the expression the whole buffer denotes. When the buffer ends
/// on an assignment, `expression` is just that name.
struct RAScript: Equatable {
    var declarations: [TableDeclaration]
    var expression: RAExpr
    var assignments: [RAAssignment] = []

    static func == (lhs: RAScript, rhs: RAScript) -> Bool {
        lhs.declarations == rhs.declarations && lhs.expression == rhs.expression
            && lhs.assignments == rhs.assignments
    }
}

extension RAExpr {
    /// Every relation name the expression reads, once per read — which is how
    /// a named result read twice is told from one read once.
    var relationReads: [String] {
        switch self {
        case let .relation(name):
            return [name]
        case let .selection(_, child), let .projection(_, child),
             let .rename(_, _, child), let .distinct(child),
             let .grouping(_, _, child), let .sort(_, child), let .limit(_, _, child):
            return child.relationReads
        case let .join(_, _, left, right), let .cross(left, right),
             let .setOperation(_, left, right), let .division(left, right):
            return left.relationReads + right.relationReads
        }
    }

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
                 let .rename(_, _, child), let .distinct(child),
                 let .grouping(_, _, child), let .sort(_, child), let .limit(_, _, child):
                visit(child)
            case let .join(_, _, left, right), let .cross(left, right),
                 let .setOperation(_, left, right), let .division(left, right):
                visit(left)
                visit(right)
            }
        }
        visit(self)
        return seen
    }
}
