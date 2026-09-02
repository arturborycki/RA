//
//  CalcTranslation.swift
//  RelationalAlgebra
//
//  The full result of translating a query into one of the relational calculi —
//  the counterpart of `RATranslation` on the algebra side.
//
//  The step-by-step construction sequence (each step showing the whole formula
//  so far with the newly-added conjunct highlighted) lands with the calculus
//  steps view; this type carries the finished expression and the fidelity
//  diagnostics that must be shown alongside it.
//

import Foundation

struct CalcTranslation: Equatable {
    var dialect: CalcDialect
    /// `WITH` bindings, in declaration order, each named as it was in the SQL.
    var definitions: [CalcDefinition]
    /// The expression the query as a whole denotes.
    var root: CalcExpression
    /// What was known about each relation when this was built.
    var schema: QuerySchema
    /// Everything that was not translated exactly, and why.
    var diagnostics: [CalcDiagnostic]

    /// The single-line form, for copying.
    var inlineText: String { CalcRenderer().inline(self) }

    /// The line-broken form, for display.
    func prettyText(lineWidth: Int = 64) -> String {
        CalcRenderer(lineWidth: lineWidth).pretty(self)
    }

    /// Relations whose attribute list was only inferred, so a DRC atom over
    /// them could not yet be written with a trustworthy arity.
    var relationsWithInferredArity: [RelationSchema] {
        schema.sortedRelations.filter { !$0.arityKnown && !$0.attributes.isEmpty }
    }
}
