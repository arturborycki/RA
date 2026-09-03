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
    /// The expression the query as a whole denotes, as translated.
    var root: CalcExpression
    /// The same expression after the simplifier, equal to `root` when no
    /// rewrite applied. The direct translation is kept alongside it because
    /// "why did the equality disappear?" is a question the reader should be
    /// able to answer by looking.
    var simplified: CalcExpression
    /// The construction sequence that built it.
    var steps: [CalcStep]
    /// One step per simplification pass that changed something.
    var simplifications: [CalcStep] = []
    /// What was known about each relation when this was built.
    var schema: QuerySchema
    /// Everything that was not translated exactly, and why.
    var diagnostics: [CalcDiagnostic]

    /// Whether simplification changed anything worth offering a toggle for.
    var isSimplified: Bool { simplified != root }

    /// The single-line form of the direct translation, for copying.
    var inlineText: String { CalcRenderer().inline(self) }

    /// The line-broken form of the direct translation.
    func prettyText(lineWidth: Int = 64) -> String {
        CalcRenderer(lineWidth: lineWidth).pretty(self)
    }

    /// The line-broken simplified form, through the same rendering path as the
    /// direct translation so the two are directly comparable.
    func simplifiedText(lineWidth: Int = 64) -> String {
        var view = self
        view.root = simplified
        return CalcRenderer(lineWidth: lineWidth).pretty(view)
    }

    /// Run the simplifier, recording a step for every pass that fired. `WITH`
    /// bindings are simplified too, so a CTE and the body that references it
    /// are shown in the same form.
    func simplifying() -> CalcTranslation {
        let outcome = CalcSimplifier.simplify(root)
        var updated = self
        updated.definitions = definitions.map {
            CalcDefinition(name: $0.name, expression: CalcSimplifier.simplify($0.expression).expression)
        }
        updated.simplified = outcome.expression
        updated.simplifications = outcome.records.enumerated().map { offset, record in
            CalcStep(index: steps.count + offset + 1,
                     title: record.name,
                     clause: "simplify",
                     explanation: record.explanation,
                     expression: record.after,
                     added: nil)
        }
        return updated
    }

    /// Relations whose attribute list was only inferred, so a DRC atom over
    /// them could not yet be written with a trustworthy arity.
    var relationsWithInferredArity: [RelationSchema] {
        schema.sortedRelations.filter { !$0.arityKnown && !$0.attributes.isEmpty }
    }
}
