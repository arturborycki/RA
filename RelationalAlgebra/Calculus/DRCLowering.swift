//
//  DRCLowering.swift
//  RelationalAlgebra
//
//  Lowers tuple relational calculus to domain relational calculus.
//
//  This is Codd's equivalence, and it is mechanical: every tuple variable `t`
//  over a relation with schema ⟨A₁ … Aₙ⟩ explodes into one domain variable per
//  attribute, `R(t)` becomes the positional atom `R(x₁, …, xₙ)`, each `t.Aᵢ`
//  becomes `xᵢ`, and any `xᵢ` the result does not export is quantified where
//  `t` was. All the hard work — quantifier scoping, correlation, negation — was
//  already done by the tuple translation, so there is no second translator.
//
//  What DRC needs and TRC does not is the *arity and column order* of every
//  relation. Where that came from a CREATE TABLE the atom is exact; where it was
//  reconstructed from the query's own column references the atom is marked
//  incomplete and says so, because inventing the missing columns would produce a
//  formula that is wrong rather than merely partial.
//

import Foundation

struct DRCLowering {

    static func lower(_ translation: CalcTranslation) -> CalcTranslation {
        let engine = DRCLoweringEngine(schema: translation.schema)

        // One engine across the whole translation, so a domain variable name is
        // never reused between a CTE and the body that references it.
        let definitions = translation.definitions.map {
            CalcDefinition(name: $0.name, expression: engine.lower($0.expression))
        }
        let root = engine.lower(translation.root)

        return CalcTranslation(dialect: .drc,
                               definitions: definitions,
                               root: root,
                               simplified: root,
                               steps: engine.steps(for: root),
                               schema: translation.schema,
                               // The tuple translation's own notes still apply:
                               // an unexpanded sub-query is unexpanded in both.
                               diagnostics: (translation.diagnostics + engine.diagnostics).deduplicated)
    }
}

final class DRCLoweringEngine {

    /// How one tuple variable was exploded.
    private struct TupleMapping {
        var relation: String
        var attributes: [String]
        var variables: [CalcVar]
        /// Whether `attributes` is the relation's complete column list.
        var complete: Bool

        func variable(for attribute: String) -> CalcVar? {
            guard let index = attributes.firstIndex(where: {
                $0.caseInsensitiveCompare(attribute) == .orderedSame
            }) else { return nil }
            return variables[index]
        }
    }

    private let schema: QuerySchema
    private var mappings: [CalcVar: TupleMapping] = [:]
    private var usedNames = Set<String>()
    private(set) var diagnostics: [CalcDiagnostic] = []

    init(schema: QuerySchema) {
        self.schema = schema
    }

    // MARK: - Expressions

    func lower(_ expression: CalcExpression) -> CalcExpression {
        switch expression {
        case let .query(query):
            return .query(lower(query))
        case let .setOperation(op, left, right):
            return .setOperation(op: op, left: lower(left), right: lower(right))
        }
    }

    private func lower(_ query: CalcQuery) -> CalcQuery {
        let formula = lower(query.formula)
        let result = query.result.flatMap { lower($0) }

        // Domain variables the result does not export are existentially
        // quantified.
        let exported = result.reduce(into: Set<CalcVar>()) { $0.formUnion($1.term.variables) }
        let body = quantifyUnexported(formula, exported: exported)

        return CalcQuery(dialect: .drc,
                         result: result,
                         formula: body,
                         resultStyle: .tuple,
                         extensions: query.extensions)
    }

    // MARK: - Result columns

    /// One tuple column can become several domain columns: `SELECT *` projects a
    /// whole tuple variable, which is every one of its attributes.
    private func lower(_ column: ResultColumn) -> [ResultColumn] {
        if case let .variable(tuple) = column.term, let mapping = mappings[tuple] {
            if !mapping.complete {
                diagnostics.append(.annotated(
                    "SELECT * over \(mapping.relation)",
                    "'\(mapping.relation)' has \(mapping.attributes.count) column(s) reconstructed " +
                    "from this query; * may name more, so the projected tuple may be incomplete."))
            }
            return mapping.variables.map { ResultColumn(term: .variable($0)) }
        }
        return [ResultColumn(term: lower(column.term), name: column.name)]
    }

    // MARK: - Formulas

    private func lower(_ formula: CalcFormula) -> CalcFormula {
        switch formula {
        case let .relationAtom(relation, terms, _):
            // `R(t)` is the one place a tuple variable is introduced, so this is
            // where it explodes into its columns.
            if terms.count == 1, case let .variable(tuple) = terms[0] {
                let mapping = mapping(for: tuple, relation: relation)
                return .relationAtom(relation: relation,
                                     terms: mapping.variables.map { .variable($0) },
                                     arityKnown: mapping.complete)
            }
            return .relationAtom(relation: relation, terms: terms.map { lower($0) }, arityKnown: true)

        case let .comparison(lhs, op, rhs):
            return .comparison(lhs: lower(lhs), op: op, rhs: lower(rhs))

        case let .and(parts):
            return CalcFormula.conjunction(parts.map { lower($0) })
        case let .or(parts):
            return CalcFormula.disjunction(parts.map { lower($0) })
        case let .not(inner):
            return .not(lower(inner))

        case let .exists(vars, body):
            // Lower the body first: the atoms inside it are what establish each
            // tuple variable's mapping.
            let loweredBody = lower(body)
            return .exists(domainVariables(of: vars), loweredBody)

        case let .forAll(vars, body):
            let loweredBody = lower(body)
            return .forAll(domainVariables(of: vars), loweredBody)

        case let .implies(lhs, rhs):
            return .implies(lower(lhs), lower(rhs))

        case let .predicate(rendered, terms):
            return .predicate(rendered: rendered, terms: terms.map { lower($0) })

        case let .aggregateBinding(result, function, distinct, element, variables, condition):
            // Condition first: its atoms establish the tuple variables that the
            // collected element and the variable list then refer to.
            let loweredCondition = lower(condition)
            return .aggregateBinding(result: result, function: function, distinct: distinct,
                                     element: element.map { lower($0) },
                                     variables: domainVariables(of: variables),
                                     condition: loweredCondition)

        case .constant:
            return formula
        }
    }

    // MARK: - Terms

    private func lower(_ term: CalcTerm) -> CalcTerm {
        switch term {
        case let .attribute(tuple, attribute):
            guard let mapping = mappings[tuple] else {
                // No relation atom introduced this variable — nothing to explode.
                return .opaque("\(tuple.name).\(attribute)")
            }
            if let variable = mapping.variable(for: attribute) {
                return .variable(variable)
            }
            diagnostics.append(.annotated(
                "\(tuple.name).\(attribute)",
                "'\(attribute)' is not among the known columns of '\(mapping.relation)', so it has " +
                "no position in the atom. Declare the table with CREATE TABLE to place it."))
            return .opaque("\(tuple.name).\(attribute)")

        case let .variable(tuple):
            // A whole tuple where a single value is expected — it has no domain
            // equivalent, and the result-column path handles the cases that do.
            guard let mapping = mappings[tuple] else { return term }
            diagnostics.append(.annotated(
                tuple.name,
                "'\(tuple.name)' stands for a whole tuple of \(mapping.relation), which has no " +
                "single domain value."))
            return .opaque(tuple.name)

        case let .application(name, args, distinct):
            return .application(name: name, args: args.map { lower($0) }, distinct: distinct)
        case let .binaryOp(op, lhs, rhs):
            return .binaryOp(op: op, lhs: lower(lhs), rhs: lower(rhs))
        case .literal, .opaque:
            return term
        }
    }

    // MARK: - Mapping tuple variables to domain variables

    private func mapping(for tuple: CalcVar, relation: String) -> TupleMapping {
        if let existing = mappings[tuple] { return existing }

        let known = schema.schema(for: relation)
        let attributes = known?.attributes ?? []
        let complete = known?.arityKnown ?? false

        if !complete {
            diagnostics.append(.annotated(
                relation,
                attributes.isEmpty
                    ? "No columns of '\(relation)' are named anywhere in the query, so its atom " +
                      "has no positions at all. Add a CREATE TABLE to give it an arity."
                    : "'\(relation)' has \(attributes.count) column(s) reconstructed from this " +
                      "query's references; the real relation may have more, and they may be in a " +
                      "different order. Add a CREATE TABLE to make this atom exact."))
        }

        let stems = DRCLoweringEngine.mnemonicStems(of: attributes)
        let variables = zip(attributes, stems).map {
            allocate(for: $0, stem: $1, relation: relation)
        }
        let mapping = TupleMapping(relation: relation, attributes: attributes,
                                   variables: variables, complete: complete)
        mappings[tuple] = mapping
        return mapping
    }

    /// The domain variables standing in for a list of tuple variables, in
    /// column order. A variable with no mapping is passed through unchanged.
    private func domainVariables(of tuples: [CalcVar]) -> [CalcVar] {
        tuples.flatMap { mappings[$0]?.variables ?? [$0] }
    }

    /// The part of each column name its mnemonic letter is taken from.
    ///
    /// Normally the whole name, so `dept_id` gives `d` — the column means "the
    /// department", and that is what a reader should see. But a schema that
    /// prefixes every column with its table (`l_orderkey`, `l_quantity`, TPC-H
    /// throughout) would give all sixteen columns of a relation the same
    /// letter, and `l, l₁, l₂, …` says nothing. So when *every* column shares
    /// one prefix, that prefix is dropped and `orderkey` → `o`,
    /// `quantity` → `q`.
    static func mnemonicStems(of attributes: [String]) -> [String] {
        let prefixes = attributes.map { attribute -> String in
            guard let underscore = attribute.firstIndex(of: "_") else { return "" }
            return String(attribute[attribute.startIndex..<underscore])
        }
        guard let shared = prefixes.first, !shared.isEmpty,
              prefixes.allSatisfy({ $0 == shared }) else { return attributes }
        return attributes.map { String($0.dropFirst(shared.count + 1)) }
    }

    /// A mnemonic name taken from the attribute — `salary` → `s` — uniqued
    /// against everything already handed out.
    private func allocate(for attribute: String, stem: String, relation: String) -> CalcVar {
        let letters = stem.lowercased().filter { $0.isLetter }
        var name = letters.isEmpty ? "x" : String(letters.first!)
        if usedNames.contains(name) {
            var suffix = 1
            while usedNames.contains(name + TRCBuilder.subscriptNumber(suffix)) { suffix += 1 }
            name += TRCBuilder.subscriptNumber(suffix)
        }
        usedNames.insert(name)
        return CalcVar(name: name, relation: relation, attribute: attribute)
    }

    // MARK: - Quantification

    /// Wrap the whole body in one ∃ over the columns the result does not export.
    ///
    /// The tuple translation partitions instead, hoisting conjuncts that do not
    /// mention a bound variable out of the quantifier — which is what makes
    /// `Employee(e) ∧ ∃d ( … )` read well. That does not transfer: a domain atom
    /// names *every* one of its columns, so partitioning drags the atom inside
    /// and leaves the conditions stranded before the variables they mention are
    /// introduced. One quantifier over the whole body is both correct and the
    /// form textbooks print.
    private func quantifyUnexported(_ body: CalcFormula, exported: Set<CalcVar>) -> CalcFormula {
        let bound = body.freeVariables.subtracting(exported)
        guard !bound.isEmpty else { return body }
        // Column order, which is the order the atoms named them in.
        let ordered = orderedVariables(of: body).filter { bound.contains($0) }
        guard !ordered.isEmpty else { return body }
        return .exists(ordered, body)
    }

    private func orderedVariables(of formula: CalcFormula) -> [CalcVar] {
        var seen = Set<CalcVar>()
        var ordered: [CalcVar] = []
        func visitTerm(_ term: CalcTerm) {
            for variable in term.variables.sorted(by: { $0.name < $1.name })
            where seen.insert(variable).inserted {
                ordered.append(variable)
            }
        }
        func visit(_ f: CalcFormula) {
            switch f {
            case let .relationAtom(_, terms, _):
                // Atom order is column order, which is the order to quantify in.
                for term in terms {
                    if case let .variable(v) = term, seen.insert(v).inserted { ordered.append(v) }
                }
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
                terms.forEach(visitTerm)
            case let .aggregateBinding(result, _, _, _, _, _):
                // The comprehension's own variables stay inside it; only the
                // result it binds is visible out here.
                if seen.insert(result).inserted { ordered.append(result) }
            case .constant:
                break
            }
        }
        visit(formula)
        return ordered
    }

    // MARK: - Steps

    /// The lowering is one move, not a sequence: every tuple variable explodes
    /// at once. Showing it as a single step with the mapping spelled out says
    /// more than five near-identical formulas would.
    func steps(for root: CalcExpression) -> [CalcStep] {
        let described = mappings.values
            .sorted { $0.relation.lowercased() < $1.relation.lowercased() }
            .map { mapping in
                "\(mapping.relation)(" + mapping.variables.map(\.name).joined(separator: ", ")
                    + (mapping.complete ? ")" : ", …)")
            }
        return [CalcStep(
            index: 1,
            title: "Explode tuple variables into columns",
            clause: "TRC → DRC",
            explanation: "A domain atom is positional, so each tuple variable becomes one variable " +
                         "per column and every t.A becomes the variable in that column's position. " +
                         "Columns the result does not export are quantified away.",
            expression: root,
            added: described.isEmpty ? nil : described.joined(separator: "   "))]
    }
}
