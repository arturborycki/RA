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

    static func == (lhs: CalcScript, rhs: CalcScript) -> Bool {
        lhs.declarations == rhs.declarations && lhs.definitions == rhs.definitions
            && lhs.expression == rhs.expression && lhs.dialect == rhs.dialect
    }
}
