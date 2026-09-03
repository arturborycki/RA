//
//  Schema.swift
//  RelationalAlgebra
//
//  What the calculus back end knows about each relation's attributes.
//
//  TRC reaches attributes by name (`t.salary`) and so needs only to know which
//  relation an unqualified column belongs to. DRC atoms are *positional*
//  (`Employee(n, s, d)`) and cannot be written at all without the arity and the
//  column order — which a query text alone does not contain. Everything here
//  exists to make that gap explicit rather than to paper over it: a schema that
//  was guessed says so, and a guessed arity is never presented as fact.
//

import Foundation

/// Where a relation's attribute list came from, in descending order of trust.
enum SchemaSource: Equatable {
    /// From a `CREATE TABLE`: exact attributes, in declaration order.
    case declared
    /// From a `WITH` common table expression's select list.
    case cte
    /// From a derived table (a sub-query in `FROM`) with an alias.
    case derived
    /// Reconstructed from the column references in the query itself.
    case inferred

    var label: String {
        switch self {
        case .declared: return "declared"
        case .cte:      return "from CTE"
        case .derived:  return "from sub-query"
        case .inferred: return "inferred"
        }
    }
}

struct RelationSchema: Equatable {
    var name: String
    /// ORDER IS SIGNIFICANT — DRC atoms are positional. For an inferred schema
    /// this is first-appearance order, which is a guess; `arityKnown` says so.
    var attributes: [String]
    var source: SchemaSource
    /// `false` when the attribute list may be incomplete or misordered.
    var arityKnown: Bool

    func index(of attribute: String) -> Int? {
        attributes.firstIndex { $0.caseInsensitiveCompare(attribute) == .orderedSame }
    }

    func has(_ attribute: String) -> Bool { index(of: attribute) != nil }
}

/// Everything inferred about the relations a query touches.
///
/// Aliases are deliberately absent: an alias is scope-local (the `e` of an inner
/// sub-query is not the `e` of the outer one), so alias resolution lives in the
/// translator's scope stack rather than in a flat query-wide map.
struct QuerySchema: Equatable {
    /// Keyed by relation name, matched case-insensitively via `schema(for:)`.
    var relations: [String: RelationSchema] = [:]

    func schema(for name: String) -> RelationSchema? {
        if let exact = relations[name] { return exact }
        return relations.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// The relations that carry at least one known attribute, name-ordered so
    /// the schema inspector and the tests see a stable list.
    var sortedRelations: [RelationSchema] {
        relations.values.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    /// The storage key an existing entry uses for `name`, so that `Employee`
    /// and `EMPLOYEE` in the same query do not become two relations.
    private func key(for name: String) -> String {
        relations.keys.first { $0.caseInsensitiveCompare(name) == .orderedSame } ?? name
    }

    mutating func record(attribute: String, on relation: String) {
        let k = key(for: relation)
        var existing = relations[k] ?? RelationSchema(name: relation, attributes: [],
                                                      source: .inferred, arityKnown: false)
        if !existing.has(attribute) { existing.attributes.append(attribute) }
        relations[k] = existing
    }

    /// Record an exactly-known attribute list, replacing anything inferred.
    mutating func declare(_ schema: RelationSchema) {
        relations[key(for: schema.name)] = schema
    }

    /// Ensure a relation is present even when nothing is known about its columns.
    mutating func touch(_ relation: String) {
        let k = key(for: relation)
        if relations[k] == nil {
            relations[k] = RelationSchema(name: relation, attributes: [],
                                          source: .inferred, arityKnown: false)
        }
    }
}
