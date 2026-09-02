//
//  CalcDiagnostic.swift
//  RelationalAlgebra
//
//  The fidelity model.
//
//  Some SQL maps onto the relational calculus exactly; some needs a documented
//  extension; some has no first-order expression at all. Every construct the
//  translator handles declares which of the three it is, and the UI shows the
//  ones that were not exact. Nothing is silently approximated — a formula that
//  quietly drops `ORDER BY`, or invents an arity for a DRC atom, is a formula a
//  grader would mark wrong.
//

import Foundation

/// How faithfully a construct was expressed in the calculus.
enum Fidelity: Equatable {
    /// Standard textbook notation, no caveats.
    case exact
    /// Expressible only with a documented extension to the pure calculus
    /// (aggregation, nulls, three-valued logic).
    case extended
    /// Outside first-order calculus entirely; shown as an annotation *outside*
    /// the set-builder braces rather than faked inside it.
    case annotated

    var label: String {
        switch self {
        case .exact:     return "exact"
        case .extended:  return "extension"
        case .annotated: return "annotated"
        }
    }
}

enum DiagnosticSeverity: Equatable {
    /// Worth knowing, but the formula is correct as shown (e.g. DISTINCT is a
    /// no-op because a calculus expression denotes a set).
    case info
    /// The formula is incomplete or approximate in a way the reader must see.
    case warning
}

/// Which axis a diagnostic is about. Fidelity is how faithfully SQL was
/// expressed in the calculus; safety is whether the resulting formula is
/// domain-independent. They are independent — an exactly-translated formula can
/// still be unsafe — so they are not folded into one enum.
enum DiagnosticKind: Equatable {
    case fidelity
    case safety
}

struct CalcDiagnostic: Identifiable, Equatable {
    let id = UUID()
    var kind: DiagnosticKind = .fidelity
    var severity: DiagnosticSeverity
    var fidelity: Fidelity
    /// The SQL construct responsible, e.g. "LEFT JOIN", "COUNT(*)", "ORDER BY".
    var construct: String
    /// What the reader needs to know, in one sentence.
    var message: String

    /// The short word shown on the badge.
    var badge: String {
        kind == .safety ? "unsafe" : fidelity.label
    }

    static func == (lhs: CalcDiagnostic, rhs: CalcDiagnostic) -> Bool {
        lhs.kind == rhs.kind && lhs.severity == rhs.severity && lhs.fidelity == rhs.fidelity &&
        lhs.construct == rhs.construct && lhs.message == rhs.message
    }

    static func info(_ construct: String, _ message: String) -> CalcDiagnostic {
        CalcDiagnostic(severity: .info, fidelity: .exact, construct: construct, message: message)
    }

    static func extended(_ construct: String, _ message: String) -> CalcDiagnostic {
        CalcDiagnostic(severity: .warning, fidelity: .extended, construct: construct, message: message)
    }

    static func annotated(_ construct: String, _ message: String) -> CalcDiagnostic {
        CalcDiagnostic(severity: .warning, fidelity: .annotated, construct: construct, message: message)
    }

    /// The formula is domain-dependent: its answer would depend on the infinite
    /// universe of possible values rather than on the database.
    static func unsafe(_ construct: String, _ message: String) -> CalcDiagnostic {
        CalcDiagnostic(kind: .safety, severity: .warning, fidelity: .exact,
                       construct: construct, message: message)
    }
}

extension Array where Element == CalcDiagnostic {
    /// Warnings first, then info, preserving discovery order within each group.
    var presentationOrder: [CalcDiagnostic] {
        filter { $0.severity == .warning } + filter { $0.severity == .info }
    }

    var warningCount: Int { lazy.filter { $0.severity == .warning }.count }

    /// Drop repeats of the same construct + message, which a query with several
    /// similar clauses would otherwise produce.
    var deduplicated: [CalcDiagnostic] {
        var seen = Set<String>()
        return filter { seen.insert("\($0.construct)\u{1}\($0.message)").inserted }
    }
}
