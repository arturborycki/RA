//
//  RAStep.swift
//  RelationalAlgebra
//
//  One entry in the step-by-step derivation. Each step names its output
//  (R₁, R₂, …) and shows a single operator applied to previously-named
//  results, so no individual line repeats the whole nested expression.
//

import Foundation

struct RAStep: Identifiable, Equatable {
    let id = UUID()
    /// 1-based order in the derivation.
    let index: Int
    /// The name this step's result is bound to, e.g. "R₁" or a CTE name.
    let resultName: String
    /// e.g. "Selection (σ)".
    let title: String
    /// Which SQL clause this corresponds to, e.g. "WHERE".
    let clause: String
    /// Plain-language description of what happened.
    let explanation: String
    /// The assignment for this step, e.g. `R₂ = σ[age > 30] ( R₁ )`.
    let definition: String
    /// The full relational-algebra expression after this step (used elsewhere).
    let expression: RANode
}

/// The full result of translating a query.
struct RATranslation: Equatable {
    var steps: [RAStep]
    /// The final RA expression (equal to the last step's expression).
    var finalExpression: RANode
    /// The name bound to the final result (e.g. "R₅").
    var finalName: String
}
