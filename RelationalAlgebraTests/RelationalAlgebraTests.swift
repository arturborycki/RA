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

    func testParseSubstringFromFor() throws {
        // SUBSTRING(col FROM 1 FOR 2) — the FROM/FOR argument syntax.
        let query = try SQLParser.parse(
            "SELECT SUBSTRING(c_phone FROM 1 FOR 2) AS cc FROM customer")
        guard case let .select(stmt) = query else { return XCTFail("expected select") }
        guard case let .expression(expr, alias) = stmt.projections[0] else {
            return XCTFail("expected expression projection")
        }
        XCTAssertEqual(alias, "cc")
        guard case let .function(name, args, _) = expr else {
            return XCTFail("expected function")
        }
        XCTAssertEqual(name, "SUBSTRING")
        XCTAssertEqual(args.count, 3)
    }

    func testParseExists() throws {
        let query = try SQLParser.parse(
            "SELECT * FROM customer WHERE EXISTS (SELECT * FROM orders WHERE o_custkey = c_custkey)")
        guard case let .select(stmt) = query else { return XCTFail("expected select") }
        XCTAssertNotNil(stmt.whereClause)
    }

    func testParseNotExists() throws {
        let query = try SQLParser.parse(
            "SELECT * FROM customer WHERE NOT EXISTS (SELECT * FROM orders WHERE o_custkey = c_custkey)")
        let result = RATranslator().translate(query)
        XCTAssertTrue(result.finalExpression.formula.contains("EXISTS"))
    }

    func testParseScalarSubqueryComparison() throws {
        let query = try SQLParser.parse(
            "SELECT c_acctbal FROM customer WHERE c_acctbal > (SELECT AVG(c_acctbal) FROM customer)")
        guard case .select = query else { return XCTFail("expected select") }
    }

    func testParseTpchQ22LikeQuery() throws {
        // TPC-H Q22: derived table + SUBSTRING(FROM/FOR) + scalar subquery +
        // NOT EXISTS + GROUP BY / ORDER BY. Should parse and translate cleanly.
        let sql = """
        select cntrycode, count(*) as numcust, sum(c_acctbal) as totacctbal
        from (
            select substring(c_phone from 1 for 2) as cntrycode, c_acctbal
            from customer
            where substring(c_phone from 1 for 2) in ('13', '31', '23')
              and c_acctbal > (
                  select avg(c_acctbal) from customer
                  where c_acctbal > 0.00
                    and substring(c_phone from 1 for 2) in ('13', '31', '23')
              )
              and not exists (
                  select * from orders where o_custkey = c_custkey
              )
        ) as custsale
        group by cntrycode
        order by cntrycode;
        """
        let query = try SQLParser.parse(sql)
        let result = RATranslator().translate(query)
        XCTAssertFalse(result.steps.isEmpty)
        // Outer query groups and aggregates.
        XCTAssertTrue(result.finalExpression.formula.contains(RASymbol.group))
    }

    // MARK: - Advanced SQL (TPC-H / TPC-DS constructs)

    func testParseCaseExpression() throws {
        let query = try SQLParser.parse("""
        SELECT
            SUM(CASE WHEN l_returnflag = 'R' THEN l_extendedprice ELSE 0 END) AS refunds
        FROM lineitem
        """)
        let result = RATranslator().translate(query)
        XCTAssertTrue(result.finalExpression.formula.contains(RASymbol.group))
    }

    func testParseCast() throws {
        let query = try SQLParser.parse(
            "SELECT CAST(l_quantity AS decimal(15, 2)) AS q FROM lineitem")
        guard case .select = query else { return XCTFail("expected select") }
    }

    func testParseDateAndInterval() throws {
        let query = try SQLParser.parse(
            "SELECT * FROM lineitem WHERE l_shipdate <= DATE '1998-12-01' - INTERVAL '90' DAY")
        guard case let .select(stmt) = query else { return XCTFail("expected select") }
        XCTAssertNotNil(stmt.whereClause)
    }

    func testParseWindowFunction() throws {
        let query = try SQLParser.parse("""
        SELECT ss_item_sk,
               RANK() OVER (PARTITION BY ss_store_sk ORDER BY SUM(ss_net_profit) DESC) AS rnk
        FROM store_sales
        GROUP BY ss_item_sk, ss_store_sk
        """)
        let result = RATranslator().translate(query)
        XCTAssertTrue(result.finalExpression.formula.contains("OVER"))
    }

    func testParseWithCTE() throws {
        let query = try SQLParser.parse("""
        WITH revenue AS (
            SELECT l_suppkey AS supplier_no, SUM(l_extendedprice) AS total
            FROM lineitem
            GROUP BY l_suppkey
        )
        SELECT s_name, total
        FROM supplier, revenue
        WHERE s_suppkey = supplier_no
        ORDER BY total DESC
        """)
        guard case let .with(ctes, _) = query else { return XCTFail("expected WITH") }
        XCTAssertEqual(ctes.count, 1)
        XCTAssertEqual(ctes[0].name, "revenue")
        let result = RATranslator().translate(query)
        XCTAssertFalse(result.steps.isEmpty)
    }

    func testParseGroupByRollup() throws {
        let query = try SQLParser.parse(
            "SELECT d_year, SUM(ss_net_profit) FROM store_sales GROUP BY ROLLUP(d_year)")
        let result = RATranslator().translate(query)
        XCTAssertTrue(result.finalExpression.formula.contains("ROLLUP"))
    }

    func testTpchQ1() throws {
        // TPC-H Q1: aggregation with CASE-free arithmetic aggregates.
        let query = try SQLParser.parse("""
        select
            l_returnflag, l_linestatus,
            sum(l_quantity) as sum_qty,
            sum(l_extendedprice * (1 - l_discount)) as sum_disc_price,
            sum(l_extendedprice * (1 - l_discount) * (1 + l_tax)) as sum_charge,
            avg(l_quantity) as avg_qty,
            count(*) as count_order
        from lineitem
        where l_shipdate <= date '1998-12-01' - interval '90' day
        group by l_returnflag, l_linestatus
        order by l_returnflag, l_linestatus
        """)
        let result = RATranslator().translate(query)
        XCTAssertTrue(result.finalExpression.formula.contains(RASymbol.group))
        XCTAssertTrue(result.finalExpression.formula.contains(RASymbol.sort))
    }

    func testFetchFirst() throws {
        let query = try SQLParser.parse(
            "SELECT * FROM item ORDER BY i_item_sk FETCH FIRST 100 ROWS ONLY")
        guard case let .select(stmt) = query else { return XCTFail("expected select") }
        XCTAssertEqual(stmt.limit, 100)
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
