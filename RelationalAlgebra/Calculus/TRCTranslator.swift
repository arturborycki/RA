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
//  Scope of this phase: select–project–join with `WHERE`, plus set operations
//  and `WITH` bindings composed at the expression level. Sub-query predicates
//  are carried as opaque atoms and expanded into quantifiers in the next phase;
//  every one of them raises a diagnostic, so nothing is silently approximated.
//

import Foundation

struct TRCTranslator {

    func translate(_ query: SQLQuery, schema: QuerySchema) -> CalcTranslation {
        let builder = TRCBuilder(schema: schema)
        let root = builder.build(query, outer: TupleScope())
        return CalcTranslation(dialect: .trc,
                               definitions: builder.definitions,
                               root: root,
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
    private var usedNames = Set<String>()

    init(schema: QuerySchema) {
        self.schema = schema
    }

    // MARK: Query dispatch

    func build(_ query: SQLQuery, outer: TupleScope) -> CalcExpression {
        switch query {
        case let .select(stmt):
            return .query(buildSelect(stmt, outer: outer))

        case let .setOperation(op, left, right, all):
            let lhs = build(left, outer: outer)
            let rhs = build(right, outer: outer)
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
            diagnostics.append(.info(
                op.rawValue,
                "Shown as a set operation on two calculus expressions. A later version merges " +
                "them into one formula over shared result variables."))
            return .setOperation(op: calcOp, left: lhs, right: rhs)

        case let .with(ctes, body):
            for cte in ctes {
                definitions.append(CalcDefinition(name: cte.name,
                                                  expression: build(cte.query, outer: outer)))
            }
            return build(body, outer: outer)
        }
    }

    // MARK: SELECT

    private func buildSelect(_ stmt: SelectStatement, outer: TupleScope) -> CalcQuery {
        var scope = TupleScope(nestedIn: outer)
        var conjuncts: [CalcFormula] = []

        // 1. FROM and JOIN declare one tuple variable per relation. A comma in
        //    FROM is the cartesian product, and needs no operator here: two
        //    unrelated atoms in a conjunction already mean every combination.
        for table in stmt.from {
            conjuncts.append(atom(for: table, into: &scope))
        }
        for join in stmt.joins {
            conjuncts.append(atom(for: join.table, into: &scope))
            conjuncts.append(contentsOf: joinConditions(join, scope: scope))
        }

        // 2. WHERE conjoins onto the same formula.
        if let whereClause = stmt.whereClause {
            conjuncts.append(formula(whereClause, scope: scope))
        }

        // 3. The SELECT list becomes the result specification.
        let result = resultColumns(stmt, scope: scope)

        // 4. Everything SQL asks for that first-order calculus cannot express.
        let extensions = self.extensions(stmt)
        noteFidelity(of: stmt)

        // 5. Variables the result does not export are existentially quantified,
        //    over just the conjuncts that mention them.
        let body = quantifyNonResultVariables(CalcFormula.conjunction(conjuncts), result: result)

        return CalcQuery(dialect: .trc, result: result, formula: body, extensions: extensions)
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
        // A TRC atom is `R(t)`, not positional, so an incomplete attribute list
        // costs nothing to render here. The flag is carried truthfully anyway,
        // because DRC lowering reads it to decide whether `R(x, y, …)` can be
        // written at all.
        let arityKnown = schema.schema(for: relation)?.arityKnown ?? false
        return .relationAtom(relation: relation, terms: [.variable(variable)], arityKnown: arityKnown)
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

    private func extensions(_ stmt: SelectStatement) -> [CalcExtension] {
        var result: [CalcExtension] = []

        let grouping = stmt.groupBy.map { $0.rendered }
        if !grouping.isEmpty {
            let rendered = stmt.groupByModifier.map { "\($0)(\(grouping.joined(separator: ", ")))" }
                ?? grouping.joined(separator: ", ")
            result.append(CalcExtension(kind: .grouping, rendered: "group by \(rendered)"))
        }
        if let having = stmt.having {
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
        if !stmt.groupBy.isEmpty || stmt.projections.contains(where: { $0.isAggregate }) {
            diagnostics.append(.extended(
                "GROUP BY / aggregates",
                "First-order relational calculus has no aggregation. Grouping is shown as an " +
                "annotation outside the braces rather than faked inside it."))
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

        let bound = body.variables.subtracting(free)
        guard !bound.isEmpty else { return body }

        var outerParts: [CalcFormula] = []
        var innerParts: [CalcFormula] = []
        for conjunct in conjuncts {
            if conjunct.variables.isDisjoint(with: bound) {
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

        case let .exists(_, negated):
            diagnostics.append(.annotated(
                negated ? "NOT EXISTS" : "EXISTS",
                "Sub-query predicates become ∃ / ¬∃ quantifiers in the next version; shown as an " +
                "opaque atom for now."))
            return .predicate(rendered: "\(negated ? "¬" : "")∃ (…)", terms: [])

        case let .inSubquery(value, _, negated):
            diagnostics.append(.annotated(
                negated ? "NOT IN (sub-query)" : "IN (sub-query)",
                "Sub-query predicates become ∃ / ¬∃ quantifiers in the next version; shown as an " +
                "opaque atom for now."))
            let v = term(value, scope: scope)
            return .predicate(rendered: "\(v.plainText) \(negated ? "∉" : "∈") (…)", terms: [v])

        case let .boolLiteral(value):
            return .constant(value)

        case let .function(_, args, _):
            return .predicate(rendered: expr.rendered,
                              terms: args.map { term($0, scope: scope) })

        default:
            // A bare column or other term used as a condition.
            return .predicate(rendered: expr.rendered, terms: [term(expr, scope: scope)])
        }
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

        default:
            // CASE, CAST, window functions, typed literals, intervals and
            // sub-queries keep the pretty-printed SQL the algebra side already
            // produces. They are terms, not conditions, so nothing is lost by
            // carrying them verbatim.
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
    private func allocate(preferred: String, relation: String) -> CalcVar {
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
