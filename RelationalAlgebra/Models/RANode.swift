//
//  RANode.swift
//  RelationalAlgebra
//
//  The relational-algebra expression tree together with its rendering.
//  Every node knows how to render itself both as a one-line formula (using the
//  conventional Unicode operator glyphs) and as a hierarchical tree of
//  `RATreeNode` values for the visual canvas.
//

import Foundation

/// Canonical relational-algebra operator glyphs.
enum RASymbol {
    static let selection      = "σ"   // WHERE / HAVING
    static let projection     = "π"   // SELECT list
    static let rename         = "ρ"   // AS / alias
    static let join           = "⋈"   // theta / natural join
    static let leftJoin       = "⟕"   // left outer join
    static let rightJoin      = "⟖"   // right outer join
    static let fullJoin       = "⟗"   // full outer join
    static let cross          = "×"   // cartesian product
    static let group          = "γ"   // GROUP BY + aggregation
    static let distinct       = "δ"   // DISTINCT (duplicate elimination)
    static let sort           = "τ"   // ORDER BY
    static let union          = "∪"
    static let intersect      = "∩"
    static let difference     = "−"
}

/// A node in the relational-algebra expression tree.
indirect enum RANode: Equatable {
    /// A base relation (table), optionally with an alias applied via ρ.
    case relation(name: String, alias: String?)
    /// σ_condition(child)
    case selection(condition: String, child: RANode)
    /// π_attributes(child)
    case projection(attributes: [String], child: RANode)
    /// ρ_alias(child)
    case rename(alias: String, child: RANode)
    /// Theta join ⋈_condition, or natural join when condition == nil.
    case join(condition: String?, left: RANode, right: RANode)
    case outerJoin(kind: OuterKind, condition: String?, left: RANode, right: RANode)
    /// Cartesian product ×
    case cross(left: RANode, right: RANode)
    /// grouping γ_{grouping; aggregates}
    case group(grouping: [String], aggregates: [String], child: RANode)
    /// δ duplicate elimination
    case distinct(child: RANode)
    /// τ_{sort keys}
    case sort(keys: [String], child: RANode)
    case union(left: RANode, right: RANode)
    case intersect(left: RANode, right: RANode)
    case difference(left: RANode, right: RANode)

    enum OuterKind: Equatable { case left, right, full }
}

// MARK: - Linear formula rendering

extension RANode {

    /// A multi-line, indented rendering of the expression — reads top-down like
    /// formatted code, one operator per line with its operands nested beneath.
    var prettyFormula: String {
        prettyLines(indent: 0).joined(separator: "\n")
    }

    private func prettyLines(indent: Int) -> [String] {
        let unit = "    " // 4 spaces per level
        let pad = String(repeating: unit, count: indent)
        let opPad = String(repeating: unit, count: indent + 1)

        func unary(_ head: String, _ child: RANode) -> [String] {
            [pad + head + " ("] + child.prettyLines(indent: indent + 1) + [pad + ")"]
        }
        func binary(_ glyph: String, _ lhs: RANode, _ rhs: RANode) -> [String] {
            [pad + "("]
                + lhs.prettyLines(indent: indent + 1)
                + [opPad + glyph]
                + rhs.prettyLines(indent: indent + 1)
                + [pad + ")"]
        }

        switch self {
        case let .relation(name, alias):
            if let alias, alias != name {
                return unary("\(RASymbol.rename)[\(alias)]", .relation(name: name, alias: nil))
            }
            return [pad + name]
        case let .selection(condition, child):
            return unary("\(RASymbol.selection)[\(condition)]", child)
        case let .projection(attributes, child):
            return unary("\(RASymbol.projection)[\(attributes.joined(separator: ", "))]", child)
        case let .rename(alias, child):
            return unary("\(RASymbol.rename)[\(alias)]", child)
        case let .join(condition, lhs, rhs):
            let glyph = condition.map { "\(RASymbol.join)[\($0)]" } ?? RASymbol.join
            return binary(glyph, lhs, rhs)
        case let .outerJoin(kind, condition, lhs, rhs):
            let base: String
            switch kind {
            case .left:  base = RASymbol.leftJoin
            case .right: base = RASymbol.rightJoin
            case .full:  base = RASymbol.fullJoin
            }
            let glyph = condition.map { "\(base)[\($0)]" } ?? base
            return binary(glyph, lhs, rhs)
        case let .cross(lhs, rhs):
            return binary(RASymbol.cross, lhs, rhs)
        case let .group(grouping, aggregates, child):
            let left = grouping.joined(separator: ", ")
            let right = aggregates.joined(separator: ", ")
            let sub = left.isEmpty ? right : (right.isEmpty ? left : "\(left); \(right)")
            return unary("\(RASymbol.group)[\(sub)]", child)
        case let .distinct(child):
            return unary(RASymbol.distinct, child)
        case let .sort(keys, child):
            return unary("\(RASymbol.sort)[\(keys.joined(separator: ", "))]", child)
        case let .union(lhs, rhs):
            return binary(RASymbol.union, lhs, rhs)
        case let .intersect(lhs, rhs):
            return binary(RASymbol.intersect, lhs, rhs)
        case let .difference(lhs, rhs):
            return binary(RASymbol.difference, lhs, rhs)
        }
    }

    /// A single-line formula using subscript-in-brackets notation, e.g.
    /// `π[name] ( σ[age > 30] ( Employee ) )`.
    var formula: String {
        switch self {
        case let .relation(name, alias):
            if let alias, alias != name {
                return "\(RASymbol.rename)[\(alias)] ( \(name) )"
            }
            return name

        case let .selection(condition, child):
            return "\(RASymbol.selection)[\(condition)] ( \(child.formula) )"

        case let .projection(attributes, child):
            return "\(RASymbol.projection)[\(attributes.joined(separator: ", "))] ( \(child.formula) )"

        case let .rename(alias, child):
            return "\(RASymbol.rename)[\(alias)] ( \(child.formula) )"

        case let .join(condition, left, right):
            if let condition {
                return "( \(left.formula) \(RASymbol.join)[\(condition)] \(right.formula) )"
            }
            return "( \(left.formula) \(RASymbol.join) \(right.formula) )"

        case let .outerJoin(kind, condition, left, right):
            let glyph: String
            switch kind {
            case .left:  glyph = RASymbol.leftJoin
            case .right: glyph = RASymbol.rightJoin
            case .full:  glyph = RASymbol.fullJoin
            }
            if let condition {
                return "( \(left.formula) \(glyph)[\(condition)] \(right.formula) )"
            }
            return "( \(left.formula) \(glyph) \(right.formula) )"

        case let .cross(left, right):
            return "( \(left.formula) \(RASymbol.cross) \(right.formula) )"

        case let .group(grouping, aggregates, child):
            let left = grouping.joined(separator: ", ")
            let right = aggregates.joined(separator: ", ")
            let sub = left.isEmpty ? right : "\(left); \(right)"
            return "\(RASymbol.group)[\(sub)] ( \(child.formula) )"

        case let .distinct(child):
            return "\(RASymbol.distinct) ( \(child.formula) )"

        case let .sort(keys, child):
            return "\(RASymbol.sort)[\(keys.joined(separator: ", "))] ( \(child.formula) )"

        case let .union(left, right):
            return "( \(left.formula) \(RASymbol.union) \(right.formula) )"

        case let .intersect(left, right):
            return "( \(left.formula) \(RASymbol.intersect) \(right.formula) )"

        case let .difference(left, right):
            return "( \(left.formula) \(RASymbol.difference) \(right.formula) )"
        }
    }
}

// MARK: - Tree rendering model

/// A layout-friendly, value-type projection of an `RANode` used by the visual
/// canvas. Operators become nodes labelled with their glyph and a subscript;
/// relations become leaves.
struct RATreeNode: Identifiable, Equatable {
    let id = UUID()
    var symbol: String        // operator glyph or relation name
    var detail: String?       // subscript (condition / attribute list)
    var isLeaf: Bool
    var children: [RATreeNode]

    static func == (lhs: RATreeNode, rhs: RATreeNode) -> Bool {
        lhs.symbol == rhs.symbol && lhs.detail == rhs.detail &&
        lhs.isLeaf == rhs.isLeaf && lhs.children == rhs.children
    }
}

extension RANode {
    /// Convert to a `RATreeNode` for the visual canvas.
    var tree: RATreeNode {
        switch self {
        case let .relation(name, alias):
            if let alias, alias != name {
                return RATreeNode(symbol: RASymbol.rename, detail: alias,
                                  isLeaf: false,
                                  children: [RATreeNode(symbol: name, detail: nil, isLeaf: true, children: [])])
            }
            return RATreeNode(symbol: name, detail: nil, isLeaf: true, children: [])

        case let .selection(condition, child):
            return RATreeNode(symbol: RASymbol.selection, detail: condition, isLeaf: false, children: [child.tree])

        case let .projection(attributes, child):
            return RATreeNode(symbol: RASymbol.projection, detail: attributes.joined(separator: ", "),
                              isLeaf: false, children: [child.tree])

        case let .rename(alias, child):
            return RATreeNode(symbol: RASymbol.rename, detail: alias, isLeaf: false, children: [child.tree])

        case let .join(condition, left, right):
            return RATreeNode(symbol: RASymbol.join, detail: condition, isLeaf: false,
                              children: [left.tree, right.tree])

        case let .outerJoin(kind, condition, left, right):
            let glyph: String
            switch kind {
            case .left:  glyph = RASymbol.leftJoin
            case .right: glyph = RASymbol.rightJoin
            case .full:  glyph = RASymbol.fullJoin
            }
            return RATreeNode(symbol: glyph, detail: condition, isLeaf: false,
                              children: [left.tree, right.tree])

        case let .cross(left, right):
            return RATreeNode(symbol: RASymbol.cross, detail: nil, isLeaf: false,
                              children: [left.tree, right.tree])

        case let .group(grouping, aggregates, child):
            let g = grouping.joined(separator: ", ")
            let a = aggregates.joined(separator: ", ")
            let detail = g.isEmpty ? a : "\(g); \(a)"
            return RATreeNode(symbol: RASymbol.group, detail: detail, isLeaf: false, children: [child.tree])

        case let .distinct(child):
            return RATreeNode(symbol: RASymbol.distinct, detail: nil, isLeaf: false, children: [child.tree])

        case let .sort(keys, child):
            return RATreeNode(symbol: RASymbol.sort, detail: keys.joined(separator: ", "),
                              isLeaf: false, children: [child.tree])

        case let .union(left, right):
            return RATreeNode(symbol: RASymbol.union, detail: nil, isLeaf: false, children: [left.tree, right.tree])

        case let .intersect(left, right):
            return RATreeNode(symbol: RASymbol.intersect, detail: nil, isLeaf: false, children: [left.tree, right.tree])

        case let .difference(left, right):
            return RATreeNode(symbol: RASymbol.difference, detail: nil, isLeaf: false, children: [left.tree, right.tree])
        }
    }
}
