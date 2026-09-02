//
//  CalcRenderer.swift
//  RelationalAlgebra
//
//  Renders the shared calculus IR as text.
//
//  Two modes matter. `inline` produces the single-line form used for copying
//  and for measuring; `pretty` breaks long formulas across lines — at top-level
//  connectives, with quantifier bodies indented — because a TPC-H query renders
//  as one 900-character line otherwise, which is unreadable on an iPad and
//  hopeless on an iPhone.
//
//  Only the relation-atom and term cases differ between TRC and DRC, so one
//  renderer serves both dialects.
//

import Foundation

// MARK: - Terms

extension CalcTerm {
    /// The term as it appears in a formula. Also used by the translator when it
    /// has to embed a term inside an opaque predicate's text.
    var plainText: String {
        switch self {
        case let .variable(v):
            return v.name
        case let .attribute(v, attribute):
            return "\(v.name).\(attribute)"
        case let .literal(value):
            return value
        case let .application(name, args, distinct):
            let inner = (distinct ? "DISTINCT " : "")
                + args.map { $0.plainText }.joined(separator: ", ")
            return name.isEmpty ? "(\(inner))" : "\(name)(\(inner))"
        case let .binaryOp(op, lhs, rhs):
            return "\(lhs.plainText) \(op) \(rhs.plainText)"
        case let .opaque(text):
            return text
        }
    }
}

// MARK: - Renderer

struct CalcRenderer {

    /// How wide a line may get before the pretty printer breaks it.
    var lineWidth: Int = 64

    init(lineWidth: Int = 64) {
        self.lineWidth = lineWidth
    }

    // MARK: Whole translations

    /// Every `WITH` binding, then the main expression, separated by blank lines.
    func pretty(_ translation: CalcTranslation) -> String {
        var blocks: [String] = []
        for definition in translation.definitions {
            blocks.append("\(definition.name) =\n" + indent(pretty(definition.expression), by: 1))
        }
        blocks.append(pretty(translation.root))
        return blocks.joined(separator: "\n\n")
    }

    func inline(_ translation: CalcTranslation) -> String {
        var blocks: [String] = []
        for definition in translation.definitions {
            blocks.append("\(definition.name) = \(inline(definition.expression))")
        }
        blocks.append(inline(translation.root))
        return blocks.joined(separator: "\n")
    }

    // MARK: Expressions

    func inline(_ expression: CalcExpression) -> String {
        switch expression {
        case let .query(query):
            return inline(query)
        case let .setOperation(op, left, right):
            return "\(inline(left)) \(op.glyph) \(inline(right))"
        }
    }

    func pretty(_ expression: CalcExpression) -> String {
        switch expression {
        case let .query(query):
            return pretty(query)
        case let .setOperation(op, left, right):
            return "\(pretty(left))\n\(op.glyph)\n\(pretty(right))"
        }
    }

    // MARK: Queries

    func inline(_ query: CalcQuery) -> String {
        let core = "{ \(resultSpec(query)) \(CalcSymbol.such) \(inline(query.formula)) }"
        guard !query.extensions.isEmpty else { return core }
        return "\(extensionPrefix(query)) \(core)"
    }

    func pretty(_ query: CalcQuery) -> String {
        let spec = resultSpec(query)
        let body = inline(query.formula)
        let core: String

        if "{ \(spec) \(CalcSymbol.such) \(body) }".count <= lineWidth {
            core = "{ \(spec) \(CalcSymbol.such) \(body) }"
        } else {
            core = "{ \(spec) \(CalcSymbol.such)\n"
                + indent(prettyFormula(query.formula, width: lineWidth - 4), by: 1)
                + "\n}"
        }

        guard !query.extensions.isEmpty else { return core }
        return "\(extensionPrefix(query))\n\(core)"
    }

    /// `sort by total ↓, limit 10  applied to` — kept *outside* the braces so
    /// the calculus expression itself stays a legal calculus expression.
    private func extensionPrefix(_ query: CalcQuery) -> String {
        let parts = query.extensions.map { $0.rendered }.joined(separator: ", ")
        return "\(parts)  applied to"
    }

    func resultSpec(_ query: CalcQuery) -> String {
        // Mid-derivation the SELECT list has not been read yet.
        guard !query.result.isEmpty else { return "…" }
        let columns = query.result.map { column -> String in
            guard let name = column.name, name != column.term.plainText else {
                return column.term.plainText
            }
            return "\(column.term.plainText) \(CalcSymbol.renameArrow) \(name)"
        }
        let joined = columns.joined(separator: ", ")
        switch query.resultStyle {
        case .compact:
            return joined
        case .tuple:
            // Fresh result variables bound by equality — the general form, and
            // the only one that can line two set-operation branches up.
            return "\(CalcSymbol.openTuple)\(joined)\(CalcSymbol.closeTuple)"
        }
    }

    // MARK: Formulas — single line

    func inline(_ formula: CalcFormula) -> String {
        render(formula, parentPrecedence: 0)
    }

    /// Binding strength, so parentheses appear only where they are needed:
    /// ¬ and quantifiers bind tightest, then ∧, then ∨, then →.
    private func precedence(_ formula: CalcFormula) -> Int {
        switch formula {
        case .relationAtom, .comparison, .predicate, .constant: return 5
        case .not, .exists, .forAll:                            return 4
        case .and:                                              return 3
        case .or:                                               return 2
        case .implies:                                          return 1
        }
    }

    private func render(_ formula: CalcFormula, parentPrecedence: Int) -> String {
        let own = precedence(formula)
        let text: String

        switch formula {
        case let .relationAtom(relation, terms, arityKnown):
            var inner = terms.map { $0.plainText }.joined(separator: ", ")
            // An inferred attribute list may be missing columns; say so in the
            // atom rather than presenting a guessed arity as fact.
            if !arityKnown && terms.count > 1 { inner += ", …" }
            text = "\(relation)(\(inner))"

        case let .comparison(lhs, op, rhs):
            text = "\(lhs.plainText) \(op) \(rhs.plainText)"

        case let .and(parts):
            text = parts.map { render($0, parentPrecedence: own) }
                .joined(separator: " \(CalcSymbol.and) ")

        case let .or(parts):
            // A conjunction inside a disjunction is bracketed even though ∧
            // binds tighter: `a ∨ b ∧ c` is correct but reads as a trap.
            text = parts.map { render($0, parentPrecedence: own + 2) }
                .joined(separator: " \(CalcSymbol.or) ")

        case let .not(inner):
            text = "\(CalcSymbol.not)\(negated(inner))"

        case let .exists(vars, body):
            text = "\(CalcSymbol.exists)\(variableList(vars)) ( \(render(body, parentPrecedence: 0)) )"

        case let .forAll(vars, body):
            text = "\(CalcSymbol.forAll)\(variableList(vars)) ( \(render(body, parentPrecedence: 0)) )"

        case let .implies(lhs, rhs):
            text = "\(render(lhs, parentPrecedence: own + 1)) \(CalcSymbol.implies) "
                 + "\(render(rhs, parentPrecedence: own))"

        case let .predicate(rendered, _):
            text = rendered

        case let .constant(value):
            text = value ? "TRUE" : "FALSE"
        }

        return own < parentPrecedence ? "(\(text))" : text
    }

    /// What `¬` is applied to. A relation atom and a quantifier already carry
    /// their own brackets — `¬R(t)`, `¬∃t ( … )` — but a bare comparison does
    /// not, and `¬t.a > 1` reads as a comparison against a negated value.
    private func negated(_ formula: CalcFormula) -> String {
        switch formula {
        case .relationAtom, .exists, .forAll, .not:
            return render(formula, parentPrecedence: 0)
        default:
            return "( \(render(formula, parentPrecedence: 0)) )"
        }
    }

    private func variableList(_ vars: [CalcVar]) -> String {
        vars.map { $0.name }.joined(separator: ", ")
    }

    // MARK: Formulas — line broken

    /// Render `formula` so that no produced line exceeds `width` where the tree
    /// gives somewhere to break. Sub-formulas that already fit stay on one line,
    /// which keeps short conjuncts readable inside a long formula.
    func prettyFormula(_ formula: CalcFormula, width: Int) -> String {
        let flat = inline(formula)
        if flat.count <= width { return flat }

        switch formula {
        case let .and(parts):
            return joinBroken(parts, glyph: CalcSymbol.and,
                              bracketBelow: precedence(formula), width: width)

        case let .or(parts):
            // Same bracketing rule as the inline renderer: a ∧ inside a ∨ gets
            // brackets even though it binds tighter.
            return joinBroken(parts, glyph: CalcSymbol.or,
                              bracketBelow: precedence(formula) + 2, width: width)

        case let .not(inner):
            return "\(CalcSymbol.not)(\n" + indent(prettyFormula(inner, width: width - 4), by: 1) + "\n)"

        case let .exists(vars, body):
            return quantifierBlock(CalcSymbol.exists, vars, body, width: width)

        case let .forAll(vars, body):
            return quantifierBlock(CalcSymbol.forAll, vars, body, width: width)

        case let .implies(lhs, rhs):
            return prettyFormula(lhs, width: width) + "\n\(CalcSymbol.implies)\n"
                 + prettyFormula(rhs, width: width)

        case .relationAtom, .comparison, .predicate, .constant:
            // Atomic: there is nowhere to break, so an over-long line stands
            // and the surrounding scroll view handles it.
            return flat
        }
    }

    private func quantifierBlock(_ glyph: String, _ vars: [CalcVar],
                                 _ body: CalcFormula, width: Int) -> String {
        "\(glyph)\(variableList(vars)) (\n"
            + indent(prettyFormula(body, width: width - 4), by: 1)
            + "\n)"
    }

    /// One operand per line with the connective leading each continuation, so
    /// the ∧ / ∨ column lines up down the left edge and the structure is legible.
    private func joinBroken(_ parts: [CalcFormula], glyph: String,
                            bracketBelow: Int, width: Int) -> String {
        var lines: [String] = []
        for (index, part) in parts.enumerated() {
            let needsParens = precedence(part) < bracketBelow
            var rendered = prettyFormula(part, width: width - 2)
            if needsParens {
                rendered = rendered.contains("\n")
                    ? "(\n" + indent(rendered, by: 1) + "\n)"
                    : "(\(rendered))"
            }
            if index == 0 {
                lines.append(rendered)
            } else {
                let segments = rendered.split(separator: "\n", omittingEmptySubsequences: false)
                let head = "\(glyph) \(segments.first ?? "")"
                let tail = segments.dropFirst().map { "  \($0)" }
                lines.append(([head] + tail).joined(separator: "\n"))
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Helpers

    private func indent(_ text: String, by levels: Int) -> String {
        let pad = String(repeating: "    ", count: levels)
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? String($0) : pad + $0 }
            .joined(separator: "\n")
    }
}
