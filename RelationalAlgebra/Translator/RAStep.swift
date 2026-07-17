//
//  RAStep.swift
//  RelationalAlgebra
//
//  One entry in the step-by-step derivation. Each step captures the relational
//  operator that was applied, a plain-language explanation, and the full RA
//  expression as it stands after the step is applied.
//

import Foundation

struct RAStep: Identifiable, Equatable {
    let id = UUID()
    /// 1-based order in the derivation.
    let index: Int
    /// e.g. "Selection (σ)".
    let title: String
    /// Which SQL clause this corresponds to, e.g. "WHERE".
    let clause: String
    /// Plain-language description of what happened.
    let explanation: String
    /// The relational-algebra expression after this step.
    let expression: RANode
}

/// The full result of translating a query.
struct RATranslation: Equatable {
    var steps: [RAStep]
    /// The final RA expression (equal to the last step's expression).
    var finalExpression: RANode
}
