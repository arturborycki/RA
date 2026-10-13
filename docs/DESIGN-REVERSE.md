# Design: Typing RA or Calculus and Getting SQL Back

**Status:** proposal · **Scope:** `RelationalAlgebra` iOS/iPadOS app · **Follows:** [DESIGN-CALCULUS.md](DESIGN-CALCULUS.md)

The app is a one-way pipeline today: SQL in, RA / TRC / DRC out. This document designs
the reverse direction: the user types a **relational-algebra** expression, a
**tuple-calculus** formula or a **domain-calculus** formula, and the app produces
**SQL text**, plus every other notation it already renders.

---

## 1. Why this is worth doing

Coursework runs in both directions. "Write this query in RA" is half the homework, and
"now check it against a real database" is the other half. Students also write an RA answer
and want to know whether it means what they think it means. Running the SQL is the only way
most of them can check.

The reverse direction also tests the forward one. If `SQL → RA → SQL` or
`TRC → SQL → TRC` does not come back with the same answers, one of the two translators is
wrong. The app gains an equivalence check it does not have now (§11).

---

## 2. The one decision that shapes everything: SQL is the hub

Every input notation lowers to the existing `SQLQuery` AST. Nothing else is new in the middle:

```
                ┌──── RAParser ───► RAExpr ──── RAToSQL ────┐
 input text ────┼──── CalcParser ─► CalcExpression (TRC) ───┼──► SQLQuery ──► SQLPrinter ──► SQL text
                └──── CalcParser ─► CalcExpression (DRC) ───┘        │
                       │            └─ DRCRaising ─► TRC ──┘          │
                       │                                              ▼
                       └─ SafetyChecker (existing)         AppViewModel.translate (existing)
                                                                      │
                                                         RA · TRC · DRC · Compare (existing)
```

What this buys:

- **One new back end, not three.** RA, TRC and DRC each lower to `SQLQuery`. Then one
  `SQLPrinter` writes the text. A DRC formula is first *raised* to TRC (the inverse of the
  existing `DRCLowering`), so the calculus has one path into SQL, not two.
- **Every existing view works unchanged.** The generated `SQLQuery` goes into the same
  `AppViewModel.translate(_:)` that SQL input uses. So typing RA gives you TRC, DRC, the
  operator tree, the scope tree and Compare mode with no new rendering code.
- **The calculus parser targets an IR that already exists.** `CalcExpression` / `CalcQuery`
  / `CalcFormula` are already built for this. `SafetyChecker`, `CalcSimplifier` and
  `CalcRenderer` work on a parsed formula as they do on a translated one.

The alternative, separate RA↔TRC↔DRC converters, would need six translators instead of
three and would bypass the SQL front end that is the most tested part of the app.

---

## 3. Input syntax

### 3.1 The rule: accept what the app prints

Whatever the app renders must parse back to the same thing. Copying a formula out of the
Formula view and pasting it into the editor must work. That fixes the core grammar: the
bracket-subscript notation of `RANode.formula` and the Unicode / ASCII styles of
`CalcRenderer`.

### 3.2 Nobody can type σ on a phone

Each glyph gets an **ASCII alias** that the lexer accepts directly. The aliases match the
words `CalcRenderer`'s plain-text style already prints:

| Glyph | Aliases | | Glyph | Aliases |
|---|---|---|---|---|
| `σ` | `sigma`, `select` | | `∃` | `exists`, `EXISTS` |
| `π` | `pi`, `project` | | `∀` | `forall`, `FORALL` |
| `ρ` | `rho`, `rename` | | `∧` | `and`, `AND`, `&` |
| `⋈` | `join`, `\|x\|` | | `∨` | `or`, `OR`, `\|` *(not inside `{…}`)* |
| `⟕ ⟖ ⟗` | `ljoin`, `rjoin`, `fjoin` | | `¬` | `not`, `NOT`, `~` |
| `×` | `cross`, `x` *(between operands)* | | `→` | `->`, `implies` |
| `∪ ∩ −` | `union`, `intersect`, `minus`, `-` | | `⟨ ⟩` | `<`, `>` *(in result position)* |
| `÷` | `divide`, `/` | | `≠ ≤ ≥` | `<>`, `!=`, `<=`, `>=` |
| `γ δ τ` | `gamma`, `delta`, `tau` | | `∈` | `in` *(TRC `t ∈ R`, Silberschatz style)* |

Aliases are case-insensitive keywords only where they cannot be a relation or attribute
name. `x` is a cross product only between two operands. A relation actually named `select`
can be quoted: `"select"`.

The editor does **not** rewrite aliases to glyphs as you type. Doing that in a SwiftUI
`TextEditor` moves the cursor and fights the user. Instead there are two helpers:

- A **symbol bar** above the keyboard (§8.2) inserts glyphs at the cursor.
- A **Prettify** button rewrites the whole buffer to glyphs from the parse tree, so it
  never corrupts text that does not parse.

### 3.3 Relational-algebra grammar

```
script      := { assignment NEWLINE } expr
assignment  := IDENT ( '=' | '←' | ':=' ) expr          -- R₁ = σ[…](…)  → WITH R₁ AS (…)
expr        := setExpr
setExpr     := joinExpr { ( '∪' | '∩' | '−' ) joinExpr }        -- left-assoc, lowest
joinExpr    := unary { ( '⋈' sub? | '⟕' sub? | '⟖' sub? | '⟗' sub? | '×' | '÷' ) unary }
unary       := unaryOp sub? unary | primary
unaryOp     := 'σ' | 'π' | 'ρ' | 'γ' | 'δ' | 'τ' | 'LIMIT'
sub         := '[' text ']' | '_{' text '}' | '_' atom      -- three subscript spellings
primary     := IDENT | '(' expr ')'
```

- **Subscripts accept three spellings.** `σ[a > 5]` is the app's own form, `σ_{a > 5}` is
  LaTeX, and `σ_a>5` is the lazy form. One subscript rule covers all three.
- **Condition subscripts reuse the SQL expression parser.** Inside `σ[…]` and `⋈[…]`, the
  text is an expression. The lexer maps `∧ ∨ ¬ ≠ ≤ ≥` to `AND OR NOT <> <= >=` and hands the
  tokens to the existing `SQLParser.parseExpression()`. RA conditions then get `LIKE`,
  `BETWEEN`, `IN (…)`, `CASE` and arithmetic for free, with the same error positions.
- **Projection lists** are `attr [→ name]`, comma-separated. `π[name, salary*12 → annual]`
  becomes `SELECT name, salary*12 AS annual`.
- **Rename** takes the textbook forms: `ρ[E](Employee)`, `ρ[E(a, b, c)](Employee)`, and
  `ρ[a→x, b→y](R)` for attributes.
- **Grouping** uses the app's printed form, `γ[dept; COUNT(*)→n, AVG(salary)→avg](R)`.
- **Assignments** (`R₁ = …` lines, which is what the Steps view prints) become CTEs. Pasting
  a whole Steps derivation then gives you a `WITH` query.

### 3.4 Calculus grammar

```
query       := '{' resultSpec '|' formula '}'  { setOp query }
resultSpec  := term { ',' term }                       -- compact:  t.name, t.salary
             | '⟨' IDENT { ',' IDENT } '⟩'              -- tuple:    ⟨n, s⟩
             | IDENT                                    -- whole tuple: { t | … }
formula     := implication
implication := disjunction [ '→' implication ]          -- right-assoc
disjunction := conjunction { '∨' conjunction }
conjunction := negation { '∧' negation }
negation    := '¬' negation | quantified | atom
quantified  := ( '∃' | '∀' ) varList ( '(' formula ')' | quantified | atom )
atom        := IDENT '(' termList ')'                   -- R(t) or R(x₁, …, xₙ)
             | IDENT '∈' IDENT                          -- t ∈ R
             | term compOp term
             | '(' formula ')'
             | 'TRUE' | 'FALSE'
```

**The dialect is detected, not declared.** A relation atom with one argument whose
variable is later used as `t.attr` means TRC. A positional atom with several arguments
means DRC. A mix of the two is an error with a clear message. The input-language picker
(§8.1) still offers TRC and DRC separately, but only to choose the placeholder text and
examples. The parser accepts either and says which one it saw.

**`∃x ∈ R (φ)`** (the Silberschatz range-restricted form) desugars to `∃x ( R(x) ∧ φ )`.
**`∀x ∈ R (φ)`** desugars to `∀x ( R(x) → φ )`.

The parser stamps every `CalcVar` with its `relation` from the atom that ranges it. That is
the field `DRCLowering` already uses, and the raising pass in §6 needs it.

---

## 4. A structured RA tree

`RANode` cannot be the target of the RA parser. Its conditions are pre-rendered `String`s,
and `CalculusEquivalenceTests` already notes why that blocks evaluation. Lowering to SQL
needs the same structure.

Add a new input-side tree, `Models/RAExpr.swift`, whose leaves are SQL `Expression`s:

```swift
indirect enum RAExpr: Equatable {
    case relation(String)
    case select(Expression, RAExpr)
    case project([ProjectItem], RAExpr)               // ProjectItem: Expression + alias
    case rename(relation: String?, attributes: [String: String] /* or positional */, RAExpr)
    case join(JoinFlavor, on: Expression?, RAExpr, RAExpr)   // theta / natural / outer
    case cross(RAExpr, RAExpr)
    case divide(RAExpr, RAExpr)
    case group(keys: [Expression], aggregates: [ProjectItem], RAExpr)
    case distinct(RAExpr)
    case sort([OrderItem], RAExpr)
    case limit(count: Int?, offset: Int?, RAExpr)
    case setOp(SetOperator, RAExpr, RAExpr)
}

struct RAScript: Equatable {
    var assignments: [(name: String, expr: RAExpr)]
    var result: RAExpr
}
```

**Why a second tree rather than changing `RANode`?** Changing `RANode` to hold `Expression`
is the better long-term state. It would also let the equivalence tests evaluate the RA side.
But it touches the forward translator, three renderers and every golden test. Ship `RAExpr`
first. Moving `RANode` onto it later is a separate refactor, and the open questions (§13)
ask whether it is worth doing.

---

## 5. RA → SQL

`ReverseTranslation/RAToSQL.swift`. This has two stages, and the second one is the
interesting one.

### 5.1 Stage 1: faithful (one SELECT per operator)

Each operator becomes one query block wrapping its child as a derived table:

| RA | SQL |
|---|---|
| `R` | `SELECT * FROM R` |
| `σ[p](E)` | `SELECT * FROM (E) AS t WHERE p` |
| `π[a, b](E)` | `SELECT DISTINCT a, b FROM (E) AS t` |
| `ρ[S](E)` | `… AS S` on the derived table or base relation |
| `ρ[S(x, y)](E)` | `WITH S(x, y) AS (E)`, using the existing `CommonTableExpression.columns` |
| `E₁ × E₂` | `SELECT * FROM E₁, E₂` |
| `E₁ ⋈[p] E₂` | `SELECT * FROM E₁ JOIN E₂ ON p` |
| `E₁ ⋈ E₂` | `SELECT * FROM E₁ NATURAL JOIN E₂` |
| `E₁ ⟕[p] E₂` | `LEFT JOIN … ON p` (and so on for right and full) |
| `E₁ ∪ ∩ − E₂` | `UNION` / `INTERSECT` / `EXCEPT` (set semantics, which is correct as-is) |
| `γ[k; f→n](E)` | `SELECT k, f AS n FROM (E) GROUP BY k` |
| `δ(E)` | `SELECT DISTINCT * FROM (E)` |
| `τ[a ↓](E)` | `… ORDER BY a DESC` |
| `E₁ ÷ E₂` | double `NOT EXISTS` (§5.4) |

This is always correct and maps one to one onto the Steps view. It is also the SQL nobody
writes.

### 5.2 Stage 2: flatten into idiomatic SQL

A merge pass folds a block into its parent when this is safe. It runs as a separate pass
over `SQLQuery`, so each rewrite can be shown as a step in the same way the calculus
simplifier's rewrites are:

| Rewrite | Condition |
|---|---|
| Merge `σ` into the block below | child has no `GROUP BY` / `LIMIT` → `AND` into `WHERE` (into `HAVING` if the child is a `γ`) |
| Merge `π` into the block below | always; the projection replaces `*` |
| Merge joins and products into one `FROM` | children are plain (no `DISTINCT`, `GROUP BY`, `LIMIT`) |
| Inline a derived table that is just `SELECT * FROM R` | always → `FROM R AS alias` |
| Drop a redundant `DISTINCT` | the block projects a `GROUP BY`'s full key set, or sits directly under a set operator |
| Push `σ[p]` above `×` into `ON` | `p` references both sides (optional, off by default) |

The classic textbook shape `π[…](σ[…](R × S))` comes out as a single
`SELECT DISTINCT … FROM R, S WHERE …`, which is what a student expects.

**Default:** the flattened SQL in the main view, with the faithful version available in
Steps. This matches DESIGN-CALCULUS.md §15 Q2, which settled the same trade-off for the
simplifier.

### 5.3 Sets versus bags, made explicit

RA is set-based and SQL is bag-based. This is the most common silent error in hand-written
translations, so the app is explicit about it:

- Every `π` emits `DISTINCT` unless the flattening pass can prove it is redundant.
- An `info` diagnostic explains this: *"π removes duplicates; SQL keeps them unless told
  otherwise, so this SELECT says DISTINCT."* This is the mirror image of the forward
  direction's note that `DISTINCT` is a no-op in calculus.
- A **"Bag semantics"** toggle drops the automatic `DISTINCT` for courses that teach the
  multiset algebra. Off by default.

### 5.4 Division

`R ÷ S` has no SQL operator. Its standard double-negation form is:

```sql
SELECT DISTINCT r.a FROM R r
WHERE NOT EXISTS (SELECT * FROM S s
                  WHERE NOT EXISTS (SELECT * FROM R r2
                                    WHERE r2.a = r.a AND r2.b = s.b))
```

This needs to know which attributes are `R − S` (`a`) and which are shared (`b`). That is
a **schema question**, the same one DRC raised in the forward design. The existing
`QuerySchema` and `SchemaInference` answer it from declared `CREATE TABLE`s, which the RA
editor accepts above the expression just as the SQL editor does. Without a declaration,
division emits a `warning` and uses `π` subscripts seen elsewhere in the expression as the
best evidence. It never guesses silently.

### 5.5 Attribute resolution

RA attributes are usually unqualified (`σ[salary > 5](Employee)`). SQL needs them qualified
whenever two relations in one `FROM` share a name. The lowering keeps a scope of
`(alias, columns)` pairs per block and qualifies a reference **only when it is ambiguous**,
using `QuerySchema`. If the schema is unknown, a reference is qualified with its innermost
candidate and a `warning` is attached. `R × S` where both have attribute `a` is ill-formed
in strict RA. The app flags it as `info` ("the textbook would require a ρ here") instead of
rejecting it.

---

## 6. Calculus → SQL

`ReverseTranslation/CalcToSQL.swift` and `ReverseTranslation/DRCRaising.swift`.

### 6.1 Safety first: unsafe formulas have no SQL

`{ t | ¬Employee(t) }` has no SQL translation, because no finite query denotes it. The
existing `SafetyChecker` runs first. If it reports a safety diagnostic, the SQL view shows
**no SQL**, the safety message, and the offending variable. This is the right lesson to
teach, and the existing checker already produces it.

### 6.2 TRC → SQL

TRC is close to SQL already. That is why the forward translator could treat SQL as TRC with
keywords, and the reverse mapping is just as direct:

| TRC | SQL |
|---|---|
| free `t` with `R(t)` in the top-level conjunction | `FROM R t` |
| result `t.a, u.b → x` | `SELECT DISTINCT t.a, u.b AS x` |
| `{ t \| R(t) ∧ … }` (whole tuple) | `SELECT DISTINCT t.*` |
| other top-level conjuncts | `WHERE …` |
| `∃u ( R(u) ∧ φ )` | `EXISTS (SELECT * FROM R u WHERE φ)` |
| `¬∃u ( R(u) ∧ φ )` | `NOT EXISTS (…)` |
| `∀u ( R(u) → φ )` | `NOT EXISTS (SELECT * FROM R u WHERE NOT (φ))` |
| `∧ ∨ ¬` | `AND OR NOT` |
| comparisons, `predicate` atoms | the corresponding `Expression` |

**Refinements**, in the spirit of §5.2's flattening, which make the SQL read like
hand-written SQL:

- `∃u ( R(u) ∧ u.y = x ∧ φ )` where `u` appears nowhere else becomes
  `x IN (SELECT u.y FROM R u WHERE φ)`. This reverses the forward translator's `IN` rule.
- A guard-free `∀` (`∀u ( φ )` with no range atom) is unsafe and was already rejected in
  §6.1.

### 6.3 Disjunction becomes UNION

`{ t | R(t) ∨ S(t) }` cannot become one `FROM`, because each disjunct ranges `t` over a
different relation. The translator normalises to **disjunctive form at the top level only**
and emits one `SELECT` per disjunct, joined with `UNION`. It also accepts the app's own
printed set-operation form `{…} ∪ {…}` directly, through `CalcExpression.setOperation`.

Disjunctions *inside* a block, where each side ranges no new variables
(`R(t) ∧ (t.a = 1 ∨ t.b = 2)`), stay as `OR`. Only disjunctions that bind ranges are split.

### 6.4 DRC → TRC (raising)

The inverse of `DRCLowering`. For each positional atom `R(x₁, …, xₙ)`:

1. Allocate a tuple variable `r` (named from the relation's initial and de-duplicated,
   using the same naming helper as the forward pass).
2. Replace the atom with `R(r)`.
3. Bind each position: the first occurrence of a variable `xᵢ` defines `xᵢ := r.Aᵢ`. A
   **repeated** variable in another atom becomes an equality `r.Aᵢ = s.Bⱼ`, which is the
   implicit join. A **constant** in a position becomes `r.Aᵢ = 'Berlin'`.
4. Move each `∃xᵢ` to `∃r`, at the scope where the atom sits.

Step 3 needs column **names**, while DRC only has positions. Like forward DRC, this is
exact only with a declared schema. Without one, the generated SQL uses `R.col1, R.col2, …`
and a `warning` asks for a `CREATE TABLE`. That is the honest equivalent of the ellipsis the
forward DRC renders for unknown arity.

### 6.5 What the calculus parser accepts but SQL cannot express

| Construct | Outcome |
|---|---|
| Unsafe formula | no SQL; safety diagnostic (§6.1) |
| `COUNT{ u \| … }` aggregate extension | `GROUP BY` + aggregate; `extended` (P3) |
| `sort by … / limit …` annotations outside the braces | `ORDER BY` / `LIMIT`; `annotated` (P3) |
| Free variable not in the result | error: *"y is free but not returned; quantify it or add it to the result"* |

---

## 7. Printing SQL

`ReverseTranslation/SQLPrinter.swift`, `SQLQuery → String`. The app has
`Expression.rendered` but no query printer, because it never needed to print SQL.

- One clause per line. Sub-queries are indented one level and parenthesised on their own
  lines, the way people format correlated `EXISTS`.
- Identifiers are quoted only when they are reserved words or contain unusual characters.
- **Round-trip invariant:** `SQLParser.parse(SQLPrinter.print(q))` must equal `q` after
  normalising parentheses. This is tested over every sample query (§11). The printer also
  makes a useful "Format SQL" button for the existing SQL editor, at no extra cost.
- The output targets two engines, **DuckDB** and **Apache DataFusion** (§7.1).

### 7.1 Target engines: DuckDB and DataFusion

Both engines speak a Postgres-flavoured SQL and agree on almost everything this feature
emits: double-quoted identifiers, single-quoted strings, `EXISTS` / `IN` sub-queries,
`UNION` / `INTERSECT` / `EXCEPT`, `FULL OUTER JOIN`, `LIMIT … OFFSET …`, `||`, and
`DATE '…'` literals. So the printer writes **one portable subset by default**. A
`SQLDialect` value (`.duckdb`, `.datafusion`) changes the output only where the engines
actually differ.

**Portable-by-construction choices.** The printer avoids these constructs even though one
engine accepts them:

| Avoid | Emit instead | Why |
|---|---|---|
| `NATURAL JOIN` | `JOIN … USING (shared columns)` when the schema is declared | `USING` is supported by both; `NATURAL JOIN` is emitted only without a schema, with a diagnostic |
| Un-aliased derived table | always `(…) AS t` | Some engines require the alias and none reject it |
| Relying on default null ordering | explicit `NULLS FIRST/LAST` whenever the input says which | Engines differ on whether `DESC` puts nulls first |

**Where the dialect setting changes output:**

| Concern | DuckDB | DataFusion |
|---|---|---|
| Integer division in a user expression (`a / b`) | `/` is fractional; `//` is integer division | `/` on integers is integer division |
| Nested correlation (a sub-query referring two scopes out, as division's double `NOT EXISTS` and nested `∀` do) | emitted as is | **rejected** (`No field named r.a`, verified on DataFusion 55); emit the uncorrelated form (below) |
| Identifier case | case-insensitive, case-preserving | unquoted identifiers are lower-cased, so mixed-case names in a declared schema are quoted |

For `/`, the printer keeps the user's operator and adds an `info` diagnostic that the two
engines disagree on integer operands. It does not silently rewrite arithmetic.

**Verified, not assumed.** A probe against DuckDB 1.5 and DataFusion 55 settled these:
`NATURAL JOIN`, `USING`, CTE column lists (`WITH S(x, y) AS …`), derived-table column
aliases, and parenthesised set-operation operands all run on both engines. Two forms fail
on DataFusion only: nested correlation, as above, and `FROM a, b JOIN c ON <mentions a>`,
because `JOIN` binds tighter than the comma. The RA translator therefore turns a comma list
into `CROSS JOIN`s before it appends a `JOIN`.

**Uncorrelated fallbacks.** Division and `∀` each have a standard form that needs no
correlated sub-query:

```sql
-- R(a, b) ÷ S(b), via set difference: π_a(R) − π_a((π_a(R) × S) − R)
SELECT a FROM R
EXCEPT
SELECT a FROM (SELECT r.a, s.b FROM (SELECT DISTINCT a FROM R) r, S s
               EXCEPT
               SELECT a, b FROM R) AS missing;
```

The correlated `NOT EXISTS` form reads better and stays the default where the engine runs
it. The `EXCEPT` form is used where it does not, and it is also offered as a Steps card,
because it is the textbook RA definition of division.

**Scripts, not just queries.** "Copy" can include the `CREATE TABLE` declarations above the
query, printed with types, so the script pastes into the DuckDB CLI or `datafusion-cli`
and runs as is.

---

## 8. UI

### 8.1 An input-language picker on the editor

```
┌───────────── editor ─────────────┐   ┌──────────────── results ─────────────────┐
│ [ SQL │ RA │ TRC │ DRC ]   ⋯     │   │ [ SQL │ RA │ TRC │ DRC │ Compare ]       │
│                                  │   │ [ Steps │ Formula │ Diagram ]            │
│ π[name] (                        │   ├──────────────────────────────────────────┤
│   σ[salary > 50000] (Employee) ) │   │ ⓘ π removes duplicates → SELECT DISTINCT │
│                                  │   ├──────────────────────────────────────────┤
│                                  │   │ SELECT DISTINCT name                     │
├──────────────────────────────────┤   │ FROM Employee                            │
│ σ π ρ ⋈ × ∪ ∩ − ÷ γ  [ ]  ⌄      │   │ WHERE salary > 50000;                    │
├──────────────────────────────────┤   │                        [Copy] [Edit SQL] │
│ ✓ Parsed as RA · 2 lines         │   └──────────────────────────────────────────┘
└──────────────────────────────────┘
```

- A segmented **input picker** at the top of the editor, persisted with `@AppStorage`.
  The nav title follows it ("SQL" → "Relational Algebra"). On iPhone, so does the label of
  the first tab.
- **One buffer per input language.** Switching languages does not destroy text. Each
  buffer has its own placeholder and its own **Examples** menu group: the classic textbook
  exercises such as Students/Courses division, "employees earning more than every manager",
  and the Elmasri company schema.
- The status bar says what was parsed ("Parsed as DRC") and reports errors with the same
  character-offset highlighting the SQL parser already provides.

### 8.2 The symbol bar

This extends the keyboard toolbar `EditorView` already has (the hide-keyboard button).
It is a horizontally scrolling row of glyph buttons that depends on the input language:

- **RA:** `σ π ρ ⋈ ⟕ ⟖ ⟗ × ∪ ∩ − ÷ γ δ τ [ ] → ←`
- **TRC / DRC:** `∃ ∀ ∧ ∨ ¬ → { } | ⟨ ⟩ ∈ ≠ ≤ ≥`

Each button inserts at the cursor. That needs a small `UITextView` wrapper because SwiftUI's
`TextEditor` does not expose the selection. The wrapper is the only UIKit added. On iPad
with a hardware keyboard the bar stays visible, and the ASCII aliases make it optional.

### 8.3 SQL as a result notation

When the input language is not SQL, the results notation picker gains a **SQL** segment
in first position and selects it once on the switch:

- **Formula:** the flattened SQL, monospaced, with **Copy** and **Edit as SQL**. The latter
  copies the text into the SQL buffer and switches the input picker, making the round trip
  one tap.
- **Steps:** the faithful lowering (§5.1) or construction sequence, one card per RA
  operator or per quantifier, showing the SQL fragment it became. Flattening rewrites
  appear as their own cards, reusing `StepsView`'s card layout.
- **Diagram:** hidden; SQL has no meaningful third view.

The **other** notations need no change. RA input still shows the RA operator tree, rendered
from the regenerated SQL, so the user sees their expression *normalised*. TRC and DRC appear
too, which makes **RA → TRC** a supported conversion with no dedicated code. Compare mode
gains SQL as a fourth stacked panel when the input is not SQL.

One subtlety: for RA input, the RA panel shows the expression **as re-derived from SQL**,
not as typed. These can differ, for example `σ` merged into a join condition. The RA panel
shows a one-line note when the re-derived formula differs textually from the input. That is
a useful lesson in itself.

### 8.4 View-model changes

```swift
enum InputLanguage: String, CaseIterable { case sql, ra, trc, drc }

@AppStorage-backed  var inputLanguage: InputLanguage
@Published          var buffers: [InputLanguage: String]

struct TranslationBundle {
    var ra, trc, drc: …, schema: QuerySchema     // unchanged
    var sql: SQLGeneration?                       // nil when the input *is* SQL
}

struct SQLGeneration {
    var text: String                // flattened, printed
    var faithful: String            // one block per operator
    var steps: [ReverseStep]
    var diagnostics: [CalcDiagnostic]   // reuse; FidelityBanner works unchanged
}
```

`parseNow()` dispatches on `inputLanguage`. Non-SQL inputs produce a `SQLScript`
(declarations + generated query) and then call the existing pure `translate(_:)`. The
debounce, error handling and every existing consumer stay as they are.

---

## 9. Diagnostics

`CalcDiagnostic` is reused unchanged. `FidelityBanner` already renders a list of them and
does not care which direction they came from.

| Situation | Severity · fidelity |
|---|---|
| `π` emitted as `SELECT DISTINCT` | info · exact |
| Division / DRC column names without a declared schema | warning · exact (placeholder columns) |
| Ambiguous attribute qualified by best guess | warning · exact |
| Unsafe formula, no SQL produced | warning · safety |
| Outer join / `γ` / `τ` / `LIMIT` in RA input | info · extended (SQL has them; textbook RA does not) |
| `R × S` with clashing attribute names | info · exact |

---

## 10. Files

**New (~2,000 lines, estimated):**

```
Models/RAExpr.swift                       structured RA tree with Expression leaves
Parser/NotationLexer.swift                glyphs + ASCII aliases → tokens; maps ∧∨¬≠≤≥ for SQL exprs
Parser/RAParser.swift                     RAScript, delegating subscripts to SQLParser.parseExpression
Parser/CalcParser.swift                   → CalcExpression; dialect detection; ∈-sugar
ReverseTranslation/RAToSQL.swift          faithful lowering (§5.1), division, attribute resolution
ReverseTranslation/SQLFlattener.swift     merge pass (§5.2), each rewrite a step
ReverseTranslation/DRCRaising.swift       DRC → TRC (§6.4)
ReverseTranslation/CalcToSQL.swift        TRC → SQLQuery (§6.2–6.3)
ReverseTranslation/SQLPrinter.swift       SQLQuery → formatted text
ReverseTranslation/SQLDialect.swift       .duckdb / .datafusion differences (§7.1)
ReverseTranslation/ReverseStep.swift      ReverseStep, SQLGeneration
Views/InputLanguagePicker.swift
Views/SymbolBar.swift                     + small UITextView wrapper for cursor insertion
Views/SQLResultView.swift
```

**Modified:**

```
Parser/SQLParser.swift              make parseExpression usable on a token slice
ViewModel/AppViewModel.swift        InputLanguage, per-language buffers, SQLGeneration
Views/EditorView.swift              picker, symbol bar, per-language Examples
Views/NotationPicker.swift          `.sql` case, shown only for non-SQL input
App/ContentView.swift               route `.sql`; phone tab label
Views/CompareView.swift             fourth panel
ViewModel/SampleQueries.swift       RA / TRC / DRC example groups
```

The project uses `PBXFileSystemSynchronizedRootGroup`, so new files need **no
`project.pbxproj` edits**. Everything outside `Views/` stays free of SwiftUI and UIKit. The
CI type-check probes in `ci.yml` gain a `ReverseTranslation` layer.

---

## 11. Testing

1. **Printer round-trip.** For every bundled sample: `parse(print(parse(sql))) ==
   parse(sql)`. This catches printer bugs independently of everything else.
2. **Render → parse round-trip.** For every sample, `CalcParser.parse(CalcRenderer.render(
   trc)) == trc` in Unicode and ASCII style, and the same for DRC. This enforces §3.1
   ("accept what the app prints") and is the cheapest high-value test in the plan.
3. **Semantic equivalence.** Extend `CalculusEquivalenceTests`' toy evaluator:
   - *calculus input:* `eval(parsed) == eval(TRCTranslator(CalcToSQL(parsed)))`. The
     generated SQL, translated forward again, must give the same answers as the formula
     the user typed.
   - *DRC input:* the same, through `DRCRaising`.
   - *RA input:* a small `RAExpr` evaluator (~80 lines, practical now because conditions
     are `Expression`s) checked against the forward calculus of the generated SQL. This is
     the first test that evaluates the RA side at all.
4. **Golden SQL** for the textbook examples (division, `∀`-queries, self-joins via `ρ`,
   unions of differently-ranged disjuncts).
5. **Negative cases:** unsafe formulas produce no SQL, mixed TRC/DRC atoms are a parse
   error, and an undeclared division produces the warning.
6. **Run it on the real engines.** A CI job installs the `duckdb` and `datafusion` Python
   packages. For every golden case it loads the toy database, executes the generated SQL
   in **both** dialects, and asserts that the answers equal the in-app evaluator's. This is
   the only test that catches SQL that parses in the app but that an engine rejects or
   evaluates differently. It also settles the nested-correlation question in §7.1 with
   evidence rather than documentation.

---

## 12. Phasing

> **P0 as built** (branch `claude/reverse-translation-p0`) differs from the table below in
> three ways, each decided during implementation:
>
> - **No separate faithful stage.** One `SELECT` per operator breaks qualified names: once
>   `Employee e ⋈ Department d` is wrapped in a derived table, `e.salary` no longer resolves.
>   So the translator builds open blocks that σ and joins extend, and only π, δ and set
>   operations close them (§5.2 in effect, from the start). The Steps view's per-operator
>   cards are still to come.
> - **No dialect setting yet.** Every P0 construct prints identically for both engines, and
>   CI proves it by running every golden case on both. The setting arrives with the first
>   construct whose output must differ (division, nested `∀`). Until then, integer division
>   gets a diagnostic.
> - **`ρ[S(a, b)]` is in P0.** It becomes a CTE with a column list, which both engines run.

| Phase | Content | Ships |
|---|---|---|
| **P0** | `SQLPrinter` with DuckDB / DataFusion dialects and the CI job that runs both engines (+ "Format SQL" on the SQL editor), input picker, per-language buffers, `NotationLexer`, `RAParser` and `RAToSQL` for σ π ρ ⋈ × ∪ ∩ −, faithful output only, SQL result view | RA → SQL for most homework |
| **P1** | Flattening pass + steps, DISTINCT reasoning, symbol bar, RA examples, assignments → CTEs | SQL that looks hand-written |
| **P2** | `CalcParser`, TRC → SQL incl. ∀ and UNION splitting, safety gate, DRC raising, render→parse round-trip tests | Calculus → SQL |
| **P3** | Division, γ/τ/LIMIT, aggregate-extension input, Prettify, Compare fourth panel, semantic-equivalence tests for RA | Completeness and classroom extras |

P0 delivers value alone and also produces the `SQLPrinter` that every later phase needs.
Calculus input follows RA because it depends on the safety gate being correct. Showing SQL
for an unsafe formula would be worse than showing none.

---

## 13. Risks and open questions

| Risk | Mitigation |
|---|---|
| **Notation varies more on input than on output.** Every textbook writes subscripts, renames and division slightly differently. | Accept several spellings (§3.3). Golden tests per textbook style. Error messages suggest the accepted form. |
| **Keyboard friction kills the feature on iPhone.** | ASCII aliases make glyphs optional. The symbol bar makes them one tap. |
| **Set/bag mismatch produces SQL that looks right and isn't.** | DISTINCT by default, explained by a diagnostic, with a toggle (§5.3). |
| **Generated SQL is ugly.** | The flattening pass is P1, not "later". Faithful output is kept for the Steps view only. |
| **Users expect their RA to come back unchanged in the RA panel.** | The "re-derived" note in §8.3 explains the difference instead of hiding it. |

**Open questions for review:**

1. Should `RANode` eventually move onto `Expression` conditions and replace `RAExpr`?
   (Recommendation: yes, after P1. Two RA trees is debt, but not urgent debt.)
2. Should DISTINCT default on (set RA) or off (bag RA)? (Recommendation: on. Most courses
   teach set semantics first.)
3. Where does the DuckDB / DataFusion choice live? (Recommendation: a single app setting,
   default DuckDB, shown as a small badge on the SQL result view. Most output is identical
   in both, so a per-query picker would be chrome for nothing.)
4. Should the app eventually *run* the generated SQL against sample data? The P3 toy
   evaluator is most of a "try it" feature. (Recommendation: separate design doc.)
