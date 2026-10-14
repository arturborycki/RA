//
//  CalcScript.swift
//  RelationalAlgebra
//
//  What the calculus editor holds, parsed.
//
//  The parser targets the same IR the SQL → calculus direction produces —
//  `CalcExpression`, `CalcQuery`, `CalcFormula` — so a formula the user typed
//  can go through the very safety checker and renderer the translated ones do.
//

import Foundation

struct CalcScript: Equatable {
    var declarations: [TableDeclaration]
    /// `Name = { … }` lines, which become WITH clauses — the form the Formula
    /// view prints a CTE in.
    var definitions: [CalcDefinition]
    /// The expression the buffer denotes. When the buffer ends on a definition,
    /// a query over that name.
    var expression: CalcExpression
    /// Which calculus the formulas turned out to be written in.
    var dialect: CalcDialect
    /// `sort by … , limit …  applied to { … }` — the annotations the Formula
    /// view writes outside the braces, because first-order calculus has no
    /// order. They apply to the expression as a whole.
    var ordering: [CalcOrderKey] = []
    var limit: Int? = nil
    var offset: Int? = nil

    static func == (lhs: CalcScript, rhs: CalcScript) -> Bool {
        lhs.declarations == rhs.declarations && lhs.definitions == rhs.definitions
            && lhs.expression == rhs.expression && lhs.dialect == rhs.dialect
            && lhs.ordering == rhs.ordering && lhs.limit == rhs.limit && lhs.offset == rhs.offset
    }
}

/// One key of a `sort by` annotation.
struct CalcOrderKey: Equatable {
    var term: CalcTerm
    var descending: Bool
    var nullsFirst: Bool? = nil

    static func == (lhs: CalcOrderKey, rhs: CalcOrderKey) -> Bool {
        lhs.term == rhs.term && lhs.descending == rhs.descending && lhs.nullsFirst == rhs.nullsFirst
    }

    /// `total ↓ nulls last`, as the annotation prints it.
    var rendered: String {
        var text = "\(term.plainText) \(descending ? "↓" : "↑")"
        if let nullsFirst { text += nullsFirst ? " nulls first" : " nulls last" }
        return text
    }
}
