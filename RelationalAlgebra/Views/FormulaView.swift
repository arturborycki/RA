//
//  FormulaView.swift
//  RelationalAlgebra
//
//  Shows the final relational-algebra expression on its own, plus a legend of
//  the operator glyphs so the notation is self-explanatory.
//

import SwiftUI

struct FormulaView: View {
    @EnvironmentObject private var viewModel: AppViewModel

    var body: some View {
        if let expression = viewModel.translation?.finalExpression {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Relational algebra expression").font(.headline)
                        FormulaText(formula: expression.formula)
                    }

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
        VStack(alignment: .leading, spacing: 10) {
            Text("Notation").font(.headline)
            ForEach(Self.legendEntries, id: \.symbol) { entry in
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text(entry.symbol)
                        .font(.system(.title3, design: .serif))
                        .frame(width: 28, alignment: .center)
                        .foregroundStyle(Color.accentColor)
                    Text(entry.meaning)
                        .font(.subheadline)
                    Spacer()
                }
                .padding(.vertical, 2)
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
