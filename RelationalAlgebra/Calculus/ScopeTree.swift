//
//  ScopeTree.swift
//  RelationalAlgebra
//
//  The calculus expression drawn as a tree.
//
//  The algebra's diagram shows an operator tree — what to compute, in what
//  order. The calculus has no operators, so its diagram shows something else
//  entirely: the *scope* structure. Which quantifier binds which variable, how
//  deep the negations nest, and which variables the result leaves free. That is
//  the part of a formula that is genuinely hard to read off one line of text,
//  and it is what a reader gets wrong.
//
//  It reuses `DiagramNode`, so `TreeLayout` and `TreeView` serve both notations
//  without a second layout engine.
//

import Foundation

extension CalcExpression {
    /// The quantifier-and-connective structure, as a drawable tree.
    var scopeTree: DiagramNode {
        switch self {
        case let .query(query):
            return query.scopeTree
        case let .setOperation(op, left, right):
            return DiagramNode(symbol: op.glyph, detail: nil, isLeaf: false,
                               children: [left.scopeTree, right.scopeTree])
        }
    }
}

extension CalcQuery {
    var scopeTree: DiagramNode {
        let renderer = CalcRenderer()
        let spec = renderer.resultSpec(self)
        let free = formula.freeVariables.map(\.name).sorted()
        let detail = free.isEmpty ? spec : "\(spec)   free: \(free.joined(separator: ", "))"
        return DiagramNode(symbol: "{ … | … }", detail: detail, isLeaf: false,
                           children: [formula.scopeTree])
    }
}

extension CalcFormula {
    var scopeTree: DiagramNode {
        let renderer = CalcRenderer()

        switch self {
        case let .relationAtom(relation, terms, arityKnown):
            let inner = terms.map { $0.plainText }.joined(separator: ", ")
                + (arityKnown ? "" : ", …")
            return DiagramNode(symbol: "\(relation)(\(inner))", detail: nil,
                               isLeaf: true, children: [])

        case .comparison, .predicate, .constant, .aggregateBinding:
            // Atomic conditions are the leaves: they bind nothing, so the tree
            // has nothing to say about them beyond what they are.
            return DiagramNode(symbol: renderer.inline(self), detail: nil,
                               isLeaf: true, children: [])

        case let .and(parts):
            return DiagramNode(symbol: CalcSymbol.and, detail: nil, isLeaf: false,
                               children: parts.map(\.scopeTree))

        case let .or(parts):
            return DiagramNode(symbol: CalcSymbol.or, detail: nil, isLeaf: false,
                               children: parts.map(\.scopeTree))

        case let .not(inner):
            return DiagramNode(symbol: CalcSymbol.not, detail: nil, isLeaf: false,
                               children: [inner.scopeTree])

        case let .exists(vars, body):
            return DiagramNode(symbol: CalcSymbol.exists,
                               detail: vars.map(\.name).joined(separator: ", "),
                               isLeaf: false, children: [body.scopeTree])

        case let .forAll(vars, body):
            return DiagramNode(symbol: CalcSymbol.forAll,
                               detail: vars.map(\.name).joined(separator: ", "),
                               isLeaf: false, children: [body.scopeTree])

        case let .implies(lhs, rhs):
            return DiagramNode(symbol: CalcSymbol.implies, detail: "guard → body",
                               isLeaf: false, children: [lhs.scopeTree, rhs.scopeTree])
        }
    }
}
