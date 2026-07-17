//
//  RelationalAlgebraTests.swift
//  RelationalAlgebraTests
//
//  Unit tests for the lexer, parser and relational-algebra translator.
//

import XCTest
@testable import RelationalAlgebra

final class RelationalAlgebraTests: XCTestCase {

    // MARK: - Lexer

    func testLexerTokenizesBasicSelect() throws {
        let tokens = try Lexer("SELECT a FROM t").tokenize()
        // SELECT, a, FROM, t, EOF
        XCTAssertEqual(tokens.count, 5)
        XCTAssertEqual(tokens[0].kind, .keyword)
        XCTAssertEqual(tokens[0].text.uppercased(), "SELECT")
        XCTAssertEqual(tokens[1].kind, .identifier)
        XCTAssertEqual(tokens.last?.kind, .eof)
    }

    func testLexerHandlesStringsAndComments() throws {
        let tokens = try Lexer("SELECT 'hi' -- comment\nFROM t").tokenize()
        let strings = tokens.filter { $0.kind == .string }
        XCTAssertEqual(strings.count, 1)
        XCTAssertEqual(strings[0].text, "hi")
    }

    // MARK: - Parser

    func testParseSimpleSelect() throws {
        let query = try SQLParser.parse("SELECT name, salary FROM Employee WHERE salary > 50000")
        guard case let .select(stmt) = query else { return XCTFail("expected select") }
        XCTAssertEqual(stmt.projections.count, 2)
        XCTAssertEqual(stmt.from.count, 1)
        XCTAssertNotNil(stmt.whereClause)
    }

    func testParseJoin() throws {
        let sql = "SELECT * FROM A JOIN B ON A.id = B.a_id"
        let query = try SQLParser.parse(sql)
        guard case let .select(stmt) = query else { return XCTFail("expected select") }
        XCTAssertEqual(stmt.joins.count, 1)
        XCTAssertEqual(stmt.joins[0].kind, .inner)
        XCTAssertNotNil(stmt.joins[0].on)
    }

    func testParseGroupByHaving() throws {
        let sql = "SELECT dept, COUNT(*) FROM Emp GROUP BY dept HAVING COUNT(*) > 3"
        let query = try SQLParser.parse(sql)
        guard case let .select(stmt) = query else { return XCTFail("expected select") }
        XCTAssertEqual(stmt.groupBy.count, 1)
        XCTAssertNotNil(stmt.having)
    }

    func testParseUnion() throws {
        let query = try SQLParser.parse("SELECT a FROM x UNION SELECT a FROM y")
        guard case .setOperation(let op, _, _, let all) = query else {
            return XCTFail("expected set operation")
        }
        XCTAssertEqual(op, .union)
        XCTAssertFalse(all)
    }

    func testParseErrorOnMissingFrom() {
        XCTAssertThrowsError(try SQLParser.parse("SELECT a"))
    }

    func testEmptyQueryThrows() {
        XCTAssertThrowsError(try SQLParser.parse("   "))
    }

    // MARK: - Translator

    func testTranslateProducesSelectionAndProjection() throws {
        let query = try SQLParser.parse("SELECT name FROM Employee WHERE salary > 50000")
        let result = RATranslator().translate(query)
        let clauses = result.steps.map { $0.clause }
        XCTAssertTrue(clauses.contains("FROM"))
        XCTAssertTrue(clauses.contains("WHERE"))
        XCTAssertTrue(clauses.contains("SELECT"))
        // Final formula contains both σ and π glyphs.
        XCTAssertTrue(result.finalExpression.formula.contains(RASymbol.selection))
        XCTAssertTrue(result.finalExpression.formula.contains(RASymbol.projection))
    }

    func testSelectStarSkipsProjection() throws {
        let query = try SQLParser.parse("SELECT * FROM Employee")
        let result = RATranslator().translate(query)
        XCTAssertFalse(result.finalExpression.formula.contains(RASymbol.projection))
    }

    func testGroupByProducesGamma() throws {
        let query = try SQLParser.parse("SELECT dept, COUNT(*) FROM Emp GROUP BY dept")
        let result = RATranslator().translate(query)
        XCTAssertTrue(result.finalExpression.formula.contains(RASymbol.group))
    }

    func testDistinctProducesDelta() throws {
        let query = try SQLParser.parse("SELECT DISTINCT city FROM Customer")
        let result = RATranslator().translate(query)
        XCTAssertTrue(result.finalExpression.formula.contains(RASymbol.distinct))
    }

    func testJoinProducesJoinGlyph() throws {
        let query = try SQLParser.parse("SELECT * FROM A JOIN B ON A.id = B.a_id")
        let result = RATranslator().translate(query)
        XCTAssertTrue(result.finalExpression.formula.contains(RASymbol.join))
    }

    func testLeftJoinProducesOuterGlyph() throws {
        let query = try SQLParser.parse("SELECT * FROM A LEFT JOIN B ON A.id = B.a_id")
        let result = RATranslator().translate(query)
        XCTAssertTrue(result.finalExpression.formula.contains(RASymbol.leftJoin))
    }

    func testTreeHasRootAndLeaves() throws {
        let query = try SQLParser.parse("SELECT name FROM Employee WHERE salary > 50000")
        let result = RATranslator().translate(query)
        let tree = result.finalExpression.tree
        // Root should be projection, and there should be a leaf named Employee.
        XCTAssertEqual(tree.symbol, RASymbol.projection)
        XCTAssertTrue(containsLeaf(tree, named: "Employee"))
    }

    private func containsLeaf(_ node: RATreeNode, named name: String) -> Bool {
        if node.isLeaf && node.symbol == name { return true }
        return node.children.contains { containsLeaf($0, named: name) }
    }
}
