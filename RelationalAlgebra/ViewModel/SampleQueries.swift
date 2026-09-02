//
//  SampleQueries.swift
//  RelationalAlgebra
//
//  Bundled examples so the app is useful the moment it launches and so users
//  have working templates to learn from.
//

import Foundation

struct SampleQuery: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let sql: String
}

enum SampleQueries {
    static let all: [SampleQuery] = [
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
    ]
}
