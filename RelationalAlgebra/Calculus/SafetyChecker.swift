//
//  SafetyChecker.swift
//  RelationalAlgebra
//
//  Domain-independence analysis.
//
//  Relational calculus admits *unsafe* expressions — `{ t | ¬R(t) }` denotes
//  every tuple in the universe that is not in R, an answer that depends on the
//  infinite domain of possible values rather than on the database. A translator
//  that emits these teaches a false lesson, so every formula is checked.
//
//  A formula is safe when every free variable is *range-restricted*: bound by a
//  positive relation atom, or equated to a term that is. Negation and
//  comparison never range-restrict, which is where unsafe formulas come from.
//
//  In practice this reports nothing for a formula the translator built from
//  valid SQL — SQL cannot express an unsafe query. That makes the checker a
//  regression net for the translator, and it becomes a teaching device the
//  moment a formula can be hand-edited.
//

import Foundation

struct SafetyChecker {

    static func check(_ translation: CalcTranslation) -> [CalcDiagnostic] {
        var diagnostics: [CalcDiagnostic] = []
        for definition in translation.definitions {
            diagnostics += check(definition.expression, in: definition.name)
        }
        diagnostics += check(translation.root, in: nil)
        return diagnostics.deduplicated
    }

    private static func check(_ expression: CalcExpression, in context: String?) -> [CalcDiagnostic] {
        switch expression {
        case let .query(query):
            return check(query, in: context)
        case let .setOperation(_, left, right):
            return check(left, in: context) + check(right, in: context)
        }
    }

    private static func check(_ query: CalcQuery, in context: String?) -> [CalcDiagnostic] {
        var diagnostics: [CalcDiagnostic] = []
        let where_ = context.map { " in '\($0)'" } ?? ""

        let restricted = rangeRestricted(query.formula)

        // 1. Every variable the result exports must be restricted, or the
        //    expression ranges over the whole domain.
        for column in query.result {
            for variable in column.term.variables where !restricted.contains(variable) {
                diagnostics.append(.unsafe(
                    variable.name,
                    "The result uses '\(variable.name)'\(where_), but no positive relation atom " +
                    "restricts what it ranges over, so the expression is domain-dependent."))
            }
        }

        // 2. Same for anything left free in the formula itself.
        for variable in query.formula.freeVariables where !restricted.contains(variable) {
            diagnostics.append(.unsafe(
                variable.name,
                "'\(variable.name)' is free\(where_) but not restricted by a relation atom. " +
                "Comparisons and negation do not restrict a variable's range."))
        }

        // 3. A universal quantifier must be guarded — `∀x ( R(x) → … )` — or it
        //    asserts something about every value in the universe.
        diagnostics += unguardedUniversals(query.formula, context: where_)

        return diagnostics
    }

    /// Variables a formula range-restricts: those bound by a positive relation
    /// atom, plus anything an equality carries the restriction to, so that
    /// `∃u ( R(u) ∧ u.a = x )` restricts `x` as well as `u`.
    ///
    /// The analysis is compositional rather than a single walk collecting atoms,
    /// because a disjunction restricts only what *every* branch restricts — and
    /// each branch has to propagate its own equalities before that intersection
    /// is taken, or a merged `UNION` looks unsafe when it is not.
    private static func rangeRestricted(_ formula: CalcFormula) -> Set<CalcVar> {
        switch formula {
        case let .relationAtom(_, terms, _):
            return terms.reduce(into: Set()) { $0.formUnion($1.variables) }

        case let .and(parts):
            var restricted = parts.reduce(into: Set<CalcVar>()) { $0.formUnion(rangeRestricted($1)) }
            propagate(equalities(among: parts), bindings: aggregateBindings(among: parts),
                      into: &restricted)
            return restricted

        case let .or(parts):
            var common: Set<CalcVar>?
            for part in parts {
                let branch = rangeRestricted(part)
                common = common.map { $0.intersection(branch) } ?? branch
            }
            return common ?? []

        case let .exists(_, body):
            return rangeRestricted(body)

        case let .implies(antecedent, _):
            // The antecedent of a guarded ∀ restricts the variables it names.
            return rangeRestricted(antecedent)

        case let .comparison(lhs, op, rhs) where op == "=":
            // A lone equality is still a restriction when one side is ground:
            // `{ ⟨x⟩ | x = 5 }` denotes one value, not the whole domain.
            var restricted = Set<CalcVar>()
            propagate([(lhs, rhs)], bindings: [], into: &restricted)
            return restricted

        case .aggregateBinding:
            // `{ ⟨c⟩ | c = COUNT{ … } }` — one group, so one value.
            var restricted = Set<CalcVar>()
            propagate([], bindings: aggregateBindings(among: [formula]), into: &restricted)
            return restricted

        case .forAll, .not, .comparison, .predicate, .constant:
            // Negation does not restrict: `{ t | ¬R(t) }` is the classic unsafe
            // expression. Nor does a comparison: `{ x | x > 5 }` is unbounded.
            return []
        }
    }

    /// Equality comparisons directly among a conjunction's parts.
    private static func equalities(among parts: [CalcFormula]) -> [(CalcTerm, CalcTerm)] {
        parts.flatMap { part -> [(CalcTerm, CalcTerm)] in
            switch part {
            case let .comparison(lhs, op, rhs) where op == "=":
                return [(lhs, rhs)]
            case let .and(inner):
                return equalities(among: inner)
            default:
                return []
            }
        }
    }

    /// Aggregate bindings among a conjunction's parts, as (result variable, what
    /// the comprehension refers to from outside).
    private static func aggregateBindings(among parts: [CalcFormula]) -> [(CalcVar, Set<CalcVar>)] {
        parts.flatMap { part -> [(CalcVar, Set<CalcVar>)] in
            switch part {
            case let .aggregateBinding(result, _, _, element, variables, condition):
                return [(result, CalcFormula.aggregateFreeVariables(element: element,
                                                                    variables: variables,
                                                                    condition: condition))]
            case let .and(inner):
                return aggregateBindings(among: inner)
            default:
                return []
            }
        }
    }

    /// Carry restrictions across equalities until nothing new is restricted.
    ///
    /// A *ground* side — a constant, or an aggregate whose own free variables
    /// are already restricted — restricts the other side too: `{ ⟨x⟩ | x = 5 }`
    /// denotes one value, not the whole domain. That is the standard rule, and
    /// it is what keeps `h = COUNT{ … }` from reading as unsafe.
    ///
    /// An aggregate binding restricts its result the same way: once whatever the
    /// comprehension refers to from outside is restricted, the aggregate over it
    /// is a single value.
    private static func propagate(_ equalities: [(CalcTerm, CalcTerm)],
                                  bindings: [(CalcVar, Set<CalcVar>)],
                                  into restricted: inout Set<CalcVar>) {
        guard !equalities.isEmpty || !bindings.isEmpty else { return }
        var changed = true
        while changed {
            changed = false
            for (result, referenced) in bindings
            where referenced.isSubset(of: restricted) && !restricted.contains(result) {
                restricted.insert(result)
                changed = true
            }
            for (lhs, rhs) in equalities {
                let left = lhs.variables, right = rhs.variables
                if right.isSubset(of: restricted), !left.isEmpty, !left.isSubset(of: restricted) {
                    restricted.formUnion(left)
                    changed = true
                }
                if left.isSubset(of: restricted), !right.isEmpty, !right.isSubset(of: restricted) {
                    restricted.formUnion(right)
                    changed = true
                }
            }
        }
    }

    /// `∀x ( … )` whose body is not an implication guarded by a relation atom
    /// over `x`.
    private static func unguardedUniversals(_ formula: CalcFormula,
                                            context: String) -> [CalcDiagnostic] {
        switch formula {
        case let .forAll(vars, body):
            var diagnostics: [CalcDiagnostic] = []
            var guarded = Set<CalcVar>()
            if case let .implies(antecedent, _) = body {
                guarded = rangeRestricted(antecedent)
            }
            for variable in vars where !guarded.contains(variable) {
                diagnostics.append(.unsafe(
                    "∀\(variable.name)",
                    "'\(variable.name)' is universally quantified\(context) without a relation " +
                    "atom guarding it, so the claim is about every value in the universe. " +
                    "A safe ∀ has the form ∀\(variable.name) ( R(\(variable.name)) → … )."))
            }
            return diagnostics + unguardedUniversals(body, context: context)

        case let .aggregateBinding(_, _, _, _, _, condition):
            return unguardedUniversals(condition, context: context)
        case let .and(parts), let .or(parts):
            return parts.flatMap { unguardedUniversals($0, context: context) }
        case let .not(inner):
            return unguardedUniversals(inner, context: context)
        case let .exists(_, body):
            return unguardedUniversals(body, context: context)
        case let .implies(lhs, rhs):
            return unguardedUniversals(lhs, context: context)
                 + unguardedUniversals(rhs, context: context)
        case .relationAtom, .comparison, .predicate, .constant:
            return []
        }
    }
}
