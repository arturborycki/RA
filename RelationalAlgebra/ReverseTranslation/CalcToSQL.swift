//
//  CalcToSQL.swift
//  RelationalAlgebra
//
//  Tuple or domain relational calculus → SQL.
//
//  SQL is close to tuple calculus already — the forward translator relies on
//  that — so the mapping back is direct:
//
//      Employee(e) at the top          FROM Employee AS e
//      the other top-level conjuncts   WHERE …
//      the result                      SELECT DISTINCT …   (a set, like π)
//      ∃u ( R(u) ∧ φ )                 EXISTS (SELECT * FROM R AS u WHERE φ)
//      ∀u ( R(u) → φ )                 NOT EXISTS (SELECT * FROM R AS u WHERE NOT φ)
//      R(t) ∨ S(t) ranging t           one SELECT per branch, joined by UNION
//
//  Domain calculus is raised to tuple calculus first (`DRCRaising`), so there
//  is one path into SQL, not two.
//
//  An unsafe formula has no SQL at all — no finite query denotes "every tuple
//  not in R" — so the safety checker runs first, and its finding is the
//  answer instead of a query.
//

import Foundation

final class CalcToSQL {

    static func translate(_ script: CalcScript,
                          dialect: SQLDialect = .duckdb) throws -> SQLGeneration {
        let translator = CalcToSQL(script)
        return try translator.run(script, dialect: dialect)
    }

    // MARK: - State

    /// Declared columns, by lower-cased relation name.
    private var declaredColumns: [String: [String]] = [:]
    /// Output columns of each `Name = { … }` definition, once translated.
    private var definitionColumns: [String: [String]] = [:]
    private let names: NameAllocator
    private var diagnostics: [CalcDiagnostic] = []
    /// Value variables bound to an aggregate — `h = COUNT{ … }` — by name. They
    /// stay variables in the formula and become a scalar sub-query wherever
    /// they are read.
    private var aggregateValues: [String: CalcFormula] = [:]
    private var steps: [ReverseStep] = []
    private let renderer = CalcRenderer()
    private let printer = SQLPrinter()

    private init(_ script: CalcScript) {
        for declaration in script.declarations {
            declaredColumns[declaration.name.lowercased()] = declaration.columns
        }
        var taken = script.declarations.map(\.name) + script.definitions.map(\.name)
        for expression in script.definitions.map(\.expression) + [script.expression] {
            taken += CalcToSQL.mentionedNames(expression)
        }
        names = NameAllocator(taken: taken)
    }

    private func columns(of relation: String) -> [String]? {
        definitionColumns[relation.lowercased()] ?? declaredColumns[relation.lowercased()]
    }

    private func record(_ title: String, _ calculus: String, _ sql: String, _ explanation: String) {
        steps.append(ReverseStep(index: steps.count + 1, title: title, algebra: calculus,
                                 sql: sql, explanation: explanation))
    }

    // MARK: - Driver

    private func run(_ script: CalcScript, dialect: SQLDialect) throws -> SQLGeneration {
        try checkSafety(script)

        let raising = script.dialect == .drc
            ? DRCRaising(columns: { [unowned self] in self.columns(of: $0) }, names: names)
            : nil

        var ctes: [CommonTableExpression] = []
        for definition in script.definitions {
            let query = try lower(definition.expression, raising: raising)
            ctes.append(CommonTableExpression(name: definition.name, columns: [], query: query))
            if let outputs = outputColumns(query) {
                definitionColumns[definition.name.lowercased()] = outputs
            }
        }
        var query = try lower(script.expression, raising: raising)
        if !script.ordering.isEmpty || script.limit != nil || script.offset != nil {
            query = try applyingAnnotations(script, to: query)
        }
        if !ctes.isEmpty {
            query = .with(ctes: ctes, body: query)
        }

        if !dialect.allowsDeepCorrelation {
            let rewrite = SQLDecorrelation(columnsOf: { [unowned self] in self.columns(of: $0) },
                                           names: names)
            let (rewritten, changed) = try rewrite.rewrite(query)
            if changed {
                query = rewritten
                note(.info("\(dialect.rawValue): correlation",
                           "\(dialect.rawValue) cannot run a sub-query that refers to a row two " +
                           "levels out, so that row is ranged again one level down and equated " +
                           "to the original, column by column. (A column holding NULL never " +
                           "equals itself, so such rows would not match.)"))
                record("Correlation for \(dialect.rawValue)", "", printer.print(query),
                       "A sub-query nested inside another may refer only to the level directly " +
                       "above it on \(dialect.rawValue), so each row used deeper down is ranged " +
                       "again one level down and equated to the original.")
            }
        }

        diagnostics += raising?.diagnostics ?? []
        note(.info("{ … } → SELECT DISTINCT",
                   "A set-builder expression denotes a set, so the SELECT says DISTINCT: SQL " +
                   "would otherwise keep duplicate rows."))
        return SQLGeneration(query: query, text: printer.print(query),
                             diagnostics: diagnostics, steps: steps)
    }

    private func lower(_ expression: CalcExpression, raising: DRCRaising?) throws -> SQLQuery {
        guard let raising else { return try lower(expression) }
        let raised = try raising.raise(expression)
        record("Domain → tuple variables", renderer.inline(raised), "",
               "SQL has rows, not values on their own: each positional atom R(x, y, …) becomes " +
               "a tuple variable r with R(r), its first occurrence of a variable names r's " +
               "column, and repeated variables and constants become equalities.")
        return try lower(raised)
    }

    private func note(_ diagnostic: CalcDiagnostic) {
        if !diagnostics.contains(diagnostic) { diagnostics.append(diagnostic) }
    }

    /// Unsafe formulas have no SQL; say why instead.
    private func checkSafety(_ script: CalcScript) throws {
        let view = CalcTranslation(dialect: script.dialect, definitions: script.definitions,
                                   root: script.expression, simplified: script.expression,
                                   steps: [], schema: QuerySchema(), diagnostics: [])
        let findings = SafetyChecker.check(view)
        guard let first = findings.first else { return }
        let more = findings.count > 1 ? " (and \(findings.count - 1) more)" : ""
        throw TranslationError(message: "No SQL query means the same thing, because the formula " +
                                        "is unsafe: \(first.message)\(more)")
    }

    // MARK: - Expressions and queries

    private func lower(_ expression: CalcExpression) throws -> SQLQuery {
        switch expression {
        case let .query(query):
            return try lower(query)
        case let .setOperation(op, left, right):
            let sqlOp: SetOperator
            switch op {
            case .union:      sqlOp = .union
            case .intersect:  sqlOp = .intersect
            case .difference: sqlOp = .except
            }
            return .setOperation(sqlOp, left: try lower(left), right: try lower(right), all: false)
        }
    }

    private func lower(_ query: CalcQuery) throws -> SQLQuery {
        if let eliminated = try eliminatingValueVariables(query) { return eliminated }

        let free = Set(query.result.flatMap { $0.term.variables.map(\.name) })
            .union(query.formula.freeVariables.map(\.name))
            .subtracting(aggregateValues.keys)
        var conjuncts = query.formula.conjuncts

        if let i = conjuncts.firstIndex(where: { DRCRaising.rangesDisjunctively($0, free) }),
           case let .or(branches) = conjuncts[i] {
            conjuncts.remove(at: i)
            var parts: [SQLQuery] = []
            for branch in branches {
                var copy = query
                copy.formula = CalcFormula.conjunction(conjuncts + [branch])
                parts.append(try lower(copy))
            }
            let union = parts.dropFirst().reduce(parts[0]) {
                SQLQuery.setOperation(.union, left: $0, right: $1, all: false)
            }
            record("∨ over ranges → UNION", renderer.inline(query), printer.print(union),
                   "Each branch of this ∨ ranges a result variable over a different relation, " +
                   "and one FROM clause cannot do both — so each branch becomes its own SELECT, " +
                   "and UNION combines them.")
            return union
        }

        var scope: [String: String] = [:]
        var stmt = SelectStatement()
        var others: [CalcFormula] = []
        for conjunct in conjuncts {
            if case let (variable, relation)? = CalcToSQL.range(conjunct), free.contains(variable),
               scope[variable] == nil {
                scope[variable] = relation
                stmt.from.append(.named(name: relation, alias: CalcToSQL.alias(variable, relation)))
            } else {
                others.append(conjunct)
            }
        }
        if let unranged = free.subtracting(scope.keys).sorted().first {
            throw TranslationError(message: "\(unranged) is not ranged over a relation at the top " +
                                            "level of the formula. Add an atom such as R(\(unranged)) " +
                                            "beside the other conditions.")
        }

        stmt.distinct = true
        stmt.projections = try query.result.map { try selectItem($0, scope: scope) }
        stmt.whereClause = CalcToSQL.allOf(try others.map { try condition($0, scope: scope) })
        let sql = SQLQuery.select(stmt)
        record("Query", renderer.inline(query), printer.print(sql),
               "Every variable ranged at the top level — R(t) — becomes a FROM entry. The other " +
               "conditions become WHERE, and the result becomes SELECT DISTINCT.")
        return sql
    }

    // MARK: - Value variables

    /// `{ ⟨name⟩ | ∃a ( Author(a) ∧ a.name = name ) ∨ … }` — the general form the
    /// app prints a UNION in. `name` is a value, not a tuple: SQL has nothing
    /// to range it over, only the attribute it is equated to. So: a ∨ that
    /// mentions it becomes a UNION, the ∃ around it is a projection and is
    /// lifted, and `name` is replaced by `a.name`. Nil when there is nothing
    /// to eliminate.
    private func eliminatingValueVariables(_ query: CalcQuery) throws -> SQLQuery? {
        let topRanged = Set(query.formula.conjuncts.compactMap { CalcToSQL.range($0)?.0 })
        let aggregated = query.formula.conjuncts.compactMap { part -> String? in
            if case let .aggregateBinding(result, _, _, _, _, _) = part { return result.name }
            return nil
        }
        let values = Set(query.result.flatMap { column -> [String] in
            if case let .variable(v) = column.term { return [v.name] }
            return []
        }).union(aggregated).subtracting(topRanged).subtracting(aggregateValues.keys)
        guard !values.isEmpty else { return nil }

        var conjuncts = query.formula.conjuncts
        if let i = conjuncts.firstIndex(where: { conjunct in
            guard case .or = conjunct else { return false }
            return !values.isDisjoint(with: conjunct.freeVariables.map(\.name))
        }), case let .or(branches) = conjuncts[i] {
            conjuncts.remove(at: i)
            var parts: [SQLQuery] = []
            for branch in branches {
                var copy = query
                copy.formula = CalcFormula.conjunction(conjuncts + [branch])
                parts.append(try lower(copy))
            }
            let union = parts.dropFirst().reduce(parts[0]) {
                SQLQuery.setOperation(.union, left: $0, right: $1, all: false)
            }
            record("∨ → UNION", renderer.inline(query), printer.print(union),
                   "Each branch of this ∨ finds the result values in a different relation, so " +
                   "each becomes its own SELECT, and UNION combines them.")
            return union
        }

        // An ∃ in a conjunction is a projection: lift it, so its ranges are
        // visible here and its equalities can name the value.
        var lifted: [CalcFormula] = []
        for conjunct in conjuncts {
            if case let .exists(_, body) = conjunct {
                lifted += body.conjuncts
            } else {
                lifted.append(conjunct)
            }
        }

        var copy = query
        // Aggregates last: their conditions mention the other values, which
        // must be replaced by attributes first.
        let aggregates = Set(aggregated)
        for value in values.sorted() where !aggregates.contains(value) {
            guard let i = lifted.firstIndex(where: { CalcToSQL.binding($0, of: value) != nil }),
                  let attribute = CalcToSQL.binding(lifted[i], of: value) else {
                throw TranslationError(message: "\(value) is in the result but neither ranged " +
                                                "over a relation nor equated to an attribute, " +
                                                "such as t.\(value) = \(value).")
            }
            lifted.remove(at: i)
            lifted = lifted.map { $0.substituting(value, with: attribute) }
            copy.result = copy.result.map { column in
                guard case let .variable(v) = column.term, v.name == value else { return column }
                let keepsName: Bool
                if case let .attribute(_, name) = attribute { keepsName = name == value } else { keepsName = false }
                return ResultColumn(term: attribute, name: column.name ?? (keepsName ? nil : value))
            }
        }
        for value in values.sorted() where aggregates.contains(value) {
            guard let i = lifted.firstIndex(where: { part in
                if case let .aggregateBinding(result, _, _, _, _, _) = part { return result.name == value }
                return false
            }) else { continue }
            aggregateValues[value] = lifted.remove(at: i)
            copy.result = copy.result.map { column in
                guard case let .variable(v) = column.term, v.name == value else { return column }
                return ResultColumn(term: column.term, name: column.name ?? value)
            }
        }
        copy.formula = CalcFormula.conjunction(lifted)
        copy.resultStyle = .compact
        return try lower(copy)
    }

    /// `h = SUM{ u.salary | Employee(u) ∧ u.dept_id = t.dept_id }` as the scalar
    /// sub-query `(SELECT SUM(u.salary) FROM Employee AS u WHERE …)`: first-order
    /// calculus has no aggregates, and SQL computes one per row this way, which
    /// is what the comprehension says.
    private func aggregateExpression(_ binding: CalcFormula, scope: [String: String]) throws -> Expression {
        guard case let .aggregateBinding(_, function, distinct, element, variables, body) = binding
        else { return .nullLiteral }
        let names = Set(variables.map(\.name))
        var inner = scope
        var bound: Set<String> = []
        var stmt = SelectStatement()
        var others: [CalcFormula] = []
        for conjunct in body.conjuncts {
            if case let (variable, relation)? = CalcToSQL.range(conjunct), names.contains(variable),
               !bound.contains(variable) {
                bound.insert(variable)
                inner[variable] = relation
                stmt.from.append(.named(name: relation, alias: CalcToSQL.alias(variable, relation)))
            } else {
                others.append(conjunct)
            }
        }
        if let unranged = names.subtracting(bound).sorted().first {
            throw TranslationError(message: "\(unranged) is collected by \(function){ … } but no " +
                                            "relation atom in it ranges \(unranged).")
        }
        let argument = try element.map { try term($0, scope: inner) } ?? .star
        stmt.projections = [.expression(.function(name: function, args: [argument], distinct: distinct),
                                        alias: nil)]
        stmt.whereClause = CalcToSQL.allOf(try others.map { try condition($0, scope: inner) })
        let expression = Expression.subquery(.select(stmt))
        note(.extended("\(function){ … }",
                       "Aggregates are an extension to first-order calculus. Each becomes a " +
                       "sub-query computing the aggregate for the current row."))
        record("\(function){ … } → sub-query", renderer.inline(binding), printer.expression(expression),
               "An aggregate over a set comprehension becomes a scalar sub-query: the " +
               "comprehension's ranges are its FROM, its condition its WHERE, and the collected " +
               "value the aggregate's argument.")
        return expression
    }

    // MARK: - Annotations

    /// `sort by …, limit …  applied to { … }` as ORDER BY and LIMIT — on the
    /// query itself when it can take them, else on a wrapper around it.
    private func applyingAnnotations(_ script: CalcScript, to query: SQLQuery) throws -> SQLQuery {
        let firstResult = CalcToSQL.firstQuery(script.expression).result
        let outputs = CalcToSQL.outputNames(query)
        var plain: SelectStatement? = nil
        if case let .select(stmt) = query, stmt.orderBy.isEmpty, stmt.limit == nil, stmt.offset == nil {
            plain = stmt
        }

        let keys = try script.ordering.map { key -> OrderItem in
            let expression: Expression
            if case let .variable(v) = key.term,
               let i = firstResult.firstIndex(where: { column in
                   if case let .variable(r) = column.term { return r.name == v.name }
                   return false
               }), i < outputs.count, let name = outputs[i] {
                // A result variable sorts by the column it became.
                expression = .column(table: nil, name: name)
            } else if case let .attribute(v, attribute) = key.term {
                expression = .column(table: plain == nil ? nil : v.name, name: attribute)
            } else {
                expression = try term(key.term, scope: [:])
            }
            return OrderItem(expression: expression, descending: key.descending,
                             nullsFirst: key.nullsFirst)
        }

        var stmt: SelectStatement
        if let plain {
            stmt = plain
        } else {
            stmt = SelectStatement()
            stmt.projections = [.star]
            stmt.from = [.derived(query, alias: names.fresh(for: "t"))]
        }
        stmt.orderBy = keys
        stmt.limit = script.limit
        stmt.offset = script.offset
        let result = SQLQuery.select(stmt)
        note(.annotated("sort / limit",
                        "Order and row limits are outside first-order calculus; the annotations " +
                        "outside the braces become ORDER BY and LIMIT on the finished query."))
        record("Annotations → ORDER BY / LIMIT", "", printer.print(result),
               "The annotations written outside the braces apply to the finished query, which " +
               "is where SQL puts ORDER BY and LIMIT.")
        return result
    }

    private static func firstQuery(_ expression: CalcExpression) -> CalcQuery {
        switch expression {
        case let .query(query):            return query
        case let .setOperation(_, left, _): return firstQuery(left)
        }
    }

    /// The name each output column of a query goes by, where it has one.
    private static func outputNames(_ query: SQLQuery) -> [String?] {
        switch query {
        case let .select(stmt):
            return stmt.projections.map { item in
                guard case let .expression(expression, alias) = item else { return nil }
                if let alias { return alias }
                if case let .column(_, name) = expression { return name }
                return nil
            }
        case let .setOperation(_, left, _, _):
            return outputNames(left)
        case let .with(_, body):
            return outputNames(body)
        }
    }

    /// `t.a = value` or `value = t.a`: the attribute a value is equated to.
    private static func binding(_ formula: CalcFormula, of value: String) -> CalcTerm? {
        guard case let .comparison(lhs, "=", rhs) = formula else { return nil }
        if case let .variable(v) = lhs, v.name == value, case .attribute = rhs { return rhs }
        if case let .variable(v) = rhs, v.name == value, case .attribute = lhs { return lhs }
        return nil
    }

    // MARK: - Conditions

    private func condition(_ formula: CalcFormula, scope: [String: String]) throws -> Expression {
        switch formula {
        case let .comparison(lhs, op, rhs):
            let left = try term(lhs, scope: scope)
            switch op {
            case "IS":     return .isNull(left, negated: false)
            case "IS NOT": return .isNull(left, negated: true)
            default:
                return .binary(op: CalcToSQL.sqlOperator(op), lhs: left, rhs: try term(rhs, scope: scope))
            }

        case let .and(parts):
            return CalcToSQL.allOf(try parts.map { try condition($0, scope: scope) })
                ?? .boolLiteral(true)

        case let .or(parts):
            let disjuncts = try parts.map { try condition($0, scope: scope) }
            return disjuncts.dropFirst().reduce(disjuncts[0]) { .binary(op: "OR", lhs: $0, rhs: $1) }

        case let .not(inner):
            if case let .exists(vars, body) = inner {
                return try exists(vars, body, scope: scope, negated: true)
            }
            return .unary(op: "NOT", operand: try condition(inner, scope: scope))

        case let .implies(lhs, rhs):
            return .binary(op: "OR",
                           lhs: .unary(op: "NOT", operand: try condition(lhs, scope: scope)),
                           rhs: try condition(rhs, scope: scope))

        case let .exists(vars, body):
            return try exists(vars, body, scope: scope, negated: false)

        case let .forAll(vars, body):
            let expression = try exists(vars, body.negated, scope: scope, negated: true,
                                        recordStep: false)
            record("∀ → NOT EXISTS", renderer.inline(formula), printer.expression(expression),
                   "∀u ( R(u) → φ ) says no row of R fails φ: NOT EXISTS (SELECT * FROM R AS u " +
                   "WHERE NOT φ). SQL has no ∀, so this double negation is how it is said.")
            return expression

        case let .relationAtom(relation, terms, _):
            return try membership(relation, terms, scope: scope)

        case let .constant(value):
            return .boolLiteral(value)

        case let .predicate(rendered, _):
            return try SQLParser.parseStandaloneExpression(rendered)

        case .aggregateBinding:
            throw TranslationError(message: "An aggregate h = F{ … } belongs at the top level of " +
                                            "a query, beside the other conditions.")
        }
    }

    /// `∃u, v ( … )` as `EXISTS (SELECT * FROM … WHERE …)`.
    private func exists(_ vars: [CalcVar], _ body: CalcFormula, scope: [String: String],
                        negated: Bool, recordStep: Bool = true) throws -> Expression {
        let names = Set(vars.map(\.name))
        var conjuncts = body.conjuncts

        // ∃u ( R(u) ∨ S(u) ) is ∃u R(u) ∨ ∃u S(u): one EXISTS per range.
        if let i = conjuncts.firstIndex(where: { DRCRaising.rangesDisjunctively($0, names) }),
           case let .or(branches) = conjuncts[i] {
            conjuncts.remove(at: i)
            let parts = try branches.map {
                try exists(vars, CalcFormula.conjunction(conjuncts + [$0]), scope: scope,
                           negated: false, recordStep: recordStep)
            }
            let any = parts.dropFirst().reduce(parts[0]) { .binary(op: "OR", lhs: $0, rhs: $1) }
            return negated ? .unary(op: "NOT", operand: .paren(any)) : any
        }

        var inner = scope
        var bound: Set<String> = []
        var stmt = SelectStatement()
        stmt.projections = [.star]
        var others: [CalcFormula] = []
        for conjunct in conjuncts {
            if case let (variable, relation)? = CalcToSQL.range(conjunct), names.contains(variable),
               !bound.contains(variable) {
                bound.insert(variable)
                inner[variable] = relation
                stmt.from.append(.named(name: relation, alias: CalcToSQL.alias(variable, relation)))
            } else {
                others.append(conjunct)
            }
        }
        if let unranged = names.subtracting(bound).sorted().first {
            throw TranslationError(message: "∃\(unranged) has no relation atom ranging \(unranged) in " +
                                            "its body. Write it as ∃\(unranged) ( R(\(unranged)) ∧ … ).")
        }
        stmt.whereClause = CalcToSQL.allOf(try others.map { try condition($0, scope: inner) })

        let expression = Expression.exists(query: .select(stmt), negated: negated)
        if recordStep {
            record(negated ? "¬∃ → NOT EXISTS" : "∃ → EXISTS",
                   renderer.inline(CalcFormula.exists(vars, body)), printer.expression(expression),
                   "∃u ( R(u) ∧ φ ) asks whether some row of R satisfies φ: EXISTS (SELECT * FROM " +
                   "R AS u WHERE φ). Variables from outside stay visible inside, which is what " +
                   "makes the sub-query correlated.")
        }
        return expression
    }

    /// `S(t)` where t ranges another relation: is t's row also in S? Rows are
    /// compared column by column, which needs both relations' columns.
    private func membership(_ relation: String, _ terms: [CalcTerm],
                            scope: [String: String]) throws -> Expression {
        guard terms.count == 1, case let .variable(v) = terms[0], let home = scope[v.name] else {
            throw TranslationError(message: "\(relation)(…) is used as a condition, but only a " +
                                            "single tuple variable ranged elsewhere can be tested " +
                                            "for membership.")
        }
        guard let theirs = columns(of: relation), let ours = columns(of: home) else {
            throw TranslationError(message: "Testing whether \(v.name) is also in \(relation) " +
                                            "compares rows column by column, which needs both " +
                                            "relations' columns. Declare them with CREATE TABLE " +
                                            "above the formula.")
        }
        guard theirs.count == ours.count else {
            throw TranslationError(message: "\(relation) and \(home) have different numbers of " +
                                            "columns, so a row of one cannot be a row of the other.")
        }
        let other = names.fresh(for: relation)
        var stmt = SelectStatement()
        stmt.projections = [.star]
        stmt.from = [.named(name: relation, alias: other)]
        stmt.whereClause = CalcToSQL.allOf(zip(theirs, ours).map { mine, yours in
            Expression.binary(op: "=", lhs: .column(table: other, name: mine),
                              rhs: .column(table: v.name, name: yours))
        })
        let expression = Expression.exists(query: .select(stmt), negated: false)
        record("\(relation)(\(v.name)) → EXISTS", "\(relation)(\(v.name))", printer.expression(expression),
               "\(v.name) already ranges over \(home), so \(relation)(\(v.name)) asks whether the same " +
               "row is in \(relation) too: some row of \(relation) equal to it, column by column.")
        return expression
    }

    // MARK: - Terms and results

    private func term(_ term: CalcTerm, scope: [String: String]) throws -> Expression {
        switch term {
        case let .attribute(v, attribute):
            return .column(table: v.name, name: attribute)
        case let .variable(v):
            if let binding = aggregateValues[v.name] {
                return try aggregateExpression(binding, scope: scope)
            }
            throw TranslationError(message: "\(v.name) stands for a whole tuple here. Compare its " +
                                            "attributes instead, such as \(v.name).id.")
        case let .literal(text), let .opaque(text):
            return try SQLParser.parseStandaloneExpression(text)
        case let .application(name, args, distinct):
            return .function(name: name.uppercased(),
                             args: try args.map { try self.term($0, scope: scope) }, distinct: distinct)
        case let .binaryOp(op, lhs, rhs):
            return .binary(op: op, lhs: try self.term(lhs, scope: scope),
                           rhs: try self.term(rhs, scope: scope))
        }
    }

    private func selectItem(_ column: ResultColumn, scope: [String: String]) throws -> SelectItem {
        if case let .variable(v) = column.term, scope[v.name] != nil {
            return .qualifiedStar(v.name)
        }
        return .expression(try term(column.term, scope: scope), alias: column.name)
    }

    // MARK: - Helpers

    /// `R(t)`: the variable and the relation it ranges over.
    private static func range(_ formula: CalcFormula) -> (String, String)? {
        guard case let .relationAtom(relation, terms, _) = formula, terms.count == 1,
              case let .variable(v) = terms[0] else { return nil }
        return (v.name, relation)
    }

    /// `Employee AS e`, or just `Employee` when the variable has its name.
    private static func alias(_ variable: String, _ relation: String) -> String? {
        variable.caseInsensitiveCompare(relation) == .orderedSame ? nil : variable
    }

    private static func allOf(_ conditions: [Expression]) -> Expression? {
        guard let first = conditions.first else { return nil }
        return conditions.dropFirst().reduce(first) { .binary(op: "AND", lhs: $0, rhs: $1) }
    }

    private static func sqlOperator(_ op: String) -> String {
        switch op {
        case "≠": return "<>"
        case "≤": return "<="
        case "≥": return ">="
        default:  return op
        }
    }

    /// The names a query's output columns go by, when they can be read off it.
    private func outputColumns(_ query: SQLQuery) -> [String]? {
        switch query {
        case let .select(stmt):
            var names: [String] = []
            for item in stmt.projections {
                switch item {
                case .star:
                    return nil
                case let .qualifiedStar(table):
                    let relation = stmt.from.compactMap { ref -> String? in
                        guard case let .named(name, alias) = ref,
                              (alias ?? name).caseInsensitiveCompare(table) == .orderedSame
                        else { return nil }
                        return name
                    }.first
                    guard let relation, let columns = columns(of: relation) else { return nil }
                    names += columns
                case let .expression(expression, alias):
                    names.append(alias ?? expression.attributeName)
                }
            }
            return names
        case let .setOperation(_, left, _, _):
            return outputColumns(left)
        case let .with(_, body):
            return outputColumns(body)
        }
    }

    /// Every variable and relation name a calculus expression mentions — what
    /// a generated tuple variable must not be called.
    private static func mentionedNames(_ expression: CalcExpression) -> [String] {
        switch expression {
        case let .query(query):
            return query.formula.variables.map(\.name)
                + query.result.flatMap { $0.term.variables.map(\.name) }
                + relations(in: query.formula)
        case let .setOperation(_, left, right):
            return mentionedNames(left) + mentionedNames(right)
        }
    }

    private static func relations(in formula: CalcFormula) -> [String] {
        switch formula {
        case let .relationAtom(relation, _, _):
            return [relation]
        case let .and(parts), let .or(parts):
            return parts.flatMap { relations(in: $0) }
        case let .not(inner), let .exists(_, inner), let .forAll(_, inner):
            return relations(in: inner)
        case let .implies(lhs, rhs):
            return relations(in: lhs) + relations(in: rhs)
        case let .aggregateBinding(_, _, _, _, _, condition):
            return relations(in: condition)
        case .comparison, .predicate, .constant:
            return []
        }
    }
}

extension CalcScript {
    /// The script in the app's own notation — what Prettify writes. It goes
    /// through the same renderer as the Formula view, so it is exactly what the
    /// app prints, which the parser is held to reading back.
    func prettyText(prelude: String) -> String {
        let view = CalcTranslation(dialect: dialect, definitions: definitions,
                                   root: expression, simplified: expression,
                                   steps: [], schema: QuerySchema(), diagnostics: [])
        let body = CalcRenderer().pretty(view)
        let declarations = prelude.trimmingCharacters(in: .whitespacesAndNewlines)
        return declarations.isEmpty ? body : declarations + "\n\n" + body
    }
}

extension CalcTerm {
    /// This term with the variable `name` replaced by `replacement`.
    func substituting(_ name: String, with replacement: CalcTerm) -> CalcTerm {
        switch self {
        case let .variable(v):
            return v.name == name ? replacement : self
        case .attribute, .literal, .opaque:
            return self
        case let .application(function, args, distinct):
            return .application(name: function,
                                args: args.map { $0.substituting(name, with: replacement) },
                                distinct: distinct)
        case let .binaryOp(op, lhs, rhs):
            return .binaryOp(op: op, lhs: lhs.substituting(name, with: replacement),
                             rhs: rhs.substituting(name, with: replacement))
        }
    }
}

extension CalcFormula {
    /// This formula with the free variable `name` replaced, stopping at any
    /// quantifier that binds a variable of that name.
    func substituting(_ name: String, with replacement: CalcTerm) -> CalcFormula {
        func sub(_ formula: CalcFormula) -> CalcFormula { formula.substituting(name, with: replacement) }
        func term(_ t: CalcTerm) -> CalcTerm { t.substituting(name, with: replacement) }
        switch self {
        case let .relationAtom(relation, terms, known):
            return .relationAtom(relation: relation, terms: terms.map(term), arityKnown: known)
        case let .comparison(lhs, op, rhs):
            return .comparison(lhs: term(lhs), op: op, rhs: term(rhs))
        case let .and(parts):
            return .and(parts.map(sub))
        case let .or(parts):
            return .or(parts.map(sub))
        case let .not(inner):
            return .not(sub(inner))
        case let .exists(vars, body):
            return vars.contains { $0.name == name } ? self : .exists(vars, sub(body))
        case let .forAll(vars, body):
            return vars.contains { $0.name == name } ? self : .forAll(vars, sub(body))
        case let .implies(lhs, rhs):
            return .implies(sub(lhs), sub(rhs))
        case let .predicate(rendered, terms):
            return .predicate(rendered: rendered, terms: terms.map(term))
        case let .aggregateBinding(result, function, distinct, element, variables, condition):
            // The comprehension's own variables shadow an outer one of the same name.
            guard !variables.contains(where: { $0.name == name }) else { return self }
            return .aggregateBinding(result: result, function: function, distinct: distinct,
                                     element: element.map(term), variables: variables,
                                     condition: sub(condition))
        case .constant:
            return self
        }
    }
}
