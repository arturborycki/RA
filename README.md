<p align="center">
  <img src="docs/icon.png" alt="RA app icon" width="160" height="160">
</p>

<h1 align="center">RA — SQL → Relational Algebra for iPadOS</h1>

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

## Three notations

A **notation** picker switches the results pane between relational algebra,
**tuple relational calculus** and **domain relational calculus**.

### Relational algebra — three views

- **Steps** — a numbered card for every operator, each with a plain-language
  explanation and the running RA formula (copyable).
- **Formula** — the final one-line expression using conventional glyphs, with a
  notation legend.
- **Diagram** — the expression drawn as an operator tree (pinch to zoom, drag to
  pan).

### Tuple relational calculus — two views

- **Steps** — the construction sequence. Unlike the algebra's chain of named
  intermediate relations, this builds *one* formula: each card shows the whole
  expression as it stands and calls out what that step added.
- **Formula** — the finished expression, line-broken so it stays readable.

```
{ e.name | Employee(e) ∧ ∃d ( Department(d) ∧ e.dept_id = d.id ∧ d.location = 'Berlin' ) }
```

A SQL alias *is* a tuple variable, so `FROM Employee e` becomes `Employee(e)`
directly; variables the result does not export are existentially quantified over
just the conjuncts that mention them. `DISTINCT` needs no operator at all — a
calculus expression denotes a set — where the algebra needs δ.

#### Sub-queries become quantifiers

This is where the calculus says something the algebra cannot — relational
algebra has no ∃ or ∀ at all, so the RA view can only render these as an opaque
`σ[NOT EXISTS (…)]`:

| SQL | TRC |
|-----|-----|
| `EXISTS (SELECT … FROM R WHERE p)` | `∃u ( R(u) ∧ p )` |
| `NOT EXISTS (…)` | `¬∃u ( R(u) ∧ p )` |
| `x IN (SELECT y FROM R)` | `∃u ( R(u) ∧ u.y = x )` |
| `x > ALL (SELECT y FROM R)` | `∀u ( R(u) → x > u.y )` |
| `x > ANY \| SOME (SELECT y FROM R)` | `∃u ( R(u) ∧ x > u.y )` |
| `x = (SELECT y FROM R WHERE p)` | `∃u ( R(u) ∧ p ∧ x = u.y )` |

Correlation needs no machinery of its own: a column that resolves to a variable
in an enclosing scope simply keeps referring to it. So the classic division query
comes out directly —

```
{ s.name | Student(s) ∧ ¬∃c ( Course(c) ∧ ¬∃e ( Enrolled(e) ∧ e.sid = s.id ∧ e.cid = c.id ) ) }
```

Set operations merge into a single formula over shared result variables, where
`UNION` is a disjunction, `INTERSECT` a conjunction, and `EXCEPT` a conjunction
with a negation:

```
{ ⟨a⟩ | ∃x ( X(x) ∧ x.a = a ) ∧ ¬∃y ( Y(y) ∧ y.a = a ) }
```

### Domain relational calculus

The same expression with every tuple variable exploded into one variable per
column. A domain atom is *positional*, so this is the notation that needs to know
each relation's arity and column order:

```
{ ⟨n⟩ | ∃d, l ( Employee(n, d) ∧ Department(d, l) ) }
```

This is a mechanical lowering of the tuple form — Codd's equivalence — not a
second translator, so quantifier scoping, correlation and negation all carry over
unchanged.

#### Declaring your tables

Paste `CREATE TABLE` statements above the query and the atoms become exact:

```sql
CREATE TABLE Employee (name TEXT, salary INT, dept_id INT);

SELECT name, salary FROM Employee WHERE salary > 50000;
```
```
{ ⟨n, s⟩ | ∃d ( Employee(n, s, d) ∧ s > 50000 ) }
```

Without a declaration the app reconstructs what it can from the query's own
column references and marks the atom incomplete rather than inventing the
missing columns — `Employee(n, s, …)` — because a guessed arity is a *wrong*
formula, not a partial one. The **Schema** button in the editor toolbar lists
every relation with its columns numbered by position, says where each came from,
and offers a `CREATE TABLE` template for the ones that were only inferred.

#### Simplification

The direct translation is mechanical; these meaning-preserving rewrites turn it
into the form a textbook would print. Each is shown as its own step, because
"why did the equality disappear?" is a question worth answering:

| Rewrite | Before | After |
|---|---|---|
| Unify equated variables | `Employee(n, d) ∧ Department(i, l) ∧ d = i` | `Employee(n, d) ∧ Department(d, l)` |
| Inline constants | `Department(i, l) ∧ l = 'Berlin'` | `Department(i, 'Berlin')` |
| Flatten quantifiers | `∃x ( ∃y ( φ ) )` | `∃x, y ( φ )` |
| Drop vacuous quantifiers | `∃x ( φ )`, x unused | `φ` |
| Rewrite ¬∃ as ∀ | `¬∃c ( C(c) ∧ ¬φ )` | `∀c ( C(c) → φ )` |

That last one is where SQL's doubly-negated division query turns back into "for
every":

```
{ s.name | Student(s) ∧ ∀c ( Course(c) → ∃e ( Enrolled(e) ∧ e.sid = s.id ∧ e.cid = c.id ) ) }
```

The Formula view shows the simplified form with a toggle back to the direct
translation.

#### Safety

Relational calculus admits *unsafe* expressions — `{ t | ¬R(t) }` denotes every
tuple in the universe that is not in R, an answer that depends on the infinite
domain rather than on the database. Every formula is checked for
domain-independence: a variable is safe when a positive relation atom restricts
its range, and neither negation nor comparison does that. Findings appear in the
banner marked **unsafe**.

Alongside the formula the view lists each **relation** the query ranges over,
with its attributes and where they came from (declared, from a CTE, or inferred
from the query's own column references).

#### Fidelity

Not all SQL maps onto first-order calculus. Every construct is translated at a
declared fidelity, and anything that is not **exact** is named in a banner above
the formula:

| Fidelity | Meaning | Examples |
|----------|---------|----------|
| **exact** | Standard notation, no caveats | selection, projection, join, cross product, `DISTINCT` (a no-op) |
| **extension** | Needs a documented extension to the pure calculus | `GROUP BY` and aggregates, `IS NULL`, `LIKE` |
| **annotated** | No first-order expression; shown *outside* the braces | `ORDER BY`, `LIMIT`, `UNION ALL`, outer joins |

Nothing is silently approximated: an ambiguous unqualified column is reported
rather than attributed to a guess, and a relation whose attributes were only
inferred says so — which is what a domain-calculus atom will need, since `R(x, y, z)`
is positional.

## Input methods

- **Type** directly in the monospaced editor (live parsing, 250 ms debounce).
- **Paste** from the clipboard.
- **Import** a `.sql` / text file via the iOS document picker.
- **Examples** menu with six ready-made queries.

## Appearance

A toolbar menu switches between **System / Light / Dark** appearance; the choice
is remembered across launches (`@AppStorage`) and defaults to following the iPad
system setting. All colors use dynamic system semantics, so both themes look
right out of the box.

## Supported SQL

The parser covers the `SELECT` surface that maps cleanly onto relational
algebra:

- `CREATE TABLE` declarations preceding the query — column names and order,
  which is what makes the domain calculus exact
- `WITH` common table expressions (incl. `RECURSIVE`) → labelled sub-derivations
- `SELECT` list with `*`, `table.*`, expressions, and `AS` aliases → **π / ρ**
- `DISTINCT` → **δ**
- `FROM` with multiple comma tables → **× (cartesian product)**
- `INNER` / `LEFT` / `RIGHT` / `FULL` / `CROSS` `JOIN` … `ON` / `USING` →
  **⋈ / ⟕ / ⟖ / ⟗ / ×**
- `WHERE` and `HAVING` predicates → **σ**
- `GROUP BY` (incl. `ROLLUP` / `CUBE` / `GROUPING SETS`) with `COUNT` / `SUM` /
  `AVG` / `MIN` / `MAX` / `STDDEV` / `VARIANCE` → **γ**
- `ORDER BY … ASC/DESC [NULLS FIRST/LAST]` → **τ** (a common RA extension)
- `LIMIT` / `OFFSET` / `FETCH FIRST n ROWS ONLY`
- `UNION [ALL]`, `INTERSECT`, `EXCEPT` → **∪ / ∩ / −**
- Sub-queries in `FROM`, `IN`, scalar comparisons, and `EXISTS` / `NOT EXISTS`
- `CASE WHEN … THEN … ELSE … END`, `CAST(x AS type)`
- Window functions: `func(…) OVER (PARTITION BY … ORDER BY … <frame>)`
- Date / interval literals: `DATE '…'`, `TIMESTAMP '…'`, `INTERVAL '90' DAY`
- `BETWEEN`, `IN (…)`, `LIKE`, `IS NULL`
- Function calls including `SUBSTRING(x FROM 1 FOR 2)` / `EXTRACT`-style `FROM`/`FOR` syntax
- Comments (`--` and `/* */`) and standard operator precedence

### Benchmark coverage

The grammar targets the constructs used by the **TPC-H** (22 queries) and
**TPC-DS** (99 queries) benchmark suites — CTEs, window functions, `CASE`,
`CAST`, date/interval arithmetic, grouping extensions, and deeply nested
sub-queries. Correlated / scalar sub-queries inside predicates are shown
compactly as `(…)` within the σ condition rather than expanded into their own
derivation; the outer query's relational-algebra structure is always derived in
full. If you hit a query that doesn't parse, the editor points at the offending
token — please file it.

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
SQLQuery ─┬─ RATranslator      (Translator/…)    → [RAStep] + RANode
          │                                         ├─► .formula (one-line string)
          │                                         └─► .tree    → TreeLayout → canvas
          │
          ├─ SchemaInference   (Calculus/…)      → QuerySchema
          │                                         ▲ CREATE TABLE declarations
          │
          └─ TRCTranslator     (Calculus/…)      → CalcTranslation (TRC)
                                                    │
                                                    ├─ DRCLowering   → CalcTranslation (DRC)
                                                    ├─ CalcSimplifier → simplified form + steps
                                                    ├─ SafetyChecker  → diagnostics
                                                    └─ CalcRenderer   → set-builder text
```

The calculus translates from the **SQL AST**, not from `RANode`: by the time RA
is built, predicates are flattened to strings and sub-queries erased to `(…)`,
while SQL is very nearly sugar over TRC to begin with. The IR is shared, so
domain relational calculus lowers from the tuple form rather than needing a
second translator — and one simplifier, one safety checker and one renderer
serve both.

| Layer | Files |
|-------|-------|
| **Models** | `Models/SQLAST.swift`, `Models/RANode.swift`, `Models/CalcIR.swift`, `Models/Schema.swift`, `Models/CalcDiagnostic.swift` |
| **Parser** | `Parser/Token.swift`, `Parser/Lexer.swift`, `Parser/SQLParser.swift` |
| **Translator** | `Translator/RATranslator.swift`, `RAStep.swift`, `ExpressionRendering.swift` |
| **Calculus** | `Calculus/SchemaInference.swift`, `TRCTranslator.swift`, `DRCLowering.swift`, `CalcSimplifier.swift`, `SafetyChecker.swift`, `CalcRenderer.swift`, `CalcStep.swift`, `CalcTranslation.swift` |
| **View model** | `ViewModel/AppViewModel.swift`, `ViewModel/SampleQueries.swift` |
| **UI** | `App/…`, `Views/…` (editor, steps, formula, tree, calculus, banner) |

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

`RelationalAlgebraTests` covers the lexer, parser, and both translators — token
stream shape, clause parsing (joins, grouping, unions), error cases, and that
each SQL construct produces the expected RA glyph.

`CalculusTests` adds schema inference, the TRC translator and the renderer:
golden formulas for the core constructs, fidelity assertions (that `DISTINCT` is
explained rather than dropped, that `ORDER BY` lands outside the braces), and
structural invariants checked across every bundled sample — every quantified
variable is used in its body, every formula passes the safety checker, and
simplification is both idempotent and safety-preserving.

## Notes & limitations

- The translator models SQL's **logical** operator order for teaching purposes;
  it is not a query optimizer and does not push selections down.
- A sub-query carrying its own `GROUP BY`, `ORDER BY` or `LIMIT` cannot live
  inside a formula, so it is kept as an opaque atom and the reason is reported.
- `¬∃x ( R(x) ∧ ¬φ )` is not yet rewritten to the equivalent `∀x ( R(x) → φ )`;
  that rewrite belongs to the simplifier, alongside equality unification.
- Aggregation still has no calculus notation of its own: `GROUP BY` and the
  aggregate functions are annotated outside the braces rather than expressed.
  See [`docs/DESIGN-CALCULUS.md`](docs/DESIGN-CALCULUS.md).
- `ORDER BY` (τ) and duplicate handling are the usual pragmatic extensions to
  the pure (set-based) relational algebra.
- Only the `SELECT` surface is parsed; DML/DDL is out of scope.

## License

Apache License 2.0 — see [LICENSE](LICENSE).
