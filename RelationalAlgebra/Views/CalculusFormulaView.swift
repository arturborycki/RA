//
//  CalculusFormulaView.swift
//  RelationalAlgebra
//
//  The calculus expression for the current query — tuple or domain — together
//  with the fidelity notes, the relations it ranges over, and a legend for the
//  logic glyphs.
//

import SwiftUI
import UIKit

struct CalculusFormulaView: View {
    let translation: CalcTranslation

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                FidelityBanner(diagnostics: translation.diagnostics)
                CalculusFormulaCard(translation: translation)
                RangeRelationsCard(schema: translation.schema, dialect: translation.dialect)
                legend
            }
            .padding()
        }
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Notation").font(.headline)
            ForEach(entries, id: \.symbol) { entry in
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text(entry.symbol)
                        .font(.system(.subheadline, design: .monospaced))
                        .frame(width: 74, alignment: .leading)
                        .foregroundStyle(Color.accentColor)
                    Text(entry.meaning)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
    }

    private var entries: [(symbol: String, meaning: String)] {
        let shared: [(symbol: String, meaning: String)] = [
            ("{ … | … }",       "Set builder — the result, then the condition it satisfies"),
            (CalcSymbol.exists, "There exists … such that"),
            (CalcSymbol.forAll, "For every …"),
            (CalcSymbol.and,    "And"),
            (CalcSymbol.or,     "Or"),
            (CalcSymbol.not,    "Not"),
            (CalcSymbol.implies, "Implies — the guard of a safe ∀"),
        ]
        switch translation.dialect {
        case .trc:
            return shared + [
                ("R(t)", "The tuple variable t ranges over relation R"),
                ("t.a",  "Attribute a of the tuple t"),
            ]
        case .drc:
            return shared + [
                ("R(x, y, z)", "One variable per column, in column order — a domain atom is positional"),
                ("R(x, y, …)", "The column list is incomplete: declare the table to make it exact"),
                ("⟨x, y⟩",     "The tuple of values the expression denotes"),
            ]
        }
    }
}

/// The expression itself, line-broken, with a toggle between the direct
/// translation and the simplified form when they differ.
struct CalculusFormulaCard: View {
    let translation: CalcTranslation
    @State private var showSimplified = true

    private var text: String {
        showSimplified ? translation.simplifiedText() : translation.prettyText()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(translation.dialect == .trc ? "Tuple relational calculus"
                                                  : "Domain relational calculus",
                      systemImage: "function")
                    .font(.headline)
                Spacer()
                Button {
                    UIPasteboard.general.string = text
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
            }

            if translation.isSimplified {
                Picker("Form", selection: $showSimplified) {
                    Text("Simplified").tag(true)
                    Text("As translated").tag(false)
                }
                .pickerStyle(.segmented)
            }

            ScrollView(.horizontal, showsIndicators: true) {
                Text(text)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .lineSpacing(4)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(12)
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(.tertiarySystemGroupedBackground)))
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
    }
}

/// What the translator worked out about each relation. Attribute order is shown
/// because it is exactly what a domain atom's positions are, and the source
/// badge says how much to trust it.
struct RangeRelationsCard: View {
    let schema: QuerySchema
    var dialect: CalcDialect = .trc

    private var relations: [RelationSchema] { schema.sortedRelations }
    private var anyInferred: Bool { relations.contains { !$0.arityKnown } }

    var body: some View {
        if !relations.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Relations").font(.headline)

                ForEach(relations, id: \.name) { relation in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(relation.name)
                                .font(.subheadline.weight(.semibold).monospaced())
                            Text(relation.source.label)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(badgeTint(relation).opacity(0.18)))
                                .foregroundStyle(badgeTint(relation))
                            Spacer(minLength: 0)
                        }
                        Text(attributeList(relation))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if dialect == .drc && anyInferred {
                    Text("A domain atom is positional, so a relation whose columns were " +
                         "reconstructed from this query cannot be written exactly. Paste its " +
                         "CREATE TABLE above the query to fix the arity and the order.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
        }
    }

    private func attributeList(_ relation: RelationSchema) -> String {
        guard !relation.attributes.isEmpty else {
            return "no columns named in this query"
        }
        let names = relation.attributes.joined(separator: ", ")
        return relation.arityKnown ? names : "\(names), …"
    }

    private func badgeTint(_ relation: RelationSchema) -> Color {
        relation.arityKnown ? .green : .orange
    }
}
