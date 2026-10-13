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
}

/// A well-formed input that has no SQL translation, such as a self-join whose
/// two sides were never renamed apart.
struct TranslationError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
