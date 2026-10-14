//
//  SQLStepsView.swift
//  RelationalAlgebra
//
//  How typed algebra became SQL, one operator at a time.
//
//  The cards run bottom-up — relations first, the outermost operator last —
//  which is the order the forward derivation uses too. Each shows the
//  sub-expression, the SQL it amounts to at that point, and *how* it was folded
//  in: a σ adding to WHERE rather than starting a new SELECT is exactly the
//  thing worth seeing.
//

import SwiftUI

struct SQLStepsView: View {
    @EnvironmentObject private var viewModel: AppViewModel

    var body: some View {
        if let generated = viewModel.result?.sql {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    FidelityBanner(diagnostics: generated.diagnostics)
                    ForEach(generated.steps) { step in
                        ReverseStepCard(step: step)
                    }
                    SQLCard(sql: generated.text) {
                        viewModel.editGeneratedSQL()
                    }
                }
                .padding()
            }
        } else {
            EmptyResultView(systemImage: "list.number",
                            message: "The translation steps appear here once the input parses.")
        }
    }
}

struct ReverseStepCard: View {
    let step: ReverseStep

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("\(step.index)")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.accentColor))
                Text(step.title).font(.headline)
                Spacer()
            }

            if !step.algebra.isEmpty {
                FormulaText(formula: step.algebra)
            }

            Text(step.explanation)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !step.sql.isEmpty {
                FormulaText(formula: step.sql)
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
    }
}
