//
//  StepsView.swift
//  RelationalAlgebra
//
//  The step-by-step derivation: an ordered list of cards, each showing the
//  operator applied, a plain-language explanation, and the running RA formula.
//

import SwiftUI
import UIKit

struct StepsView: View {
    @EnvironmentObject private var viewModel: AppViewModel

    var body: some View {
        if let translation = viewModel.translation {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(translation.steps) { step in
                        StepCard(step: step)
                    }

                    finalResultCard(translation)
                }
                .padding()
            }
        } else {
            EmptyResultView(systemImage: "list.number",
                            message: "The derivation appears here once the SQL parses.")
        }
    }

    private func finalResultCard(_ translation: RATranslation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Final expression", systemImage: "checkmark.seal.fill")
                .font(.headline)
                .foregroundStyle(.green)
            FormulaText(translation.finalExpression.formula)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.green.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.green.opacity(0.35), lineWidth: 1))
    }
}

struct StepCard: View {
    let step: RAStep

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("\(step.index)")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.accentColor))
                VStack(alignment: .leading, spacing: 1) {
                    Text(step.title).font(.headline)
                    Text(step.clause)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Text(step.explanation)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            FormulaText(step.expression.formula)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
    }
}

/// Monospaced, horizontally scrollable formula display with a copy button.
struct FormulaText: View {
    let formula: String

    var body: some View {
        HStack(alignment: .top) {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(formula)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.vertical, 2)
            }
            Button {
                UIPasteboard.general.string = formula
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(.tertiarySystemGroupedBackground)))
    }
}

struct EmptyResultView: View {
    let systemImage: String
    let message: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
