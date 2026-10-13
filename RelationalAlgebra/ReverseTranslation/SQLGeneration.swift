//
//  SQLGeneration.swift
//  RelationalAlgebra
//
//  The result of translating a notation *into* SQL.
//

import Foundation

struct SQLGeneration: Equatable {
    /// The generated query, which the forward pipeline then translates into
    /// every other notation exactly as if the user had typed it.
    var query: SQLQuery
    /// `query`, printed.
    var text: String
    /// What the reader should know about how the SQL was produced. The same
    /// type the calculus uses, so one banner serves every direction.
    var diagnostics: [CalcDiagnostic]
    /// One card per operator, bottom-up: how each became part of the SQL.
    var steps: [ReverseStep] = []

    /// Written out rather than derived; see `RAExpr.==`.
    static func == (lhs: SQLGeneration, rhs: SQLGeneration) -> Bool {
        lhs.text == rhs.text && lhs.query == rhs.query && lhs.diagnostics == rhs.diagnostics
            && lhs.steps == rhs.steps
    }
}

/// One operator of the input, and the SQL it has become by that point.
struct ReverseStep: Identifiable, Equatable {
    let id = UUID()
    /// 1-based, in the order the operators were translated: children first.
    var index: Int
    /// e.g. "Selection σ".
    var title: String
    /// The sub-expression this step translated, on one line.
    var algebra: String
    /// The SQL for that sub-expression.
    var sql: String
    /// How the operator was folded into the SQL, and why that way.
    var explanation: String

    /// Identity aside: two steps are equal when they say the same thing.
    static func == (lhs: ReverseStep, rhs: ReverseStep) -> Bool {
        lhs.index == rhs.index && lhs.title == rhs.title && lhs.algebra == rhs.algebra
            && lhs.sql == rhs.sql && lhs.explanation == rhs.explanation
    }
}

/// A well-formed input that has no SQL translation, such as a self-join whose
/// two sides were never renamed apart.
struct TranslationError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
