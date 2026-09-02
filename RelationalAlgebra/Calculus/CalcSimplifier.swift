//
//  CalcSimplifier.swift
//  RelationalAlgebra
//
//  Rewrites that turn a mechanical translation into the formula a textbook
//  would print.
//
//  Each rewrite is a named pass rather than one opaque tidy-up, because "why did
//  the equality disappear?" is exactly the question a reader needs answered —
//  so a pass that fires can be shown as a derivation step, with the formula
//  before and after.
//
//  The passes are meaning-preserving. Substituting equals for equals is only
//  done from a *positive conjunctive* position that dominates the occurrences
//  being rewritten, and a variable is only eliminated when it is bound at that
//  same level; a variable the result exports is never substituted away.
//

import Foundation

struct CalcSimplifier {

    /// What one pass did, so the UI can show the rewrite rather than just its
    /// outcome.
    struct Record {
        var name: String
        var explanation: String
        var after: CalcExpression
    }

    struct Outcome {
        var expression: CalcExpression
        var records: [Record]
    }

    /// Applied in this order, repeatedly, until nothing changes. Unification
    /// exposes vacuous quantifiers, which expose more flattening, so a single
    /// pass over the list is not enough.
    private static let passes: [(name: String, explanation: String,
                                 apply: (CalcQuery) -> CalcQuery)] = [
        ("Unify equated variables",
         "Two domain variables joined by an equality are the same value, so one name serves for " +
         "both and the equality itself is no longer needed. This is what turns a mechanical " +
         "lowering into the idiomatic form where a shared column appears in both atoms.",
         CalcSimplifier.unifyEquatedVariables),

        ("Inline constants",
         "A variable equated to a constant can be written as that constant in the atom itself, " +
         "which drops both the variable and the comparison.",
         CalcSimplifier.inlineConstants),

        ("Flatten nested quantifiers",
         "∃x ( ∃y ( φ ) ) is ∃x, y ( φ ) — adjacent quantifiers of the same kind collapse into one.",
         CalcSimplifier.flattenQuantifiers),

        ("Drop vacuous quantifiers",
         "A quantifier binding a variable its body never mentions says nothing, so it goes.",
         CalcSimplifier.dropVacuousQuantifiers),

        ("Rewrite ¬∃ as ∀",
         "¬∃x ( R(x) ∧ ¬φ ) says no R fails φ, which is ∀x ( R(x) → φ ). The universal form is how " +
         "the same query is usually written, and it is where SQL's doubly-negated division query " +
         "turns back into 'for every'.",
         CalcSimplifier.rewriteNegatedExistentials)
    ]

    static func simplify(_ expression: CalcExpression) -> Outcome {
        var current = expression
        var records: [Record] = []
        // Bounded: each pass strictly shrinks the formula or renames into a
        // smaller variable set, but the bound makes non-termination impossible
        // rather than merely unlikely. Headroom for a TPC-H query, where one
        // relation contributes sixteen domain variables.
        for _ in 0..<16 {
            var changedThisRound = false
            for pass in passes {
                let next = map(current, pass.apply)
                guard next != current else { continue }
                records.append(Record(name: pass.name, explanation: pass.explanation, after: next))
                current = next
                changedThisRound = true
            }
            if !changedThisRound { break }
        }
        return Outcome(expression: current, records: records)
    }

    private static func map(_ expression: CalcExpression,
                            _ transform: (CalcQuery) -> CalcQuery) -> CalcExpression {
        switch expression {
        case let .query(query):
            return .query(transform(query))
        case let .setOperation(op, left, right):
            return .setOperation(op: op, left: map(left, transform), right: map(right, transform))
        }
    }

    // MARK: - Pass: unify equated variables

    private static func unifyEquatedVariables(_ query: CalcQuery) -> CalcQuery {
        var updated = query
        updated.formula = unify(query.formula, protected: exported(query))
        return updated
    }

    /// Within one quantifier's scope, `x = y` lets one name serve for both. The
    /// eliminated variable must be bound *here* — otherwise the substitution
    /// would escape the scope where the equality is known to hold.
    private static func unify(_ formula: CalcFormula, protected: Set<CalcVar>) -> CalcFormula {
        switch formula {
        case let .exists(vars, body):
            var vars = vars
            var body = unify(body, protected: protected)

            // Re-derive the equalities after every substitution: a chain
            // `a = b ∧ b = c` rewrites the later links, so a single pass over a
            // stale list would need one outer round per link to converge.
            var substituted = true
            while substituted {
                substituted = false
                for (lhs, rhs) in equalities(inSpineOf: body) {
                    guard case let .variable(a) = lhs, case let .variable(b) = rhs,
                          a != b else { continue }
                    // Keep whichever the result exports; otherwise keep the first.
                    let keep = protected.contains(b) && !protected.contains(a) ? b : a
                    let drop = keep == a ? b : a
                    guard vars.contains(drop), !protected.contains(drop) else { continue }
                    body = substitute(body, drop, with: .variable(keep))
                    vars.removeAll { $0 == drop }
                    substituted = true
                    break
                }
            }
            body = dropTrivialEqualities(body)
            return vars.isEmpty ? body : .exists(vars, body)

        case let .and(parts):
            return CalcFormula.conjunction(parts.map { unify($0, protected: protected) })
        case let .or(parts):
            return CalcFormula.disjunction(parts.map { unify($0, protected: protected) })
        case let .not(inner):
            return .not(unify(inner, protected: protected))
        case let .forAll(vars, body):
            return .forAll(vars, unify(body, protected: protected))
        case let .implies(lhs, rhs):
            return .implies(unify(lhs, protected: protected), unify(rhs, protected: protected))
        default:
            return formula
        }
    }

    // MARK: - Pass: inline constants

    private static func inlineConstants(_ query: CalcQuery) -> CalcQuery {
        var updated = query
        updated.formula = inline(query.formula, protected: exported(query))
        return updated
    }

    private static func inline(_ formula: CalcFormula, protected: Set<CalcVar>) -> CalcFormula {
        switch formula {
        case let .exists(vars, body):
            var vars = vars
            var body = inline(body, protected: protected)

            for (lhs, rhs) in equalities(inSpineOf: body) {
                let pair: (variable: CalcVar, literal: CalcTerm)?
                if case let .variable(v) = lhs, case .literal = rhs {
                    pair = (variable: v, literal: rhs)
                } else if case let .variable(v) = rhs, case .literal = lhs {
                    pair = (variable: v, literal: lhs)
                } else {
                    pair = nil
                }
                guard let pair, vars.contains(pair.variable),
                      !protected.contains(pair.variable) else { continue }
                body = substitute(body, pair.variable, with: pair.literal)
                vars.removeAll { $0 == pair.variable }
            }
            body = dropTrivialEqualities(body)
            return vars.isEmpty ? body : .exists(vars, body)

        case let .and(parts):
            return CalcFormula.conjunction(parts.map { inline($0, protected: protected) })
        case let .or(parts):
            return CalcFormula.disjunction(parts.map { inline($0, protected: protected) })
        case let .not(inner):
            return .not(inline(inner, protected: protected))
        case let .forAll(vars, body):
            return .forAll(vars, inline(body, protected: protected))
        case let .implies(lhs, rhs):
            return .implies(inline(lhs, protected: protected), inline(rhs, protected: protected))
        default:
            return formula
        }
    }

    // MARK: - Pass: flatten nested quantifiers

    private static func flattenQuantifiers(_ query: CalcQuery) -> CalcQuery {
        var updated = query
        updated.formula = flatten(query.formula)
        return updated
    }

    private static func flatten(_ formula: CalcFormula) -> CalcFormula {
        switch formula {
        case let .exists(vars, body):
            if case let .exists(innerVars, innerBody) = flatten(body) {
                return .exists(vars + innerVars.filter { !vars.contains($0) }, innerBody)
            }
            return .exists(vars, flatten(body))
        case let .forAll(vars, body):
            if case let .forAll(innerVars, innerBody) = flatten(body) {
                return .forAll(vars + innerVars.filter { !vars.contains($0) }, innerBody)
            }
            return .forAll(vars, flatten(body))
        case let .and(parts):
            return CalcFormula.conjunction(parts.map(flatten))
        case let .or(parts):
            return CalcFormula.disjunction(parts.map(flatten))
        case let .not(inner):
            return .not(flatten(inner))
        case let .implies(lhs, rhs):
            return .implies(flatten(lhs), flatten(rhs))
        default:
            return formula
        }
    }

    // MARK: - Pass: drop vacuous quantifiers

    private static func dropVacuousQuantifiers(_ query: CalcQuery) -> CalcQuery {
        var updated = query
        updated.formula = dropVacuous(query.formula)
        return updated
    }

    private static func dropVacuous(_ formula: CalcFormula) -> CalcFormula {
        switch formula {
        case let .exists(vars, body):
            let body = dropVacuous(body)
            let used = body.freeVariables
            let kept = vars.filter { used.contains($0) }
            return kept.isEmpty ? body : .exists(kept, body)
        case let .forAll(vars, body):
            let body = dropVacuous(body)
            let used = body.freeVariables
            let kept = vars.filter { used.contains($0) }
            return kept.isEmpty ? body : .forAll(kept, body)
        case let .and(parts):
            return CalcFormula.conjunction(parts.map(dropVacuous))
        case let .or(parts):
            return CalcFormula.disjunction(parts.map(dropVacuous))
        case let .not(inner):
            return .not(dropVacuous(inner))
        case let .implies(lhs, rhs):
            return .implies(dropVacuous(lhs), dropVacuous(rhs))
        default:
            return formula
        }
    }

    // MARK: - Pass: ¬∃ becomes ∀

    private static func rewriteNegatedExistentials(_ query: CalcQuery) -> CalcQuery {
        var updated = query
        updated.formula = rewriteNegated(query.formula)
        return updated
    }

    private static func rewriteNegated(_ formula: CalcFormula) -> CalcFormula {
        switch formula {
        case let .not(inner):
            let inner = rewriteNegated(inner)
            guard case let .exists(vars, body) = inner else { return .not(inner) }

            // Only worth doing when the body actually contains a negation: the
            // guard becomes the antecedent and the negated conjunct the
            // consequent. `¬∃x ( R(x) )` alone would only become `∀x ( ¬R(x) )`,
            // which is no clearer than where it started.
            let parts = body.conjuncts
            var negatedIndex: Int?
            for (index, part) in parts.enumerated() {
                if case .not = part {
                    guard negatedIndex == nil else { return .not(inner) } // more than one
                    negatedIndex = index
                }
            }
            guard let index = negatedIndex, parts.count >= 2,
                  case let .not(consequent) = parts[index] else { return .not(inner) }

            var guardParts = parts
            guardParts.remove(at: index)
            return .forAll(vars, .implies(CalcFormula.conjunction(guardParts), consequent))

        case let .and(parts):
            return CalcFormula.conjunction(parts.map(rewriteNegated))
        case let .or(parts):
            return CalcFormula.disjunction(parts.map(rewriteNegated))
        case let .exists(vars, body):
            return .exists(vars, rewriteNegated(body))
        case let .forAll(vars, body):
            return .forAll(vars, rewriteNegated(body))
        case let .implies(lhs, rhs):
            return .implies(rewriteNegated(lhs), rewriteNegated(rhs))
        default:
            return formula
        }
    }

    // MARK: - Shared helpers

    private static func exported(_ query: CalcQuery) -> Set<CalcVar> {
        query.result.reduce(into: Set<CalcVar>()) { $0.formUnion($1.term.variables) }
    }

    /// Equalities along a formula's positive conjunctive spine — the ones that
    /// hold wherever the formula does, and can therefore be used to rewrite it.
    /// Negation, disjunction and quantifiers all end the spine.
    private static func equalities(inSpineOf formula: CalcFormula) -> [(CalcTerm, CalcTerm)] {
        switch formula {
        case let .comparison(lhs, op, rhs) where op == "=":
            return [(lhs, rhs)]
        case let .and(parts):
            return parts.flatMap { equalities(inSpineOf: $0) }
        default:
            return []
        }
    }

    private static func dropTrivialEqualities(_ formula: CalcFormula) -> CalcFormula {
        switch formula {
        case let .comparison(lhs, op, rhs) where op == "=" && lhs == rhs:
            return .constant(true)
        case let .and(parts):
            return CalcFormula.conjunction(parts.map(dropTrivialEqualities))
        default:
            return formula
        }
    }

    // MARK: Substitution

    private static func substitute(_ formula: CalcFormula,
                                   _ variable: CalcVar, with replacement: CalcTerm) -> CalcFormula {
        switch formula {
        case let .relationAtom(relation, terms, arityKnown):
            return .relationAtom(relation: relation,
                                 terms: terms.map { substitute($0, variable, with: replacement) },
                                 arityKnown: arityKnown)
        case let .comparison(lhs, op, rhs):
            return .comparison(lhs: substitute(lhs, variable, with: replacement), op: op,
                               rhs: substitute(rhs, variable, with: replacement))
        case let .and(parts):
            return .and(parts.map { substitute($0, variable, with: replacement) })
        case let .or(parts):
            return .or(parts.map { substitute($0, variable, with: replacement) })
        case let .not(inner):
            return .not(substitute(inner, variable, with: replacement))
        case let .exists(vars, body):
            // A quantifier that re-binds the name shadows it: stop here.
            guard !vars.contains(variable) else { return formula }
            return .exists(vars, substitute(body, variable, with: replacement))
        case let .forAll(vars, body):
            guard !vars.contains(variable) else { return formula }
            return .forAll(vars, substitute(body, variable, with: replacement))
        case let .implies(lhs, rhs):
            return .implies(substitute(lhs, variable, with: replacement),
                            substitute(rhs, variable, with: replacement))
        case let .predicate(rendered, terms):
            return .predicate(rendered: rendered,
                              terms: terms.map { substitute($0, variable, with: replacement) })
        case .constant:
            return formula
        }
    }

    private static func substitute(_ term: CalcTerm,
                                   _ variable: CalcVar, with replacement: CalcTerm) -> CalcTerm {
        switch term {
        case let .variable(v):
            return v == variable ? replacement : term
        case let .attribute(v, _):
            return v == variable ? replacement : term
        case let .application(name, args, distinct):
            return .application(name: name,
                                args: args.map { substitute($0, variable, with: replacement) },
                                distinct: distinct)
        case let .binaryOp(op, lhs, rhs):
            return .binaryOp(op: op, lhs: substitute(lhs, variable, with: replacement),
                             rhs: substitute(rhs, variable, with: replacement))
        case let .aggregate(function, distinct, element, variables, condition):
            // A comprehension that re-binds the name shadows it.
            guard !variables.contains(variable) else { return term }
            return .aggregate(function: function, distinct: distinct,
                              element: element.map { substitute($0, variable, with: replacement) },
                              variables: variables,
                              condition: substitute(condition, variable, with: replacement))
        case .literal, .opaque:
            return term
        }
    }
}
