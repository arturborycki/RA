//
//  CalcStep.swift
//  RelationalAlgebra
//
//  One entry in a calculus derivation.
//
//  The algebra's derivation is a chain of named intermediate relations
//  (R₁ = σ[…]( R₀ ), …). The calculus builds *one* formula instead, so the
//  analogue is a construction sequence: each step shows the whole expression as
//  it stands, together with the part this step introduced.
//

import Foundation

struct CalcStep: Identifiable, Equatable {
    let id = UUID()
    /// 1-based order in the derivation.
    var index: Int
    /// e.g. "Range variables", "Selection", "Quantification".
    var title: String
    /// Which SQL clause this corresponds to, e.g. "WHERE".
    var clause: String
    /// Plain-language description of what happened and why.
    var explanation: String
    /// The whole expression after this step.
    var expression: CalcExpression
    /// What this step added, rendered on its own — the running formula shows it
    /// in context, this shows it in isolation.
    var added: String?

    static func == (lhs: CalcStep, rhs: CalcStep) -> Bool {
        lhs.index == rhs.index && lhs.title == rhs.title && lhs.clause == rhs.clause &&
        lhs.explanation == rhs.explanation && lhs.expression == rhs.expression &&
        lhs.added == rhs.added
    }
}
