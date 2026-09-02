# Design: Adding Tuple and Domain Relational Calculus

**Status:** proposal · **Scope:** `RelationalAlgebra` iPadOS app · **Author:** design doc for review

Today the app is a one-way pipeline: SQL → relational algebra (RA), rendered three
ways (steps, formula, tree). This document designs the addition of **tuple relational
calculus (TRC)** and **domain relational calculus (DRC)** as first-class outputs, so
that every query the parser accepts produces all three notations.

---

## 1. Why this is worth doing

RA, TRC and DRC are the three notations every database course teaches side by side, and
students are routinely asked to convert between them. The app already owns the hard
part — a working SQL front end — so the marginal cost of two more back ends is much
smaller than the marginal value.

There is also a concrete quality argument. The RA translator today collapses sub-queries
to an opaque placeholder:

```
σ[NOT EXISTS (…)] ( Student )
```

That teaches nothing, because RA has no quantifiers — expressing correlated `NOT EXISTS`
in RA requires division or an anti-join, neither of which the translator attempts. The
calculus, by contrast, expresses it *directly*, and the SQL AST already retains the full
sub-query tree (`Expression.exists(query:negated:)`, `.inSubquery(...)`, `.subquery(...)`):

```
{ s.name | Student(s) ∧ ¬∃c ( Course(c) ∧ ¬∃e ( Enrolled(e) ∧ e.sid = s.id ∧ e.cid = c.id ) ) }
```

So the calculus back end is not merely a third rendering of the same thing — for the
whole sub-query surface it is strictly more informative than what the app prints now.

---

## 2. The three design problems

Everything else in this document follows from three problems that have to be settled up front.

### 2.1 DRC needs a schema; TRC mostly does not

A TRC atom is `Employee(t)` and attributes are reached by name: `t.salary`. A DRC atom is
positional: `Employee(n, s, d)`. **DRC cannot be generated at all without knowing each
relation's arity and column order.** A query text alone does not contain that information.

The design must therefore include a schema model, an inference pass, and — critically — an
honest story for when the schema is incomplete. Guessing an arity silently produces a
*wrong formula*, which is worse than producing no formula.

### 2.2 Aggregation is outside first-order calculus

`GROUP BY`, `COUNT`, `ORDER BY` and `LIMIT` have no expression in pure, safe relational
calculus. RA gets away with it because the app already uses the standard extensions (γ, τ).
The calculus back end needs the same courtesy, but the extension has to be *labelled* as
one rather than presented as textbook notation.

### 2.3 Not every well-formed formula is a legal one

Relational calculus admits *unsafe* (domain-dependent) expressions such as `{ t | ¬R(t) }`,
whose answer depends on the infinite universe of possible tuples. A translator that emits
these teaches a false lesson. Safety analysis is cheap to add and is itself good pedagogy.

**The unifying answer to all three is a fidelity model** (§7): every construct is translated
at a declared fidelity — `exact`, `extension`, or `annotated` — and the UI always shows which
parts of a formula fell back and why. Nothing is ever silently approximated.

---

## 3. Where the translation should start

Three candidate sources for the calculus translation:

| Source | Verdict |
|---|---|
| From the **RA tree** (`RANode`) | **No.** By the time RA is built, predicates are flattened to `String` and sub-queries are erased to `(…)`. The structure the calculus needs has already been destroyed. |
| From the **SQL AST** (`SQLQuery`) | **Yes, for TRC.** SQL is essentially syntactic sugar over TRC: `FROM` declares tuple variables, `WHERE` is the formula, `SELECT` is the result specification. The mapping is nearly one-to-one and the AST retains sub-query trees. |
| From **TRC**, mechanically | **Yes, for DRC.** Codd's equivalence lowers TRC to DRC by exploding each tuple variable into one domain variable per attribute. All the hard work — quantifier scoping, correlation resolution, negation — is reused. |

So the pipeline forks once and lowers once:

```
SQL text ─► Lexer ─► SQLParser ─► SQLQuery ─┬─► RATranslator ────► RANode        (unchanged)
                                            │
                                            ├─► SchemaInference ─► QuerySchema
                                            │
                                            └─► TRCTranslator ──► CalcQuery(.trc)
                                                                      │
                                                                      └─► DRCLowering ─► CalcQuery(.drc)
```

The single most important consequence: **TRC and DRC share one IR, one simplifier, one
safety checker, one renderer and one step engine.** DRC is a lowering pass plus two
rendering cases, not a second translator.

---

## 4. The calculus IR

A new `Models/CalcIR.swift`. Sketch:

```swift
/// Which calculus a `CalcQuery` is expressed in. Affects rendering and lowering only.
enum CalcDialect { case trc, drc }

/// A variable: a tuple variable in TRC, a domain variable in DRC.
struct CalcVar: Hashable {
    var name: String            // "e", "t₁", "sal"
    var relation: String?       // originating relation, for explanations
    var attribute: String?      // DRC only: which column this variable stands for
}

indirect enum CalcTerm: Equatable {
    case variable(CalcVar)                       // DRC: n
    case attribute(CalcVar, String)              // TRC: e.salary
    case literal(String)                         // 'Berlin', 50000, NULL
    case application(String, [CalcTerm])         // UPPER(x), x + y, CAST(…)
    case aggregate(AggregateSpec)                // extension — see §7.2
    case opaque(String)                          // escape hatch, carries a fidelity note
}

indirect enum CalcFormula: Equatable {
    case relationAtom(relation: String, terms: [CalcTerm], arityKnown: Bool)
    case comparison(CalcTerm, CompareOp, CalcTerm)
    case and([CalcFormula])
    case or([CalcFormula])
    case not(CalcFormula)
    case exists([CalcVar], CalcFormula)
    case forAll([CalcVar], CalcFormula)
    case implies(CalcFormula, CalcFormula)
    case predicate(String, [CalcTerm])           // LIKE, IS NULL, BETWEEN …
    case constant(Bool)
}

/// One output column: the term that produces it and the name it is published under.
struct ResultColumn: Equatable { var term: CalcTerm; var name: String? }

struct CalcQuery: Equatable {
    var dialect: CalcDialect
    var result: [ResultColumn]
    var formula: CalcFormula
    /// Post-calculus operators that FO calculus cannot express (§7.2).
    var extensions: [CalcExtension]   // grouping, sort, limit
}
```

Two notes on the shape:

- **`and([CalcFormula])` is n-ary, not binary.** The top-level conjunction is where the
  step-by-step derivation appends, where the simplifier unifies equalities, and where the
  safety checker looks for range restrictions. A flat list makes all three trivial; nested
  binary `and` makes all three annoying.
- **Nodes carry identity.** For step highlighting, tap-to-explain and inline diagnostic
  underlines, the renderer must be able to point at a subtree. Add a `CalcNodeID` (a
  monotonically-assigned `Int` stamped during construction) to `CalcFormula` and `CalcTerm`
  cases, or wrap them in a `Node<T>` struct carrying `id`. Retrofitting this later means
  touching every case, so it belongs in the first version.

### 4.1 Result specification: one general form, two presentations

The general, always-correct form binds fresh result variables by equality:

```
{ ⟨a⟩ | ∃t ( X(t) ∧ t.a = a ) ∨ ∃u ( Y(u) ∧ u.a = a ) }
```

The readable Elmasri-style form projects attributes of a free tuple variable directly:

```
{ t.name, t.salary | Employee(t) ∧ t.salary > 50000 }
```

The second is a *special case* of the first, available when every result column is an
attribute of a single free tuple variable. So: build the general form always, and let a
**presentation pass** collapse it to the compact style when the shape permits. Expose the
choice as a setting (`Compact (Elmasri)` / `Explicit (Ullman)`) rather than hard-coding a
textbook's convention — different courses teach different ones.

---

## 5. Schema model and inference

New `Models/Schema.swift` and `Calculus/SchemaInference.swift`.

```swift
struct RelationSchema: Equatable {
    var name: String
    var attributes: [String]     // ORDER IS SIGNIFICANT — DRC atoms are positional
    var source: SchemaSource
    var arityKnown: Bool         // false ⇒ inferred, may be missing columns
}

enum SchemaSource { case declared, cte, inferred }

struct QuerySchema: Equatable {
    var relations: [String: RelationSchema]
    var aliases: [String: String]      // "e" → "Employee"
}
```

Evidence is gathered in descending order of trust:

1. **Declared DDL.** `CREATE TABLE` statements in the editor buffer, or pasted into a
   schema panel. Gives exact attributes *in order*. `arityKnown = true`.
2. **CTE definitions.** A CTE's output columns are fully determined by its `SELECT` list
   (or its explicit `WITH name(a, b, c)` column list, which `CommonTableExpression.columns`
   already carries). `arityKnown = true`.
3. **Derived tables.** Same reasoning as CTEs, from the sub-query's projection.
4. **Qualified references.** `e.salary` where `e` aliases `Employee` ⇒ `Employee` has a
   `salary` column. Order = first appearance. `arityKnown = false`.
5. **`USING (a, b)`** ⇒ both sides have `a` and `b`.
6. **Unqualified references** when exactly one relation is in scope ⇒ attribute of that
   relation. With several relations in scope the reference is *ambiguous* and is recorded
   as a diagnostic, not resolved by coin-flip.

Inference is a pure function `SQLQuery -> QuerySchema` with no UI dependency, so it unit-tests
like the rest of the pipeline.

### 5.1 Handling an incomplete schema, honestly

When `arityKnown == false`, DRC renders a trailing ellipsis and raises a warning rather than
inventing columns:

```
{ ⟨n, s⟩ | ∃d ( Employee(n, s, d, …) ∧ s > 50000 ) }
          ⚠︎ Employee: 3 of an unknown number of columns inferred from the query.
             Add a CREATE TABLE to make this exact.
```

The warning is actionable: it links to the schema inspector. This is the difference between
a teaching tool and a plausible-looking lie.

### 5.2 Parser work required

Small, and it pays for itself:

- **`CREATE TABLE`** — parse column names and types, keep them out of the translation path.
  This is the single highest-value parser addition, because it turns every DRC formula from
  "approximately right" into "exactly right".
- **`> ALL (…)` / `> ANY|SOME (…)`** — not currently supported, and they lower to `∀` and `∃`
  respectively. Disproportionate teaching value per line of parser code.
- **`NATURAL JOIN`** — implies an equality on shared attributes, which needs a schema; nice
  once DDL exists.

---

## 6. Translation rules

`Calculus/TRCTranslator.swift`, walking `SQLQuery` with a scope stack of visible tuple
variables (this is what makes correlated sub-queries work).

### 6.1 Core SELECT

| SQL | TRC |
|---|---|
| `FROM Employee e` | declare tuple variable `e`; conjunct `Employee(e)` |
| `FROM A, B` | `A(a) ∧ B(b)` — the comma *is* the cartesian product |
| `JOIN B ON p` | `B(b) ∧ p′` |
| `LEFT JOIN` | no FO equivalent — `annotated` fidelity (§7) |
| `WHERE p` | conjoin `p′` |
| `SELECT x, y AS z` | result columns `[x, y→z]` |
| `SELECT *` | one result column per attribute of every in-scope relation |
| `DISTINCT` | **no-op** — a calculus expression denotes a set |

The `DISTINCT` row is worth surfacing to the user as an explanation card, not hiding: RA needs
δ, the calculus does not, and understanding why is the point of teaching both.

Note that **SQL aliases already are tuple variables**. `FROM Employee e` → `Employee(e)` is a
one-token change, and saying so in the step explanation is one of the most useful sentences
the app can print.

### 6.2 Predicates and sub-queries — the payoff

With `outer` denoting variables in scope from enclosing blocks:

| SQL predicate | TRC |
|---|---|
| `EXISTS (SELECT * FROM R WHERE p)` | `∃u ( R(u) ∧ p′ )` |
| `NOT EXISTS (…)` | `¬∃u ( R(u) ∧ p′ )`, rewritable as `∀u ( R(u) → ¬p′ )` |
| `x IN (SELECT y FROM R WHERE p)` | `∃u ( R(u) ∧ u.y = x ∧ p′ )` |
| `x NOT IN (…)` | `¬∃u ( R(u) ∧ u.y = x ∧ p′ )` |
| `x > ALL (SELECT y FROM R)` | `∀u ( R(u) → x > u.y )` |
| `x > ANY (SELECT y FROM R)` | `∃u ( R(u) ∧ x > u.y )` |
| scalar `x = (SELECT y FROM R WHERE p)` | `∃u ( R(u) ∧ p′ ∧ x = u.y )` |
| `p AND q` / `OR` / `NOT` | `∧` / `∨` / `¬` |
| `x BETWEEN a AND b` | `x ≥ a ∧ x ≤ b` |
| `x IN (v1, v2, v3)` | `x = v1 ∨ x = v2 ∨ x = v3` |
| `x IS NULL`, `LIKE` | `predicate(…)` atoms — `extension` fidelity (the pure calculus has no nulls) |

Correlation falls out for free: a column reference that resolves to a variable in an *enclosing*
scope simply keeps referring to it, which is exactly the semantics of a correlated sub-query.

### 6.3 Set operations

Combine at the formula level over shared result variables:

| SQL | TRC |
|---|---|
| `UNION` | `∃t ( X(t) ∧ t.a = a ) ∨ ∃u ( Y(u) ∧ u.a = a )` |
| `INTERSECT` | the same with `∧` |
| `EXCEPT` | `∃t(…) ∧ ¬∃u(…)` |

`UNION ALL` cannot preserve duplicates in a set-based calculus — `annotated`, with a note.

### 6.4 DRC lowering

`Calculus/DRCLowering.swift`. For each tuple variable `t` over relation `R` with schema
`⟨A₁ … Aₙ⟩`:

1. Allocate domain variables `x₁ … xₙ`, named mnemonically from the attribute (`salary` → `s`,
   collision-resolved to `s₁`) or as `x₁ … xₙ` under an indexed naming policy.
2. Replace `R(t)` with `R(x₁, …, xₙ)`.
3. Replace every `t.Aᵢ` with `xᵢ`.
4. Existentially quantify every `xᵢ` not exported by the result specification, at the point
   where `t` was quantified (or at the top level for a free `t`).

Then run the simplifier (§6.5), which is what turns the mechanical output into idiomatic DRC.

### 6.5 Simplification — where DRC becomes readable

`Calculus/CalcSimplifier.swift`, a set of individually-toggleable rewrites, each of which can
be *shown as a derivation step*:

| Rewrite | Before | After |
|---|---|---|
| Equality unification | `Employee(n,s,ed) ∧ Department(di,dn,dl) ∧ ed = di` | `Employee(n,s,d) ∧ Department(d,dn,dl)` |
| Constant inlining | `Department(di,dn,dl) ∧ dl = 'Berlin'` | `Department(di,dn,'Berlin')` |
| ∃-flattening | `∃x ( ∃y ( φ ) )` | `∃x,y ( φ )` |
| Vacuous-∃ elimination | `∃x ( φ )` where `x ∉ free(φ)` | `φ` |
| `¬∃` → `∀` | `¬∃c ( C(c) ∧ ¬φ )` | `∀c ( C(c) → φ )` |
| `TRUE` absorption | `φ ∧ TRUE` | `φ` |

Making these opt-in steps rather than a silent pass is deliberate: "why did the equality
disappear?" is exactly the question a student needs answered, and the unsimplified form is
what a mechanical translation from SQL actually yields.

---

## 7. The fidelity model

`Models/Diagnostics.swift`:

```swift
enum Fidelity { case exact, extension_, annotated }

struct CalcDiagnostic: Identifiable {
    let id = UUID()
    var severity: Severity          // .info, .warning
    var fidelity: Fidelity
    var construct: String           // "LEFT JOIN", "COUNT(*)", "ORDER BY"
    var message: String
    var node: CalcNodeID?           // for inline highlighting
}
```

### 7.1 `exact`

Selection, projection, join, cross product, set operations, all sub-query forms, `DISTINCT`
(as a no-op). Standard textbook notation, no caveats.

### 7.2 `extension_` — labelled, not faked

**Aggregation.** Rendered as an aggregate over a set comprehension, which is readable and
close to how textbooks introduce the extension:

```sql
SELECT dept_id, COUNT(*) AS headcount
FROM Employee GROUP BY dept_id HAVING COUNT(*) > 5
```

```
{ ⟨d, h⟩ | ∃t ( Employee(t) ∧ t.dept_id = d )
           ∧ h = COUNT{ u | Employee(u) ∧ u.dept_id = d }
           ∧ h > 5 }
```

with the banner: *"COUNT is an extension — first-order relational calculus has no aggregation."*
Note `HAVING` conjoins onto the outer formula while `WHERE` conjoins inside the comprehension;
that distinction is another thing the app can teach for free.

**Nulls / `LIKE` / three-valued logic.** Kept as opaque predicate atoms with a note that the
pure calculus is two-valued.

### 7.3 `annotated` — outside the calculus entirely

`ORDER BY`, `LIMIT`/`OFFSET`, `UNION ALL`, outer joins. Rendered as a wrapper *outside* the
braces so the calculus expression itself stays honest:

```
sort by avg_salary ↓ , limit 10  applied to
{ ⟨d, a⟩ | … }
```

This mirrors what the RA side already concedes about τ, and keeps the app from ever printing
something a grader would mark wrong.

---

## 8. Safety analysis

`Calculus/SafetyChecker.swift`. A formula is *safe* (domain-independent) if every free variable
is range-restricted by a positive relation atom. Rules:

- Every result variable must occur in a positive `relationAtom` in the top-level conjunction,
  or be equated to a term that does.
- A variable occurring only under `¬` is unsafe: `{ ⟨n⟩ | ¬Employee(n, s, d) }` ranges over the
  infinite domain.
- Comparisons never range-restrict: `{ ⟨x⟩ | x > 5 }` is unsafe.
- `∀x ( φ )` must be guarded: `∀x ( R(x) → ψ )`.

Output is `[CalcDiagnostic]` with node ids, rendered as an inline underline plus a banner entry.
This runs on every translation and costs one tree walk. Because the translator only produces
safe formulas from valid SQL, in practice the checker is a *regression net* for the translator
and a *teaching device* when the user edits a formula — both worth the ~120 lines.

---

## 9. Rendering

`Calculus/CalcRenderer.swift`, a protocol with three implementations over the shared IR:

| Renderer | `∃t ( R(t) ∧ t.a > 5 )` |
|---|---|
| **Unicode** (screen, copy) | `∃t ( R(t) ∧ t.a > 5 )` |
| **ASCII** (plain-text export) | `EXISTS t ( R(t) AND t.a > 5 )` |
| **LaTeX** (homework export) | `\exists t\,( R(t) \wedge t.a > 5 )` |

LaTeX export is high-value and nearly free once the IR exists — the audience is students
writing up assignments. It should also cover the RA side (`\sigma`, `\pi`, `\bowtie`), which
is a small bonus win for the existing feature.

Long formulas need a **line-breaking pretty printer**, mirroring `RANode.prettyFormula`: break
at top-level `∧`, indent quantifier bodies one level, keep atoms atomic. Without it, a TPC-H
query renders as a single 900-character line that is unreadable on an iPad and hopeless on an
iPhone.

The renderer returns `AttributedString` with node ids attached as attributes, which is what
powers step highlighting, diagnostic underlines and tap-to-explain from one code path.

---

## 10. Derivation steps for the calculus

The RA view's numbered `R₁ = σ[…]( … )` derivation does not transfer: the calculus builds
*one* formula rather than a chain of named intermediate relations. The analogue is a
**construction sequence**, where each step shows the whole formula so far with the newly-added
part highlighted:

| # | Step | Formula so far |
|---|---|---|
| 1 | Declare a tuple variable for each `FROM` entry | `{ … \| Employee(e) ∧ Department(d) }` |
| 2 | `JOIN … ON` becomes an equality conjunct | `… ∧ e.dept_id = d.id` |
| 3 | `WHERE` conjuncts | `… ∧ d.location = 'Berlin'` |
| 4 | Sub-query becomes a quantifier | `… ∧ ¬∃c ( … )` |
| 5 | `SELECT` list becomes the result specification | `{ e.name, d.name → department \| … }` |
| 6 | Quantify non-result variables | `∃d ( … )` |
| 7 | *(optional)* simplify: unify equalities, rewrite `¬∃` as `∀` | … |

```swift
struct CalcStep: Identifiable {
    let id = UUID()
    var index: Int
    var title: String
    var clause: String            // "FROM", "WHERE", "NOT EXISTS", "simplify"
    var explanation: String
    var query: CalcQuery          // full state after this step
    var highlight: [CalcNodeID]   // what this step added or changed
}
```

`CalcTranslation { steps, final: CalcQuery, diagnostics: [CalcDiagnostic], schema: QuerySchema }`
parallels `RATranslation`, so `StepsView` generalises with modest changes rather than being
duplicated.

---

## 11. UI

### 11.1 Two axes, not nine tabs

Three notations × three views = nine tabs, which is unusable. Instead, two orthogonal pickers:

```
┌──────────────────────────────────────────────────────────────┐
│  [ RA │ TRC │ DRC ]        ← notation (segmented, persisted)  │
│  [ Steps │ Formula │ Structure ]  ← view (segmented, persisted)│
├──────────────────────────────────────────────────────────────┤
│  ⚠︎ Employee: arity inferred · COUNT is an extension          │  ← fidelity banner
├──────────────────────────────────────────────────────────────┤
│                                                              │
│                      result content                          │
└──────────────────────────────────────────────────────────────┘
```

The third view slot is notation-dependent: **Diagram** (the existing operator tree) for RA,
**Structure** for TRC/DRC — a quantifier-scope tree showing `∃`/`∀` nesting, which variables
are bound where, and which are free. That view reuses `TreeLayout` almost verbatim; a scope
tree and an operator tree have the same layout problem.

### 11.2 Compare mode

A fourth notation-axis option, **Compare**, stacking the three final formulas in one scroll
view. On an iPad in landscape this is the single most pedagogically useful screen in the app —
the same query, three notations, visible at once. It is also nearly free: three existing views
in a `VStack`.

### 11.3 Schema inspector

A sheet from the editor toolbar (next to the existing Examples / Paste / Import buttons)
listing every relation, its attributes **in order**, and the source badge
(*declared* / *from CTE* / *inferred*). Attributes are drag-reorderable and editable, because
DRC positional order matters and inference cannot always get it right. Edits persist per
relation name via `@AppStorage`, so a user who works with one schema across many queries
enters it once.

### 11.4 View model changes

```swift
struct TranslationBundle: Equatable {
    var ra: RATranslation
    var trc: CalcTranslation
    var drc: CalcTranslation
    var schema: QuerySchema
    var diagnostics: [CalcDiagnostic]
}

@Published private(set) var result: TranslationBundle?
```

`parseNow()` parses once and translates three times. All three translators are pure and
operate on trees of at most a few hundred nodes, so the cost is microseconds — well inside the
existing 250 ms debounce. If a TPC-DS-scale query ever proves otherwise, the fix is a
per-notation lazy cache keyed on the notation, not a re-architecture. Measure before optimising.

Existing views read `viewModel.translation`; keeping a computed `var translation: RATranslation?
{ result?.ra }` lets `StepsView`, `FormulaView` and `TreeView` keep working untouched during
the migration.

---

## 12. Files

**New (~2,200 lines):**

```
Models/CalcIR.swift                  IR: CalcQuery, CalcFormula, CalcTerm, CalcVar, node ids
Models/Schema.swift                  RelationSchema, QuerySchema, SchemaSource
Models/Diagnostics.swift             Fidelity, CalcDiagnostic
Calculus/SchemaInference.swift       SQLQuery -> QuerySchema
Calculus/TRCTranslator.swift         SQLQuery + QuerySchema -> CalcTranslation
Calculus/DRCLowering.swift           TRC CalcQuery -> DRC CalcQuery
Calculus/CalcSimplifier.swift        unification, ∃-flattening, ¬∃→∀, constant inlining
Calculus/SafetyChecker.swift         domain-independence analysis
Calculus/CalcRenderer.swift          Unicode / ASCII / LaTeX + pretty-printer
Calculus/CalcStep.swift              CalcStep, CalcTranslation
Views/CalculusFormulaView.swift
Views/CalculusStepsView.swift
Views/ScopeTreeView.swift            quantifier-scope tree (reuses TreeLayout)
Views/SchemaInspectorView.swift
Views/NotationPicker.swift
Views/CompareView.swift
Views/FidelityBanner.swift
```

**Modified:**

```
Parser/SQLParser.swift               CREATE TABLE, ALL/ANY/SOME, NATURAL JOIN
ViewModel/AppViewModel.swift         TranslationBundle
App/ContentView.swift                two-axis picker, banner, compare mode
ViewModel/SampleQueries.swift        division / correlated-subquery samples that show off ∀
RelationalAlgebraTests/…             see §13
```

The Xcode project uses `PBXFileSystemSynchronizedRootGroup` (objectVersion 77), so new files
under `RelationalAlgebra/` are picked up automatically — **no `project.pbxproj` edits.**

Everything under `Models/`, `Calculus/` and `Parser/` stays free of UIKit and SwiftUI, preserving
the property that the whole engine is unit-testable — which is what makes §13 possible.

---

## 13. Testing

1. **Golden formulas.** For every bundled sample plus the TPC-H queries already exercised in
   the test suite, snapshot the TRC and DRC strings. Catches regressions in renderer and
   translator alike.
2. **Structural invariants**, checked over every test query:
   - every variable is declared before use and bound exactly once;
   - DRC atom arity equals the schema arity for every relation with `arityKnown`;
   - the safety checker reports no errors on any formula generated from valid SQL.
3. **Simplifier idempotence.** `simplify(simplify(q)) == simplify(q)`.
4. **Cross-notation equivalence (stretch, high value).** A ~50-line in-memory evaluator over a
   handful of toy relations, run against the RA tree, the TRC formula and the DRC formula, with
   the three result sets asserted equal. This is the only test that can catch a translation that
   is well-formed but *wrong*, and it doubles as a future user-facing "run it on sample data"
   feature.

---

## 14. Phasing

| Phase | Content | Ships |
|---|---|---|
| **P0** | IR, schema inference, TRC for select-project-join + `WHERE`, Unicode renderer, notation picker, calculus formula view | TRC for the queries most students actually write |
| **P1** | Sub-queries → quantifiers, `ALL`/`ANY`, set operations, safety checker, calculus steps view | The feature's main differentiator (§1) |
| **P2** | DRC lowering, simplifier, `CREATE TABLE` parsing, schema inspector, fidelity banner | DRC that is exactly right rather than approximately right |
| **P3** | Aggregation extension, scope-tree view, compare mode, LaTeX/ASCII export, equivalence tests | Polish and the classroom-facing extras |

P0+P1 is a coherent, shippable release on its own: full TRC. DRC deliberately follows, because
it depends on the schema story landing first, and shipping DRC on inferred arities would
undermine trust in the whole feature.

---

## 15. Risks and open questions

| Risk | Mitigation |
|---|---|
| **DRC correctness depends on schema.** A wrong arity is a wrong formula. | Never guess silently: `…` marker, warning, one-tap schema inspector. Gate DRC behind P2. |
| **Notation conventions vary by textbook.** Elmasri, Ullman and Silberschatz differ on result-spec style, `∈` vs predicate atoms, and implicit quantification. | Make style a setting, not a hard-coded choice. The IR is convention-neutral; only renderers commit. |
| **Formula width on iPhone.** | The line-breaking pretty printer (§9) is not optional — it is a P0 item. |
| **UI complexity creep.** Two pickers plus a banner is already a lot of chrome. | Persist both picker states; hide the banner entirely when there are no diagnostics. |
| **Aggregation notation is genuinely non-standard.** | Label it as an extension everywhere it appears; never present it as textbook calculus. |

**Open questions for review:**

1. Which textbook convention should be the *default* result-spec style — compact/Elmasri or
   explicit/Ullman? (Recommendation: compact, with a setting.)
2. Should the simplifier run by default, or should the mechanical translation be shown first?
   (Recommendation: simplify by default for the Formula view, show the unsimplified form plus
   simplification steps in the Steps view.)
3. Is the schema worth persisting across app launches, or is per-query inference enough for
   the target user? (Recommendation: persist — it is `@AppStorage` and a few lines.)
