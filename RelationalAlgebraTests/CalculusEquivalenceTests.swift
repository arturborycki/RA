//
//  CalculusEquivalenceTests.swift
//  RelationalAlgebraTests
//
//  Evaluates the calculus against a toy database and checks that translations
//  which should agree do.
//
//  Every other test asserts on the *text* of a formula, which catches a
//  translation that changed but not one that was always wrong. This one
//  evaluates instead, so it can catch a formula that is well-formed, safe,
//  renders beautifully, and means something else:
//
//    · the domain lowering must answer exactly what the tuple form answers
//    · the simplifier must not change what a formula denotes
//
//  The relational algebra is deliberately absent. `RANode` stores its selection
//  conditions as pre-rendered strings, so evaluating it would mean writing a
//  second expression parser — which would test that parser, not the translator.
//
//  Formulas using anything the evaluator does not model (aggregates, LIKE, an
//  unexpanded sub-query) return `nil` and the case is skipped rather than
//  silently passing.
//

import XCTest
@testable import RelationalAlgebra

// MARK: - A toy database

struct ToyRelation {
    var columns: [String]
    var rows: [[String]]
}

struct ToyDatabase {
    var relations: [String: ToyRelation]

    func relation(named name: String) -> ToyRelation? {
        relations.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// The `CREATE TABLE` prelude that makes the domain calculus exact.
    var ddl: String {
        relations.keys.sorted().map { name in
            "CREATE TABLE \(name) (" + relations[name]!.columns.joined(separator: ", ") + ");"
        }.joined(separator: "\n")
    }

    static let sample = ToyDatabase(relations: [
        "Student": ToyRelation(columns: ["id", "name"],
                               rows: [["1", "ana"], ["2", "bo"], ["3", "cy"]]),
        "Course": ToyRelation(columns: ["cid", "title"],
                              rows: [["10", "db"], ["20", "os"]]),
        "Enrolled": ToyRelation(columns: ["sid", "cid"],
                                rows: [["1", "10"], ["1", "20"], ["2", "10"]])
    ])
}

// MARK: - Evaluator

/// What a variable is bound to: a whole row for a tuple variable, one value for
/// a domain variable.
enum CalcBinding: Equatable {
    case tuple(relation: String, row: [String])
    case value(String)
}

typealias CalcEnv = [CalcVar: CalcBinding]

/// A small tableau evaluator. Relation atoms bind variables from actual rows —
/// which is what keeps this tractable for the domain calculus, where naive
/// enumeration over the active domain would be astronomically large.
struct CalcEvaluator {
    let db: ToyDatabase

    /// The set of result tuples, or `nil` when the formula uses something not
    /// modelled here.
    func answers(_ query: CalcQuery) -> Set<[String]>? {
        guard let envs = assignments(query.formula, from: [CalcEnv()]) else { return nil }
        var results = Set<[String]>()
        for env in envs {
            var tuple: [String] = []
            for column in query.result {
                guard let value = value(of: column.term, in: env) else { return nil }
                tuple.append(value)
            }
            results.insert(tuple)
        }
        return results
    }

    // MARK: Formulas

    /// Every extension of `envs` that satisfies `formula`, or `nil` if the
    /// formula cannot be evaluated.
    private func assignments(_ formula: CalcFormula, from envs: [CalcEnv]) -> [CalcEnv]? {
        switch formula {
        case let .relationAtom(relation, terms, _):
            guard let table = db.relation(named: relation) else { return nil }
            var out: [CalcEnv] = []
            for env in envs {
                for row in table.rows {
                    if let extended = unify(terms, with: row, relation: relation, in: env) {
                        out.append(extended)
                    }
                }
            }
            return out

        case let .and(parts):
            // Atoms and quantifiers bind; comparisons and negations only filter.
            // Running the binders first means the filters always see bound
            // variables, which is exactly what safety guarantees.
            let binders = parts.filter { $0.binds }
            let filters = parts.filter { !$0.binds }
            var current = envs
            for part in binders + filters {
                guard let next = assignments(part, from: current) else { return nil }
                current = next
            }
            return current

        case let .or(parts):
            var out: [CalcEnv] = []
            for part in parts {
                guard let branch = assignments(part, from: envs) else { return nil }
                out.append(contentsOf: branch)
            }
            return out

        case let .not(inner):
            var out: [CalcEnv] = []
            for env in envs {
                guard let satisfying = assignments(inner, from: [env]) else { return nil }
                if satisfying.isEmpty { out.append(env) }
            }
            return out

        case let .exists(vars, body):
            // Projection: the quantifier's own variables are dropped, but a free
            // variable the body bound — `∃x ( X(x) ∧ x.a = a )` binds `a` — has
            // to survive, or a merged set operation would answer nothing.
            guard let satisfying = assignments(body, from: envs) else { return nil }
            return satisfying.map { env in
                var projected = env
                for variable in vars { projected.removeValue(forKey: variable) }
                return projected
            }

        case let .forAll(_, body):
            guard case let .implies(guardPart, consequent) = body else {
                // An unguarded ∀ would range over an infinite domain.
                return nil
            }
            var out: [CalcEnv] = []
            for env in envs {
                guard let guarded = assignments(guardPart, from: [env]) else { return nil }
                var holds = true
                for candidate in guarded {
                    guard let satisfying = assignments(consequent, from: [candidate]) else { return nil }
                    if satisfying.isEmpty { holds = false; break }
                }
                if holds { out.append(env) }
            }
            return out

        case let .implies(lhs, rhs):
            return assignments(.or([.not(lhs), rhs]), from: envs)

        case let .comparison(lhs, op, rhs):
            var out: [CalcEnv] = []
            for env in envs {
                let left = value(of: lhs, in: env), right = value(of: rhs, in: env)
                // An equality against a still-free variable binds it rather than
                // filtering — that is how a result variable gets its value.
                if op == "=", left == nil, case let .variable(variable) = lhs, let right {
                    var extended = env
                    extended[variable] = .value(right)
                    out.append(extended)
                    continue
                }
                if op == "=", right == nil, case let .variable(variable) = rhs, let left {
                    var extended = env
                    extended[variable] = .value(left)
                    out.append(extended)
                    continue
                }
                guard let left, let right, let holds = compare(left, op, right) else { return nil }
                if holds { out.append(env) }
            }
            return out

        case let .constant(value):
            return value ? envs : []

        case .predicate:
            return nil // LIKE, IS NULL, an unexpanded sub-query
        }
    }

    /// Match a relation atom's terms against one row, binding what is free.
    private func unify(_ terms: [CalcTerm], with row: [String],
                       relation: String, in env: CalcEnv) -> CalcEnv? {
        // A tuple atom: `R(t)` binds the whole row. Domain variables always
        // carry the column they stand for, so this cannot mistake `R(x)` over a
        // one-column relation for a tuple binding.
        if terms.count == 1, case let .variable(variable) = terms[0], variable.attribute == nil {
            if let existing = env[variable] {
                return existing == .tuple(relation: relation, row: row) ? env : nil
            }
            var extended = env
            extended[variable] = .tuple(relation: relation, row: row)
            return extended
        }

        // A domain atom: one term per column, positionally.
        guard terms.count == row.count else { return nil }
        var extended = env
        for (term, cell) in zip(terms, row) {
            switch term {
            case let .variable(variable):
                if let existing = extended[variable] {
                    guard existing == .value(cell) else { return nil }
                } else {
                    extended[variable] = .value(cell)
                }
            case let .literal(text):
                guard unquote(text) == cell else { return nil }
            default:
                guard let value = value(of: term, in: extended), value == cell else { return nil }
            }
        }
        return extended
    }

    // MARK: Terms

    private func value(of term: CalcTerm, in env: CalcEnv) -> String? {
        switch term {
        case let .variable(variable):
            guard case let .value(text)? = env[variable] else { return nil }
            return text

        case let .attribute(variable, attribute):
            guard case let .tuple(relation, row)? = env[variable],
                  let table = db.relation(named: relation),
                  let index = table.columns.firstIndex(where: {
                      $0.caseInsensitiveCompare(attribute) == .orderedSame
                  }), index < row.count else { return nil }
            return row[index]

        case let .literal(text):
            return unquote(text)

        default:
            return nil // applications, aggregates, opaque terms
        }
    }

    private func unquote(_ text: String) -> String {
        guard text.count >= 2, text.hasPrefix("'"), text.hasSuffix("'") else { return text }
        return String(text.dropFirst().dropLast())
    }

    private func compare(_ lhs: String, _ op: String, _ rhs: String) -> Bool? {
        if let l = Double(lhs), let r = Double(rhs) {
            switch op {
            case "=":  return l == r
            case "≠":  return l != r
            case "<":  return l < r
            case "≤":  return l <= r
            case ">":  return l > r
            case "≥":  return l >= r
            default:   return nil
            }
        }
        switch op {
        case "=":  return lhs == rhs
        case "≠":  return lhs != rhs
        case "<":  return lhs < rhs
        case "≤":  return lhs <= rhs
        case ">":  return lhs > rhs
        case "≥":  return lhs >= rhs
        default:   return nil
        }
    }
}

private extension CalcFormula {
    /// Whether this can bind a free variable, as opposed to only filtering
    /// assignments that already bind one.
    var binds: Bool {
        switch self {
        case .relationAtom, .or:            return true
        case let .and(parts):               return parts.contains { $0.binds }
        case .comparison, .not, .exists, .forAll, .implies, .predicate, .constant:
            return false
        }
    }
}

// MARK: - Tests

final class CalculusEquivalenceTests: XCTestCase {

    private let db = ToyDatabase.sample

    /// Queries whose meaning the evaluator can check. Each is prefixed with the
    /// toy schema so the domain atoms are exact.
    private let queries: [(title: String, sql: String)] = [
        ("projection",
         "SELECT s.name FROM Student s"),
        ("selection",
         "SELECT s.name FROM Student s WHERE s.id = 2"),
        ("join",
         "SELECT s.name, c.title FROM Student s JOIN Enrolled e ON e.sid = s.id " +
         "JOIN Course c ON c.cid = e.cid"),
        ("comma join with a condition",
         "SELECT s.name FROM Student s, Enrolled e WHERE e.sid = s.id AND e.cid = 10"),
        ("exists",
         "SELECT s.name FROM Student s WHERE EXISTS (SELECT e.sid FROM Enrolled e WHERE e.sid = s.id)"),
        ("not exists",
         "SELECT s.name FROM Student s " +
         "WHERE NOT EXISTS (SELECT e.sid FROM Enrolled e WHERE e.sid = s.id)"),
        ("in sub-query",
         "SELECT s.name FROM Student s WHERE s.id IN (SELECT e.sid FROM Enrolled e WHERE e.cid = 20)"),
        ("not in sub-query",
         "SELECT s.name FROM Student s WHERE s.id NOT IN (SELECT e.sid FROM Enrolled e)"),
        ("division",
         "SELECT s.name FROM Student s WHERE NOT EXISTS ( SELECT c.cid FROM Course c " +
         "WHERE NOT EXISTS ( SELECT e.sid FROM Enrolled e WHERE e.sid = s.id AND e.cid = c.cid ) )"),
        ("disjunction",
         "SELECT s.name FROM Student s WHERE s.id = 1 OR s.id = 3"),
        ("union",
         "SELECT s.id FROM Student s UNION SELECT e.sid FROM Enrolled e"),
        ("intersect",
         "SELECT s.id FROM Student s INTERSECT SELECT e.sid FROM Enrolled e"),
        ("except",
         "SELECT s.id FROM Student s EXCEPT SELECT e.sid FROM Enrolled e"),
        ("greater than all",
         "SELECT s.name FROM Student s WHERE s.id > ALL (SELECT e.sid FROM Enrolled e)"),
    ]

    // MARK: Helpers

    private func translations(_ sql: String) throws -> (trc: CalcTranslation, drc: CalcTranslation) {
        let script = try SQLParser.parseScript(db.ddl + "\n" + sql)
        let inference = SchemaInference.infer(script.query, declarations: script.declarations)
        let trc = TRCTranslator().translate(script.query, schema: inference.schema)
        return (trc, DRCLowering.lower(trc))
    }

    /// The answer to an expression, or `nil` when any part of it is outside what
    /// the evaluator models.
    private func answers(_ expression: CalcExpression, evaluator: CalcEvaluator) -> Set<[String]>? {
        switch expression {
        case let .query(query):
            return evaluator.answers(query)
        case let .setOperation(op, left, right):
            guard let l = answers(left, evaluator: evaluator),
                  let r = answers(right, evaluator: evaluator) else { return nil }
            switch op {
            case .union:      return l.union(r)
            case .intersect:  return l.intersection(r)
            case .difference: return l.subtracting(r)
            }
        }
    }

    // MARK: The checks

    func testDomainCalculusAnswersTheSameAsTupleCalculus() throws {
        let evaluator = CalcEvaluator(db: db)
        var checked = 0

        for query in queries {
            let (trc, drc) = try translations(query.sql)
            guard let tupleAnswer = answers(trc.root, evaluator: evaluator),
                  let domainAnswer = answers(drc.root, evaluator: evaluator) else { continue }
            XCTAssertEqual(tupleAnswer, domainAnswer,
                           "\(query.title): the lowering changed the answer")
            checked += 1
        }

        XCTAssertGreaterThan(checked, 8,
                             "too few queries were actually evaluated for this to mean much")
    }

    func testSimplificationPreservesMeaning() throws {
        let evaluator = CalcEvaluator(db: db)
        var checked = 0

        for query in queries {
            let (trc, drc) = try translations(query.sql)
            for translation in [trc, drc] {
                let simplified = CalcSimplifier.simplify(translation.root).expression
                guard simplified != translation.root,
                      let before = answers(translation.root, evaluator: evaluator),
                      let after = answers(simplified, evaluator: evaluator) else { continue }
                XCTAssertEqual(before, after,
                               "\(query.title) (\(translation.dialect.rawValue)): " +
                               "simplification changed the answer")
                checked += 1
            }
        }

        XCTAssertGreaterThan(checked, 0, "no simplification was actually exercised")
    }

    // MARK: Spot checks on the evaluator itself

    /// If the evaluator agreed with itself but not with reality, the tests above
    /// would pass vacuously — so pin a few answers by hand.
    func testEvaluatorProducesTheExpectedAnswers() throws {
        let evaluator = CalcEvaluator(db: db)

        let enrolled = try translations("SELECT s.name FROM Student s " +
            "WHERE EXISTS (SELECT e.sid FROM Enrolled e WHERE e.sid = s.id)")
        XCTAssertEqual(answers(enrolled.trc.root, evaluator: evaluator),
                       [["ana"], ["bo"]])

        let notEnrolled = try translations("SELECT s.name FROM Student s " +
            "WHERE NOT EXISTS (SELECT e.sid FROM Enrolled e WHERE e.sid = s.id)")
        XCTAssertEqual(answers(notEnrolled.trc.root, evaluator: evaluator), [["cy"]])

        // Only ana is enrolled in every course.
        let division = try translations(
            "SELECT s.name FROM Student s WHERE NOT EXISTS ( SELECT c.cid FROM Course c " +
            "WHERE NOT EXISTS ( SELECT e.sid FROM Enrolled e " +
            "WHERE e.sid = s.id AND e.cid = c.cid ) )")
        XCTAssertEqual(answers(division.trc.root, evaluator: evaluator), [["ana"]])
    }
}
