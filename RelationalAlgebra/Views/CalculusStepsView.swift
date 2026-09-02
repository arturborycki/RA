//
//  CalculusStepsView.swift
//  RelationalAlgebra
//
//  The construction sequence for the calculus expression.
//
//  Unlike the algebra's derivation, which names a new relation at every step,
//  this builds one formula: each card shows the whole expression as it stands
//  and calls out the part that step introduced.
//

import SwiftUI
import UIKit

struct CalculusStepsView: View {
    @EnvironmentObject private var viewModel: AppViewModel

    var body: some View {
        if let translation = viewModel.calculus, !translation.steps.isEmpty {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    FidelityBanner(diagnostics: translation.diagnostics)

                    ForEach(translation.steps) { step in
                        CalculusStepCard(step: step)
                    }

                    finalCard(translation)
                }
                .padding()
            }
        } else {
            EmptyResultView(systemImage: "list.number",
                            message: "The construction sequence appears here once the SQL parses.")
        }
    }

    private func finalCard(_ translation: CalcTranslation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Final expression", systemImage: "checkmark.seal.fill")
                .font(.headline)
                .foregroundStyle(.green)
            Text("One formula, built in \(translation.steps.count) steps — not a chain of " +
                 "intermediate relations. The calculus says *what* the answer is; the algebra " +
                 "says how to compute it.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            CalculusText(text: translation.prettyText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.green.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.green.opacity(0.35), lineWidth: 1))
    }
}

struct CalculusStepCard: View {
    let step: CalcStep

    private var running: String { CalcRenderer().pretty(step.expression) }

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
                Spacer(minLength: 0)
            }

            Text(step.explanation)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let added = step.added, !added.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Text("adds")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.top, 3)
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(added)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(Color.accentColor)
                            .textSelection(.enabled)
                    }
                }
            }

            CalculusText(text: running)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
    }
}

/// Monospaced, horizontally scrollable formula display with a copy button.
struct CalculusText: View {
    let text: String

    var body: some View {
        HStack(alignment: .top) {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .lineSpacing(3)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.vertical, 2)
            }
            Button {
                UIPasteboard.general.string = text
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
