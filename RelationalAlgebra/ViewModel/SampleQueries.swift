//
//  SampleQueries.swift
//  RelationalAlgebra
//
//  Bundled examples so the app is useful the moment it launches and so users
//  have working templates to learn from.
//
//  The benchmark groups matter for a reason beyond realism: TPC-H's correlated
//  `EXISTS` / `NOT EXISTS` queries are exactly where the calculus says something
//  the algebra cannot, and its aggregate queries are where the extension
//  notation earns its keep. Each TPC-H sample carries the `CREATE TABLE`
//  declarations for the tables it touches, so the domain calculus comes out
//  exact rather than marked incomplete.
//

import Foundation

struct SampleQuery: Identifiable, Hashable {
    let id = UUID()
    let title: String
    /// Table declarations to load above the query, so a domain-calculus atom
    /// has a real arity and column order to work from. Declared before `sql`
    /// so the memberwise initialiser reads in the order the editor shows them.
    var schema: String? = nil
    /// The query text, written in `language` — SQL for most samples, but
    /// relational algebra for the ones that show translation into SQL.
    let sql: String
    var language: InputLanguage = .sql

    /// What actually goes into the editor.
    var text: String {
        guard let schema else { return sql }
        return schema + "\n\n" + sql
    }
}

/// A named set of examples. The menu nests these, because a flat list of thirty
/// queries is a list nobody reads.
struct SampleGroup: Identifiable, Hashable {
    let id = UUID()
    let title: String
    /// One line on what the group is for, shown under the menu section.
    let note: String
    let queries: [SampleQuery]
}

enum SampleQueries {

    // Explicitly typed, and declared after the groups they name: a static
    // property whose type must be inferred while another static property is
    // being type-checked is how "circular reference" happens.
    static let groups: [SampleGroup] = [basics, tpch, tpcds]

    /// Every bundled query, flattened — what the test suite runs over.
    static let all: [SampleQuery] = groups.flatMap(\.queries)

    /// The examples offered when the editor holds relational algebra.
    static let raGroups: [SampleGroup] = [raBasics]

    static let trcGroups: [SampleGroup] = [trcBasics]
    static let drcGroups: [SampleGroup] = [drcBasics]

    static func groups(for language: InputLanguage) -> [SampleGroup] {
        switch language {
        case .sql: return groups
        case .ra:  return raGroups
        case .trc: return trcGroups
        case .drc: return drcGroups
        }
    }

    // MARK: - Calculus in, SQL out

    static let trcBasics: SampleGroup = SampleGroup(
        title: "Tuple calculus → SQL",
        note: "Type a set-builder expression; read the SQL it means.",
        queries: [
            SampleQuery(
                title: "Select + project",
                schema: companySchema,
                sql: "{ e.name, e.salary | Employee(e) ∧ e.salary > 50000 }",
                language: .trc),

            SampleQuery(
                title: "Typed with words",
                schema: companySchema,
                sql: "{ e.name | e in Employee and exists d in Department " +
                     "( d.id = e.dept_id and d.location = 'Berlin' ) }",
                language: .trc),

            SampleQuery(
                title: "∃ becomes EXISTS",
                schema: companySchema,
                sql: """
                { e.name | Employee(e) ∧
                    ∃d ( Department(d) ∧ d.id = e.dept_id ∧ d.location = 'Berlin' ) }
                """,
                language: .trc),

            SampleQuery(
                title: "¬∃: never enrolled",
                schema: universitySchema,
                sql: "{ s.name | Student(s) ∧ ¬∃e ( Enrolled(e) ∧ e.sid = s.sid ) }",
                language: .trc),

            SampleQuery(
                title: "∀: enrolled in every course",
                schema: universitySchema,
                sql: """
                { s.name | Student(s) ∧
                    ∀c ( Course(c) → ∃e ( Enrolled(e) ∧ e.sid = s.sid ∧ e.cid = c.cid ) ) }
                """,
                language: .trc),

            SampleQuery(
                title: "∨ over two relations: UNION",
                schema: universitySchema + "\n" + companySchema,
                sql: "{ t.name | (Employee(t) ∧ t.salary > 65000) ∨ Student(t) }",
                language: .trc),

            SampleQuery(
                title: "Unsafe: no SQL",
                schema: companySchema,
                sql: "{ t | ¬Employee(t) }",
                language: .trc),
        ])

    static let drcBasics: SampleGroup = SampleGroup(
        title: "Domain calculus → SQL",
        note: "Positional atoms need the tables' columns: each sample declares them.",
        queries: [
            SampleQuery(
                title: "Select + project",
                schema: companySchema,
                sql: "{ ⟨n, s⟩ | ∃i, d ( Employee(i, n, s, d) ∧ s > 50000 ) }",
                language: .drc),

            SampleQuery(
                title: "Join by a shared variable",
                schema: companySchema,
                sql: "{ ⟨n⟩ | ∃i, s, d, dn ( Employee(i, n, s, d) ∧ Department(d, dn, 'Berlin') ) }",
                language: .drc),

            SampleQuery(
                title: "Unnamed columns: …",
                schema: companySchema,
                sql: "{ ⟨n⟩ | ∃i ( Employee(i, n, …) ∧ i < 3 ) }",
                language: .drc),

            SampleQuery(
                title: "∀: enrolled in every course",
                schema: universitySchema,
                sql: "{ ⟨n⟩ | ∃s ( Student(s, n) ∧ ∀c, t ( Course(c, t) → Enrolled(s, c) ) ) }",
                language: .drc),

            SampleQuery(
                title: "Typed with words",
                schema: companySchema,
                sql: "{ <n> | EXISTS i, s, d ( Employee(i, n, s, d) AND s > 50000 AND d = 1 ) }",
                language: .drc),
        ])

    // MARK: - Relational algebra in, SQL out

    static let universitySchema: String = """
        CREATE TABLE Student (sid INT, name VARCHAR);
        CREATE TABLE Course (cid INT, title VARCHAR);
        CREATE TABLE Enrolled (sid INT, cid INT);
        """

    static let companySchema: String = """
        CREATE TABLE Employee (id INT, name VARCHAR, salary INT, dept_id INT);
        CREATE TABLE Department (id INT, name VARCHAR, location VARCHAR);
        """

    static let raBasics: SampleGroup = SampleGroup(
        title: "Algebra → SQL",
        note: "Type relational algebra; read the SQL it means.",
        queries: [
            SampleQuery(
                title: "Select + project",
                schema: companySchema,
                sql: "π[name, salary] ( σ[salary > 50000] ( Employee ) )",
                language: .ra),

            SampleQuery(
                title: "Typed with words",
                schema: companySchema,
                sql: "pi[name] ( sigma[salary > 50000 and dept_id = 1] ( Employee ) )",
                language: .ra),

            SampleQuery(
                title: "Theta join with renames",
                schema: companySchema,
                sql: """
                π[e.name, d.name → department] (
                    ρ[e](Employee) ⋈[e.dept_id = d.id] σ[d.location = 'Berlin'](ρ[d](Department))
                )
                """,
                language: .ra),

            SampleQuery(
                title: "Product, then select",
                schema: universitySchema,
                sql: """
                π[Student.name] (
                    σ[Student.sid = Enrolled.sid ∧ Enrolled.cid = 10] ( Student × Enrolled )
                )
                """,
                language: .ra),

            SampleQuery(
                title: "Natural join",
                schema: universitySchema,
                sql: "π[name, title] ( Student ⋈ Enrolled ⋈ Course )",
                language: .ra),

            SampleQuery(
                title: "Difference: never enrolled",
                schema: universitySchema,
                sql: "π[name] ( Student ⋈ ( π[sid](Student) − π[sid](Enrolled) ) )",
                language: .ra),

            SampleQuery(
                title: "Union",
                schema: companySchema,
                sql: "π[name](σ[dept_id = 1](Employee)) ∪ π[name](σ[salary > 65000](Employee))",
                language: .ra),

            SampleQuery(
                title: "Self-join via ρ",
                schema: universitySchema,
                sql: """
                π[s1, s2] (
                    σ[s1 < s2] ( ρ[A(s1, c1)](Enrolled) ⋈[c1 = c2] ρ[B(s2, c2)](Enrolled) )
                )
                """,
                language: .ra),

            SampleQuery(
                title: "Left outer join",
                schema: companySchema,
                sql: "π[Employee.name, location] ( Employee ⟕[dept_id = Department.id] Department )",
                language: .ra),

            SampleQuery(
                title: "Division: enrolled in every course",
                schema: universitySchema,
                sql: "π[name] ( Student ⋈ ( Enrolled ÷ π[cid](Course) ) )",
                language: .ra),

            SampleQuery(
                title: "Grouping γ",
                schema: companySchema,
                sql: "σ[n > 1] ( γ[dept_id; COUNT(*) → n, AVG(salary) → pay] ( Employee ) )",
                language: .ra),

            SampleQuery(
                title: "Sort τ and LIMIT",
                schema: companySchema,
                sql: "LIMIT[2] ( τ[salary ↓] ( π[name, salary] ( Employee ) ) )",
                language: .ra),
        ])

    // MARK: - Basics

    static let basics: SampleGroup = SampleGroup(
        title: "Basics",
        note: "One construct at a time.",
        queries: [
            SampleQuery(
                title: "Filter + project",
                sql: """
                SELECT name, salary
                FROM Employee
                WHERE salary > 50000;
                """),

            SampleQuery(
                title: "Inner join",
                sql: """
                SELECT e.name, d.name AS department
                FROM Employee e
                JOIN Department d ON e.dept_id = d.id
                WHERE d.location = 'Berlin';
                """),

            SampleQuery(
                title: "Group + aggregate",
                sql: """
                SELECT dept_id, COUNT(*) AS headcount, AVG(salary) AS avg_salary
                FROM Employee
                GROUP BY dept_id
                HAVING COUNT(*) > 5
                ORDER BY avg_salary DESC;
                """),

            SampleQuery(
                title: "Distinct + IN",
                sql: """
                SELECT DISTINCT city
                FROM Customer
                WHERE country IN ('DE', 'FR', 'NL');
                """),

            SampleQuery(
                title: "Left join + BETWEEN",
                sql: """
                SELECT c.name, o.total
                FROM Customer c
                LEFT JOIN Orders o ON o.customer_id = c.id
                WHERE o.total BETWEEN 100 AND 500;
                """),

            SampleQuery(
                title: "Division (NOT EXISTS)",
                sql: """
                SELECT s.name
                FROM Student s
                WHERE NOT EXISTS (
                  SELECT c.id FROM Course c
                  WHERE NOT EXISTS (
                    SELECT e.sid FROM Enrolled e
                    WHERE e.sid = s.id AND e.cid = c.id));
                """),

            SampleQuery(
                title: "Sub-query (IN)",
                sql: """
                SELECT c.name
                FROM Customer c
                WHERE c.id IN (SELECT o.customer_id FROM Orders o WHERE o.total > 1000);
                """),

            SampleQuery(
                title: "Set operation (UNION)",
                sql: """
                SELECT name FROM Author
                UNION
                SELECT name FROM Editor;
                """),
        ])

    // MARK: - TPC-H

    static let tpch: SampleGroup = SampleGroup(
        title: "TPC-H",
        note: "A selection of the 22 decision-support queries, with their schema.",
        queries: [
            SampleQuery(
                title: "Q1 — Pricing summary report",
                schema: TPCHSchema.declarations(for: ["lineitem"]),
                sql: """
                SELECT l_returnflag, l_linestatus,
                       SUM(l_quantity) AS sum_qty,
                       SUM(l_extendedprice) AS sum_base_price,
                       SUM(l_extendedprice * (1 - l_discount)) AS sum_disc_price,
                       SUM(l_extendedprice * (1 - l_discount) * (1 + l_tax)) AS sum_charge,
                       AVG(l_quantity) AS avg_qty,
                       AVG(l_extendedprice) AS avg_price,
                       AVG(l_discount) AS avg_disc,
                       COUNT(*) AS count_order
                FROM lineitem
                WHERE l_shipdate <= DATE '1998-12-01' - INTERVAL '90' DAY
                GROUP BY l_returnflag, l_linestatus
                ORDER BY l_returnflag, l_linestatus;
                """),

            SampleQuery(
                title: "Q3 — Shipping priority",
                schema: TPCHSchema.declarations(for: ["customer", "orders", "lineitem"]),
                sql: """
                SELECT l_orderkey,
                       SUM(l_extendedprice * (1 - l_discount)) AS revenue,
                       o_orderdate,
                       o_shippriority
                FROM customer, orders, lineitem
                WHERE c_mktsegment = 'BUILDING'
                  AND c_custkey = o_custkey
                  AND l_orderkey = o_orderkey
                  AND o_orderdate < DATE '1995-03-15'
                  AND l_shipdate > DATE '1995-03-15'
                GROUP BY l_orderkey, o_orderdate, o_shippriority
                ORDER BY revenue DESC, o_orderdate
                LIMIT 10;
                """),

            SampleQuery(
                title: "Q4 — Order priority checking (EXISTS)",
                schema: TPCHSchema.declarations(for: ["orders", "lineitem"]),
                sql: """
                SELECT o_orderpriority, COUNT(*) AS order_count
                FROM orders
                WHERE o_orderdate >= DATE '1993-07-01'
                  AND o_orderdate < DATE '1993-10-01'
                  AND EXISTS (
                    SELECT l_orderkey FROM lineitem
                    WHERE l_orderkey = o_orderkey
                      AND l_commitdate < l_receiptdate)
                GROUP BY o_orderpriority
                ORDER BY o_orderpriority;
                """),

            SampleQuery(
                title: "Q6 — Forecasting revenue change",
                schema: TPCHSchema.declarations(for: ["lineitem"]),
                sql: """
                SELECT SUM(l_extendedprice * l_discount) AS revenue
                FROM lineitem
                WHERE l_shipdate >= DATE '1994-01-01'
                  AND l_shipdate < DATE '1994-01-01' + INTERVAL '1' YEAR
                  AND l_discount BETWEEN 0.06 - 0.01 AND 0.06 + 0.01
                  AND l_quantity < 24;
                """),

            SampleQuery(
                title: "Q16 — Parts/supplier relationship (NOT IN)",
                schema: TPCHSchema.declarations(for: ["partsupp", "part", "supplier"]),
                sql: """
                SELECT p_brand, p_type, p_size, COUNT(DISTINCT ps_suppkey) AS supplier_cnt
                FROM partsupp, part
                WHERE p_partkey = ps_partkey
                  AND p_brand <> 'Brand#45'
                  AND p_type NOT LIKE 'MEDIUM POLISHED%'
                  AND p_size IN (49, 14, 23, 45, 19, 3, 36, 9)
                  AND ps_suppkey NOT IN (
                    SELECT s_suppkey FROM supplier
                    WHERE s_comment LIKE '%Customer%Complaints%')
                GROUP BY p_brand, p_type, p_size
                ORDER BY supplier_cnt DESC, p_brand, p_type, p_size;
                """),

            SampleQuery(
                title: "Q17 — Small-quantity-order revenue",
                schema: TPCHSchema.declarations(for: ["lineitem", "part"]),
                sql: """
                SELECT SUM(l_extendedprice) / 7.0 AS avg_yearly
                FROM lineitem, part
                WHERE p_partkey = l_partkey
                  AND p_brand = 'Brand#23'
                  AND p_container = 'MED BOX'
                  AND l_quantity < (
                    SELECT 0.2 * AVG(l_quantity) FROM lineitem WHERE l_partkey = p_partkey);
                """),

            SampleQuery(
                title: "Q18 — Large volume customer",
                schema: TPCHSchema.declarations(for: ["customer", "orders", "lineitem"]),
                sql: """
                SELECT c_name, c_custkey, o_orderkey, o_orderdate, o_totalprice,
                       SUM(l_quantity) AS total_quantity
                FROM customer, orders, lineitem
                WHERE o_orderkey IN (
                    SELECT l_orderkey FROM lineitem
                    GROUP BY l_orderkey HAVING SUM(l_quantity) > 300)
                  AND c_custkey = o_custkey
                  AND o_orderkey = l_orderkey
                GROUP BY c_name, c_custkey, o_orderkey, o_orderdate, o_totalprice
                ORDER BY o_totalprice DESC, o_orderdate
                LIMIT 100;
                """),

            SampleQuery(
                title: "Q21 — Suppliers who kept orders waiting",
                schema: TPCHSchema.declarations(for: ["supplier", "lineitem", "orders", "nation"]),
                sql: """
                SELECT s_name, COUNT(*) AS numwait
                FROM supplier, lineitem l1, orders, nation
                WHERE s_suppkey = l1.l_suppkey
                  AND o_orderkey = l1.l_orderkey
                  AND o_orderstatus = 'F'
                  AND l1.l_receiptdate > l1.l_commitdate
                  AND EXISTS (
                    SELECT l2.l_orderkey FROM lineitem l2
                    WHERE l2.l_orderkey = l1.l_orderkey
                      AND l2.l_suppkey <> l1.l_suppkey)
                  AND NOT EXISTS (
                    SELECT l3.l_orderkey FROM lineitem l3
                    WHERE l3.l_orderkey = l1.l_orderkey
                      AND l3.l_suppkey <> l1.l_suppkey
                      AND l3.l_receiptdate > l3.l_commitdate)
                  AND s_nationkey = n_nationkey
                  AND n_name = 'SAUDI ARABIA'
                GROUP BY s_name
                ORDER BY numwait DESC, s_name
                LIMIT 100;
                """),
        ])

    // MARK: - TPC-DS

    static let tpcds: SampleGroup = SampleGroup(
        title: "TPC-DS",
        note: "A few of the 99 queries. No schema is bundled, so the domain " +
              "atoms are marked incomplete — declare the tables to fix that.",
        queries: [
            SampleQuery(
                title: "Q3 — Brand sales in a month",
                sql: """
                SELECT dt.d_year, item.i_brand_id AS brand_id, item.i_brand AS brand,
                       SUM(ss_ext_sales_price) AS sum_agg
                FROM date_dim dt, store_sales, item
                WHERE dt.d_date_sk = store_sales.ss_sold_date_sk
                  AND store_sales.ss_item_sk = item.i_item_sk
                  AND item.i_manufact_id = 128
                  AND dt.d_moy = 11
                GROUP BY dt.d_year, item.i_brand, item.i_brand_id
                ORDER BY dt.d_year, sum_agg DESC, brand_id
                LIMIT 100;
                """),

            SampleQuery(
                title: "Q1 — Customers with high store returns (CTE)",
                sql: """
                WITH customer_total_return AS (
                  SELECT sr_customer_sk AS ctr_customer_sk,
                         sr_store_sk AS ctr_store_sk,
                         SUM(sr_return_amt) AS ctr_total_return
                  FROM store_returns, date_dim
                  WHERE sr_returned_date_sk = d_date_sk AND d_year = 2000
                  GROUP BY sr_customer_sk, sr_store_sk)
                SELECT c_customer_id
                FROM customer_total_return ctr1, store, customer
                WHERE ctr1.ctr_total_return > (
                    SELECT AVG(ctr_total_return) * 1.2 FROM customer_total_return ctr2
                    WHERE ctr1.ctr_store_sk = ctr2.ctr_store_sk)
                  AND s_store_sk = ctr1.ctr_store_sk
                  AND s_state = 'TN'
                  AND ctr1.ctr_customer_sk = c_customer_sk
                ORDER BY c_customer_id
                LIMIT 100;
                """),

            SampleQuery(
                title: "Q6 — States with above-average purchases",
                sql: """
                SELECT a.ca_state AS state, COUNT(*) AS cnt
                FROM customer_address a, customer c, store_sales s, date_dim d, item i
                WHERE a.ca_address_sk = c.c_current_addr_sk
                  AND c.c_customer_sk = s.ss_customer_sk
                  AND s.ss_sold_date_sk = d.d_date_sk
                  AND s.ss_item_sk = i.i_item_sk
                  AND d.d_month_seq = (
                    SELECT DISTINCT d_month_seq FROM date_dim
                    WHERE d_year = 2001 AND d_moy = 1)
                  AND i.i_current_price > 1.2 * (
                    SELECT AVG(j.i_current_price) FROM item j WHERE j.i_category = i.i_category)
                GROUP BY a.ca_state
                HAVING COUNT(*) >= 10
                ORDER BY cnt, a.ca_state
                LIMIT 100;
                """),
        ])
}

/// The TPC-H tables, so the domain calculus has real arities to work with.
/// Only column names and their order matter here — types are irrelevant to the
/// translation, and are given only so the declarations read as real SQL.
enum TPCHSchema {

    static func declarations(for tables: [String]) -> String {
        tables.compactMap { name in
            columns[name].map { "CREATE TABLE \(name) (" + $0.joined(separator: ", ") + ");" }
        }.joined(separator: "\n")
    }

    static let columns: [String: [String]] = [
        "region": ["r_regionkey", "r_name", "r_comment"],
        "nation": ["n_nationkey", "n_name", "n_regionkey", "n_comment"],
        "supplier": ["s_suppkey", "s_name", "s_address", "s_nationkey",
                     "s_phone", "s_acctbal", "s_comment"],
        "customer": ["c_custkey", "c_name", "c_address", "c_nationkey", "c_phone",
                     "c_acctbal", "c_mktsegment", "c_comment"],
        "part": ["p_partkey", "p_name", "p_mfgr", "p_brand", "p_type", "p_size",
                 "p_container", "p_retailprice", "p_comment"],
        "partsupp": ["ps_partkey", "ps_suppkey", "ps_availqty", "ps_supplycost", "ps_comment"],
        "orders": ["o_orderkey", "o_custkey", "o_orderstatus", "o_totalprice", "o_orderdate",
                   "o_orderpriority", "o_clerk", "o_shippriority", "o_comment"],
        "lineitem": ["l_orderkey", "l_partkey", "l_suppkey", "l_linenumber", "l_quantity",
                     "l_extendedprice", "l_discount", "l_tax", "l_returnflag", "l_linestatus",
                     "l_shipdate", "l_commitdate", "l_receiptdate", "l_shipinstruct",
                     "l_shipmode", "l_comment"]
    ]
}
