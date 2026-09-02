//
//  CalcIR.swift
//  RelationalAlgebra
//
//  The shared intermediate representation for both relational calculi.
//
//  Tuple relational calculus (TRC) and domain relational calculus (DRC) differ
//  only in the shape of their relation atoms and terms — `R(t)` with `t.A`
//  versus `R(x₁, …, xₙ)` with bare `x` — so they share one tree, one renderer
//  and (later) one simplifier and safety checker. DRC is produced by lowering a
//  TRC tree, not by a second translator.
//
//  The tree is deliberately structural: no identity, no UUIDs, so `Equatable`
//  means "the same formula" and tests can compare trees directly. When step
//  highlighting needs to point at a subtree, the renderer computes a path from
//  the root rather than the nodes carrying ids.
//

import Foundation

/// Canonical logic glyphs, mirroring `RASymbol` for the algebra side.
enum CalcSymbol {
    static let exists      = "∃"
    static let forAll      = "∀"
    static let and         = "∧"
    static let or          = "∨"
    static let not         = "¬"
    static let implies     = "→"
    static let union       = "∪"
    static let intersect   = "∩"
    static let difference  = "−"
    static let openTuple   = "⟨"
    static let closeTuple  = "⟩"
    static let such        = "|"
    static let renameArrow = "→"
}

/// Which calculus a `CalcQuery` is expressed in. Affects rendering and
/// lowering only — the tree shape is shared.
enum CalcDialect: String, Equatable {
    case trc = "TRC"
    case drc = "DRC"
}

// MARK: - Variables and terms

/// A tuple variable in TRC, a domain variable in DRC.
struct CalcVar: Hashable {
    /// The name as written in the formula, e.g. "e", "t₁", "sal".
    var name: String
    /// The relation this variable ranges over, kept for explanations.
    var relation: String?
    /// DRC only: which column of that relation this variable stands for.
    var attribute: String? = nil
}

/// A scalar term appearing in a comparison, a relation atom or a result column.
indirect enum CalcTerm: Equatable {
    /// A bare variable — the DRC form, and the TRC form when a whole tuple is meant.
    case variable(CalcVar)
    /// `t.salary` — the TRC form.
    case attribute(CalcVar, String)
    /// A literal rendered exactly as it should appear: `'Berlin'`, `50000`, `NULL`.
    case literal(String)
    /// A function application: `UPPER(x)`, `COUNT(*)`, `COUNT(DISTINCT x)`.
    case application(name: String, args: [CalcTerm], distinct: Bool)
    /// An infix arithmetic or concatenation operator: `x + y`, `a || b`.
    case binaryOp(op: String, lhs: CalcTerm, rhs: CalcTerm)
    /// Anything not yet given structure, carrying its pre-rendered text.
    /// Always accompanied by a diagnostic so it is never silently approximated.
    case opaque(String)
}

extension CalcTerm {
    /// Every variable mentioned anywhere in this term.
    var variables: Set<CalcVar> {
        switch self {
        case let .variable(v):              return [v]
        case let .attribute(v, _):          return [v]
        case .literal, .opaque:             return []
        case let .application(_, args, _):  return args.reduce(into: Set()) { $0.formUnion($1.variables) }
        case let .binaryOp(_, lhs, rhs):    return lhs.variables.union(rhs.variables)
        }
    }
}

// MARK: - Formulas

/// A well-formed formula of the relational calculus.
indirect enum CalcFormula: Equatable {
    /// `Employee(t)` in TRC, `Employee(n, s, d)` in DRC.
    ///
    /// `arityKnown` says whether `terms` is the relation's *complete* column
    /// list. A TRC atom names one tuple variable and is therefore always
    /// complete; a DRC atom is positional, so it is complete only when the
    /// schema was declared. An incomplete list renders with a trailing ellipsis
    /// rather than passing a guessed arity off as fact.
    case relationAtom(relation: String, terms: [CalcTerm], arityKnown: Bool)
    case comparison(lhs: CalcTerm, op: String, rhs: CalcTerm)
    /// N-ary on purpose: the top-level conjunction is where the derivation
    /// appends, where the simplifier unifies equalities, and where the safety
    /// checker looks for range restrictions. A flat list makes all three easy.
    case and([CalcFormula])
    case or([CalcFormula])
    case not(CalcFormula)
    case exists([CalcVar], CalcFormula)
    case forAll([CalcVar], CalcFormula)
    case implies(CalcFormula, CalcFormula)
    /// A predicate with no first-order structure yet — `x IS NULL`, `x LIKE …`,
    /// an unexpanded sub-query. `terms` is what the checker can still see.
    case predicate(rendered: String, terms: [CalcTerm])
    case constant(Bool)
}

extension CalcFormula {
    /// Every variable mentioned, bound or free.
    var variables: Set<CalcVar> {
        switch self {
        case let .relationAtom(_, terms, _):
            return terms.reduce(into: Set()) { $0.formUnion($1.variables) }
        case let .comparison(lhs, _, rhs):
            return lhs.variables.union(rhs.variables)
        case let .and(parts), let .or(parts):
            return parts.reduce(into: Set()) { $0.formUnion($1.variables) }
        case let .not(inner):
            return inner.variables
        case let .exists(vars, body), let .forAll(vars, body):
            return body.variables.union(vars)
        case let .implies(lhs, rhs):
            return lhs.variables.union(rhs.variables)
        case let .predicate(_, terms):
            return terms.reduce(into: Set()) { $0.formUnion($1.variables) }
        case .constant:
            return []
        }
    }

    /// Variables not bound by any enclosing quantifier. This is what the safety
    /// checker analyses and what set-operation merging must not re-quantify.
    var freeVariables: Set<CalcVar> {
        switch self {
        case let .relationAtom(_, terms, _):
            return terms.reduce(into: Set()) { $0.formUnion($1.variables) }
        case let .comparison(lhs, _, rhs):
            return lhs.variables.union(rhs.variables)
        case let .and(parts), let .or(parts):
            return parts.reduce(into: Set()) { $0.formUnion($1.freeVariables) }
        case let .not(inner):
            return inner.freeVariables
        case let .exists(vars, body), let .forAll(vars, body):
            return body.freeVariables.subtracting(vars)
        case let .implies(lhs, rhs):
            return lhs.freeVariables.union(rhs.freeVariables)
        case let .predicate(_, terms):
            return terms.reduce(into: Set()) { $0.formUnion($1.variables) }
        case .constant:
            return []
        }
    }

    /// Whether an ∃ or ∀ appears anywhere inside — the marker that a sub-query
    /// was expanded rather than kept opaque.
    var containsQuantifier: Bool {
        switch self {
        case .exists, .forAll:
            return true
        case let .and(parts), let .or(parts):
            return parts.contains { $0.containsQuantifier }
        case let .not(inner):
            return inner.containsQuantifier
        case let .implies(lhs, rhs):
            return lhs.containsQuantifier || rhs.containsQuantifier
        case .relationAtom, .comparison, .predicate, .constant:
            return false
        }
    }

    /// Conjoin, flattening nested `and` and dropping `TRUE`.
    static func conjunction(_ parts: [CalcFormula]) -> CalcFormula {
        var flat: [CalcFormula] = []
        for part in parts {
            switch part {
            case .constant(true):     continue
            case let .and(inner):     flat.append(contentsOf: inner)
            default:                  flat.append(part)
            }
        }
        if flat.isEmpty { return .constant(true) }
        if flat.count == 1 { return flat[0] }
        return .and(flat)
    }

    /// Disjoin, flattening nested `or`.
    static func disjunction(_ parts: [CalcFormula]) -> CalcFormula {
        var flat: [CalcFormula] = []
        for part in parts {
            if case let .or(inner) = part { flat.append(contentsOf: inner) } else { flat.append(part) }
        }
        if flat.isEmpty { return .constant(false) }
        if flat.count == 1 { return flat[0] }
        return .or(flat)
    }

    /// The conjuncts of a top-level `and`, or `[self]` for anything else.
    var conjuncts: [CalcFormula] {
        if case let .and(parts) = self { return parts }
        if case .constant(true) = self { return [] }
        return [self]
    }
}

// MARK: - Result specification

/// One output column: the term that produces it, and the name it is published
/// under when `SELECT … AS` gave it one.
struct ResultColumn: Equatable {
    var term: CalcTerm
    var name: String? = nil
}

/// An operator SQL asks for that first-order calculus cannot express. Rendered
/// outside the braces so the calculus expression itself stays honest.
struct CalcExtension: Equatable {
    enum Kind: Equatable {
        case grouping
        case having
        case sort
        case limit
    }
    var kind: Kind
    /// Pre-rendered description, e.g. "sort by avg_salary ↓".
    var rendered: String
}

/// How the result specification is written.
///
/// The tuple form is the general one — fresh result variables bound by equality,
/// which is what merging two branches of a set operation needs. The compact form
/// projects attributes of a free tuple variable directly and is available only
/// when every result column has that shape; it is much the more readable of the
/// two, so it is preferred wherever it applies.
enum CalcResultStyle: Equatable {
    /// `{ t.name, t.salary | … }`
    case compact
    /// `{ ⟨a, b⟩ | … }`
    case tuple
}

/// A single set-builder expression: `{ result | formula }`.
struct CalcQuery: Equatable {
    var dialect: CalcDialect
    var result: [ResultColumn]
    var formula: CalcFormula
    var resultStyle: CalcResultStyle = .compact
    var extensions: [CalcExtension] = []
}

/// Set operations combine whole calculus expressions. In a later phase these
/// are merged into a single formula over shared result variables; expressing
/// them as a set-algebra combination first is both correct and closer to how
/// the SQL is written.
enum CalcSetOperator: Equatable {
    case union, intersect, difference

    var glyph: String {
        switch self {
        case .union:      return CalcSymbol.union
        case .intersect:  return CalcSymbol.intersect
        case .difference: return CalcSymbol.difference
        }
    }
}

indirect enum CalcExpression: Equatable {
    case query(CalcQuery)
    case setOperation(op: CalcSetOperator, left: CalcExpression, right: CalcExpression)
}

/// A named binding, used for `WITH` common table expressions.
struct CalcDefinition: Equatable {
    var name: String
    var expression: CalcExpression
}
