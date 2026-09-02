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
        let script = try SQLParser.parseScript(sql)
        let inference = SchemaInference.infer(script.query, declarations: script.declarations)
        var translation = TRCTranslator().translate(script.query, schema: inference.schema)
        translation.diagnostics = (inference.diagnostics + translation.diagnostics).deduplicated
        return translation
    }

    private func lowerToDRC(_ sql: String) throws -> CalcTranslation {
        DRCLowering.lower(try translate(sql))
    }

    private func inline(_ sql: String) throws -> String {
        try CalcRenderer().inline(translate(sql))
    }

    private func drc(_ sql: String) throws -> String {
        try CalcRenderer().inline(lowerToDRC(sql))
    }

    /// DRC after the simplifier — the form a textbook would print.
    private func drcSimplified(_ sql: String) throws -> String {
        let lowered = try lowerToDRC(sql).simplifying()
        return CalcRenderer().inline(lowered.simplified)
    }

    private func schema(_ sql: String) throws -> QuerySchema {
        let script = try SQLParser.parseScript(sql)
        return SchemaInference.infer(script.query, declarations: script.declarations).schema
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
            let translation = try translate(sample.text)
            assertQuantifiersAreUsed(in: translation.root, sample: sample.title)
        }
    }

    func testAllSamplesTranslateWithoutCrashing() throws {
        for sample in SampleQueries.all {
            let translation = try translate(sample.text)
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
            case .relationAtom, .comparison, .predicate, .constant, .aggregateBinding:
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
            let translation = try translate(sample.text)
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
                                          simplified: .query(query), steps: [],
                                          schema: QuerySchema(), diagnostics: [])
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
                                          simplified: .query(query), steps: [],
                                          schema: QuerySchema(), diagnostics: [])
        XCTAssertFalse(SafetyChecker.check(translation).isEmpty)
    }

    func testUnguardedUniversalIsReported() throws {
        let u = CalcVar(name: "u", relation: nil)
        let query = CalcQuery(dialect: .trc,
                              result: [],
                              formula: .forAll([u], .comparison(lhs: .variable(u), op: ">",
                                                                rhs: .literal("0"))))
        let translation = CalcTranslation(dialect: .trc, definitions: [], root: .query(query),
                                          simplified: .query(query), steps: [],
                                          schema: QuerySchema(), diagnostics: [])
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
            let translation = try translate(sample.text)
            XCTAssertFalse(translation.steps.isEmpty, "\(sample.title) produced no steps")
        }
    }

    // MARK: - CREATE TABLE

    func testDeclaredColumnsAreExactAndOrdered() throws {
        let s = try schema("""
            CREATE TABLE Employee (id INTEGER, name VARCHAR(50), salary DECIMAL(10,2));
            SELECT name FROM Employee
            """)
        let employee = s.schema(for: "Employee")
        XCTAssertEqual(employee?.attributes, ["id", "name", "salary"])
        XCTAssertEqual(employee?.source, .declared)
        XCTAssertTrue(employee?.arityKnown ?? false)
    }

    func testDeclarationOutranksInference() throws {
        // The query only ever mentions `name`, but the declaration knows better.
        let s = try schema("""
            CREATE TABLE Employee (id INT, name TEXT, salary INT);
            SELECT name FROM Employee WHERE name = 'x'
            """)
        XCTAssertEqual(s.schema(for: "Employee")?.attributes.count, 3)
    }

    func testTableConstraintsAreSkippedNotTakenAsColumns() throws {
        let s = try schema("""
            CREATE TABLE Orders (
              id INTEGER,
              customer_id INTEGER,
              PRIMARY KEY (id),
              FOREIGN KEY (customer_id) REFERENCES Customer(id)
            );
            SELECT id FROM Orders
            """)
        XCTAssertEqual(s.schema(for: "Orders")?.attributes, ["id", "customer_id"])
    }

    func testParenthesisedTypesDoNotEndTheColumnEntry() throws {
        let s = try schema("""
            CREATE TABLE T (a DECIMAL(10, 2), b VARCHAR(255));
            SELECT a FROM T
            """)
        XCTAssertEqual(s.schema(for: "T")?.attributes, ["a", "b"])
    }

    func testMultipleDeclarationsAreAllRead() throws {
        let s = try schema("""
            CREATE TABLE A (x INT);
            CREATE TABLE B (y INT);
            SELECT x FROM A
            """)
        XCTAssertTrue(s.schema(for: "A")?.arityKnown ?? false)
        XCTAssertTrue(s.schema(for: "B")?.arityKnown ?? false)
    }

    func testQueryWithoutDeclarationsStillParses() throws {
        XCTAssertEqual(try SQLParser.parseScript("SELECT a FROM T").declarations.count, 0)
    }

    // MARK: - DRC lowering

    func testTupleVariableExplodesIntoOneVariablePerColumn() throws {
        let text = try drc("""
            CREATE TABLE Employee (name TEXT, salary INT, dept_id INT);
            SELECT name, salary FROM Employee WHERE salary > 50000
            """)
        XCTAssertEqual(text, "{ ⟨n, s⟩ | ∃d ( Employee(n, s, d) ∧ s > 50000 ) }")
    }

    func testColumnsTheResultExportsStayFree() throws {
        let text = try drc("""
            CREATE TABLE T (a INT, b INT, c INT);
            SELECT a, b, c FROM T
            """)
        // Nothing to quantify: every column is exported.
        XCTAssertEqual(text, "{ ⟨a, b, c⟩ | T(a, b, c) }")
    }

    func testAtomIsMarkedIncompleteWhenTheSchemaWasOnlyInferred() throws {
        let text = try drc("SELECT e.name FROM Employee e WHERE e.salary > 1")
        // Two columns are known; the relation may well have more, and a guessed
        // arity would be a wrong formula rather than an incomplete one.
        XCTAssertTrue(text.contains("Employee(n, s, …)"), text)
    }

    func testIncompleteArityIsReported() throws {
        let translation = try lowerToDRC("SELECT e.name FROM Employee e")
        XCTAssertTrue(translation.diagnostics.contains {
            $0.construct == "Employee" && $0.message.contains("CREATE TABLE")
        })
    }

    func testJoinLowersToTwoAtomsAndAnEquality() throws {
        let text = try drc("""
            CREATE TABLE Employee (name TEXT, dept_id INT);
            CREATE TABLE Department (id INT, location TEXT);
            SELECT e.name FROM Employee e JOIN Department d ON e.dept_id = d.id
            """)
        // Nested, not flattened: collapsing the quantifiers is a named
        // simplification pass, not something the lowering does silently.
        XCTAssertEqual(text,
            "{ ⟨n⟩ | ∃d ( Employee(n, d) ∧ ∃i, l ( Department(i, l) ∧ d = i ) ) }")
    }

    func testQuantifiersFromSubqueriesSurviveLowering() throws {
        let text = try drc("""
            CREATE TABLE Customer (id INT, name TEXT);
            CREATE TABLE Orders (oid INT, cid INT);
            SELECT c.name FROM Customer c
            WHERE NOT EXISTS (SELECT o.oid FROM Orders o WHERE o.cid = c.id)
            """)
        XCTAssertTrue(text.contains("¬∃"), text)
        XCTAssertTrue(text.contains("Orders(o, c)"), text)
    }

    func testLoweredQueriesAreSafe() throws {
        for sample in SampleQueries.all {
            let lowered = try lowerToDRC(sample.text)
            XCTAssertTrue(SafetyChecker.check(lowered).isEmpty,
                          "\(sample.title): \(SafetyChecker.check(lowered).map(\.message))")
        }
    }

    func testEverySampleLowersWithoutCrashing() throws {
        for sample in SampleQueries.all {
            let text = try lowerToDRC(sample.text).prettyText()
            XCTAssertTrue(text.contains("{"), "\(sample.title): \(text)")
        }
    }

    // MARK: - Simplification

    func testEqualityUnificationMergesJoinedColumns() throws {
        let text = try drcSimplified("""
            CREATE TABLE Employee (name TEXT, dept_id INT);
            CREATE TABLE Department (id INT, location TEXT);
            SELECT e.name FROM Employee e JOIN Department d ON e.dept_id = d.id
            """)
        // One variable now stands in both atoms, and the equality is gone.
        XCTAssertEqual(text, "{ ⟨n⟩ | ∃d, l ( Employee(n, d) ∧ Department(d, l) ) }")
    }

    func testConstantsAreInlinedIntoTheAtom() throws {
        let text = try drcSimplified("""
            CREATE TABLE Department (id INT, location TEXT);
            SELECT d.id FROM Department d WHERE d.location = 'Berlin'
            """)
        XCTAssertEqual(text, "{ ⟨i⟩ | Department(i, 'Berlin') }")
    }

    func testNegatedExistentialBecomesAGuardedUniversal() throws {
        let outcome = CalcSimplifier.simplify(try translate("""
            SELECT s.name FROM Student s
            WHERE NOT EXISTS (
              SELECT c.id FROM Course c
              WHERE NOT EXISTS (
                SELECT e.sid FROM Enrolled e
                WHERE e.sid = s.id AND e.cid = c.id))
            """).root)
        XCTAssertEqual(CalcRenderer().inline(outcome.expression),
            "{ s.name | Student(s) ∧ ∀c ( Course(c) → ∃e ( Enrolled(e) ∧ e.sid = s.id ∧ e.cid = c.id ) ) }")
        XCTAssertTrue(outcome.records.contains { $0.name == "Rewrite ¬∃ as ∀" })
    }

    func testPlainNegatedExistentialIsLeftAlone() throws {
        // `¬∃o ( Orders(o) )` would only become `∀o ( ¬Orders(o) )`, which is
        // no clearer than where it started.
        let outcome = CalcSimplifier.simplify(try translate("""
            SELECT c.name FROM Customer c
            WHERE NOT EXISTS (SELECT o.id FROM Orders o WHERE o.cid = c.id)
            """).root)
        XCTAssertTrue(CalcRenderer().inline(outcome.expression).contains("¬∃"))
    }

    func testSimplificationIsIdempotent() throws {
        for sample in SampleQueries.all {
            let once = CalcSimplifier.simplify(try translate(sample.text).root).expression
            let twice = CalcSimplifier.simplify(once).expression
            XCTAssertEqual(once, twice, "\(sample.title) is not a fixpoint")
        }
    }

    func testSimplificationPreservesSafety() throws {
        for sample in SampleQueries.all {
            var lowered = try lowerToDRC(sample.text)
            lowered = lowered.simplifying()
            var checked = lowered
            checked.root = lowered.simplified
            XCTAssertTrue(SafetyChecker.check(checked).isEmpty,
                          "\(sample.title) became unsafe under simplification")
        }
    }

    func testSimplificationRecordsAStepPerPassThatFired() throws {
        let lowered = try lowerToDRC("""
            CREATE TABLE Employee (name TEXT, dept_id INT);
            CREATE TABLE Department (id INT, location TEXT);
            SELECT e.name FROM Employee e JOIN Department d ON e.dept_id = d.id
            WHERE d.location = 'Berlin'
            """).simplifying()
        XCTAssertFalse(lowered.simplifications.isEmpty)
        XCTAssertTrue(lowered.isSimplified)
        // Steps continue the construction sequence's numbering.
        XCTAssertEqual(lowered.simplifications.first?.index, lowered.steps.count + 1)
    }

    func testUnchangedFormulaOffersNoSimplification() throws {
        let translation = try translate("SELECT a FROM T").simplifying()
        XCTAssertFalse(translation.isSimplified)
        XCTAssertTrue(translation.simplifications.isEmpty)
    }

    // MARK: - Aggregation (an extension, not pure calculus)

    func testAggregateBecomesAComprehensionOverTheGroup() throws {
        let text = try inline("""
            SELECT dept_id, COUNT(*) AS headcount FROM Employee GROUP BY dept_id
            """)
        XCTAssertEqual(text,
            "{ ⟨d, headcount⟩ | ∃e ( Employee(e) ∧ e.dept_id = d ) " +
            "∧ headcount = COUNT{ e | Employee(e) ∧ e.dept_id = d } }")
    }

    func testAggregateOverAValueCollectsThatValue() throws {
        let text = try inline("SELECT dept_id, AVG(salary) FROM Employee GROUP BY dept_id")
        XCTAssertTrue(text.contains("AVG{ e.salary |"), text)
    }

    func testWhereGoesInsideTheComprehensionAndHavingOutside() throws {
        let text = try inline("""
            SELECT dept_id, COUNT(*) FROM Employee
            WHERE salary > 100 GROUP BY dept_id HAVING COUNT(*) > 5
            """)
        // The filter on rows is inside the comprehension…
        XCTAssertTrue(text.contains("e.salary > 100 ∧ e.dept_id = d }"), text)
        // …and the filter on groups is outside it.
        XCTAssertTrue(text.hasSuffix("∧ c > 5 }"), text)
    }

    func testTheSameAggregateIsBoundOnce() throws {
        // COUNT(*) appears in both the SELECT list and HAVING.
        let text = try inline("""
            SELECT dept_id, COUNT(*) AS n FROM Employee GROUP BY dept_id HAVING COUNT(*) > 5
            """)
        XCTAssertEqual(text.components(separatedBy: "COUNT{").count - 1, 1, text)
        XCTAssertTrue(text.contains("n > 5"), text)
    }

    func testAggregateWithoutGroupByHasNoGroupEnumeration() throws {
        let text = try inline("SELECT COUNT(*) FROM Employee")
        // One group — the whole relation — so nothing to enumerate.
        XCTAssertEqual(text, "{ ⟨c⟩ | c = COUNT{ e | Employee(e) } }")
    }

    func testAggregationIsLabelledAsAnExtension() throws {
        let translation = try translate("SELECT dept_id, COUNT(*) FROM Employee GROUP BY dept_id")
        XCTAssertTrue(translation.diagnostics.contains {
            $0.construct == "GROUP BY / aggregates" && $0.fidelity == .extended
        })
        // And it is no longer pushed outside the braces.
        let query = try onlyQuery(translation)
        XCTAssertFalse(query.extensions.contains { $0.kind == .grouping })
    }

    func testGroupingModifierStaysAnnotated() throws {
        // ROLLUP produces several groupings at once, which one set of grouping
        // variables cannot express.
        let translation = try translate("SELECT a, COUNT(*) FROM T GROUP BY ROLLUP(a)")
        XCTAssertTrue(translation.diagnostics.contains { $0.fidelity == .annotated })
    }

    func testAggregateQueriesAreStillSafe() throws {
        for sql in ["SELECT dept_id, COUNT(*) FROM Employee GROUP BY dept_id",
                    "SELECT COUNT(*) FROM Employee",
                    "SELECT d, SUM(x) FROM T GROUP BY d HAVING SUM(x) > 1"] {
            XCTAssertTrue(SafetyChecker.check(try translate(sql)).isEmpty, sql)
        }
    }

    // MARK: - Bundled examples

    func testEveryBundledQueryParses() throws {
        for group in SampleQueries.groups {
            for sample in group.queries {
                XCTAssertNoThrow(try SQLParser.parseScript(sample.text),
                                 "\(group.title) / \(sample.title) does not parse")
            }
        }
    }

    /// The one test that says "every bundled example works": each parses, and
    /// each produces a rendered expression in all three notations without a
    /// crash, an empty result or an unsafe formula.
    func testEveryBundledQueryWorksInAllThreeNotations() throws {
        for group in SampleQueries.groups {
            for sample in group.queries {
                let label = "\(group.title) / \(sample.title)"
                let script = try SQLParser.parseScript(sample.text)
                let bundle = AppViewModel.translate(script)

                let algebra = bundle.ra.finalExpression.formula
                XCTAssertFalse(algebra.isEmpty, "\(label): no algebra expression")

                for translation in [bundle.trc, bundle.drc] {
                    let dialect = translation.dialect.rawValue
                    let rendered = translation.prettyText()
                    XCTAssertTrue(rendered.contains("{"), "\(label) \(dialect): \(rendered)")
                    XCTAssertFalse(translation.steps.isEmpty, "\(label) \(dialect): no steps")
                    XCTAssertTrue(SafetyChecker.check(translation).isEmpty,
                                  "\(label) \(dialect) is unsafe: " +
                                  "\(SafetyChecker.check(translation).map(\.message))")
                    // Simplification must reach a fixpoint within the bound.
                    let once = CalcSimplifier.simplify(translation.root).expression
                    XCTAssertEqual(once, CalcSimplifier.simplify(once).expression,
                                   "\(label) \(dialect): simplification did not converge")
                }
            }
        }
    }

    func testBenchmarkSamplesCarryTheirSchemaWhereBundled() throws {
        for sample in SampleQueries.tpch.queries {
            let script = try SQLParser.parseScript(sample.text)
            XCTAssertFalse(script.declarations.isEmpty,
                           "\(sample.title) should load its tables so the domain atoms are exact")
        }
    }

    func testDeclaredBenchmarkTablesMakeTheDomainAtomsExact() throws {
        // Every relation a TPC-H sample touches should have a declared arity —
        // otherwise its DRC atoms carry an ellipsis and the sample teaches the
        // wrong lesson.
        for sample in SampleQueries.tpch.queries {
            let translation = try lowerToDRC(sample.text)
            let inferred = translation.schema.sortedRelations.filter { !$0.arityKnown }
            XCTAssertTrue(inferred.isEmpty,
                          "\(sample.title): \(inferred.map(\.name)) were not declared")
        }
    }

    func testDomainVariableNamesAreDistinguishable() throws {
        // TPC-H prefixes every column with its table, so naming from the prefix
        // would give a sixteen-column relation sixteen variants of "l".
        let translation = try lowerToDRC(
            TPCHSchema.declarations(for: ["lineitem"]) + "\nSELECT l_orderkey, l_quantity FROM lineitem")
        let text = CalcRenderer().inline(translation)
        XCTAssertTrue(text.contains("o"), text)
        XCTAssertTrue(text.contains("q"), text)
        XCTAssertFalse(text.contains("l₁₅"), text)
    }

    // MARK: - Nothing is opaque without saying so

    func testWindowFunctionIsReportedNotSilentlyCarried() throws {
        let translation = try translate("""
            SELECT RANK() OVER (PARTITION BY dept ORDER BY salary DESC) AS r FROM Employee
            """)
        XCTAssertTrue(translation.diagnostics.contains { $0.construct == "window function" },
                      "a window function has no first-order expression and must say so")
    }

    func testCaseExpressionIsReported() throws {
        let translation = try translate(
            "SELECT CASE WHEN salary > 1 THEN 'high' ELSE 'low' END AS band FROM Employee")
        XCTAssertTrue(translation.diagnostics.contains { $0.construct == "CASE" })
    }

    func testScalarSubqueryInTheSelectListIsReported() throws {
        let translation = try translate(
            "SELECT e.name, (SELECT COUNT(*) FROM Orders o) AS total FROM Employee e")
        XCTAssertTrue(translation.diagnostics.contains {
            $0.construct == "(sub-query) as a value"
        })
    }

    func testCastCarriesNoWarningBecauseNothingIsLost() throws {
        // A cast is an ordinary scalar function; it needs no caveat.
        let translation = try translate("SELECT CAST(salary AS INTEGER) AS s FROM Employee")
        XCTAssertFalse(translation.diagnostics.contains { $0.construct == "CASE" })
        XCTAssertEqual(translation.diagnostics.warningCount, 0)
    }

    // MARK: - Export styles

    func testAsciiStyleSpellsTheGlyphsOut() throws {
        let translation = try translate("SELECT e.name FROM Employee e WHERE e.salary > 1")
        let text = CalcRenderer(style: .ascii).inline(translation)
        XCTAssertFalse(text.contains("∧"), text)
        XCTAssertTrue(text.contains("AND"), text)
    }

    func testLatexStyleEmitsCommandsAndEscapesUnderscores() throws {
        let translation = try translate("""
            SELECT e.name FROM Employee e JOIN Department d ON e.dept_id = d.id
            """)
        let text = CalcRenderer(style: .latex).inline(translation)
        XCTAssertTrue(text.contains("\\wedge"), text)
        XCTAssertTrue(text.contains("\\mid"), text)
        // `dept_id` would be a subscript unescaped.
        XCTAssertTrue(text.contains("dept\\_id"), text)
        XCTAssertFalse(text.contains("∧"), text)
    }

    func testUnicodeStyleIsUnchanged() throws {
        let translation = try translate("SELECT a FROM T WHERE a > 1")
        XCTAssertEqual(CalcRenderer(style: .unicode).inline(translation),
                       CalcRenderer().inline(translation))
    }

    func testAlgebraLatexUsesStandardOperatorCommands() throws {
        let query = try SQLParser.parse("SELECT name FROM Employee WHERE dept_id > 1")
        let latex = RATranslator().translate(query).finalExpression.latex
        XCTAssertTrue(latex.contains("\\pi_"), latex)
        XCTAssertTrue(latex.contains("\\sigma_"), latex)
        XCTAssertTrue(latex.contains("dept\\_id"), latex)
    }

    // MARK: - Scope tree

    func testScopeTreeShowsQuantifiersAsNodes() throws {
        let translation = try translate("""
            SELECT c.name FROM Customer c
            WHERE NOT EXISTS (SELECT o.id FROM Orders o WHERE o.cid = c.id)
            """)
        let tree = translation.root.scopeTree
        XCTAssertEqual(tree.symbol, "{ … | … }")
        XCTAssertTrue(contains(tree, symbol: CalcSymbol.exists))
        XCTAssertTrue(contains(tree, symbol: CalcSymbol.not))
        XCTAssertTrue(contains(tree, symbol: "Customer(c)"))
    }

    func testScopeTreeNamesTheVariablesEachQuantifierBinds() throws {
        let translation = try translate("""
            SELECT e.name FROM Employee e JOIN Department d ON e.dept_id = d.id
            """)
        let tree = translation.root.scopeTree
        XCTAssertTrue(node(tree, symbol: CalcSymbol.exists)?.detail == "d")
    }

    private func contains(_ node: DiagramNode, symbol: String) -> Bool {
        self.node(node, symbol: symbol) != nil
    }

    private func node(_ node: DiagramNode, symbol: String) -> DiagramNode? {
        if node.symbol == symbol { return node }
        for child in node.children {
            if let found = self.node(child, symbol: symbol) { return found }
        }
        return nil
    }

    func testResultVariablesAreNeverSubstitutedAway() throws {
        // `a` is exported, so unification must keep it rather than the bound name.
        let text = try drcSimplified("""
            CREATE TABLE X (a INT, b INT);
            SELECT x.a FROM X x WHERE x.a = x.b
            """)
        XCTAssertTrue(text.contains("⟨a⟩"), text)
    }
}
