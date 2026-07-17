//
//  FormulaView.swift
//  RelationalAlgebra
//
//  Shows the final relational-algebra expression, pretty-printed as an indented
//  tree, plus a legend of the operator glyphs so the notation is self-explanatory.
//

import SwiftUI
import UIKit

struct FormulaView: View {
    @EnvironmentObject private var viewModel: AppViewModel

    var body: some View {
        if let expression = viewModel.translation?.finalExpression {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    PrettyFormulaCard(expression: expression)
                    legend
                }
                .padding()
            }
        } else {
            EmptyResultView(systemImage: "function",
                            message: "The relational-algebra formula appears here once the SQL parses.")
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
        (RASymbol.selection,  "Selection — filter rows (WHERE / HAVING)"),
        (RASymbol.projection, "Projection — choose columns (SELECT)"),
        (RASymbol.rename,     "Rename — alias a relation or attribute (AS)"),
        (RASymbol.join,       "Join — combine matching rows (JOIN … ON)"),
        (RASymbol.leftJoin,   "Left / right / full outer join"),
        (RASymbol.cross,      "Cartesian product (comma / CROSS JOIN)"),
        (RASymbol.group,      "Grouping & aggregation (GROUP BY)"),
        (RASymbol.distinct,   "Duplicate elimination (DISTINCT)"),
        (RASymbol.sort,       "Sort (ORDER BY)"),
        (RASymbol.union,      "Union / intersection / difference"),
    ]
}

/// A card that renders the RA expression pretty-printed over multiple indented
/// lines, in a horizontally-scrollable monospaced block with a copy button.
struct PrettyFormulaCard: View {
    let expression: RANode

    private var pretty: String { expression.prettyFormula }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Relational algebra expression", systemImage: "function")
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
