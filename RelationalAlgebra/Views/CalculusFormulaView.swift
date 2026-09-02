//
//  CalculusFormulaView.swift
//  RelationalAlgebra
//
//  The tuple-relational-calculus expression for the current query, together
//  with the fidelity notes, the relations it ranges over, and a legend for the
//  logic glyphs.
//

import SwiftUI
import UIKit

struct CalculusFormulaView: View {
    @EnvironmentObject private var viewModel: AppViewModel

    var body: some View {
        if let translation = viewModel.calculus {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    FidelityBanner(diagnostics: translation.diagnostics)
                    CalculusFormulaCard(translation: translation)
                    RangeRelationsCard(schema: translation.schema)
                    legend
                }
                .padding()
            }
        } else {
            EmptyResultView(systemImage: "textformat.abc.dottedunderline",
                            message: "The relational-calculus expression appears here once the SQL parses.")
        }
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Notation").font(.headline)
            ForEach(Self.legendEntries, id: \.symbol) { entry in
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text(entry.symbol)
                        .font(.system(.title3, design: .serif))
                        .frame(width: 26, alignment: .center)
                        .foregroundStyle(Color.accentColor)
                    Text(entry.meaning)
                        .font(.subheadline)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
    }

    static let legendEntries: [(symbol: String, meaning: String)] = [
        ("{ … | … }", "Set builder — result columns, then the condition they satisfy"),
        (CalcSymbol.exists, "There exists a tuple such that …"),
        (CalcSymbol.forAll, "For every tuple …"),
        (CalcSymbol.and,    "And"),
        (CalcSymbol.or,     "Or"),
        (CalcSymbol.not,    "Not"),
        ("R(t)",            "The tuple variable t ranges over relation R"),
        ("t.a",             "Attribute a of the tuple t"),
    ]
}

/// The expression itself, line-broken, in a scrollable monospaced block.
struct CalculusFormulaCard: View {
    let translation: CalcTranslation

    private var pretty: String { translation.prettyText() }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Tuple relational calculus", systemImage: "function")
                    .font(.headline)
                Spacer()
                Button {
                    UIPasteboard.general.string = pretty
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
            }

            ScrollView(.horizontal, showsIndicators: true) {
                Text(pretty)
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
/// because it is what a domain-calculus atom will need, and the source badge
/// says how much to trust it.
struct RangeRelationsCard: View {
    let schema: QuerySchema

    private var relations: [RelationSchema] { schema.sortedRelations }

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
