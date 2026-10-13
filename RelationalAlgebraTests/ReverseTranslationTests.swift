//
//  ReverseTranslationTests.swift
//  RelationalAlgebraTests
//
//  Relational algebra in, SQL out.
//
//  The golden cases live in Fixtures/ra_to_sql.json rather than here, because a
//  second checker reads them too: scripts/check_engines.py runs each case's SQL
//  on DuckDB and DataFusion and compares the answers. This file proves the app
//  prints exactly that SQL; the script proves the SQL means what the algebra
//  does on the engines users will paste it into.
//

import XCTest
@testable import RelationalAlgebra

final class ReverseTranslationTests: XCTestCase {

    // MARK: - Fixture

    private struct Fixture: Decodable {
        struct Case: Decodable {
            let name: String
            let ra: String
            let sql: String
            /// Present where the DataFusion setting writes something else.
            let sql_datafusion: String?
        }
        let cases: [Case]
    }

    /// Read from the source tree: a simulator test process can see the host's
    /// file system, and keeping one copy means the two checkers cannot drift.
    private func fixture() throws -> Fixture {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ra_to_sql.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    /// The whole script — declarations and assignments too, not just the
    /// final expression.
    private func sql(_ ra: String) throws -> SQLGeneration {
        try RAToSQL.translate(RAParser.parseScript(ra))
    }

    // MARK: - Golden SQL

    func testGoldenCasesProduceExactlyTheRecordedSQL() throws {
        let cases = try fixture().cases
        XCTAssertFalse(cases.isEmpty)
        for golden in cases {
            XCTAssertEqual(try sql(golden.ra).text, golden.sql, golden.name)
            XCTAssertEqual(try RAToSQL.translate(RAParser.parseScript(golden.ra), dialect: .datafusion).text,
                           golden.sql_datafusion ?? golden.sql, "\(golden.name) (DataFusion)")
        }
    }

    /// Whatever the printer writes, the app's own parser must read back to a
    /// query that prints identically — otherwise "Edit as SQL" would break it.
    func testGeneratedSQLParsesBackToItself() throws {
        for golden in try fixture().cases {
            for sql in [golden.sql, golden.sql_datafusion].compactMap({ $0 }) {
                XCTAssertEqual(SQLPrinter().print(try SQLParser.parse(sql)), sql, golden.name)
            }
        }
    }

    func testBundledSamplesPrintSQLTheAppCanReadBack() throws {
        for sample in SampleQueries.all {
            let query = try SQLParser.parse(sample.sql)
            let printed = SQLPrinter().print(query)
            let reprinted = SQLPrinter().print(try SQLParser.parse(printed))
            XCTAssertEqual(reprinted, printed, sample.title)
        }
    }

    // MARK: - The whole pipeline

    func testAlgebraSamplesReachEveryNotation() throws {
        let samples = SampleQueries.raGroups.flatMap(\.queries)
        XCTAssertFalse(samples.isEmpty)
        for sample in samples {
            XCTAssertEqual(sample.language, .ra, sample.title)
            let bundle = try AppViewModel.translate(ra: try RAParser.parseScript(sample.text))
            XCTAssertNotNil(bundle.sql, sample.title)
            XCTAssertFalse(bundle.ra.steps.isEmpty, sample.title)
        }
    }

    func testDeclarationsAboveTheAlgebraReachTheSchema() throws {
        let script = try RAParser.parseScript("""
            CREATE TABLE R (a INT, b INT);
            CREATE TABLE CreatedAt (x INT);
            π[a](R)
            """)
        XCTAssertEqual(script.declarations.map(\.name), ["R", "CreatedAt"])
        XCTAssertEqual(script.declarations.first?.columns, ["a", "b"])
        XCTAssertEqual(script.expression,
                       .projection(items: [.expression(.column(table: nil, name: "a"), alias: nil)],
                                   child: .relation("R")))
    }

    func testARelationNamedLikeCreateIsNotADeclaration() throws {
        let script = try RAParser.parseScript("CreatedItems")
        XCTAssertTrue(script.declarations.isEmpty)
        XCTAssertEqual(script.expression, .relation("CreatedItems"))
    }

    // MARK: - Spellings

    func testGlyphsAndWordsParseAlike() throws {
        XCTAssertEqual(try RAParser.parse("π[name](σ[a ≥ 1 ∧ b ≠ 2](R)) ∪ S"),
                       try RAParser.parse("pi[name](select[a >= 1 AND b <> 2](R)) union S"))
        XCTAssertEqual(try RAParser.parse("R ⋈[R.a = S.a] S"),
                       try RAParser.parse("R join[R.a = S.a] S"))
        XCTAssertEqual(try RAParser.parse("R ⋈_{R.a = S.a} S"),
                       try RAParser.parse("R join[R.a = S.a] S"))
    }

    func testAnXBetweenOperandsIsAProduct() throws {
        XCTAssertEqual(try RAParser.parse("R x S"),
                       .cross(left: .relation("R"), right: .relation("S")))
        // …but a quoted one is a relation.
        XCTAssertThrowsError(try RAParser.parse("R \"x\" S"))
    }

    func testSetOperatorsBindLooserThanJoins() throws {
        XCTAssertEqual(try RAParser.parse("R ∪ S × T"),
                       .setOperation(.union, left: .relation("R"),
                                     right: .cross(left: .relation("S"), right: .relation("T"))))
    }

    func testArrowRenamesAProjectedColumn() throws {
        XCTAssertEqual(try sql("π[salary * 12 → annual](Employee)").text,
                       "SELECT DISTINCT salary * 12 AS annual\nFROM Employee;")
    }

    // MARK: - Named results

    func testAssignmentsInEverySpelling() throws {
        let script = try RAParser.parseScript("""
            R₁ = Employee
            R₂ ← σ[salary > 1](R₁); R3 := π[name](R₂)
            """)
        XCTAssertEqual(script.assignments.map(\.name), ["R1", "R2", "R3"])
        // Ending on an assignment makes that name the answer.
        XCTAssertEqual(script.expression, .relation("R3"))
    }

    func testTwoExpressionsOnOneLineAreATypoNotTwoStatements() {
        XCTAssertThrowsError(try RAParser.parseScript("R1 = Employee Department"))
        XCTAssertThrowsError(try RAParser.parseScript("Employee\nDepartment"))
    }

    func testANameMustBeAssignedBeforeItIsRead() {
        XCTAssertThrowsError(try RAToSQL.translate(
            RAParser.parseScript("R1 = σ[a > 1](R2)\nR2 = Employee\nR1")))
        XCTAssertThrowsError(try RAParser.parseScript("R1 = Employee\nR1 = Department"))
    }

    func testAnUnreadNameIsLeftOutAndSaysSo() throws {
        let generated = try RAToSQL.translate(
            RAParser.parseScript("Unused = Department\nπ[name](Employee)"))
        XCTAssertFalse(generated.text.contains("Department"), generated.text)
        XCTAssertTrue(generated.diagnostics.contains { $0.construct == "Unused" })
    }

    /// The point of accepting assignments: the Steps view's derivation, pasted
    /// back, must translate.
    func testTheForwardDerivationPastesBack() throws {
        let titles = ["Filter + project", "Inner join"]
        let samples = SampleQueries.all.filter { titles.contains($0.title) }
        XCTAssertEqual(samples.count, titles.count)
        for sample in samples {
            let forward = RATranslator().translate(try SQLParser.parse(sample.sql))
            let derivation = forward.steps.map(\.definition).joined(separator: "\n")
            XCTAssertNoThrow(try RAToSQL.translate(RAParser.parseScript(derivation)),
                             "\(sample.title):\n\(derivation)")
        }
    }

    // MARK: - Prettify and steps

    /// Prettify rewrites the buffer from the parse tree. Whatever it writes
    /// must mean exactly what was there: the same SQL comes out.
    func testPrettifiedAlgebraTranslatesToTheSameSQL() throws {
        for golden in try fixture().cases {
            let pretty = try RAParser.parseScript(golden.ra).prettyText(prelude: "")
            XCTAssertEqual(try RAToSQL.translate(RAParser.parseScript(pretty)).text, golden.sql,
                           "\(golden.name):\n\(pretty)")
        }
    }

    func testPrettifyTurnsWordsIntoGlyphsAndKeepsDeclarations() throws {
        let source = "CREATE TABLE R (a INT);\npi[a](sigma[a > 1](R))"
        let pretty = try RAParser.parseScript(source)
            .prettyText(prelude: RAParser.declarationPrelude(source))
        XCTAssertTrue(pretty.hasPrefix("CREATE TABLE R (a INT);"), pretty)
        XCTAssertTrue(pretty.contains("π[a]"), pretty)
        XCTAssertTrue(pretty.contains("σ[a > 1]"), pretty)
    }

    func testStepsRunBottomUpAndEndOnTheWholeQuery() throws {
        let generated = try sql("π[name, salary] ( σ[salary > 50000] ( Employee ) )")
        XCTAssertEqual(generated.steps.map(\.title), ["Relation", "Selection σ", "Projection π"])
        XCTAssertEqual(generated.steps.map(\.index), [1, 2, 3])
        XCTAssertEqual(generated.steps.last?.sql, generated.text)
        XCTAssertTrue(generated.steps[1].explanation.contains("WHERE"))
    }

    // MARK: - Errors

    func testParseErrorsPointIntoTheSubscript() {
        XCTAssertThrowsError(try RAParser.parse("π[name](σ[salary > ](Employee))")) { error in
            // The subscript starts at offset 10; its text ends at 9 more.
            XCTAssertEqual((error as? ParseError)?.position, 19)
        }
    }

    func testMissingSubscriptSaysWhatToWrite() {
        XCTAssertThrowsError(try RAParser.parse("σ(Employee)")) { error in
            XCTAssertTrue((error as? ParseError)?.message.contains("σ[") == true)
        }
    }

    /// ÷ says which attributes to keep only through the schema, so without
    /// declarations it is refused rather than guessed.
    func testDivisionNeedsDeclaredColumns() throws {
        XCTAssertThrowsError(try sql("R ÷ S")) { error in
            XCTAssertTrue(error is TranslationError)
        }
        XCTAssertNoThrow(try sql("CREATE TABLE R (a INT, b INT);\nCREATE TABLE S (b INT);\nR ÷ S"))
        XCTAssertThrowsError(try sql("CREATE TABLE R (a INT);\nCREATE TABLE S (b INT);\nR ÷ S"))
    }

    func testGroupingWithoutASemicolonSortsKeysFromAggregates() throws {
        XCTAssertEqual(try RAParser.parse("γ[COUNT(*) → n, dept_id](Employee)"),
                       try RAParser.parse("γ[dept_id; COUNT(*) → n](Employee)"))
    }

    func testTheAppsOwnSortAndLimitReadBack() throws {
        // The forms the Formula view prints for ORDER BY and LIMIT.
        XCTAssertNoThrow(try sql("LIMIT[10 offset 20] ( τ[salary ↓, name ↑] ( Employee ) )"))
        XCTAssertEqual(try sql("LIMIT[offset 5](Employee)").text, "SELECT *\nFROM Employee\nOFFSET 5;")
    }

    func testSelfJoinWithoutRenameIsRefused() {
        XCTAssertThrowsError(try sql("Employee × Employee")) { error in
            XCTAssertTrue(error is TranslationError)
        }
        XCTAssertNoThrow(try sql("Employee × ρ[E2](Employee)"))
    }

    // MARK: - Diagnostics

    func testProjectionExplainsTheDistinct() throws {
        let generated = try sql("π[name](Employee)")
        XCTAssertTrue(generated.diagnostics.contains { $0.construct == "π → SELECT DISTINCT" })
    }

    func testHiddenQualifierIsDroppedAndExplained() throws {
        let generated = try sql("σ[e.salary > 5](π[e.salary](ρ[e](Employee)))")
        XCTAssertTrue(generated.text.contains("WHERE salary > 5"), generated.text)
        XCTAssertTrue(generated.diagnostics.contains { $0.construct == "e.salary" })
    }

    func testIntegerDivisionDifferenceIsFlagged() throws {
        let generated = try sql("π[salary / 12 → monthly](Employee)")
        XCTAssertTrue(generated.diagnostics.contains { $0.construct == "a / b" })
    }

    // MARK: - Printer

    func testPrinterParenthesisesOnlyWherePrecedenceNeedsIt() throws {
        let printer = SQLPrinter()
        let orInsideAnd = try SQLParser.parseStandaloneExpression("(a = 1 OR b = 2) AND c = 3")
        XCTAssertEqual(printer.expression(orInsideAnd), "(a = 1 OR b = 2) AND c = 3")

        let built = Expression.binary(
            op: "AND",
            lhs: .binary(op: "OR", lhs: .column(table: nil, name: "a"), rhs: .column(table: nil, name: "b")),
            rhs: .binary(op: "-", lhs: .column(table: nil, name: "x"),
                         rhs: .binary(op: "-", lhs: .column(table: nil, name: "y"),
                                      rhs: .column(table: nil, name: "z"))))
        XCTAssertEqual(printer.expression(built), "(a OR b) AND x - (y - z)")
    }

    func testPrinterQuotesOnlyWhatNeedsQuoting() {
        let printer = SQLPrinter()
        XCTAssertEqual(printer.identifier("dept_id"), "dept_id")
        XCTAssertEqual(printer.identifier("select"), "\"select\"")
        XCTAssertEqual(printer.identifier("R₁"), "\"R₁\"")
        XCTAssertEqual(SQLPrinter.stringLiteral("O'Brien"), "'O''Brien'")
    }
}
