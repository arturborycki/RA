//
//  RAToSQL.swift
//  RelationalAlgebra
//
//  Translates a relational-algebra expression into a SQL query.
//
//  The naive translation — one SELECT per operator, each wrapping its child as a
//  derived table — is always valid but reads like nobody's SQL, and it breaks
//  qualified names: once `Employee e ⋈ Department d` is wrapped in a derived
//  table, `e.salary` no longer resolves. So the translation builds blocks
//  instead. A block is a `SELECT * FROM … WHERE …` that is still *open*: a σ
//  above it adds a WHERE conjunct, a join extends its FROM. Only an operator
//  that changes the shape of the rows — π, δ, a set operation — *closes* it,
//  and only an operator applied above a closed block wraps it as a derived
//  table. `π[…](σ[…](R × S))` therefore comes out as one
//  `SELECT DISTINCT … FROM R, S WHERE …`, which is what a person would write.
//
//  Named intermediate results (`R₁ = …`, as the Steps view writes them) follow
//  the same idea. A name read once is written in place, so a pasted derivation
//  comes out exactly as the nested expression would; only a name read more
//  than once earns a WITH clause.
//
//  Two engine facts shape the joins, both checked against DuckDB and
//  DataFusion rather than assumed:
//
//    · `FROM a, b JOIN c ON <mentions a>` is rejected by DataFusion, because
//      JOIN binds tighter than the comma. A JOIN is therefore only appended to
//      a block with a single FROM entry; a comma list is turned into CROSS
//      JOINs first.
//    · A CTE with a column list, `WITH S(x, y) AS (…)`, runs on both, which is
//      what ρ[S(x, y)] becomes.
//

import Foundation

final class RAToSQL {

    static func translate(_ expression: RAExpr) throws -> SQLGeneration {
        try translate(RAScript(declarations: [], expression: expression))
    }

    static func translate(_ script: RAScript) throws -> SQLGeneration {
        let translator = try RAToSQL(script)
        var query = translator.query(try translator.lower(translator.body))
        if !translator.ctes.isEmpty {
            query = .with(ctes: translator.ctes, body: query)
        }
        return SQLGeneration(query: query, text: SQLPrinter().print(query),
                             diagnostics: translator.diagnostics, steps: translator.steps)
    }

    // MARK: - State

    /// WITH definitions — from `ρ[S(a, b)]` and from names read more than once
    /// — in the order they were needed, which is dependency order.
    private var ctes: [CommonTableExpression] = []
    private var diagnostics: [CalcDiagnostic] = []
    private var steps: [ReverseStep] = []
    /// Lower-cased names already meaning something, so a generated alias
    /// never shadows one.
    private var takenNames: Set<String>
    private var aliasCounter = 0
    /// Base relations and assigned names alike: what a new name must not reuse.
    private let relationNames: [String]

    /// The expression the query as a whole denotes.
    private let body: RAExpr
    /// Assigned names, lower-cased, with their definitions.
    private var definitions: [String: RAAssignment] = [:]
    /// How many times each assigned name is read.
    private var readCounts: [String: Int] = [:]
    /// Names already emitted as a CTE.
    private var definedAsCTE: Set<String> = []
    /// For a name written in place: the qualifiers its rows can still be read
    /// through, so `R₁.name` can become `Employee.name`.
    private var inlinedScopes: [String: [String]] = [:]
    /// How the operator just lowered was turned into SQL, for its step card.
    private var explanation = ""

    private init(_ script: RAScript) throws {
        var names: [String] = []
        func add(_ more: [String]) {
            for name in more where !names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                names.append(name)
            }
        }
        for assignment in script.assignments { add(assignment.expression.relationNames) }
        add(script.expression.relationNames)
        add(script.assignments.map(\.name))
        relationNames = names
        takenNames = Set(names.map { $0.lowercased() })

        // A name may only be read after it is defined: reading it earlier (or
        // inside its own definition) would mean a base relation of that name.
        for (i, assignment) in script.assignments.enumerated() {
            let reads = script.assignments[...i].flatMap { $0.expression.relationNames }
            if reads.contains(where: { $0.caseInsensitiveCompare(assignment.name) == .orderedSame }) {
                throw TranslationError(message: "\(assignment.name) is read before it is assigned. " +
                                                "Assign each name before the lines that use it.")
            }
        }

        // The derivation's last line usually *is* the answer: when the final
        // expression only names it, that definition becomes the query itself.
        var assignments = script.assignments
        var body = script.expression
        if case let .relation(name) = body, let last = assignments.last,
           last.name.caseInsensitiveCompare(name) == .orderedSame {
            body = last.expression
            assignments.removeLast()
        }
        self.body = body

        for assignment in assignments {
            definitions[assignment.name.lowercased()] = assignment
        }
        for node in assignments.map(\.expression) + [body] {
            for name in node.relationReads where definitions[name.lowercased()] != nil {
                readCounts[name.lowercased(), default: 0] += 1
            }
        }
        for assignment in assignments where readCounts[assignment.name.lowercased()] == nil {
            note(.info(assignment.name,
                       "\(assignment.name) is assigned but never read, so it is left out of the SQL."))
        }

        for assignment in script.assignments { collectRenames(assignment.expression) }
        collectRenames(script.expression)
    }

    private func collectRenames(_ node: RAExpr) {
        switch node {
        case .relation:
            break
        case let .rename(name, _, child):
            takenNames.insert(name.lowercased())
            collectRenames(child)
        case let .selection(_, child), let .projection(_, child), let .distinct(child):
            collectRenames(child)
        case let .join(_, _, left, right), let .cross(left, right),
             let .setOperation(_, left, right):
            collectRenames(left)
            collectRenames(right)
        }
    }

    private func freshAlias() -> String {
        while true {
            aliasCounter += 1
            let name = "t\(aliasCounter)"
            if !takenNames.contains(name) {
                takenNames.insert(name)
                return name
            }
        }
    }

    private func note(_ diagnostic: CalcDiagnostic) {
        if !diagnostics.contains(diagnostic) { diagnostics.append(diagnostic) }
    }

    // MARK: - Blocks

    /// A `SELECT * FROM … WHERE …` that operators above may still extend.
    private struct Block {
        var from: [TableRef]
        var joins: [Join] = []
        var conditions: [Expression] = []
        /// The qualifiers a condition may use here: table names and aliases.
        var scope: [String]

        /// One table with nothing applied to it yet.
        var isBareTable: Bool {
            from.count == 1 && joins.isEmpty && conditions.isEmpty
        }

        var statement: SelectStatement {
            var stmt = SelectStatement()
            stmt.projections = [.star]
            stmt.from = from
            stmt.joins = joins
            var combined: Expression? = nil
            for condition in conditions {
                if let sofar = combined {
                    combined = .binary(op: "AND", lhs: sofar, rhs: condition)
                } else {
                    combined = condition
                }
            }
            stmt.whereClause = combined
            return stmt
        }
    }

    private enum Lowered {
        case open(Block)
        case closed(SQLQuery)

        var isClosed: Bool {
            if case .closed = self { return true }
            return false
        }
    }

    /// The lowered expression as a block that can be extended, wrapping a
    /// closed query as a derived table when necessary.
    private func extendable(_ lowered: Lowered) -> Block {
        switch lowered {
        case let .open(block):
            return block
        case let .closed(query):
            let alias = freshAlias()
            return Block(from: [.derived(query, alias: alias)], scope: [alias])
        }
    }

    private func query(_ lowered: Lowered) -> SQLQuery {
        switch lowered {
        case let .open(block):  return .select(block.statement)
        case let .closed(query): return query
        }
    }

    // MARK: - Lowering

    /// Lower one node and record the step that explains it. Children are
    /// lowered — and recorded — first, so the steps read bottom-up, the order
    /// the forward derivation uses too.
    private func lower(_ node: RAExpr) throws -> Lowered {
        let lowered = try lowerNode(node)
        steps.append(ReverseStep(index: steps.count + 1,
                                 title: RAToSQL.title(of: node),
                                 algebra: node.node.formula,
                                 sql: SQLPrinter().print(query(lowered)),
                                 explanation: explanation))
        return lowered
    }

    private func lowerNode(_ node: RAExpr) throws -> Lowered {
        switch node {
        case let .relation(name):
            return try lowerRelation(name)

        case let .selection(condition, child):
            let inner = try lower(child)
            var block = extendable(inner)
            block.conditions.append(requalify(condition, scope: block.scope))
            explanation = inner.isClosed
                ? "The query below has already chosen its columns or combined two results, so " +
                  "it becomes the derived table \(block.scope[0]) and the condition filters that."
                : "σ adds its condition to the WHERE clause of the query below — a selection " +
                  "needs no SELECT of its own."
            return .open(block)

        case let .projection(items, child):
            let block = extendable(try lower(child))
            var stmt = block.statement
            stmt.projections = items.map { requalify($0, scope: block.scope) }
            stmt.distinct = true
            note(.info("π → SELECT DISTINCT",
                       "Relational algebra works on sets, so π drops duplicate rows. " +
                       "SQL keeps them unless told otherwise, so the SELECT says DISTINCT."))
            explanation = "π keeps only the listed attributes. The algebra's result is a set, " +
                          "so the SELECT says DISTINCT."
            return .closed(.select(stmt))

        case let .rename(name, columns, child):
            return try lowerRename(name: name, columns: columns, child: child)

        case let .distinct(child):
            let inner = try lower(child)
            if case let .closed(.select(stmt)) = inner, stmt.distinct {
                explanation = "The rows are already distinct — the SELECT below says DISTINCT — " +
                              "so δ changes nothing."
                return inner
            }
            var stmt = extendable(inner).statement
            stmt.distinct = true
            explanation = "δ removes duplicate rows: SELECT DISTINCT."
            return .closed(.select(stmt))

        case let .cross(left, right):
            return .open(try combine(left, right, kind: .cross, condition: nil))

        case let .join(kind, condition, left, right):
            let sqlKind: JoinKind
            switch kind {
            case .inner: sqlKind = .inner
            case .left:  sqlKind = .left
            case .right: sqlKind = .right
            case .full:  sqlKind = .full
            }
            return .open(try combine(left, right, kind: sqlKind, condition: condition))

        case let .setOperation(op, left, right):
            let lhs = query(try lower(left))
            let rhs = query(try lower(right))
            explanation = "\(RAToSQL.glyph(of: op)) becomes \(op.rawValue), which — like the " +
                          "algebra and unlike UNION ALL — removes duplicate rows."
            return .closed(.setOperation(op, left: lhs, right: rhs, all: false))
        }
    }

    /// A relation by name: a table, or a name assigned earlier.
    private func lowerRelation(_ name: String) throws -> Lowered {
        let key = name.lowercased()
        guard let definition = definitions[key] else {
            explanation = "A relation is a table, read whole: SELECT * FROM \(name)."
            return .open(Block(from: [.named(name: name, alias: nil)], scope: [name]))
        }

        let reads = readCounts[key] ?? 0
        if reads > 1 {
            if !definedAsCTE.contains(key) {
                definedAsCTE.insert(key)
                let body = query(try lower(definition.expression))
                ctes.append(CommonTableExpression(name: definition.name, columns: [], query: body))
            }
            explanation = "\(name) is read \(reads) times, so it is defined once in the WITH " +
                          "clause and read by name, like a table."
            return .open(Block(from: [.named(name: definition.name, alias: nil)],
                               scope: [definition.name]))
        }

        // Read once: write the definition in place, under the name when it has
        // to become a derived table anyway.
        let inner = try lower(definition.expression)
        switch inner {
        case let .closed(query):
            explanation = "\(name) is read once, so its definition is written in place, " +
                          "as the derived table \(name)."
            return .open(Block(from: [.derived(query, alias: definition.name)],
                               scope: [definition.name]))
        case let .open(block):
            inlinedScopes[key] = block.scope
            explanation = "\(name) is read once, so its definition is written in place; " +
                          "\(name).attr now reads as \(block.scope.joined(separator: " or ")).attr."
            return .open(block)
        }
    }

    private func lowerRename(name: String, columns: [String], child: RAExpr) throws -> Lowered {
        guard !columns.isEmpty else {
            let inner = try lower(child)
            // ρ[e](Employee) is just `Employee AS e`.
            if case let .open(block) = inner, block.isBareTable,
               case let .named(table, _) = block.from[0] {
                let alias = table.caseInsensitiveCompare(name) == .orderedSame ? nil : name
                explanation = "ρ names the relation: \(table) AS \(name). Its attributes can " +
                              "now be written \(name).attr."
                return .open(Block(from: [.named(name: table, alias: alias)], scope: [name]))
            }
            explanation = "ρ names the result below: it becomes the derived table (…) AS \(name)."
            return .open(Block(from: [.derived(query(inner), alias: name)], scope: [name]))
        }

        // Renaming the attributes too needs the new names attached to a
        // query, which a WITH column list does on every engine we target.
        if relationNames.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            throw TranslationError(message: "ρ[\(name)(…)] reuses the name of a relation the " +
                                            "expression reads. Pick a new name.")
        }
        if ctes.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            throw TranslationError(message: "ρ[\(name)(…)] appears twice. Give each rename " +
                                            "its own name.")
        }
        let body = query(try lower(child))
        ctes.append(CommonTableExpression(name: name, columns: columns, query: body))
        explanation = "ρ[\(name)(\(columns.joined(separator: ", ")))] renames the relation and " +
                      "its attributes. SQL attaches new attribute names in the WITH clause: " +
                      "WITH \(name)(\(columns.joined(separator: ", "))) AS (…)."
        return .open(Block(from: [.named(name: name, alias: nil)], scope: [name]))
    }

    /// `left ⋈ right`, `left × right` and the outer joins.
    private func combine(_ leftNode: RAExpr, _ rightNode: RAExpr,
                         kind: JoinKind, condition: Expression?) throws -> Block {
        var left = extendable(try lower(leftNode))
        let right = extendable(try lower(rightNode))

        for name in left.scope
        where right.scope.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            throw TranslationError(message: "\(name) appears on both sides of a join or product. " +
                                            "Rename one side with ρ, e.g. ρ[\(name)2](\(name)).")
        }

        // Two plain FROM lists: the textbook product, with a theta join's
        // condition in WHERE. This is the shape `σ[p](R × S)` is meant to have.
        let natural = condition == nil && kind != .cross
        let commaJoin = kind == .cross || (kind == .inner && !natural &&
                                           (left.from.count > 1 || right.from.count > 1))
        if commaJoin, left.joins.isEmpty, right.joins.isEmpty {
            left.scope += right.scope
            left.from += right.from
            left.conditions += right.conditions
            if let condition { left.conditions.append(requalify(condition, scope: left.scope)) }
            explanation = kind == .cross
                ? "× pairs every row with every row: both sides are listed in FROM, " +
                  "separated by a comma."
                : "A theta join is a product followed by a selection, so the relations are " +
                  "listed in FROM and the condition joins the WHERE clause."
            return left
        }

        // Otherwise the right side becomes one more JOIN. An inner join may
        // carry the right side's conditions up into WHERE; an outer join may
        // not, since they would then filter the null-extended rows.
        let innerLike = kind == .inner || kind == .cross
        let table: TableRef
        let rightScope: [String]
        if right.from.count == 1, right.joins.isEmpty, innerLike || right.conditions.isEmpty {
            table = right.from[0]
            rightScope = right.scope
            left.conditions += right.conditions
        } else {
            let alias = freshAlias()
            table = .derived(query(.open(right)), alias: alias)
            rightScope = [alias]
        }

        // A right or full join preserves the right side; a WHERE on the left
        // side would then remove rows the join was meant to keep.
        var movedLeftFilter = false
        if (kind == .right || kind == .full), !left.conditions.isEmpty {
            left = extendable(.closed(query(.open(left))))
            movedLeftFilter = true
        }
        // JOIN binds tighter than a comma, so a comma list must become CROSS
        // JOINs before a JOIN whose condition mentions its first table.
        if left.from.count > 1 {
            let rest = left.from.dropFirst().map {
                Join(kind: .cross, table: $0, on: nil, using: [])
            }
            left.joins = rest + left.joins
            left.from = [left.from[0]]
        }

        left.scope += rightScope
        let on = condition.map { requalify($0, scope: left.scope) }
        left.joins.append(Join(kind: kind, table: table, on: on, using: [], natural: natural))

        switch kind {
        case .inner where natural:
            explanation = "A natural join equates the attributes both sides share: NATURAL JOIN."
        case .inner:
            explanation = "⋈ with a condition becomes JOIN … ON, the condition unchanged."
        case .cross:
            explanation = "× becomes CROSS JOIN here, because the left side already has joins " +
                          "and a comma would bind looser than them."
        case .left:
            explanation = "⟕ keeps every row of the left side, padding the right with NULLs: " +
                          "LEFT JOIN."
        case .right:
            explanation = "⟖ keeps every row of the right side, padding the left with NULLs: " +
                          "RIGHT JOIN."
        case .full:
            explanation = "⟗ keeps every row of both sides, padding with NULLs: FULL JOIN."
        }
        if movedLeftFilter {
            explanation += " The filter on the left side moves into a derived table first, so " +
                           "it cannot remove the rows this join is meant to keep."
        }
        return left
    }

    // MARK: - Step titles

    private static func glyph(of op: SetOperator) -> String {
        switch op {
        case .union:     return RASymbol.union
        case .intersect: return RASymbol.intersect
        case .except:    return RASymbol.difference
        }
    }

    private static func title(of node: RAExpr) -> String {
        switch node {
        case .relation:                    return "Relation"
        case .selection:                   return "Selection σ"
        case .projection:                  return "Projection π"
        case .rename:                      return "Rename ρ"
        case .distinct:                    return "Duplicate elimination δ"
        case .cross:                       return "Cartesian product ×"
        case let .join(kind, condition, _, _):
            switch kind {
            case .inner: return condition == nil ? "Natural join ⋈" : "Join ⋈"
            case .left:  return "Left outer join ⟕"
            case .right: return "Right outer join ⟖"
            case .full:  return "Full outer join ⟗"
            }
        case let .setOperation(op, _, _):
            switch op {
            case .union:     return "Union ∪"
            case .intersect: return "Intersection ∩"
            case .except:    return "Difference −"
            }
        }
    }

    // MARK: - Attribute references

    /// An attribute qualified by a relation that is no longer in scope — hidden
    /// by a projection or set operation below — is written unqualified, which
    /// is what the attribute is called by then.
    private func requalify(_ expression: Expression, scope: [String]) -> Expression {
        let result = expression.mappingColumns { table, name in
            guard let table,
                  !scope.contains(where: { $0.caseInsensitiveCompare(table) == .orderedSame })
            else { return .column(table: table, name: name) }
            // `R₁.name` where R₁ was written in place over Employee: say Employee.
            if let through = inlinedScopes[table.lowercased()] {
                let visible = through.filter { q in
                    scope.contains { $0.caseInsensitiveCompare(q) == .orderedSame }
                }
                if visible.count == 1 { return .column(table: visible[0], name: name) }
            }
            note(.info("\(table).\(name)",
                       "\(table) is no longer in scope at this point (a projection or set " +
                       "operation hides it), so the attribute is written as \(name)."))
            return .column(table: nil, name: name)
        }
        if result.containsDivision {
            note(.info("a / b",
                       "Integer division differs between engines: DuckDB gives 7 / 2 = 3.5, " +
                       "DataFusion gives 3. Cast one side to DOUBLE for the same answer on both."))
        }
        return result
    }

    private func requalify(_ item: SelectItem, scope: [String]) -> SelectItem {
        switch item {
        case .star:
            return .star
        case let .qualifiedStar(table):
            return scope.contains(where: { $0.caseInsensitiveCompare(table) == .orderedSame })
                ? item : .star
        case let .expression(expression, alias):
            return .expression(requalify(expression, scope: scope), alias: alias)
        }
    }
}

// MARK: - Expression traversal

extension Expression {
    /// This expression with every column reference replaced by `transform`'s
    /// result. Sub-queries are left alone: they have their own scope.
    func mappingColumns(_ transform: (String?, String) -> Expression) -> Expression {
        switch self {
        case let .column(table, name):
            return transform(table, name)
        case .numberLiteral, .stringLiteral, .boolLiteral, .nullLiteral, .star,
             .exists, .subquery, .typedLiteral, .interval:
            return self
        case let .binary(op, lhs, rhs):
            return .binary(op: op, lhs: lhs.mappingColumns(transform),
                           rhs: rhs.mappingColumns(transform))
        case let .unary(op, operand):
            return .unary(op: op, operand: operand.mappingColumns(transform))
        case let .function(name, args, distinct):
            return .function(name: name, args: args.map { $0.mappingColumns(transform) },
                             distinct: distinct)
        case let .between(value, lower, upper, negated):
            return .between(value: value.mappingColumns(transform),
                            lower: lower.mappingColumns(transform),
                            upper: upper.mappingColumns(transform), negated: negated)
        case let .inList(value, list, negated):
            return .inList(value: value.mappingColumns(transform),
                           list: list.map { $0.mappingColumns(transform) }, negated: negated)
        case let .inSubquery(value, query, negated):
            return .inSubquery(value: value.mappingColumns(transform), query: query,
                               negated: negated)
        case let .quantifiedComparison(value, op, quantifier, query):
            return .quantifiedComparison(value: value.mappingColumns(transform), op: op,
                                         quantifier: quantifier, query: query)
        case let .isNull(inner, negated):
            return .isNull(inner.mappingColumns(transform), negated: negated)
        case let .list(items):
            return .list(items.map { $0.mappingColumns(transform) })
        case let .paren(inner):
            return .paren(inner.mappingColumns(transform))
        case let .caseExpression(operand, cases, elseResult):
            return .caseExpression(
                operand: operand?.mappingColumns(transform),
                cases: cases.map {
                    WhenClause(condition: $0.condition.mappingColumns(transform),
                               result: $0.result.mappingColumns(transform))
                },
                elseResult: elseResult?.mappingColumns(transform))
        case let .cast(inner, type):
            return .cast(expression: inner.mappingColumns(transform), type: type)
        case let .window(function, partitionBy, orderBy, frame):
            return .window(function: function.mappingColumns(transform),
                           partitionBy: partitionBy.map { $0.mappingColumns(transform) },
                           orderBy: orderBy.map {
                               OrderItem(expression: $0.expression.mappingColumns(transform),
                                         descending: $0.descending, nullsFirst: $0.nullsFirst)
                           },
                           frame: frame)
        }
    }

    /// Whether a `/` appears outside any sub-query.
    var containsDivision: Bool {
        switch self {
        case let .binary(op, lhs, rhs):
            return op == "/" || lhs.containsDivision || rhs.containsDivision
        case let .unary(_, operand), let .paren(operand), let .cast(operand, _),
             let .isNull(operand, _):
            return operand.containsDivision
        case let .function(_, args, _), let .list(args):
            return args.contains { $0.containsDivision }
        case let .between(value, lower, upper, _):
            return value.containsDivision || lower.containsDivision || upper.containsDivision
        case let .inList(value, list, _):
            return value.containsDivision || list.contains { $0.containsDivision }
        default:
            return false
        }
    }
}
