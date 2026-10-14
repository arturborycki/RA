//
//  DRCRaising.swift
//  RelationalAlgebra
//
//  Domain calculus → tuple calculus: the inverse of `DRCLowering`.
//
//  SQL has no domain variables — only rows and their columns — so before a
//  domain-calculus formula can become SQL, every domain variable has to become
//  an attribute of some tuple variable. For each positional atom
//  `Employee(n, s, d)`:
//
//    1. a tuple variable `e` is allocated and the atom becomes `Employee(e)`;
//    2. the first atom to mention a variable *defines* it: `n` means `e.name`
//       from then on;
//    3. a variable mentioned again, in this atom or another, becomes an
//       equality — `e.dept_id = d.id` is how a domain-calculus join is written;
//    4. a constant in a position becomes an equality too: `e.location = 'Berlin'`.
//
//  Step 2 needs column *names*, which a positional atom does not carry. They
//  come from `CREATE TABLE` above the formula, or from a `Name = { … }`
//  definition's result; without either the SQL calls them col1, col2, … and
//  says so, rather than guessing.
//

import Foundation

/// Hands out tuple-variable names that collide with nothing already in use.
final class NameAllocator {
    private var taken: Set<String>

    init(taken: [String]) {
        self.taken = Set(taken.map { $0.lowercased() })
    }

    /// `e`, `e2`, `e3`, … for Employee.
    func fresh(for relation: String) -> String {
        let initial = relation.first.map { $0.isLetter ? String($0).lowercased() : "t" } ?? "t"
        var candidate = initial
        var n = 1
        while taken.contains(candidate.lowercased()) {
            n += 1
            candidate = "\(initial)\(n)"
        }
        taken.insert(candidate.lowercased())
        return candidate
    }
}

final class DRCRaising {
    /// A relation's column names, in order, when they are known.
    private let columnsOf: (String) -> [String]?
    private let names: NameAllocator
    private(set) var diagnostics: [CalcDiagnostic] = []

    init(columns: @escaping (String) -> [String]?, names: NameAllocator) {
        self.columnsOf = columns
        self.names = names
    }

    func raise(_ expression: CalcExpression) throws -> CalcExpression {
        switch expression {
        case let .query(query):
            return try raise(query)
        case let .setOperation(op, left, right):
            return .setOperation(op: op, left: try raise(left), right: try raise(right))
        }
    }

    // MARK: - Queries

    private func raise(_ query: CalcQuery) throws -> CalcExpression {
        let free = Set(query.result.flatMap { $0.term.variables.map(\.name) })
            .union(query.formula.freeVariables.map(\.name))
        var conjuncts = try hoistingExistentials(query.formula.conjuncts, avoiding: free)

        // `{ ⟨x⟩ | R(x) ∨ S(x) }`: x is a column of R in one branch and of S in
        // the other, so no single tuple variable can stand for it. Each branch
        // becomes its own query, and the union of those is the answer.
        if let i = conjuncts.firstIndex(where: { DRCRaising.rangesDisjunctively($0, free) }),
           case let .or(branches) = conjuncts[i] {
            conjuncts.remove(at: i)
            var parts: [CalcExpression] = []
            for branch in branches {
                var copy = query
                copy.formula = CalcFormula.conjunction(conjuncts + [branch])
                parts.append(try raise(copy))
            }
            return parts.dropFirst().reduce(parts[0]) {
                .setOperation(op: .union, left: $0, right: $1)
            }
        }

        var env: [String: CalcTerm] = [:]
        var parts: [CalcFormula] = []
        var others: [CalcFormula] = []
        for conjunct in conjuncts {
            if case let .relationAtom(relation, terms, complete) = conjunct {
                parts += try bind(relation, terms, complete: complete, env: &env)
            } else {
                others.append(conjunct)
            }
        }
        // An aggregate's result is a value of its own, not a column of a tuple.
        for case let .aggregateBinding(result, _, _, _, _, _) in others {
            env[result.name] = .variable(result)
        }
        for other in others {
            parts.append(try raise(other, env: env))
        }

        let columns = try query.result.map { column -> ResultColumn in
            ResultColumn(term: try raise(column.term, env: env, context: "the result"),
                         name: column.name)
        }
        return .query(CalcQuery(dialect: .trc, result: DRCRaising.distinctlyNamed(columns, query.result),
                                formula: CalcFormula.conjunction(parts), resultStyle: .compact))
    }

    /// `∃d ( … )` in a conjunction is a projection: its variables can be bound
    /// at the level it sits in, which is what lets `{ ⟨n⟩ | ∃s ( Employee(n, s) ) }`
    /// range n at the top.
    ///
    /// Two quantifiers hoisted into one scope must not share a name — sibling
    /// `∃x ( R(x) ) ∧ ∃x ( S(x) )` are different x's — so a clash is reported
    /// rather than silently equating them.
    private func hoistingExistentials(_ conjuncts: [CalcFormula],
                                      avoiding outer: Set<String>) throws -> [CalcFormula] {
        var used = outer
        return try hoist(conjuncts, used: &used)
    }

    private func hoist(_ conjuncts: [CalcFormula], used: inout Set<String>) throws -> [CalcFormula] {
        var out: [CalcFormula] = []
        for conjunct in conjuncts {
            if case let .exists(vars, body) = conjunct {
                if let clash = vars.first(where: { used.contains($0.name) }) {
                    throw TranslationError(message: "\(clash.name) is quantified here and also used " +
                                                    "elsewhere in the same conjunction. Give one of " +
                                                    "them another name.")
                }
                used.formUnion(vars.map(\.name))
                out += try hoist(body.conjuncts, used: &used)
            } else {
                out.append(conjunct)
            }
        }
        return out
    }

    /// A disjunction whose branches range one of `variables` with an atom —
    /// looking through existentials, since `∃i ( Student(i, n) )` ranges n too.
    static func rangesDisjunctively(_ formula: CalcFormula, _ variables: Set<String>) -> Bool {
        guard case let .or(branches) = formula else { return false }
        func ranges(_ parts: [CalcFormula]) -> Bool {
            parts.contains { part in
                switch part {
                case let .relationAtom(_, terms, _):
                    return terms.contains { term in
                        if case let .variable(v) = term { return variables.contains(v.name) }
                        return false
                    }
                case let .exists(_, body):
                    return ranges(body.conjuncts)
                default:
                    return false
                }
            }
        }
        return branches.contains { ranges($0.conjuncts) }
    }

    /// Result columns that would print under the same column name get the
    /// domain variable's name instead, so the SQL's columns stay distinct.
    private static func distinctlyNamed(_ columns: [ResultColumn],
                                        _ original: [ResultColumn]) -> [ResultColumn] {
        func columnName(_ column: ResultColumn) -> String? {
            if let name = column.name { return name.lowercased() }
            if case let .attribute(_, attribute) = column.term { return attribute.lowercased() }
            return nil
        }
        let counts = Dictionary(columns.compactMap(columnName).map { ($0, 1) }, uniquingKeysWith: +)
        return zip(columns, original).map { raised, typed in
            guard raised.name == nil, let name = columnName(raised), (counts[name] ?? 0) > 1,
                  case let .variable(v) = typed.term else { return raised }
            return ResultColumn(term: raised.term, name: v.name)
        }
    }

    // MARK: - Atoms

    /// `R(x, 'c', y)` → `R(r)` plus whatever equalities its positions impose,
    /// binding each variable seen for the first time.
    private func bind(_ relation: String, _ terms: [CalcTerm], complete: Bool,
                      env: inout [String: CalcTerm]) throws -> [CalcFormula] {
        let columns = try resolve(relation, count: terms.count, complete: complete)
        let tuple = CalcVar(name: names.fresh(for: relation), relation: relation)
        var parts: [CalcFormula] = [.relationAtom(relation: relation, terms: [.variable(tuple)],
                                                  arityKnown: true)]
        for (term, column) in zip(terms, columns) {
            let attribute = CalcTerm.attribute(tuple, column)
            if case let .variable(v) = term {
                if let bound = env[v.name] {
                    parts.append(.comparison(lhs: attribute, op: "=", rhs: bound))
                } else {
                    env[v.name] = attribute
                }
            } else {
                parts.append(.comparison(lhs: attribute, op: "=",
                                         rhs: try raise(term, env: env, context: "\(relation)(…)")))
            }
        }
        return parts
    }

    private func resolve(_ relation: String, count: Int, complete: Bool) throws -> [String] {
        guard let columns = columnsOf(relation) else {
            let placeholder = (0..<count).map { "col\($0 + 1)" }
            let diagnostic = CalcDiagnostic(
                severity: .warning, fidelity: .exact, construct: relation,
                message: "\(relation)'s columns are not declared, so the SQL calls them " +
                         "\(placeholder.joined(separator: ", ")). Add CREATE TABLE \(relation) (…) " +
                         "above the formula to use the real names.")
            if !diagnostics.contains(diagnostic) { diagnostics.append(diagnostic) }
            return placeholder
        }
        if count > columns.count || (complete && count != columns.count) {
            throw TranslationError(message: "\(relation) has \(columns.count) columns but the atom " +
                                            "lists \(count). End the list with … to leave the " +
                                            "rest out, as in \(relation)(x, …).")
        }
        return Array(columns.prefix(count))
    }

    // MARK: - Formulas below the top level

    private func raise(_ formula: CalcFormula, env: [String: CalcTerm]) throws -> CalcFormula {
        switch formula {
        case let .relationAtom(relation, terms, complete):
            // Not a range here — under ¬, inside ∨ — so a membership test:
            // some row of R has these values. Every variable must already be
            // bound, or the formula is unsafe.
            for case let .variable(v) in terms where env[v.name] == nil {
                throw TranslationError(message: "\(v.name) appears in \(relation)(…) where no " +
                                                "relation atom has bound it yet, so it ranges " +
                                                "over every possible value.")
            }
            var local = env
            let parts = try bind(relation, terms, complete: complete, env: &local)
            guard case let .relationAtom(_, tupleTerms, _) = parts[0],
                  case let .variable(tuple) = tupleTerms[0] else { return formula }
            return .exists([tuple], CalcFormula.conjunction(parts))

        case let .comparison(lhs, op, rhs):
            return .comparison(lhs: try raise(lhs, env: env, context: "a comparison"), op: op,
                               rhs: try raise(rhs, env: env, context: "a comparison"))

        case let .and(parts):
            return CalcFormula.conjunction(try parts.map { try raise($0, env: env) })
        case let .or(parts):
            return CalcFormula.disjunction(try parts.map { try raise($0, env: env) })
        case let .not(inner):
            return .not(try raise(inner, env: env))
        case let .implies(lhs, rhs):
            return .implies(try raise(lhs, env: env), try raise(rhs, env: env))

        case let .exists(vars, body):
            return try raiseExists(vars, body, env: env)
        case let .forAll(vars, body):
            // ∀x φ is ¬∃x ¬φ, and the ∃ is where the ranges are.
            return .not(try raiseExists(vars, body.negated, env: env))

        case .constant:
            return formula

        case let .aggregateBinding(result, function, distinct, element, variables, condition):
            // The comprehension is a scope of its own, raised like an ∃'s body;
            // what it collects is read through the bindings made inside it.
            let names = Set(variables.map(\.name))
            // The comprehension's own variables include any its ∃s bind, so
            // those may be lifted into it without clashing.
            let conjuncts = try hoistingExistentials(condition.conjuncts, avoiding: Set(env.keys))
            let (tuples, parts, local) = try raiseScope(names, conjuncts, env: env)
            return .aggregateBinding(
                result: result, function: function, distinct: distinct,
                element: try element.map { try raise($0, env: local, context: "\(function){ … }") },
                variables: tuples, condition: CalcFormula.conjunction(parts))

        case .predicate:
            throw TranslationError(message: "This formula uses a construct domain-calculus " +
                                            "input does not support yet.")
        }
    }

    private func raiseExists(_ vars: [CalcVar], _ body: CalcFormula,
                             env: [String: CalcTerm]) throws -> CalcFormula {
        let names = Set(vars.map(\.name))
        var conjuncts = try hoistingExistentials(body.conjuncts,
                                                 avoiding: Set(env.keys).union(names))

        // ∃x ( R(x) ∨ S(x) ) is ∃x R(x) ∨ ∃x S(x).
        if let i = conjuncts.firstIndex(where: { DRCRaising.rangesDisjunctively($0, names) }),
           case let .or(branches) = conjuncts[i] {
            conjuncts.remove(at: i)
            return CalcFormula.disjunction(try branches.map {
                try raiseExists(vars, CalcFormula.conjunction(conjuncts + [$0]), env: env)
            })
        }

        // Atoms that mention a variable not yet bound range it here; any other
        // atom only tests membership.
        let (tuples, parts, _) = try raiseScope(names, conjuncts, env: env)
        return .exists(tuples, CalcFormula.conjunction(parts))
    }

    /// Bind a scope's variables — an ∃'s, or an aggregate comprehension's — by
    /// the atoms that mention them, and raise everything else in the scope.
    private func raiseScope(_ names: Set<String>, _ conjuncts: [CalcFormula],
                            env: [String: CalcTerm])
        throws -> ([CalcVar], [CalcFormula], [String: CalcTerm]) {
        // The quantified names are new here even if an outer scope uses them.
        var local = env
        for name in names { local[name] = nil }
        var tuples: [CalcVar] = []
        var parts: [CalcFormula] = []
        var others: [CalcFormula] = []
        for conjunct in conjuncts {
            if case let .relationAtom(relation, terms, complete) = conjunct,
               terms.contains(where: { term in
                   if case let .variable(v) = term { return local[v.name] == nil }
                   return false
               }) {
                let bound = try bind(relation, terms, complete: complete, env: &local)
                if case let .relationAtom(_, tupleTerms, _) = bound[0],
                   case let .variable(tuple) = tupleTerms[0] {
                    tuples.append(tuple)
                }
                parts += bound
            } else {
                others.append(conjunct)
            }
        }
        for other in others {
            parts.append(try raise(other, env: local))
        }
        if let unbound = names.first(where: { local[$0] == nil }) {
            throw TranslationError(message: "\(unbound) is quantified but no relation atom in " +
                                            "the quantifier's body ranges it.")
        }
        return (tuples, parts, local)
    }

    // MARK: - Terms

    private func raise(_ term: CalcTerm, env: [String: CalcTerm], context: String) throws -> CalcTerm {
        switch term {
        case let .variable(v):
            guard let bound = env[v.name] else {
                throw TranslationError(message: "\(v.name) is used in \(context) but no relation " +
                                                "atom binds it, so it ranges over every possible value.")
            }
            return bound
        case .attribute:
            throw TranslationError(message: "t.attribute is tuple-calculus notation; in domain " +
                                            "calculus every value is a variable of its own.")
        case .literal, .opaque:
            return term
        case let .application(name, args, distinct):
            return .application(name: name,
                                args: try args.map { try raise($0, env: env, context: context) },
                                distinct: distinct)
        case let .binaryOp(op, lhs, rhs):
            return .binaryOp(op: op, lhs: try raise(lhs, env: env, context: context),
                             rhs: try raise(rhs, env: env, context: context))
        }
    }
}

extension CalcFormula {
    /// ¬φ with the negation pushed inward — De Morgan, ¬¬φ = φ, and a flipped
    /// comparison rather than a negated one — so that `∀u ( R(u) → φ )` becomes
    /// `¬∃u ( R(u) ∧ ¬φ )` with the range `R(u)` in plain sight.
    var negated: CalcFormula {
        switch self {
        case let .not(inner):
            return inner
        case let .and(parts):
            return CalcFormula.disjunction(parts.map(\.negated))
        case let .or(parts):
            return CalcFormula.conjunction(parts.map(\.negated))
        case let .implies(lhs, rhs):
            return CalcFormula.conjunction([lhs, rhs.negated])
        case let .comparison(lhs, op, rhs):
            guard let flipped = CalcFormula.oppositeComparison[op] else { return .not(self) }
            return .comparison(lhs: lhs, op: flipped, rhs: rhs)
        case let .constant(value):
            return .constant(!value)
        case let .forAll(vars, body):
            return .exists(vars, body.negated)
        case .relationAtom, .exists, .predicate, .aggregateBinding:
            return .not(self)
        }
    }

    static let oppositeComparison: [String: String] = [
        "=": "≠", "≠": "=", "<": "≥", "≥": "<", ">": "≤", "≤": ">",
        "LIKE": "NOT LIKE", "NOT LIKE": "LIKE", "IS": "IS NOT", "IS NOT": "IS"
    ]
}
