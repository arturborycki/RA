# RA — SQL → Relational Algebra for iPadOS

A native **iPadOS** app that converts a SQL query — typed, pasted, or imported
from a `.sql` file — into a **step-by-step relational-algebra derivation**, a
final one-line **RA formula**, and an interactive **operator-tree diagram**.

Built entirely in **Swift + SwiftUI** (no third-party dependencies). It also
runs on iPhone and Mac Catalyst, but the two-column layout is designed for iPad.

<p align="center"><em>SQL in → σ, π, ⋈, γ, δ, τ out.</em></p>

---

## What it does

Give it a query:

```sql
SELECT dept_id, COUNT(*) AS headcount, AVG(salary) AS avg_salary
FROM Employee
WHERE salary > 50000
GROUP BY dept_id
HAVING COUNT(*) > 5
ORDER BY avg_salary DESC;
```

…and it produces a derivation that follows SQL's logical processing order:

| # | Operator | Clause | Expression (abbreviated) |
|---|----------|--------|--------------------------|
| 1 | Base relation | `FROM` | `Employee` |
| 2 | Selection σ | `WHERE` | `σ[salary > 50000](Employee)` |
| 3 | Grouping γ | `GROUP BY` | `γ[dept_id; COUNT(*)→headcount, AVG(salary)→avg_salary](…)` |
| 4 | Selection σ | `HAVING` | `σ[COUNT(*) > 5](…)` |
| 5 | Projection π | `SELECT` | `π[dept_id, headcount, avg_salary](…)` |
| 6 | Sort τ | `ORDER BY` | `τ[avg_salary ↓](…)` |

Plus a pannable / zoomable tree diagram of the same expression.

## Three views

- **Steps** — a numbered card for every operator, each with a plain-language
  explanation and the running RA formula (copyable).
- **Formula** — the final one-line expression using conventional glyphs, with a
  notation legend.
- **Diagram** — the expression drawn as an operator tree (pinch to zoom, drag to
  pan).

## Input methods

- **Type** directly in the monospaced editor (live parsing, 250 ms debounce).
- **Paste** from the clipboard.
- **Import** a `.sql` / text file via the iOS document picker.
- **Examples** menu with six ready-made queries.

## Supported SQL

The parser covers the `SELECT` surface that maps cleanly onto relational
algebra:

- `SELECT` list with `*`, `table.*`, expressions, and `AS` aliases → **π / ρ**
- `DISTINCT` → **δ**
- `FROM` with multiple comma tables → **× (cartesian product)**
- `INNER` / `LEFT` / `RIGHT` / `FULL` / `CROSS` `JOIN` … `ON` / `USING` →
  **⋈ / ⟕ / ⟖ / ⟗ / ×**
- `WHERE` and `HAVING` predicates → **σ**
- `GROUP BY` with `COUNT` / `SUM` / `AVG` / `MIN` / `MAX` → **γ**
- `ORDER BY … ASC/DESC` → **τ** (a common RA extension)
- `UNION [ALL]`, `INTERSECT`, `EXCEPT` → **∪ / ∩ / −**
- Sub-queries in `FROM` and `IN`, plus `BETWEEN`, `IN (…)`, `LIKE`, `IS NULL`
- Comments (`--` and `/* */`) and standard operator precedence

## Operator legend

| Glyph | Operator | SQL |
|-------|----------|-----|
| σ | Selection | `WHERE`, `HAVING` |
| π | Projection | `SELECT` |
| ρ | Rename | `AS` |
| ⋈ | Theta / natural join | `JOIN … ON` |
| ⟕ ⟖ ⟗ | Outer joins | `LEFT` / `RIGHT` / `FULL JOIN` |
| × | Cartesian product | comma / `CROSS JOIN` |
| γ | Grouping & aggregation | `GROUP BY` |
| δ | Duplicate elimination | `DISTINCT` |
| τ | Sort | `ORDER BY` |
| ∪ ∩ − | Set operations | `UNION` / `INTERSECT` / `EXCEPT` |

## Architecture

```
SQL text
   │  Lexer            (Parser/Lexer.swift)      → [Token]
   ▼
[Token]
   │  SQLParser        (Parser/SQLParser.swift)  → SQLQuery AST
   ▼
SQLQuery
   │  RATranslator     (Translator/…)            → [RAStep] + RANode
   ▼
RANode ──► .formula   (one-line string)
       └─► .tree      → TreeLayout → SwiftUI canvas
```

| Layer | Files |
|-------|-------|
| **Models** | `Models/SQLAST.swift`, `Models/RANode.swift` |
| **Parser** | `Parser/Token.swift`, `Parser/Lexer.swift`, `Parser/SQLParser.swift` |
| **Translator** | `Translator/RATranslator.swift`, `RAStep.swift`, `ExpressionRendering.swift` |
| **View model** | `ViewModel/AppViewModel.swift`, `ViewModel/SampleQueries.swift` |
| **UI** | `App/…`, `Views/…` (editor, steps, formula, tree) |

The lexer + parser + translator are **pure Swift with no UIKit/SwiftUI
dependency**, which keeps them fully unit-testable (see `RelationalAlgebraTests`).

## Build & run

Requirements: **Xcode 16+**, iOS/iPadOS 17 SDK.

```bash
open RelationalAlgebra.xcodeproj
```

1. Select the **RelationalAlgebra** scheme.
2. Choose an iPad simulator (e.g. *iPad Pro 13-inch*) or a connected iPad.
3. **⌘R** to run, **⌘U** to run the unit tests.

No signing is required for the simulator. For a device, set your team under
*Signing & Capabilities* (the bundle id is `com.relationalalgebra.RelationalAlgebra`).

## Tests

`RelationalAlgebraTests` covers the lexer, parser, and translator — token
stream shape, clause parsing (joins, grouping, unions), error cases, and that
each SQL construct produces the expected RA glyph.

## Notes & limitations

- The translator models SQL's **logical** operator order for teaching purposes;
  it is not a query optimizer and does not push selections down.
- `ORDER BY` (τ) and duplicate handling are the usual pragmatic extensions to
  the pure (set-based) relational algebra.
- Only the `SELECT` surface is parsed; DML/DDL is out of scope.

## License

Apache License 2.0 — see [LICENSE](LICENSE).
