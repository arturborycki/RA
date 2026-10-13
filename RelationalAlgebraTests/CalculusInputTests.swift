//
//  CalculusInputTests.swift
//  RelationalAlgebraTests
//
//  Tuple and domain relational calculus in, SQL out.
//
//  As for the algebra, the golden cases live in Fixtures/calc_to_sql.json so
//  that scripts/check_engines.py can run the same SQL on DuckDB and DataFusion.
//  Each input is checked with the fixture database declared above it, which is
//  what gives a domain-calculus atom its column names.
//

import XCTest
@testable import RelationalAlgebra

final class CalculusInputTests: XCTestCase {

    // MARK: - Fixtures

    private struct Database: Decodable {
        struct Table: Decodable { let columns: [[String]] }
        let database: [String: Table]
    }

    private struct Cases: Decodable {
        struct Case: Decodable {
            let name: String
            let dialect: String
            let input: String
            let sql: String
            let sql_datafusion: String?
        }
        let cases: [Case]
    }

    private func fixture(_ file: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(file)")
    }

    private func cases() throws -> [Cases.Case] {
        try JSONDecoder().decode(Cases.self, from: Data(contentsOf: fixture("calc_to_sql.json"))).cases
    }

    /// `CREATE TABLE` for every table of the fixture database.
    private func ddl() throws -> String {
        let db = try JSONDecoder().decode(Database.self,
                                          from: Data(contentsOf: fixture("ra_to_sql.json")))
        return db.database.keys.sorted().map { name in
            let columns = db.database[name]!.columns.map { "\($0[0]) \($0[1])" }
            return "CREATE TABLE \(name) (\(columns.joined(separator: ", ")));"
        }.joined(separator: "\n")
    }

    private func script(_ input: String, _ dialect: CalcDialect = .trc) throws -> CalcScript {
        try CalcParser.parseScript(try ddl() + "\n\n" + input, preferring: dialect)
    }

    private func dialect(_ name: String) -> CalcDialect { name == "drc" ? .drc : .trc }

    // MARK: - Golden SQL

    func testGoldenCasesProduceExactlyTheRecordedSQL() throws {
        let all = try cases()
        XCTAssertFalse(all.isEmpty)
        for golden in all {
            let parsed = try script(golden.input, .trc)
            // Detected from the formula, not from the preference passed in.
            XCTAssertEqual(parsed.dialect, dialect(golden.dialect), golden.name)
            XCTAssertEqual(try CalcToSQL.translate(parsed, dialect: .duckdb).text, golden.sql,
                           golden.name)
            XCTAssertEqual(try CalcToSQL.translate(parsed, dialect: .datafusion).text,
                           golden.sql_datafusion ?? golden.sql, "\(golden.name) (DataFusion)")
        }
    }

    func testGeneratedSQLParsesBackToItself() throws {
        for golden in try cases() {
            for sql in [golden.sql, golden.sql_datafusion].compactMap({ $0 }) {
                XCTAssertEqual(SQLPrinter().print(try SQLParser.parse(sql)), sql, golden.name)
            }
        }
    }

    /// Prettify writes the app's own notation; it must mean what was there.
    func testPrettifiedCalculusTranslatesToTheSameSQL() throws {
        let declarations = try ddl()
        for golden in try cases() {
            let pretty = try script(golden.input).prettyText(prelude: declarations)
            let reparsed = try CalcParser.parseScript(pretty, preferring: dialect(golden.dialect))
            XCTAssertEqual(try CalcToSQL.translate(reparsed).text, golden.sql,
                           "\(golden.name):\n\(pretty)")
        }
    }

    // MARK: - Reading what the app prints

    /// Every calculus formula the app prints for the basic samples must parse
    /// back and translate — in each of the three renderings it offers.
    func testTheAppsOwnCalculusReadsBack() throws {
        let basics = SampleQueries.basics.queries
        XCTAssertFalse(basics.isEmpty)
        for sample in basics {
            let bundle = AppViewModel.translate(try SQLParser.parseScript(sample.text))
            for translation in [bundle.trc, bundle.drc] {
                // Extensions (aggregates, ORDER BY) are outside what calculus
                // input accepts; everything exact must round-trip.
                guard translation.diagnostics.allSatisfy({ $0.fidelity == .exact }) else { continue }
                var simplified = translation
                simplified.root = translation.simplified
                for style in CalcRenderer.Style.allCases {
                    let text = CalcRenderer(style: style).inline(simplified)
                    let parsed = try CalcParser.parseScript(text, preferring: translation.dialect)
                    XCTAssertNoThrow(try CalcToSQL.translate(parsed),
                                     "\(sample.title), \(translation.dialect), \(style):\n\(text)")
                }
            }
        }
    }

    func testCalculusSamplesTranslateExceptTheUnsafeOne() throws {
        for sample in SampleQueries.trcGroups.flatMap(\.queries) + SampleQueries.drcGroups.flatMap(\.queries) {
            let parsed = try CalcParser.parseScript(sample.text,
                                                    preferring: sample.language.calculus ?? .trc)
            if sample.title.hasPrefix("Unsafe") {
                XCTAssertThrowsError(try AppViewModel.translate(calculus: parsed), sample.title)
            } else {
                let bundle = try AppViewModel.translate(calculus: parsed)
                XCTAssertNotNil(bundle.sql, sample.title)
            }
        }
    }

    // MARK: - Safety, dialects, schemas

    func testAnUnsafeFormulaHasNoSQL() throws {
        XCTAssertThrowsError(try CalcToSQL.translate(script("{ t | ¬Employee(t) }"))) { error in
            XCTAssertTrue((error as? TranslationError)?.message.contains("unsafe") == true, "\(error)")
        }
        XCTAssertThrowsError(try CalcToSQL.translate(script("{ ⟨x⟩ | x > 5 }", .drc)))
    }

    func testMixingTheTwoCalculiIsAnError() {
        XCTAssertThrowsError(try CalcParser.parseScript(
            "{ t.name | Employee(t) ∧ Department(d, n, l) }", preferring: .trc))
    }

    func testAFormulaThatReadsEitherWayFollowsTheEditor() throws {
        XCTAssertEqual(try CalcParser.parseScript("{ t | R(t) }", preferring: .trc).dialect, .trc)
        XCTAssertEqual(try CalcParser.parseScript("{ t | R(t) }", preferring: .drc).dialect, .drc)
    }

    func testUndeclaredColumnsArePlaceholdersAndSaySo() throws {
        let parsed = try CalcParser.parseScript("{ ⟨x⟩ | ∃y ( R(x, y) ) }", preferring: .drc)
        let generated = try CalcToSQL.translate(parsed)
        // R's tuple variable is r2: r would read as the relation's own name.
        XCTAssertTrue(generated.text.contains("r2.col1"), generated.text)
        XCTAssertTrue(generated.diagnostics.contains { $0.construct == "R" && $0.severity == .warning })
    }

    func testAnAtomOfTheWrongArityIsRefused() throws {
        XCTAssertThrowsError(try CalcToSQL.translate(script("{ ⟨n⟩ | ∃i ( Student(i, n, n) ) }", .drc)))
        XCTAssertThrowsError(try CalcToSQL.translate(script("{ ⟨n⟩ | Course(n) }", .drc)))
    }

    func testDeepCorrelationNeedsColumnsOnDataFusion() throws {
        let parsed = try CalcParser.parseScript(
            "{ s.name | S(s) ∧ ∀c ( C(c) → ∃e ( E(e) ∧ e.sid = s.sid ∧ e.cid = c.cid ) ) }",
            preferring: .trc)
        XCTAssertNoThrow(try CalcToSQL.translate(parsed, dialect: .duckdb))
        XCTAssertThrowsError(try CalcToSQL.translate(parsed, dialect: .datafusion))
    }

    func testStepsExplainTheQuantifiers() throws {
        let generated = try CalcToSQL.translate(script(
            "{ s.name | Student(s) ∧ ¬∃e ( Enrolled(e) ∧ e.sid = s.sid ) }"))
        XCTAssertEqual(generated.steps.map(\.title), ["¬∃ → NOT EXISTS", "Query"])
        XCTAssertEqual(generated.steps.last?.sql, generated.text)
    }
}
