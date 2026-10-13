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

    private func sql(_ ra: String) throws -> SQLGeneration {
        try RAToSQL.translate(RAParser.parse(ra))
    }

    // MARK: - Golden SQL

    func testGoldenCasesProduceExactlyTheRecordedSQL() throws {
        let cases = try fixture().cases
        XCTAssertFalse(cases.isEmpty)
        for golden in cases {
            XCTAssertEqual(try sql(golden.ra).text, golden.sql, golden.name)
        }
    }

    /// Whatever the printer writes, the app's own parser must read back to a
    /// query that prints identically — otherwise "Edit as SQL" would break it.
    func testGeneratedSQLParsesBackToItself() throws {
        for golden in try fixture().cases {
            let reparsed = try SQLParser.parse(golden.sql)
            XCTAssertEqual(SQLPrinter().print(reparsed), golden.sql, golden.name)
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

    func testUnsupportedOperatorsAreRefusedNotGuessed() {
        XCTAssertThrowsError(try RAParser.parse("R ÷ S"))
        XCTAssertThrowsError(try RAParser.parse("γ[a; COUNT(*)](R)"))
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
