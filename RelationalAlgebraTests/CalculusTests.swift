//
//  CalculusTests.swift
//  RelationalAlgebraTests
//
//  Unit tests for schema inference, the TRC translator and the calculus
//  renderer. Everything under test is pure Swift with no UIKit or SwiftUI
//  dependency, so the whole engine is exercised here rather than through the UI.
//

import XCTest
@testable import RelationalAlgebra

final class CalculusTests: XCTestCase {

    // MARK: - Helpers

    private func translate(_ sql: String) throws -> CalcTranslation {
        let query = try SQLParser.parse(sql)
        let inference = SchemaInference.infer(query)
        var translation = TRCTranslator().translate(query, schema: inference.schema)
        translation.diagnostics = (inference.diagnostics + translation.diagnostics).deduplicated
        return translation
    }

    private func inline(_ sql: String) throws -> String {
        try CalcRenderer().inline(translate(sql))
    }

    private func schema(_ sql: String) throws -> QuerySchema {
        SchemaInference.infer(try SQLParser.parse(sql)).schema
    }

    /// The single query of a translation whose root is not a set operation.
    private func onlyQuery(_ translation: CalcTranslation) throws -> CalcQuery {
        guard case let .query(query) = translation.root else {
            throw XCTSkip("expected a single set-builder expression")
        }
        return query
    }

    // MARK: - Schema inference

    func testInfersAttributesFromQualifiedReferences() throws {
        let s = try schema("""
            SELECT e.name, d.title
            FROM Employee e JOIN Department d ON e.dept_id = d.id
            """)
        XCTAssertEqual(s.schema(for: "Employee")?.attributes, ["name", "dept_id"])
        XCTAssertEqual(s.schema(for: "Department")?.attributes, ["title", "id"])
        // Nothing declared the tables, so the arity is a guess and says so.
        XCTAssertEqual(s.schema(for: "Employee")?.source, .inferred)
        XCTAssertFalse(s.schema(for: "Employee")!.arityKnown)
    }

    func testInfersUnqualifiedColumnsWhenOneRelationIsInScope() throws {
        let s = try schema("SELECT name, salary FROM Employee WHERE salary > 50000")
        XCTAssertEqual(s.schema(for: "Employee")?.attributes, ["name", "salary"])
    }

    func testAmbiguousUnqualifiedColumnIsReportedNotGuessed() throws {
        let translation = try translate("SELECT x FROM A, B WHERE x > 1")
        XCTAssertTrue(translation.diagnostics.contains { $0.construct == "x" },
                      "an unqualified column with two relations in scope must be reported")
        // And it must not have been silently attributed to either relation.
        let s = translation.schema
        XCTAssertTrue(s.schema(for: "A")?.attributes.isEmpty ?? true)
        XCTAssertTrue(s.schema(for: "B")?.attributes.isEmpty ?? true)
    }

    func testCTEColumnsAreKnownExactly() throws {
        let s = try schema("""
            WITH recent AS (SELECT id, total FROM Orders WHERE total > 10)
            SELECT id FROM recent
            """)
        let cte = s.schema(for: "recent")
        XCTAssertEqual(cte?.attributes, ["id", "total"])
        XCTAssertEqual(cte?.source, .cte)
        XCTAssertTrue(cte?.arityKnown ?? false, "a CTE's output columns are fully determined")
    }

    func testUsingClauseGivesBothSidesTheColumn() throws {
        let s = try schema("SELECT * FROM A JOIN B USING (id)")
        XCTAssertTrue(s.schema(for: "A")?.has("id") ?? false)
        XCTAssertTrue(s.schema(for: "B")?.has("id") ?? false)
    }

    func testRelationNameCasingDoesNotSplitTheSchema() throws {
        let s = try schema("SELECT Employee.name FROM EMPLOYEE")
        XCTAssertEqual(s.relations.count, 1)
    }

    // MARK: - Core translation

    func testSelectProjectRendersSetBuilder() throws {
        let text = try inline("SELECT name, salary FROM Employee WHERE salary > 50000")
        XCTAssertEqual(text, "{ e.name, e.salary | Employee(e) ∧ e.salary > 50000 }")
    }

    func testSQLAliasBecomesTheTupleVariable() throws {
        let text = try inline("SELECT e.name FROM Employee e WHERE e.salary > 100")
        XCTAssertEqual(text, "{ e.name | Employee(e) ∧ e.salary > 100 }")
    }

    func testJoinConditionBecomesAConjunct() throws {
        let text = try inline("""
            SELECT e.name, d.name
            FROM Employee e JOIN Department d ON e.dept_id = d.id
            """)
        XCTAssertEqual(text,
            "{ e.name, d.name | Employee(e) ∧ Department(d) ∧ e.dept_id = d.id }")
    }

    func testCommaJoinNeedsNoOperator() throws {
        // A cartesian product is two unrelated atoms in one conjunction.
        let text = try inline("SELECT a.x, b.y FROM A a, B b")
        XCTAssertEqual(text, "{ a.x, b.y | A(a) ∧ B(b) }")
    }

    func testVariableNotExportedByTheResultIsExistentiallyQuantified() throws {
        let text = try inline("""
            SELECT e.name
            FROM Employee e JOIN Department d ON e.dept_id = d.id
            WHERE d.location = 'Berlin'
            """)
        XCTAssertEqual(text,
            "{ e.name | Employee(e) ∧ ∃d ( Department(d) ∧ e.dept_id = d.id ∧ d.location = 'Berlin' ) }")
    }

    func testColumnAliasIsShownAsARename() throws {
        let text = try inline("SELECT e.name AS who FROM Employee e")
        XCTAssertTrue(text.contains("e.name → who"), text)
    }

    func testBetweenExpandsToTwoComparisons() throws {
        let text = try inline("SELECT total FROM Orders WHERE total BETWEEN 100 AND 500")
        XCTAssertTrue(text.contains("o.total ≥ 100 ∧ o.total ≤ 500"), text)
    }

    func testInListBecomesADisjunction() throws {
        let text = try inline("SELECT city FROM Customer WHERE country IN ('DE', 'FR')")
        XCTAssertTrue(text.contains("c.country = 'DE' ∨ c.country = 'FR'"), text)
    }

    func testNotBracketsTheConditionItNegates() throws {
        // `¬t.a > 1` would read as a comparison against a negated value.
        let text = try inline("SELECT a FROM T WHERE NOT (a > 1)")
        XCTAssertTrue(text.contains("¬( t.a > 1 )"), text)
    }

    func testComparisonGlyphsUseMathematicalForms() throws {
        let text = try inline("SELECT a FROM T WHERE a <> 1 AND a >= 2 AND a <= 3")
        XCTAssertTrue(text.contains("≠"), text)
        XCTAssertTrue(text.contains("≥"), text)
        XCTAssertTrue(text.contains("≤"), text)
    }

    func testRepeatedRelationGetsDistinctVariables() throws {
        let text = try inline("SELECT a.id FROM Employee a, Employee b WHERE a.id = b.mgr")
        XCTAssertTrue(text.contains("Employee(a)"), text)
        XCTAssertTrue(text.contains("Employee(b)"), text)
    }

    func testStarExpandsToTheKnownAttributes() throws {
        let text = try inline("SELECT * FROM Employee WHERE salary > 1 AND name = 'x'")
        // `salary` and `name` are the only columns the query names.
        XCTAssertTrue(text.contains("{ e.salary, e.name |"), text)
    }

    // MARK: - Set operations and CTEs

    func testUnionMergesIntoOneFormulaWithADisjunction() throws {
        let text = try inline("SELECT a FROM X UNION SELECT a FROM Y")
        XCTAssertEqual(text, "{ ⟨a⟩ | ∃x ( X(x) ∧ x.a = a ) ∨ ∃y ( Y(y) ∧ y.a = a ) }")
    }

    func testIntersectMergesWithAConjunction() throws {
        let text = try inline("SELECT a FROM X INTERSECT SELECT a FROM Y")
        XCTAssertEqual(text, "{ ⟨a⟩ | ∃x ( X(x) ∧ x.a = a ) ∧ ∃y ( Y(y) ∧ y.a = a ) }")
    }

    func testExceptMergesWithANegation() throws {
        let text = try inline("SELECT a FROM X EXCEPT SELECT a FROM Y")
        XCTAssertEqual(text, "{ ⟨a⟩ | ∃x ( X(x) ∧ x.a = a ) ∧ ¬∃y ( Y(y) ∧ y.a = a ) }")
    }

    func testMismatchedBranchesFallBackToASetOperation() throws {
        // Different result arities cannot share result variables.
        let text = try inline("SELECT a, b FROM X UNION SELECT a FROM Y")
        XCTAssertTrue(text.contains("∪"), text)
    }

    func testCTEBecomesANamedDefinition() throws {
        let translation = try translate("""
            WITH recent AS (SELECT id FROM Orders WHERE id > 10)
            SELECT id FROM recent
            """)
        XCTAssertEqual(translation.definitions.count, 1)
        XCTAssertEqual(translation.definitions.first?.name, "recent")
        XCTAssertTrue(CalcRenderer().inline(translation).contains("recent ="))
    }

    // MARK: - Fidelity

    func testDistinctIsANoOpAndSaysSo() throws {
        let translation = try translate("SELECT DISTINCT city FROM Customer")
        let note = translation.diagnostics.first { $0.construct == "DISTINCT" }
        XCTAssertNotNil(note, "DISTINCT should be explained, not silently dropped")
        XCTAssertEqual(note?.severity, .info)
        XCTAssertEqual(note?.fidelity, .exact)
        // And it must not appear as an operator in the formula.
        XCTAssertFalse(CalcRenderer().inline(translation).contains("δ"))
    }

    func testGroupByIsFlaggedAsAnExtensionAndKeptOutsideTheBraces() throws {
        let translation = try translate("""
            SELECT dept, COUNT(*) FROM Employee GROUP BY dept
            """)
        XCTAssertTrue(translation.diagnostics.contains { $0.fidelity == .extended })
        let query = try onlyQuery(translation)
        XCTAssertTrue(query.extensions.contains { $0.kind == .grouping })
        let text = CalcRenderer().inline(translation)
        XCTAssertTrue(text.contains("applied to"), text)
    }

    func testOrderByAndLimitAreAnnotatedOutsideTheBraces() throws {
        let translation = try translate("SELECT a FROM T ORDER BY a DESC LIMIT 10")
        let query = try onlyQuery(translation)
        XCTAssertTrue(query.extensions.contains { $0.kind == .sort })
        XCTAssertTrue(query.extensions.contains { $0.kind == .limit })
        XCTAssertTrue(translation.diagnostics.contains {
            $0.construct == "ORDER BY" && $0.fidelity == .annotated
        })
    }

    func testOuterJoinIsFlaggedRatherThanFaked() throws {
        let translation = try translate("SELECT a.x FROM A a LEFT JOIN B b ON a.id = b.id")
        XCTAssertTrue(translation.diagnostics.contains {
            $0.construct == "LEFT JOIN" && $0.fidelity == .annotated
        })
    }

    func testSubqueryWithItsOwnGroupingStaysOpaqueAndSaysWhy() throws {
        // Grouping cannot appear inside a formula, so this one cannot become a
        // quantifier — and the reason has to reach the reader.
        let translation = try translate("""
            SELECT c.name FROM Customer c
            WHERE c.id IN (SELECT o.cid FROM Orders o GROUP BY o.cid)
            """)
        let note = translation.diagnostics.first { $0.construct == "IN (sub-query)" }
        XCTAssertEqual(note?.fidelity, .annotated)
        XCTAssertTrue(CalcRenderer().inline(translation).contains("(…)"))
    }

    func testUnionAllCannotPreserveDuplicates() throws {
        let translation = try translate("SELECT a FROM X UNION ALL SELECT a FROM Y")
        XCTAssertTrue(translation.diagnostics.contains {
            $0.construct == "UNION ALL" && $0.fidelity == .annotated
        })
    }

    func testPlainSelectProjectJoinHasNoWarnings() throws {
        let translation = try translate("""
            SELECT e.name FROM Employee e JOIN Department d ON e.dept_id = d.id
            WHERE d.location = 'Berlin'
            """)
        XCTAssertEqual(translation.diagnostics.warningCount, 0,
                       "select-project-join with WHERE is translated exactly")
    }

    func testDiagnosticsAreDeduplicated() throws {
        let translation = try translate("""
            SELECT a FROM T WHERE a IS NULL AND b IS NULL AND c IS NULL
            """)
        let nullNotes = translation.diagnostics.filter { $0.construct == "IS NULL" }
        XCTAssertEqual(nullNotes.count, 1)
    }

    // MARK: - Structural invariants

    func testEveryQuantifiedVariableIsUsedInItsBody() throws {
        for sample in SampleQueries.all {
            let translation = try translate(sample.sql)
            assertQuantifiersAreUsed(in: translation.root, sample: sample.title)
        }
    }

    func testAllSamplesTranslateWithoutCrashing() throws {
        for sample in SampleQueries.all {
            let translation = try translate(sample.sql)
            let text = translation.prettyText()
            XCTAssertFalse(text.isEmpty, "\(sample.title) produced no output")
            XCTAssertTrue(text.contains("{"), "\(sample.title): \(text)")
        }
    }

    private func assertQuantifiersAreUsed(in expression: CalcExpression, sample: String) {
        func check(_ formula: CalcFormula, sample: String) {
            switch formula {
            case let .exists(vars, body), let .forAll(vars, body):
                let used = body.variables
                for variable in vars {
                    XCTAssertTrue(used.contains(variable),
                                  "\(sample): quantified '\(variable.name)' is unused in its body")
                }
                check(body, sample: sample)
            case let .and(parts), let .or(parts):
                parts.forEach { check($0, sample: sample) }
            case let .not(inner):
                check(inner, sample: sample)
            case let .implies(lhs, rhs):
                check(lhs, sample: sample); check(rhs, sample: sample)
            case .relationAtom, .comparison, .predicate, .constant:
                break
            }
        }

        switch expression {
        case let .query(query):
            check(query.formula, sample: sample)
        case let .setOperation(_, left, right):
            assertQuantifiersAreUsed(in: left, sample: sample)
            assertQuantifiersAreUsed(in: right, sample: sample)
        }
    }

    // MARK: - Rendering

    func testLongFormulaIsBrokenAcrossLines() throws {
        let translation = try translate("""
            SELECT e.name, d.title, p.label
            FROM Employee e
            JOIN Department d ON e.dept_id = d.id
            JOIN Project p ON p.dept_id = d.id
            WHERE d.location = 'Berlin' AND e.salary > 50000 AND p.active = 1
            """)
        let pretty = translation.prettyText(lineWidth: 60)
        XCTAssertTrue(pretty.contains("\n"), "a long formula must not render as one line")
        for line in pretty.split(separator: "\n") {
            // Atomic conjuncts can still exceed the width, but nothing here does.
            XCTAssertLessThanOrEqual(line.count, 80, "line too long: \(line)")
        }
    }

    func testShortFormulaStaysOnOneLine() throws {
        let translation = try translate("SELECT a FROM T")
        XCTAssertFalse(translation.prettyText().contains("\n"))
    }

    func testParenthesesAppearOnlyWhereNeeded() throws {
        // ∧ binds tighter than ∨, so the conjunction needs brackets inside it.
        let text = try inline("SELECT a FROM T WHERE a = 1 OR (a = 2 AND b = 3)")
        XCTAssertTrue(text.contains("(t.a = 2 ∧ t.b = 3)"), text)
        // …and a plain conjunction needs none of its own.
        let plain = try inline("SELECT a FROM T WHERE a = 1 AND b = 2")
        XCTAssertEqual(plain, "{ t.a | T(t) ∧ t.a = 1 ∧ t.b = 2 }")
    }

    func testInlineAndPrettyAgreeOnAShortFormula() throws {
        let translation = try translate("SELECT name FROM Employee WHERE salary > 1")
        XCTAssertEqual(CalcRenderer().inline(translation), translation.prettyText())
    }

    // MARK: - Sub-queries become quantifiers

    func testExistsBecomesAnExistentialQuantifier() throws {
        let text = try inline("""
            SELECT c.name FROM Customer c
            WHERE EXISTS (SELECT o.id FROM Orders o WHERE o.cid = c.id)
            """)
        XCTAssertEqual(text,
            "{ c.name | Customer(c) ∧ ∃o ( Orders(o) ∧ o.cid = c.id ) }")
    }

    func testNotExistsBecomesANegatedQuantifier() throws {
        let text = try inline("""
            SELECT c.name FROM Customer c
            WHERE NOT EXISTS (SELECT o.id FROM Orders o WHERE o.cid = c.id)
            """)
        XCTAssertEqual(text,
            "{ c.name | Customer(c) ∧ ¬∃o ( Orders(o) ∧ o.cid = c.id ) }")
    }

    func testCorrelatedReferenceResolvesToTheOuterVariable() throws {
        // `c.id` inside the sub-query keeps referring to the outer tuple
        // variable — which is exactly what makes the sub-query correlated.
        let text = try inline("""
            SELECT c.name FROM Customer c
            WHERE EXISTS (SELECT o.id FROM Orders o WHERE o.cid = c.id)
            """)
        XCTAssertTrue(text.contains("o.cid = c.id"), text)
    }

    func testDivisionNestsTwoNegatedQuantifiers() throws {
        // The query the algebra view can only render as σ[NOT EXISTS (…)].
        let text = try inline("""
            SELECT s.name FROM Student s
            WHERE NOT EXISTS (
              SELECT c.id FROM Course c
              WHERE NOT EXISTS (
                SELECT e.sid FROM Enrolled e
                WHERE e.sid = s.id AND e.cid = c.id))
            """)
        XCTAssertEqual(text,
            "{ s.name | Student(s) ∧ ¬∃c ( Course(c) ∧ " +
            "¬∃e ( Enrolled(e) ∧ e.sid = s.id ∧ e.cid = c.id ) ) }")
    }

    func testInSubqueryBecomesAnExistentialWithAnEquality() throws {
        let text = try inline("""
            SELECT c.name FROM Customer c
            WHERE c.id IN (SELECT o.cid FROM Orders o WHERE o.total > 100)
            """)
        XCTAssertEqual(text,
            "{ c.name | Customer(c) ∧ ∃o ( Orders(o) ∧ o.total > 100 ∧ o.cid = c.id ) }")
    }

    func testNotInNegatesTheQuantifier() throws {
        let text = try inline("""
            SELECT c.name FROM Customer c WHERE c.id NOT IN (SELECT o.cid FROM Orders o)
            """)
        XCTAssertTrue(text.contains("¬∃o ( Orders(o) ∧ o.cid = c.id )"), text)
    }

    func testGreaterThanAllBecomesAGuardedUniversal() throws {
        let text = try inline("""
            SELECT e.name FROM Employee e
            WHERE e.salary > ALL (SELECT m.salary FROM Manager m)
            """)
        XCTAssertEqual(text,
            "{ e.name | Employee(e) ∧ ∀m ( Manager(m) → e.salary > m.salary ) }")
    }

    func testGreaterThanAnyBecomesAnExistential() throws {
        let text = try inline("""
            SELECT e.name FROM Employee e
            WHERE e.salary > ANY (SELECT m.salary FROM Manager m)
            """)
        XCTAssertEqual(text,
            "{ e.name | Employee(e) ∧ ∃m ( Manager(m) ∧ e.salary > m.salary ) }")
    }

    func testSomeIsASynonymForAny() throws {
        let any = try inline("SELECT e.x FROM E e WHERE e.x > ANY (SELECT m.y FROM M m)")
        let some = try inline("SELECT e.x FROM E e WHERE e.x > SOME (SELECT m.y FROM M m)")
        XCTAssertEqual(any, some)
    }

    func testAnyStaysUsableAsAColumnName() throws {
        // ANY and SOME are contextual, not reserved: parsing must not break.
        let text = try inline("SELECT any FROM T WHERE any > 1")
        XCTAssertTrue(text.contains("t.any"), text)
    }

    func testScalarSubqueryComparisonBecomesAnExistential() throws {
        let text = try inline("""
            SELECT e.name FROM Employee e
            WHERE e.salary = (SELECT m.salary FROM Manager m WHERE m.id = e.mgr)
            """)
        XCTAssertEqual(text,
            "{ e.name | Employee(e) ∧ ∃m ( Manager(m) ∧ m.id = e.mgr ∧ e.salary = m.salary ) }")
    }

    func testSubqueryVariablesAreNotQuantifiedTwice() throws {
        // The outer quantification pass must look at free variables only.
        let text = try inline("""
            SELECT c.name FROM Customer c
            WHERE EXISTS (SELECT o.id FROM Orders o WHERE o.cid = c.id)
            """)
        XCTAssertEqual(text.components(separatedBy: "∃o").count - 1, 1,
                       "o must be bound exactly once: \(text)")
    }

    func testStarSubqueryCannotSupplyAComparisonColumn() throws {
        let translation = try translate("""
            SELECT c.name FROM Customer c WHERE c.id IN (SELECT * FROM Orders o)
            """)
        XCTAssertTrue(translation.diagnostics.contains {
            $0.construct == "IN (sub-query)" && $0.message.contains("*")
        })
    }

    // MARK: - Safety

    func testTranslatedQueriesAreSafe() throws {
        for sample in SampleQueries.all {
            let translation = try translate(sample.sql)
            let unsafe = SafetyChecker.check(translation)
            XCTAssertTrue(unsafe.isEmpty,
                          "\(sample.title) produced unsafe formula(s): \(unsafe.map(\.message))")
        }
    }

    func testMergedSetOperationsAreSafe() throws {
        for sql in ["SELECT a FROM X UNION SELECT a FROM Y",
                    "SELECT a FROM X INTERSECT SELECT a FROM Y",
                    "SELECT a FROM X EXCEPT SELECT a FROM Y"] {
            XCTAssertTrue(SafetyChecker.check(try translate(sql)).isEmpty, sql)
        }
    }

    func testUnrestrictedResultVariableIsReportedAsUnsafe() throws {
        // `{ ⟨x⟩ | x > 5 }` — a comparison does not restrict a variable's range.
        let x = CalcVar(name: "x", relation: nil)
        let query = CalcQuery(dialect: .trc,
                              result: [ResultColumn(term: .variable(x))],
                              formula: .comparison(lhs: .variable(x), op: ">", rhs: .literal("5")),
                              resultStyle: .tuple)
        let translation = CalcTranslation(dialect: .trc, definitions: [], root: .query(query),
                                          steps: [], schema: QuerySchema(), diagnostics: [])
        let findings = SafetyChecker.check(translation)
        XCTAssertFalse(findings.isEmpty)
        XCTAssertEqual(findings.first?.kind, .safety)
    }

    func testNegationAloneDoesNotRestrictAVariable() throws {
        // `{ ⟨t⟩ | ¬R(t) }` is the classic domain-dependent expression.
        let t = CalcVar(name: "t", relation: "R")
        let query = CalcQuery(dialect: .trc,
                              result: [ResultColumn(term: .variable(t))],
                              formula: .not(.relationAtom(relation: "R", terms: [.variable(t)],
                                                          arityKnown: true)),
                              resultStyle: .tuple)
        let translation = CalcTranslation(dialect: .trc, definitions: [], root: .query(query),
                                          steps: [], schema: QuerySchema(), diagnostics: [])
        XCTAssertFalse(SafetyChecker.check(translation).isEmpty)
    }

    func testUnguardedUniversalIsReported() throws {
        let u = CalcVar(name: "u", relation: nil)
        let query = CalcQuery(dialect: .trc,
                              result: [],
                              formula: .forAll([u], .comparison(lhs: .variable(u), op: ">",
                                                                rhs: .literal("0"))))
        let translation = CalcTranslation(dialect: .trc, definitions: [], root: .query(query),
                                          steps: [], schema: QuerySchema(), diagnostics: [])
        XCTAssertTrue(SafetyChecker.check(translation).contains { $0.construct == "∀u" })
    }

    // MARK: - Derivation steps

    func testStepsFollowTheConstructionSequence() throws {
        let translation = try translate("""
            SELECT e.name
            FROM Employee e JOIN Department d ON e.dept_id = d.id
            WHERE d.location = 'Berlin'
            """)
        let clauses = translation.steps.map(\.clause)
        XCTAssertEqual(clauses.prefix(2).map { $0 }, ["FROM", "INNER JOIN"])
        XCTAssertTrue(clauses.contains("WHERE"))
        XCTAssertTrue(clauses.contains("SELECT"))
        // Steps are numbered from 1, without gaps.
        XCTAssertEqual(translation.steps.map(\.index), Array(1...translation.steps.count))
    }

    func testFinalStepMatchesTheFinishedExpression() throws {
        let translation = try translate("""
            SELECT e.name FROM Employee e JOIN Department d ON e.dept_id = d.id
            """)
        XCTAssertEqual(translation.steps.last?.expression, translation.root)
    }

    func testSubqueryConstructionDoesNotLeakItsOwnSteps() throws {
        // A sub-query's construction belongs to the step that introduced its
        // quantifier, not to the top-level derivation.
        let translation = try translate("""
            SELECT c.name FROM Customer c
            WHERE EXISTS (SELECT o.id FROM Orders o WHERE o.cid = c.id)
            """)
        XCTAssertEqual(translation.steps.filter { $0.clause == "FROM" }.count, 1)
    }

    func testEverySampleProducesSteps() throws {
        for sample in SampleQueries.all {
            let translation = try translate(sample.sql)
            XCTAssertFalse(translation.steps.isEmpty, "\(sample.title) produced no steps")
        }
    }
}
