//
//  SyntaxHighlighterTests.swift
//  RelationalAlgebraTests
//
//  What the editor colours each word as, in each input language.
//

import XCTest
@testable import RelationalAlgebra

final class SyntaxHighlighterTests: XCTestCase {

    /// The class of the `occurrence`-th appearance of `word` (1-based).
    private func kind(_ word: String, in text: String, _ language: InputLanguage,
                      occurrence: Int = 1) -> SyntaxClass? {
        let matches = SyntaxHighlighter.classes(in: text, language: language).filter { $0.0 == word }
        return matches.count >= occurrence ? matches[occurrence - 1].1 : nil
    }

    // MARK: - SQL

    func testSQLTellsTablesFromColumnsAndKeywords() {
        let sql = """
            SELECT e.name, COUNT(*) AS n
            FROM Employee e JOIN Department d ON e.dept_id = d.id
            WHERE d.location = 'Berlin' -- Berlin only
            """
        XCTAssertEqual(kind("SELECT", in: sql, .sql), .keyword)
        XCTAssertEqual(kind("COUNT", in: sql, .sql), .keyword)
        XCTAssertEqual(kind("Employee", in: sql, .sql), .relation)
        XCTAssertEqual(kind("Department", in: sql, .sql), .relation)
        XCTAssertEqual(kind("e", in: sql, .sql), .relation)          // an alias
        XCTAssertEqual(kind("name", in: sql, .sql), .column)
        XCTAssertEqual(kind("location", in: sql, .sql), .column)
        XCTAssertEqual(kind("n", in: sql, .sql), .column)            // a column alias, not a table
        XCTAssertEqual(kind("=", in: sql, .sql), .symbol)
        XCTAssertEqual(kind("'Berlin'", in: sql, .sql), .string)
        XCTAssertEqual(kind("-- Berlin only", in: sql, .sql), .comment)
    }

    func testCreateTableColumnsAreColumnsAndTypesAreKeywords() {
        let sql = "CREATE TABLE Employee (id INT, name VARCHAR(20));\nSELECT name FROM Employee"
        XCTAssertEqual(kind("Employee", in: sql, .sql), .relation)
        XCTAssertEqual(kind("id", in: sql, .sql), .column)
        XCTAssertEqual(kind("name", in: sql, .sql), .column)
        XCTAssertEqual(kind("INT", in: sql, .sql), .keyword)
        XCTAssertEqual(kind("VARCHAR", in: sql, .sql), .keyword)
        XCTAssertEqual(kind("20", in: sql, .sql), .number)
    }

    // MARK: - Relational algebra

    func testAlgebraOperandsAreRelationsAndSubscriptsHoldColumns() {
        let ra = "π[e.name, salary → pay](σ[salary > 50000 AND dept_id = 1](ρ[e](Employee)))"
        XCTAssertEqual(kind("π", in: ra, .ra), .symbol)
        XCTAssertEqual(kind("σ", in: ra, .ra), .symbol)
        XCTAssertEqual(kind("ρ", in: ra, .ra), .symbol)
        XCTAssertEqual(kind("→", in: ra, .ra), .symbol)
        XCTAssertEqual(kind("e", in: ra, .ra), .relation)                  // qualifier
        XCTAssertEqual(kind("e", in: ra, .ra, occurrence: 2), .relation)   // ρ's new name
        XCTAssertEqual(kind("name", in: ra, .ra), .column)
        XCTAssertEqual(kind("pay", in: ra, .ra), .column)
        XCTAssertEqual(kind("AND", in: ra, .ra), .keyword)
        XCTAssertEqual(kind("50000", in: ra, .ra), .number)
        XCTAssertEqual(kind("Employee", in: ra, .ra), .relation)
    }

    func testAlgebraWordsForGlyphsAreOperators() {
        let ra = "pi[name](sigma[a > 1](R) join S)"
        XCTAssertEqual(kind("pi", in: ra, .ra), .symbol)
        XCTAssertEqual(kind("sigma", in: ra, .ra), .symbol)
        XCTAssertEqual(kind("join", in: ra, .ra), .symbol)
        XCTAssertEqual(kind("R", in: ra, .ra), .relation)
        XCTAssertEqual(kind("name", in: ra, .ra), .column)
    }

    func testDeclarationsAboveAlgebraReadAsSQL() {
        let ra = "CREATE TABLE R (a INT);\nπ[a](R)"
        XCTAssertEqual(kind("CREATE", in: ra, .ra), .keyword)
        XCTAssertEqual(kind("INT", in: ra, .ra), .keyword)
        XCTAssertEqual(kind("a", in: ra, .ra), .column)
        XCTAssertEqual(kind("R", in: ra, .ra, occurrence: 2), .relation)
    }

    // MARK: - Calculus

    func testTupleCalculusVariablesRelationsAndAttributes() {
        let trc = "{ e.name | Employee(e) ∧ ∃d ( Department(d) ∧ d.id = e.dept_id ) }"
        XCTAssertEqual(kind("e", in: trc, .trc), .variable)
        XCTAssertEqual(kind("d", in: trc, .trc), .variable)          // bound by ∃, before a bracket
        XCTAssertEqual(kind("name", in: trc, .trc), .column)
        XCTAssertEqual(kind("Employee", in: trc, .trc), .relation)
        XCTAssertEqual(kind("Department", in: trc, .trc), .relation)
        XCTAssertEqual(kind("∃", in: trc, .trc), .symbol)
        XCTAssertEqual(kind("∧", in: trc, .trc), .symbol)
        XCTAssertEqual(kind("{", in: trc, .trc), .symbol)
    }

    func testDomainCalculusAggregatesAndAnnotations() {
        let drc = "sort by h ↓  applied to { ⟨n, h⟩ | ∃i ( Employee(i, n, …) ) ∧ h = COUNT{ x | R(x) } }"
        XCTAssertEqual(kind("sort", in: drc, .drc), .keyword)
        XCTAssertEqual(kind("↓", in: drc, .drc), .symbol)
        XCTAssertEqual(kind("n", in: drc, .drc), .variable)
        XCTAssertEqual(kind("i", in: drc, .drc), .variable)
        XCTAssertEqual(kind("Employee", in: drc, .drc), .relation)
        XCTAssertEqual(kind("COUNT", in: drc, .drc), .keyword)
        XCTAssertEqual(kind("R", in: drc, .drc), .relation)
        XCTAssertEqual(kind("…", in: drc, .drc), .symbol)
    }

    func testCalculusWordsAndRangesRead() {
        let trc = "{ e.name | e in Employee and exists d in Department ( d.id = e.dept_id ) }"
        XCTAssertEqual(kind("in", in: trc, .trc), .symbol)
        XCTAssertEqual(kind("and", in: trc, .trc), .symbol)
        XCTAssertEqual(kind("exists", in: trc, .trc), .symbol)
        XCTAssertEqual(kind("Employee", in: trc, .trc), .relation)
        XCTAssertEqual(kind("Department", in: trc, .trc), .relation)
        XCTAssertEqual(kind("d", in: trc, .trc), .variable)
    }

    // MARK: - Robustness

    /// Mid-edit text never parses; the highlighter must still return
    /// something sensible rather than give up.
    func testHalfTypedTextStillHighlights() {
        XCTAssertEqual(kind("SELECT", in: "SELECT 'unterminated", .sql), .keyword)
        XCTAssertEqual(kind("'unterminated", in: "SELECT 'unterminated", .sql), .string)
        XCTAssertEqual(kind("σ", in: "σ[salary >", .ra), .symbol)
        XCTAssertFalse(SyntaxHighlighter.classes(in: "{ ⟨n | ∃", language: .drc).isEmpty)
        XCTAssertTrue(SyntaxHighlighter.classes(in: "", language: .trc).isEmpty)
    }

    func testErrorRangeCoversTheWordAtTheOffset() {
        let text = "SELECT nme FROM t"
        let range = SyntaxHighlighter.errorRange(in: text, at: 7)
        XCTAssertEqual(range.map { String(text[$0]) }, "nme")
        let end = SyntaxHighlighter.errorRange(in: "SELECT a FROM ", at: 14)
        XCTAssertEqual(end.map { String("SELECT a FROM "[$0]) }, "M")
    }
}
