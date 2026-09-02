//
//  TRCTranslator.swift
//  RelationalAlgebra
//
//  Turns a parsed `SQLQuery` into tuple relational calculus.
//
//  The translation runs off the SQL AST rather than the relational-algebra tree
//  on purpose. SQL is very nearly sugar over TRC — `FROM` declares tuple
//  variables, `WHERE` is the formula, `SELECT` is the result specification —
//  and the AST still holds the structure (sub-query trees, predicate shape)
//  that `RATranslator` flattens to strings on its way to `RANode`.
//
//  Sub-query predicates become quantifiers, which is where the calculus says
//  something the algebra cannot: `NOT EXISTS` is `¬∃`, `> ALL` is `∀`, and a
//  correlated reference is simply a variable resolved in an enclosing scope.
//  A sub-query that cannot live inside a formula — one with its own grouping,
//  sort or row limit — is kept as an opaque atom and says so.
//

import Foundation

struct TRCTranslator {

    func translate(_ query: SQLQuery, schema: QuerySchema) -> CalcTranslation {
        let builder = TRCBuilder(schema: schema)
        let root = builder.build(query, outer: TupleScope())
        return CalcTranslation(dialect: .trc,
                               definitions: builder.definitions,
                               root: root,
                               simplified: root,
                               steps: builder.steps,
                               schema: schema,
                               diagnostics: builder.diagnostics.deduplicated)
    }
}

// MARK: - Scope

/// The tuple variables visible at one nesting level. A reference that resolves
/// to a variable in an *enclosing* level is exactly what makes a correlated
/// sub-query correlated, so the parent chain is kept rather than flattened.
struct TupleScope {
    private(set) var bindings: [(name: String, variable: CalcVar)] = []
    private var parent: [(name: String, variable: CalcVar)] = []

    init() {}

    init(nestedIn outer: TupleScope) {
        parent = outer.bindings + outer.parent
    }

    mutating func bind(name: String, to variable: CalcVar) {
        bindings.append((name: name, variable: variable))
    }

    func variable(forQualifier qualifier: String) -> CalcVar? {
        (bindings + parent).first { $0.name.caseInsensitiveCompare(qualifier) == .orderedSame }?.variable
    }

    /// Distinct variables introduced at this level, in declaration order.
    var localVariables: [CalcVar] {
        var seen = Set<CalcVar>()
        return bindings.compactMap { seen.insert($0.variable).inserted ? $0.variable : nil }
    }
}

// MARK: - Builder

final class TRCBuilder {
    private let schema: QuerySchema
    private(set) var diagnostics: [CalcDiagnostic] = []
    private(set) var definitions: [CalcDefinition] = []
    private(set) var steps: [CalcStep] = []
    private var usedNames = Set<String>()
    /// Steps are recorded for the outermost expression only. A sub-query's own
    /// construction is a detail of the step that introduced its quantifier, and
    /// interleaving the two would make the derivation unreadable.
    private var depth = 0

    init(schema: QuerySchema) {
        self.schema = schema
    }

    // MARK: Step recording

    /// Run `body` one level down, so nothing inside it records a step.
    private func nested<T>(_ body: () -> T) -> T {
        depth += 1
        defer { depth -= 1 }
        return body()
    }

    private func emitStep(title: String, clause: String, explanation: String,
                          expression: CalcExpression, added: String? = nil) {
        guard depth == 0 else { return }
        steps.append(CalcStep(index: steps.count + 1, title: title, clause: clause,
                              explanation: explanation, expression: expression, added: added))
    }

    /// The expression as it stands mid-derivation: the conjuncts built so far,
    /// with a result specification only once the SELECT list has been read.
    private func snapshot(_ conjuncts: [CalcFormula], result: [ResultColumn]) -> CalcExpression {
        .query(CalcQuery(dialect: .trc, result: result,
                         formula: CalcFormula.conjunction(conjuncts)))
    }

    // MARK: Query dispatch

    func build(_ query: SQLQuery, outer: TupleScope) -> CalcExpression {
        switch query {
        case let .select(stmt):
            return .query(buildSelect(stmt, outer: outer))

        case let .setOperation(op, left, right, all):
            let lhs = nested { build(left, outer: outer) }
            let rhs = nested { build(right, outer: outer) }
            let calcOp: CalcSetOperator
            switch op {
            case .union:     calcOp = .union
            case .intersect: calcOp = .intersect
            case .except:    calcOp = .difference
            }
            if all {
                diagnostics.append(.annotated(
                    "\(op.rawValue) ALL",
                    "A calculus expression denotes a set, so duplicates cannot be preserved."))
            }

            emitStep(title: "Left branch", clause: op.rawValue,
                     explanation: "Translate the first sub-query on its own.",
                     expression: lhs)
            emitStep(title: "Right branch", clause: op.rawValue,
                     explanation: "Translate the second sub-query on its own.",
                     expression: rhs)

            if let merged = merge(calcOp, lhs, rhs) {
                let connective = calcOp == .union ? CalcSymbol.or : CalcSymbol.and
                emitStep(title: "Combine (\(connective))", clause: op.rawValue,
                         explanation: mergeExplanation(calcOp),
                         expression: .query(merged))
                return .query(merged)
            }

            diagnostics.append(.info(
                op.rawValue,
                "The branches differ in shape (or carry operators the calculus cannot express), " +
                "so they are shown as a set operation on two expressions rather than merged " +
                "into one formula."))
            let composed = CalcExpression.setOperation(op: calcOp, left: lhs, right: rhs)
            emitStep(title: "Combine (\(calcOp.glyph))", clause: op.rawValue,
                     explanation: "Apply the set operation to the two results.",
                     expression: composed)
            return composed

        case let .with(ctes, body):
            for cte in ctes {
                let expression = nested { build(cte.query, outer: outer) }
                definitions.append(CalcDefinition(name: cte.name, expression: expression))
                emitStep(title: "Common table expression", clause: "WITH \(cte.name)",
                         explanation: "Define '\(cte.name)'. It is referenced as a relation below.",
                         expression: expression)
            }
            return build(body, outer: outer)
        }
    }

    // MARK: - Set-operation merging

    /// Merge two branches into a single formula over shared result variables:
    /// `{ ⟨a⟩ | ∃t ( X(t) ∧ t.a = a ) ∨ ∃u ( Y(u) ∧ u.a = a ) }`.
    ///
    /// Returns `nil` when the branches cannot be lined up — different result
    /// arities, or operators (sort, grouping, a nested set operation) that have
    /// no place inside a formula.
    private func merge(_ op: CalcSetOperator,
                       _ left: CalcExpression, _ right: CalcExpression) -> CalcQuery? {
        guard case let .query(lq) = left, case let .query(rq) = right,
              lq.extensions.isEmpty, rq.extensions.isEmpty,
              !lq.result.isEmpty, lq.result.count == rq.result.count else { return nil }

        let resultVars = lq.result.enumerated().map { index, column in
            allocate(preferred: column.name ?? outputName(of: column.term) ?? "a\(TRCBuilder.subscriptNumber(index + 1))",
                     relation: nil)
        }

        let leftSide = branchFormula(lq, resultVars: resultVars)
        let rightSide = branchFormula(rq, resultVars: resultVars)

        let formula: CalcFormula
        switch op {
        case .union:      formula = .disjunction([leftSide, rightSide])
        case .intersect:  formula = .conjunction([leftSide, rightSide])
        // The positive left side range-restricts the result variables, which is
        // what keeps the negated right side safe.
        case .difference: formula = .conjunction([leftSide, .not(rightSide)])
        }

        return CalcQuery(dialect: .trc,
                         result: resultVars.map { ResultColumn(term: .variable($0)) },
                         formula: formula,
                         resultStyle: .tuple)
    }

    /// One branch of a merged set operation: its own formula, plus an equality
    /// binding each of its output columns to the shared result variable, with
    /// everything it declared quantified away.
    private func branchFormula(_ query: CalcQuery, resultVars: [CalcVar]) -> CalcFormula {
        var parts = query.formula.conjuncts
        for (index, column) in query.result.enumerated() {
            parts.append(.comparison(lhs: column.term, op: "=", rhs: .variable(resultVars[index])))
        }
        let body = CalcFormula.conjunction(parts)
        let shared = Set(resultVars)
        // Only free variables get quantified here: anything already under an ∃
        // inside the branch must not be bound a second time.
        let free = body.freeVariables
        let declared = orderedVariables(of: body).filter { free.contains($0) && !shared.contains($0) }
        return declared.isEmpty ? body : .exists(declared, body)
    }

    private func mergeExplanation(_ op: CalcSetOperator) -> String {
        switch op {
        case .union:
            return "Both branches feed the same result variables, so the union is a disjunction: " +
                   "a tuple qualifies if either side produces it."
        case .intersect:
            return "Both branches must produce the same tuple, so the intersection is a conjunction."
        case .difference:
            return "Keep tuples the first branch produces and the second does not — a conjunction " +
                   "with a negation. The positive side range-restricts the result variables, which " +
                   "is what keeps the negation safe."
        }
    }

    private func outputName(of term: CalcTerm) -> String? {
        switch term {
        case let .attribute(_, name): return name
        case let .variable(v):        return v.name
        default:                      return nil
        }
    }

    // MARK: SELECT

    private func buildSelect(_ stmt: SelectStatement, outer: TupleScope) -> CalcQuery {
        if isGrouped(stmt) {
            return buildGroupedSelect(stmt, outer: outer)
        }
        var scope = TupleScope(nestedIn: outer)
        var conjuncts: [CalcFormula] = []
        let renderer = CalcRenderer()

        // 1. FROM and JOIN declare one tuple variable per relation. A comma in
        //    FROM is the cartesian product, and needs no operator here: two
        //    unrelated atoms in a conjunction already mean every combination.
        for table in stmt.from {
            conjuncts.append(atom(for: table, into: &scope))
        }
        let fromAtoms = conjuncts
        emitStep(title: "Range variables", clause: "FROM",
                 explanation: rangeVariableExplanation(scope.localVariables, commaJoined: stmt.from.count > 1),
                 expression: snapshot(conjuncts, result: []),
                 added: fromAtoms.map { renderer.inline($0) }.joined(separator: "  "))

        for join in stmt.joins {
            let joinedAtom = atom(for: join.table, into: &scope)
            let conditions = joinConditions(join, scope: scope)
            conjuncts.append(joinedAtom)
            conjuncts.append(contentsOf: conditions)
            let added = ([joinedAtom] + conditions).map { renderer.inline($0) }.joined(separator: "  ")
            emitStep(title: "Join", clause: "\(join.kind.rawValue) JOIN",
                     explanation: conditions.isEmpty
                        ? "Add the joined relation. With no condition this is a cartesian product."
                        : "Add the joined relation; its ON condition becomes an ordinary conjunct — " +
                          "a join is a cross product with a condition, and the calculus writes it that way.",
                     expression: snapshot(conjuncts, result: []), added: added)
        }

        // 2. WHERE conjoins onto the same formula.
        if let whereClause = stmt.whereClause {
            let condition = formula(whereClause, scope: scope)
            conjuncts.append(condition)
            emitStep(title: "Selection", clause: "WHERE",
                     explanation: whereExplanation(condition),
                     expression: snapshot(conjuncts, result: []),
                     added: renderer.inline(condition))
        }

        // 3. The SELECT list becomes the result specification.
        let result = resultColumns(stmt, scope: scope)
        emitStep(title: "Result specification", clause: "SELECT",
                 explanation: "The SELECT list becomes the terms to the left of the bar — what the " +
                              "expression denotes, rather than an operator applied to a relation.",
                 expression: snapshot(conjuncts, result: result),
                 added: result.map { $0.term.plainText }.joined(separator: ", "))

        // 4. Everything SQL asks for that first-order calculus cannot express.
        let extensions = self.extensions(stmt)
        noteFidelity(of: stmt)

        // 5. Variables the result does not export are existentially quantified,
        //    over just the conjuncts that mention them.
        let unquantified = CalcFormula.conjunction(conjuncts)
        let body = quantifyNonResultVariables(unquantified, result: result)
        let query = CalcQuery(dialect: .trc, result: result, formula: body, extensions: extensions)

        if body != unquantified {
            let bound = unquantified.freeVariables
                .subtracting(result.reduce(into: Set<CalcVar>()) { $0.formUnion($1.term.variables) })
            emitStep(title: "Quantification", clause: "SELECT",
                     explanation: "Variables the result does not export are existentially " +
                                  "quantified, over only the conjuncts that mention them: " +
                                  "\(list(bound)) appear\(bound.count == 1 ? "s" : "") in the " +
                                  "condition but not in the answer.",
                     expression: .query(query))
        } else if !extensions.isEmpty {
            emitStep(title: "Outside the calculus", clause: extensions.map(\.rendered).joined(separator: ", "),
                     explanation: "These operators have no first-order expression, so they are " +
                                  "annotated outside the braces rather than faked inside them.",
                     expression: .query(query))
        }

        return query
    }

    /// Whether the query aggregates: an explicit GROUP BY, or an aggregate in
    /// the SELECT list or HAVING, either of which collapses rows into groups.
    private func isGrouped(_ stmt: SelectStatement) -> Bool {
        !stmt.groupBy.isEmpty
            || stmt.projections.contains { $0.isAggregate }
            || stmt.having?.containsAggregate == true
    }

    // MARK: - Grouping and aggregation

    /// Aggregation has no first-order expression, so this uses the documented
    /// extension: a result variable bound to an aggregate over a set
    /// comprehension, with the grouping columns tying each comprehension to its
    /// own group.
    ///
    ///     { ⟨d, h⟩ | ∃u ( Employee(u) ∧ u.dept_id = d )
    ///                ∧ h = COUNT{ u | Employee(u) ∧ u.dept_id = d }
    ///                ∧ h > 5 }
    ///
    /// The comprehension is where WHERE lands and the outer formula is where
    /// HAVING lands — which is exactly the difference between the two clauses.
    private func buildGroupedSelect(_ stmt: SelectStatement, outer: TupleScope) -> CalcQuery {
        let source = buildSourceBlock(stmt, outer: outer)
        let renderer = CalcRenderer()

        diagnostics.append(.extended(
            "GROUP BY / aggregates",
            "First-order relational calculus has no aggregation. This uses the usual extension — " +
            "an aggregate over a set comprehension — with one comprehension per group."))

        emitStep(title: "Range variables", clause: "FROM",
                 explanation: rangeVariableExplanation(source.scope.localVariables,
                                                       commaJoined: stmt.from.count > 1) +
                              " These become the comprehension's own variables below.",
                 expression: snapshot(source.conjuncts, result: []),
                 added: source.conjuncts.map { renderer.inline($0) }.joined(separator: "  "))

        // One fresh result variable per grouping column, tying the group's
        // identity to the comprehensions that describe it.
        let groupingTerms = stmt.groupBy.map { term($0, scope: source.scope) }
        let groupingVars = groupingTerms.map {
            allocate(preferred: mnemonic(for: $0), relation: nil)
        }
        let groupEqualities: [CalcFormula] = zip(groupingTerms, groupingVars).map {
            .comparison(lhs: $0, op: "=", rhs: .variable($1))
        }
        let membership = CalcFormula.conjunction(source.conjuncts + groupEqualities)

        var conjuncts: [CalcFormula] = []
        // A group exists when some tuple falls in it. With no GROUP BY there is
        // exactly one group — the whole relation — and nothing to enumerate.
        if !groupingVars.isEmpty {
            conjuncts.append(.exists(source.scope.localVariables, membership))
            emitStep(title: "Group identity", clause: "GROUP BY",
                     explanation: "Each grouping column becomes a result variable, and a group " +
                                  "exists exactly when some tuple falls in it.",
                     expression: snapshot(conjuncts, result: []),
                     added: groupEqualities.map { renderer.inline($0) }.joined(separator: "  "))
        }

        // Each distinct aggregate gets a result variable bound to its own
        // comprehension over the same source.
        var bindings: [String: CalcVar] = [:]
        var result: [ResultColumn] = []

        for item in stmt.projections {
            guard case let .expression(expr, alias) = item else {
                result.append(ResultColumn(term: .opaque(item.attributeLabel)))
                continue
            }
            if expr.containsAggregate {
                let variable = bindAggregate(expr, alias: alias, source: source,
                                             membership: membership,
                                             conjuncts: &conjuncts, bindings: &bindings)
                result.append(ResultColumn(term: .variable(variable), name: alias))
                continue
            }
            // A grouping column projects the variable that stands for it.
            let projected = term(expr, scope: source.scope)
            if let index = groupingTerms.firstIndex(of: projected) {
                result.append(ResultColumn(term: .variable(groupingVars[index]), name: alias))
            } else {
                diagnostics.append(.annotated(
                    projected.plainText,
                    "'\(projected.plainText)' is neither grouped nor aggregated, so it has no " +
                    "single value within a group."))
                result.append(ResultColumn(term: projected, name: alias))
            }
        }

        if !bindings.isEmpty {
            emitStep(title: "Aggregates", clause: "SELECT",
                     explanation: "Each aggregate becomes a result variable bound to a comprehension " +
                                  "over the group. WHERE is inside the comprehension; HAVING will " +
                                  "conjoin outside it.",
                     expression: snapshot(conjuncts, result: result),
                     added: conjuncts.compactMap { conjunct -> String? in
                         if case .comparison = conjunct { return renderer.inline(conjunct) }
                         return nil
                     }.joined(separator: "  "))
        }

        // HAVING filters groups, so it conjoins outside every comprehension —
        // referring to the aggregate variables rather than recomputing them.
        if let having = stmt.having {
            let condition = havingFormula(having, source: source, membership: membership,
                                          conjuncts: &conjuncts, bindings: &bindings)
            conjuncts.append(condition)
            emitStep(title: "Group selection", clause: "HAVING",
                     explanation: "HAVING conjoins onto the outer formula, filtering whole groups. " +
                                  "That it lands here and WHERE lands inside the comprehension is " +
                                  "the whole difference between the two clauses.",
                     expression: snapshot(conjuncts, result: result),
                     added: renderer.inline(condition))
        }

        let extensions = self.extensions(stmt, includeGrouping: false)
        noteSortAndLimit(stmt)

        return CalcQuery(dialect: .trc, result: result,
                         formula: CalcFormula.conjunction(conjuncts),
                         resultStyle: .tuple, extensions: extensions)
    }

    /// Bind one aggregate to a result variable, reusing the binding when the
    /// same aggregate appears twice (in the SELECT list and again in HAVING).
    private func bindAggregate(_ expr: Expression, alias: String?,
                               source: SourceBlock, membership: CalcFormula,
                               conjuncts: inout [CalcFormula],
                               bindings: inout [String: CalcVar]) -> CalcVar {
        let key = expr.rendered
        if let existing = bindings[key] { return existing }

        let variable = allocate(preferred: alias ?? shortName(for: aggregateFunction(of: expr)),
                                relation: nil)
        bindings[key] = variable
        conjuncts.append(aggregateBinding(expr, result: variable,
                                          source: source, membership: membership))
        return variable
    }

    private func aggregateFunction(of expr: Expression) -> String {
        guard case let .function(name, _, _) = expr else { return expr.rendered }
        return name.uppercased()
    }

    private func aggregateBinding(_ expr: Expression, result: CalcVar, source: SourceBlock,
                                  membership: CalcFormula) -> CalcFormula {
        guard case let .function(name, args, distinct) = expr else {
            // An aggregate wrapped in arithmetic — kept whole rather than split,
            // since splitting it would change what is being averaged.
            return .aggregateBinding(result: result, function: expr.rendered, distinct: false,
                                     element: nil, variables: source.scope.localVariables,
                                     condition: membership)
        }
        // COUNT(*) counts tuples; every other aggregate collects a value.
        let element: CalcTerm?
        if args.count == 1, case .star = args[0] {
            element = nil
        } else {
            element = args.first.map { term($0, scope: source.scope) }
        }
        return .aggregateBinding(result: result, function: name.uppercased(), distinct: distinct,
                                 element: element, variables: source.scope.localVariables,
                                 condition: membership)
    }

    /// Translate HAVING, replacing each aggregate with the variable already
    /// bound to it (or binding a new one).
    private func havingFormula(_ expr: Expression, source: SourceBlock, membership: CalcFormula,
                               conjuncts: inout [CalcFormula],
                               bindings: inout [String: CalcVar]) -> CalcFormula {
        switch expr {
        case let .binary(op, lhs, rhs):
            let keyword = op.uppercased()
            if keyword == "AND" {
                return .conjunction([havingFormula(lhs, source: source, membership: membership,
                                                   conjuncts: &conjuncts, bindings: &bindings),
                                     havingFormula(rhs, source: source, membership: membership,
                                                   conjuncts: &conjuncts, bindings: &bindings)])
            }
            if keyword == "OR" {
                return .disjunction([havingFormula(lhs, source: source, membership: membership,
                                                   conjuncts: &conjuncts, bindings: &bindings),
                                     havingFormula(rhs, source: source, membership: membership,
                                                   conjuncts: &conjuncts, bindings: &bindings)])
            }
            if TRCBuilder.comparisonOperators.contains(op) {
                return .comparison(
                    lhs: havingTerm(lhs, source: source, membership: membership,
                                    conjuncts: &conjuncts, bindings: &bindings),
                    op: TRCBuilder.canonical(op),
                    rhs: havingTerm(rhs, source: source, membership: membership,
                                    conjuncts: &conjuncts, bindings: &bindings))
            }
            return .predicate(rendered: expr.rendered, terms: [])

        case let .paren(inner):
            return havingFormula(inner, source: source, membership: membership,
                                 conjuncts: &conjuncts, bindings: &bindings)
        case let .unary(op, operand) where op.uppercased() == "NOT":
            return .not(havingFormula(operand, source: source, membership: membership,
                                      conjuncts: &conjuncts, bindings: &bindings))
        default:
            return formula(expr, scope: source.scope)
        }
    }

    private func havingTerm(_ expr: Expression, source: SourceBlock, membership: CalcFormula,
                            conjuncts: inout [CalcFormula],
                            bindings: inout [String: CalcVar]) -> CalcTerm {
        guard expr.containsAggregate else { return term(expr, scope: source.scope) }
        return .variable(bindAggregate(expr, alias: nil, source: source, membership: membership,
                                       conjuncts: &conjuncts, bindings: &bindings))
    }

    /// A one-letter stand-in taken from the column being grouped on:
    /// `dept_id` → `d`. Long enough to recognise, short enough to read.
    private func mnemonic(for term: CalcTerm) -> String {
        guard let name = outputName(of: term) else { return "g" }
        let letters = name.lowercased().filter { $0.isLetter }
        return letters.isEmpty ? "g" : String(letters.first!)
    }

    private func shortName(for function: String) -> String {
        switch function.uppercased() {
        case "COUNT": return "c"
        case "SUM":   return "s"
        case "AVG":   return "a"
        case "MIN":   return "mn"
        case "MAX":   return "mx"
        default:      return "v"
        }
    }

    // MARK: - The FROM / JOIN / WHERE block both paths share

    struct SourceBlock {
        var scope: TupleScope
        var conjuncts: [CalcFormula]
    }

    private func buildSourceBlock(_ stmt: SelectStatement, outer: TupleScope) -> SourceBlock {
        var scope = TupleScope(nestedIn: outer)
        var conjuncts: [CalcFormula] = []
        for table in stmt.from {
            conjuncts.append(atom(for: table, into: &scope))
        }
        for join in stmt.joins {
            conjuncts.append(atom(for: join.table, into: &scope))
            conjuncts.append(contentsOf: joinConditions(join, scope: scope))
        }
        if let whereClause = stmt.whereClause {
            conjuncts.append(formula(whereClause, scope: scope))
        }
        return SourceBlock(scope: scope, conjuncts: conjuncts)
    }

    private func rangeVariableExplanation(_ variables: [CalcVar], commaJoined: Bool) -> String {
        let names = list(variables)
        let base = variables.count == 1
            ? "Declare the tuple variable \(names), ranging over the relation in FROM. " +
              "A SQL alias already is a tuple variable, so the alias is used verbatim."
            : "Declare one tuple variable per FROM entry: \(names)."
        guard commaJoined else { return base }
        return base + " A comma join needs no operator here — two unrelated atoms in one " +
                      "conjunction already mean every combination of their rows."
    }

    private func whereExplanation(_ condition: CalcFormula) -> String {
        if condition.containsQuantifier {
            return "The WHERE predicate is conjoined. Its sub-query becomes a quantifier — this is " +
                   "what the calculus can say and the algebra cannot, which has no ∃ or ∀ at all."
        }
        return "The WHERE predicate is conjoined onto the same formula. There is no separate " +
               "selection operator: filtering is just another condition."
    }

    private func list(_ variables: [CalcVar]) -> String { list(Set(variables)) }

    private func list(_ variables: Set<CalcVar>) -> String {
        let names = variables.map(\.name).sorted()
        guard names.count > 1 else { return names.first ?? "none" }
        return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
    }

    // MARK: FROM / JOIN

    private func atom(for table: TableRef, into scope: inout TupleScope) -> CalcFormula {
        switch table {
        case let .named(name, alias):
            // A SQL alias already *is* a tuple variable, so it is used verbatim.
            let variable = allocate(preferred: alias ?? initial(of: name), relation: name)
            scope.bind(name: alias ?? name, to: variable)
            if let alias, alias != name { scope.bind(name: name, to: variable) }
            return relationAtom(name, variable)

        case let .derived(_, alias):
            let name = alias ?? "(sub-query)"
            if alias == nil {
                diagnostics.append(.annotated(
                    "FROM (sub-query)",
                    "A derived table without an alias cannot be named as a relation."))
            }
            diagnostics.append(.annotated(
                "FROM (sub-query) AS \(name)",
                "The sub-query is treated as a relation named '\(name)'; its own derivation " +
                "is not expanded in this view."))
            let variable = allocate(preferred: initial(of: name), relation: name)
            scope.bind(name: name, to: variable)
            return relationAtom(name, variable)
        }
    }

    private func relationAtom(_ relation: String, _ variable: CalcVar) -> CalcFormula {
        // A TRC atom names one tuple variable, so its term list is complete
        // whatever the schema knows. Positional completeness is DRC's problem,
        // and the lowering reads the schema directly rather than this flag.
        .relationAtom(relation: relation, terms: [.variable(variable)], arityKnown: true)
    }

    private func joinConditions(_ join: Join, scope: TupleScope) -> [CalcFormula] {
        switch join.kind {
        case .cross:
            break
        case .left, .right, .full:
            diagnostics.append(.annotated(
                "\(join.kind.rawValue) JOIN",
                "Outer joins invent null-padded rows, which first-order calculus cannot do. " +
                "Shown as an inner join; the padding is not expressed."))
        case .inner:
            break
        }

        if let on = join.on {
            return [formula(on, scope: scope)]
        }
        if !join.using.isEmpty {
            // USING (a, b) is an equality between the two most recently bound
            // variables on each shared column.
            let variables = scope.localVariables
            guard variables.count >= 2 else { return [] }
            let right = variables[variables.count - 1]
            let left = variables[variables.count - 2]
            return join.using.map { column -> CalcFormula in
                .comparison(lhs: .attribute(left, column), op: "=", rhs: .attribute(right, column))
            }
        }
        return []
    }

    // MARK: SELECT list

    private func resultColumns(_ stmt: SelectStatement, scope: TupleScope) -> [ResultColumn] {
        var columns: [ResultColumn] = []
        for item in stmt.projections {
            switch item {
            case .star:
                columns.append(contentsOf: expandStar(over: scope.localVariables))
            case let .qualifiedStar(qualifier):
                if let variable = scope.variable(forQualifier: qualifier) {
                    columns.append(contentsOf: expandStar(over: [variable]))
                } else {
                    columns.append(ResultColumn(term: .opaque("\(qualifier).*")))
                }
            case let .expression(expr, alias):
                columns.append(ResultColumn(term: term(expr, scope: scope), name: alias))
            }
        }
        return columns
    }

    /// `SELECT *` names every attribute of every relation in scope. When the
    /// schema for one of them was only inferred, the expansion is incomplete —
    /// so the whole tuple variable is projected instead of a partial list.
    private func expandStar(over variables: [CalcVar]) -> [ResultColumn] {
        var columns: [ResultColumn] = []
        for variable in variables {
            guard let relation = variable.relation,
                  let known = schema.schema(for: relation), !known.attributes.isEmpty else {
                diagnostics.append(.annotated(
                    "SELECT *",
                    "No columns of '\(variable.relation ?? variable.name)' are named anywhere in " +
                    "the query, so * projects the whole tuple."))
                columns.append(ResultColumn(term: .variable(variable)))
                continue
            }
            if !known.arityKnown {
                diagnostics.append(.annotated(
                    "SELECT *",
                    "'\(relation)' has \(known.attributes.count) attribute(s) inferred from this " +
                    "query; * may name more columns than are shown."))
            }
            columns.append(contentsOf: known.attributes.map {
                ResultColumn(term: .attribute(variable, $0))
            })
        }
        return columns
    }

    // MARK: Extensions and fidelity

    private func extensions(_ stmt: SelectStatement,
                            includeGrouping: Bool = true) -> [CalcExtension] {
        var result: [CalcExtension] = []

        let grouping = stmt.groupBy.map { $0.rendered }
        // A GROUPING SETS / ROLLUP / CUBE modifier produces several groupings at
        // once, which one set of grouping variables cannot express.
        if !grouping.isEmpty, includeGrouping || stmt.groupByModifier != nil {
            let rendered = stmt.groupByModifier.map { "\($0)(\(grouping.joined(separator: ", ")))" }
                ?? grouping.joined(separator: ", ")
            result.append(CalcExtension(kind: .grouping, rendered: "group by \(rendered)"))
        }
        if let having = stmt.having, includeGrouping {
            result.append(CalcExtension(kind: .having, rendered: "having \(having.rendered)"))
        }
        if !stmt.orderBy.isEmpty {
            let keys = stmt.orderBy.map { "\($0.expression.rendered) \($0.descending ? "↓" : "↑")" }
            result.append(CalcExtension(kind: .sort, rendered: "sort by \(keys.joined(separator: ", "))"))
        }
        if let limit = stmt.limit {
            result.append(CalcExtension(kind: .limit, rendered: "limit \(limit)"))
        }
        return result
    }

    private func noteFidelity(of stmt: SelectStatement) {
        if stmt.distinct {
            diagnostics.append(.info(
                "DISTINCT",
                "No operator needed: a calculus expression denotes a set, so duplicates never " +
                "arise. The algebra needs δ here; the calculus does not."))
        }
        noteSortAndLimit(stmt)
    }

    private func noteSortAndLimit(_ stmt: SelectStatement) {
        if let modifier = stmt.groupByModifier {
            diagnostics.append(.annotated(
                "GROUP BY \(modifier)",
                "\(modifier) produces several groupings at once, which one set of grouping " +
                "variables cannot express; shown as an annotation instead."))
        }
        if !stmt.orderBy.isEmpty {
            diagnostics.append(.annotated(
                "ORDER BY",
                "A calculus expression denotes an unordered set; the sort is shown outside it."))
        }
        if stmt.limit != nil {
            diagnostics.append(.annotated(
                "LIMIT / FETCH FIRST",
                "Row limits have no expression in the calculus; shown outside the braces."))
        }
    }

    // MARK: Quantification

    /// Existentially quantify every variable the result specification does not
    /// export, scoping each quantifier over just the conjuncts that mention it.
    ///
    /// This is what turns the mechanical `∃d ( Employee(e) ∧ Department(d) ∧ … )`
    /// into the idiomatic `Employee(e) ∧ ∃d ( Department(d) ∧ … )`.
    private func quantifyNonResultVariables(_ body: CalcFormula,
                                            result: [ResultColumn]) -> CalcFormula {
        let free = result.reduce(into: Set<CalcVar>()) { $0.formUnion($1.term.variables) }
        let conjuncts = body.conjuncts
        guard !conjuncts.isEmpty else { return body }

        // Free variables only. A sub-query expanded into `∃u ( … )` has already
        // bound `u`, and quantifying it again here would capture it twice.
        let bound = body.freeVariables.subtracting(free)
        guard !bound.isEmpty else { return body }

        var outerParts: [CalcFormula] = []
        var innerParts: [CalcFormula] = []
        for conjunct in conjuncts {
            if conjunct.freeVariables.isDisjoint(with: bound) {
                outerParts.append(conjunct)
            } else {
                innerParts.append(conjunct)
            }
        }
        guard !innerParts.isEmpty else { return body }

        let innerFormula = CalcFormula.conjunction(innerParts)
        // Quantify in declaration order so the formula reads the way it was built.
        let quantified = orderedVariables(of: innerFormula).filter { bound.contains($0) }
        guard !quantified.isEmpty else { return body }

        let existential = CalcFormula.exists(quantified, innerFormula)
        return CalcFormula.conjunction(outerParts + [existential])
    }

    /// Variables in first-mention order, so quantifier lists are stable rather
    /// than in whatever order a `Set` happens to iterate.
    private func orderedVariables(of formula: CalcFormula) -> [CalcVar] {
        var seen = Set<CalcVar>()
        var ordered: [CalcVar] = []
        // Declared before `visit` because a local function cannot be referenced
        // before its declaration point.
        func visitTerm(_ t: CalcTerm) {
            for variable in orderedTermVariables(t) where seen.insert(variable).inserted {
                ordered.append(variable)
            }
        }
        func visit(_ f: CalcFormula) {
            switch f {
            case let .relationAtom(_, terms, _):
                terms.forEach { visitTerm($0) }
            case let .comparison(lhs, _, rhs):
                visitTerm(lhs); visitTerm(rhs)
            case let .and(parts), let .or(parts):
                parts.forEach(visit)
            case let .not(inner):
                visit(inner)
            case let .exists(vars, body), let .forAll(vars, body):
                vars.forEach { if seen.insert($0).inserted { ordered.append($0) } }
                visit(body)
            case let .implies(lhs, rhs):
                visit(lhs); visit(rhs)
            case let .predicate(_, terms):
                terms.forEach { visitTerm($0) }
            case let .aggregateBinding(result, _, _, _, _, _):
                if seen.insert(result).inserted { ordered.append(result) }
            case .constant:
                break
            }
        }
        visit(formula)
        return ordered
    }

    private func orderedTermVariables(_ term: CalcTerm) -> [CalcVar] {
        switch term {
        case let .variable(v):           return [v]
        case let .attribute(v, _):       return [v]
        case .literal, .opaque:          return []
        case let .application(_, args, _): return args.flatMap { orderedTermVariables($0) }
        case let .binaryOp(_, lhs, rhs): return orderedTermVariables(lhs) + orderedTermVariables(rhs)
        }
    }

    // MARK: Expressions → formulas

    private func formula(_ expr: Expression, scope: TupleScope) -> CalcFormula {
        switch expr {
        case let .binary(op, lhs, rhs):
            let keyword = op.uppercased()
            if keyword == "AND" {
                return .conjunction([formula(lhs, scope: scope), formula(rhs, scope: scope)])
            }
            if keyword == "OR" {
                return .disjunction([formula(lhs, scope: scope), formula(rhs, scope: scope)])
            }
            if keyword == "LIKE" || keyword == "NOT LIKE" {
                let operand = term(lhs, scope: scope)
                diagnostics.append(.extended(
                    keyword,
                    "Pattern matching is not a relational comparison; kept as a predicate atom."))
                return .predicate(rendered: "\(operand.plainText) \(keyword) \(term(rhs, scope: scope).plainText)",
                                  terms: [operand])
            }
            if TRCBuilder.comparisonOperators.contains(op) {
                if let expanded = scalarSubqueryComparison(op: op, lhs: lhs, rhs: rhs, scope: scope) {
                    return expanded
                }
                return .comparison(lhs: term(lhs, scope: scope),
                                   op: TRCBuilder.canonical(op),
                                   rhs: term(rhs, scope: scope))
            }
            // An arithmetic expression used where a condition was expected.
            return .predicate(rendered: expr.rendered, terms: [term(expr, scope: scope)])

        case let .unary(op, operand):
            if op.uppercased() == "NOT" { return .not(formula(operand, scope: scope)) }
            return .predicate(rendered: expr.rendered, terms: [term(operand, scope: scope)])

        case let .paren(inner):
            return formula(inner, scope: scope)

        case let .between(value, lower, upper, negated):
            let v = term(value, scope: scope)
            let range = CalcFormula.conjunction([
                .comparison(lhs: v, op: "≥", rhs: term(lower, scope: scope)),
                .comparison(lhs: v, op: "≤", rhs: term(upper, scope: scope))
            ])
            return negated ? .not(range) : range

        case let .inList(value, list, negated):
            let v = term(value, scope: scope)
            let options = CalcFormula.disjunction(list.map { option -> CalcFormula in
                .comparison(lhs: v, op: "=", rhs: term(option, scope: scope))
            })
            return negated ? .not(options) : options

        case let .isNull(inner, negated):
            let operand = term(inner, scope: scope)
            diagnostics.append(.extended(
                "IS NULL",
                "The pure calculus is two-valued and has no nulls; kept as a predicate atom."))
            return .predicate(rendered: "\(operand.plainText) IS \(negated ? "NOT " : "")NULL",
                              terms: [operand])

        case let .exists(query, negated):
            let construct = negated ? "NOT EXISTS" : "EXISTS"
            guard let block = subqueryBlock(query, outer: scope, construct: construct),
                  !block.variables.isEmpty else {
                return opaqueSubquery(rendered: "\(negated ? "¬" : "")∃ (…)", terms: [])
            }
            let quantified = CalcFormula.exists(block.variables, block.formula)
            return negated ? .not(quantified) : quantified

        case let .inSubquery(value, query, negated):
            let construct = negated ? "NOT IN (sub-query)" : "IN (sub-query)"
            let v = term(value, scope: scope)
            guard let block = subqueryBlock(query, outer: scope, construct: construct),
                  let output = block.singleOutput(construct: construct, report: &diagnostics),
                  !block.variables.isEmpty else {
                return opaqueSubquery(rendered: "\(v.plainText) \(negated ? "∉" : "∈") (…)", terms: [v])
            }
            // `x IN (SELECT y …)` is `∃u ( … ∧ u.y = x )`.
            let body = CalcFormula.conjunction([block.formula,
                                                .comparison(lhs: output, op: "=", rhs: v)])
            let quantified = CalcFormula.exists(block.variables, body)
            return negated ? .not(quantified) : quantified

        case let .quantifiedComparison(value, op, quantifier, query):
            let construct = "\(op) \(quantifier.rawValue) (sub-query)"
            let v = term(value, scope: scope)
            guard let block = subqueryBlock(query, outer: scope, construct: construct),
                  let output = block.singleOutput(construct: construct, report: &diagnostics),
                  !block.variables.isEmpty else {
                return opaqueSubquery(
                    rendered: "\(v.plainText) \(op) \(quantifier.rawValue) (…)", terms: [v])
            }
            let comparison = CalcFormula.comparison(lhs: v, op: TRCBuilder.canonical(op), rhs: output)
            switch quantifier {
            case .all:
                // Every row of the sub-query must satisfy it: a guarded ∀.
                return .forAll(block.variables, .implies(block.formula, comparison))
            case .any:
                return .exists(block.variables, .conjunction([block.formula, comparison]))
            }

        case let .boolLiteral(value):
            return .constant(value)

        case let .function(_, args, _):
            return .predicate(rendered: expr.rendered,
                              terms: args.map { term($0, scope: scope) })

        default:
            // A value used where a condition was expected: a bare column, a
            // CASE, a window function. It has no boolean structure to translate,
            // so it stays an atom — and says so.
            diagnostics.append(.annotated(
                "value as a condition",
                "'\(expr.rendered)' has no boolean structure the calculus can take apart; kept as " +
                "an opaque atom."))
            return .predicate(rendered: expr.rendered, terms: [term(expr, scope: scope)])
        }
    }

    // MARK: - Sub-queries → quantifiers

    /// A sub-query lowered into something a quantifier can bind: the tuple
    /// variables it declares, the formula over them, and the terms its select
    /// list publishes.
    private struct SubqueryBlock {
        var variables: [CalcVar]
        var formula: CalcFormula
        var outputs: [CalcTerm]

        /// The single column a membership or comparison test needs. A `*` or a
        /// multi-column select list has no such column, and guessing one would
        /// silently change the predicate.
        func singleOutput(construct: String, report diagnostics: inout [CalcDiagnostic]) -> CalcTerm? {
            guard outputs.count == 1 else {
                diagnostics.append(.annotated(
                    construct,
                    outputs.isEmpty
                        ? "The sub-query selects * , so the column being compared cannot be named."
                        : "The sub-query selects \(outputs.count) columns; a comparison needs one."))
                return nil
            }
            return outputs[0]
        }
    }

    /// Lower a sub-query for use inside a quantifier, in a scope nested in the
    /// caller's — which is what makes a correlated reference correlated: a
    /// column resolving to an enclosing variable simply keeps referring to it.
    ///
    /// Returns `nil` for a sub-query carrying anything that cannot live inside a
    /// formula, in which case the caller keeps it opaque and the reason is
    /// reported rather than swallowed.
    private func subqueryBlock(_ query: SQLQuery, outer: TupleScope,
                               construct: String) -> SubqueryBlock? {
        guard case let .select(stmt) = query else {
            diagnostics.append(.annotated(
                construct,
                "The sub-query is a set operation or a WITH block; only a plain SELECT can be " +
                "expanded into a quantifier."))
            return nil
        }
        guard stmt.groupBy.isEmpty, stmt.having == nil, stmt.orderBy.isEmpty, stmt.limit == nil,
              !stmt.projections.contains(where: { $0.isAggregate }) else {
            diagnostics.append(.annotated(
                construct,
                "The sub-query has its own grouping, sort or row limit, none of which can appear " +
                "inside a formula; kept as an opaque atom."))
            return nil
        }
        guard !stmt.from.isEmpty else { return nil }

        var scope = TupleScope(nestedIn: outer)
        var conjuncts: [CalcFormula] = []
        for table in stmt.from {
            conjuncts.append(atom(for: table, into: &scope))
        }
        for join in stmt.joins {
            conjuncts.append(atom(for: join.table, into: &scope))
            conjuncts.append(contentsOf: joinConditions(join, scope: scope))
        }
        if let whereClause = stmt.whereClause {
            conjuncts.append(formula(whereClause, scope: scope))
        }

        let outputs: [CalcTerm] = stmt.projections.compactMap { item in
            guard case let .expression(expr, _) = item else { return nil }
            return term(expr, scope: scope)
        }
        // A select list of only `*` publishes no nameable column.
        let publishesStar = stmt.projections.contains { item -> Bool in
            if case .expression = item { return false }
            return true
        }

        return SubqueryBlock(variables: scope.localVariables,
                             formula: CalcFormula.conjunction(conjuncts),
                             outputs: publishesStar ? [] : outputs)
    }

    /// `x = (SELECT y FROM R WHERE p)` on either side of the operator.
    private func scalarSubqueryComparison(op: String, lhs: Expression, rhs: Expression,
                                          scope: TupleScope) -> CalcFormula? {
        if let query = subquery(in: rhs) {
            return scalarComparison(value: lhs, op: op, query: query, flipped: false, scope: scope)
        }
        if let query = subquery(in: lhs) {
            return scalarComparison(value: rhs, op: op, query: query, flipped: true, scope: scope)
        }
        return nil
    }

    private func scalarComparison(value: Expression, op: String, query: SQLQuery,
                                  flipped: Bool, scope: TupleScope) -> CalcFormula? {
        let construct = "\(op) (sub-query)"
        guard let block = subqueryBlock(query, outer: scope, construct: construct),
              let output = block.singleOutput(construct: construct, report: &diagnostics),
              !block.variables.isEmpty else { return nil }
        let v = term(value, scope: scope)
        let comparison: CalcFormula = flipped
            ? .comparison(lhs: output, op: TRCBuilder.canonical(op), rhs: v)
            : .comparison(lhs: v, op: TRCBuilder.canonical(op), rhs: output)
        return .exists(block.variables, .conjunction([block.formula, comparison]))
    }

    private func subquery(in expr: Expression) -> SQLQuery? {
        switch expr {
        case let .subquery(query): return query
        case let .paren(inner):    return subquery(in: inner)
        default:                   return nil
        }
    }

    /// The fallback when a sub-query could not be expanded. The reason has
    /// already been reported by `subqueryBlock`; this only records that the
    /// resulting atom is opaque.
    private func opaqueSubquery(rendered: String, terms: [CalcTerm]) -> CalcFormula {
        .predicate(rendered: rendered, terms: terms)
    }

    // MARK: Expressions → terms

    private func term(_ expr: Expression, scope: TupleScope) -> CalcTerm {
        switch expr {
        case let .column(qualifier, name):
            return columnTerm(qualifier: qualifier, name: name, scope: scope)

        case let .numberLiteral(value):
            return .literal(value)
        case let .stringLiteral(value):
            return .literal("'\(value)'")
        case let .boolLiteral(value):
            return .literal(value ? "TRUE" : "FALSE")
        case .nullLiteral:
            return .literal("NULL")
        case .star:
            return .literal("*")

        case let .paren(inner):
            return term(inner, scope: scope)

        case let .binary(op, lhs, rhs):
            return .binaryOp(op: op, lhs: term(lhs, scope: scope), rhs: term(rhs, scope: scope))

        case let .unary(op, operand):
            return .application(name: op, args: [term(operand, scope: scope)], distinct: false)

        case let .function(name, args, distinct):
            return .application(name: name,
                                args: args.map { term($0, scope: scope) },
                                distinct: distinct)

        case let .list(items):
            return .application(name: "", args: items.map { term($0, scope: scope) }, distinct: false)

        // A cast, a typed literal and an interval are ordinary scalar values.
        // Carrying them verbatim loses nothing, so they need no note.
        case let .cast(inner, type):
            return .application(name: "CAST", args: [term(inner, scope: scope),
                                                     .opaque("AS \(type)")], distinct: false)
        case .typedLiteral, .interval:
            return .literal(expr.rendered)

        case .caseExpression:
            diagnostics.append(.extended(
                "CASE",
                "A conditional expression is not a term of the pure calculus. Written out, it is a " +
                "disjunction of guarded cases; kept verbatim here."))
            return .opaque(expr.rendered)

        case .window:
            diagnostics.append(.annotated(
                "window function",
                "A window function computes over a whole partition of the result, which " +
                "first-order calculus cannot express at all. Kept verbatim; it is not translated."))
            return .opaque(expr.rendered)

        case .subquery:
            diagnostics.append(.annotated(
                "(sub-query) as a value",
                "A sub-query used where a single value is expected is only expanded inside a " +
                "comparison. Here it is kept verbatim rather than turned into a quantifier."))
            return .opaque(expr.rendered)

        // A condition appearing where a value was expected — legal in some
        // dialects, but it is a truth value, not a term of the calculus.
        case .between, .inList, .inSubquery, .exists, .isNull, .quantifiedComparison:
            diagnostics.append(.annotated(
                "condition as a value",
                "'\(expr.rendered)' is a condition used where a value was expected; kept verbatim."))
            return .opaque(expr.rendered)
        }
    }

    private func columnTerm(qualifier: String?, name: String, scope: TupleScope) -> CalcTerm {
        if let qualifier {
            if let variable = scope.variable(forQualifier: qualifier) {
                return .attribute(variable, name)
            }
            diagnostics.append(.annotated(
                "\(qualifier).\(name)",
                "'\(qualifier)' does not name a table or alias in scope."))
            return .opaque("\(qualifier).\(name)")
        }

        let candidates = scope.localVariables
        if candidates.count == 1 {
            return .attribute(candidates[0], name)
        }
        // With several relations in scope, prefer the one whose inferred schema
        // actually has this column — and only when exactly one does.
        let owners = candidates.filter { variable in
            guard let relation = variable.relation else { return false }
            return schema.schema(for: relation)?.has(name) ?? false
        }
        if owners.count == 1 {
            return .attribute(owners[0], name)
        }
        if candidates.isEmpty {
            return .opaque(name)
        }
        diagnostics.append(.annotated(
            name,
            "'\(name)' is unqualified with \(candidates.count) relations in scope, so it could " +
            "not be attributed to one. Qualify it as table.\(name)."))
        return .opaque(name)
    }

    // MARK: Naming

    /// A mnemonic variable name derived from the relation, uniqued against the
    /// names already handed out: Employee → e, a second Employee → e₁.
    private func allocate(preferred: String, relation: String?) -> CalcVar {
        var name = preferred.isEmpty ? "t" : preferred
        if usedNames.contains(name) {
            var suffix = 1
            while usedNames.contains(name + TRCBuilder.subscriptNumber(suffix)) { suffix += 1 }
            name += TRCBuilder.subscriptNumber(suffix)
        }
        usedNames.insert(name)
        return CalcVar(name: name, relation: relation)
    }

    private func initial(of relation: String) -> String {
        let letters = relation.lowercased().filter { $0.isLetter }
        return letters.isEmpty ? "t" : String(letters.first!)
    }

    static func subscriptNumber(_ n: Int) -> String {
        let digits: [Character] = ["₀", "₁", "₂", "₃", "₄", "₅", "₆", "₇", "₈", "₉"]
        return String(String(n).compactMap { c in c.wholeNumberValue.map { digits[$0] } })
    }

    static let comparisonOperators: Set<String> = ["=", "<>", "!=", "<", "<=", ">", ">="]

    /// Prefer the conventional mathematical glyphs where SQL spells them out.
    static func canonical(_ op: String) -> String {
        switch op {
        case "<>", "!=": return "≠"
        case "<=":       return "≤"
        case ">=":       return "≥"
        default:         return op
        }
    }
}
