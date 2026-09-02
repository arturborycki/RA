//
//  CompareView.swift
//  RelationalAlgebra
//
//  All three notations for the same query, stacked.
//
//  This is the screen the app exists for: the point of teaching algebra and
//  calculus side by side is that they say the same thing differently, and that
//  is much easier to see than to describe. On an iPad in landscape all three
//  fit at once.
//

import SwiftUI
import UIKit

struct CompareView: View {
    @EnvironmentObject private var viewModel: AppViewModel

    var body: some View {
        if let result = viewModel.result {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ComparePane(
                        title: "Relational algebra",
                        subtitle: "Operators applied to relations — how to compute the answer.",
                        text: result.ra.finalExpression.prettyFormula,
                        exports: [
                            (CalcRenderer.Style.unicode.label, result.ra.finalExpression.formula),
                            (CalcRenderer.Style.latex.label, result.ra.finalExpression.latex)
                        ])

                    ComparePane(
                        title: "Tuple relational calculus",
                        subtitle: "Variables ranging over tuples — what the answer is.",
                        text: result.trc.simplifiedText(),
                        exports: exports(for: result.trc))

                    ComparePane(
                        title: "Domain relational calculus",
                        subtitle: "One variable per column, positional atoms.",
                        text: result.drc.simplifiedText(),
                        exports: exports(for: result.drc))

                    FidelityBanner(diagnostics: result.trc.diagnostics)
                }
                .padding()
            }
        } else {
            EmptyResultView(systemImage: "rectangle.split.3x1",
                            message: "All three notations appear here once the SQL parses.")
        }
    }

    private func exports(for translation: CalcTranslation) -> [(String, String)] {
        var view = translation
        view.root = translation.simplified
        return CalcRenderer.Style.allCases.map { style in
            (style.label, CalcRenderer(style: style).inline(view))
        }
    }
}

/// One notation's block: a heading, one line on what it is, the expression, and
/// a copy menu offering each export form.
struct ComparePane: View {
    let title: String
    let subtitle: String
    let text: String
    /// (label, text) pairs for the copy menu.
    let exports: [(String, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                ExportMenu(exports: exports)
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

/// Copy the expression in whichever form the destination wants — the screen
/// glyphs, plain text, or LaTeX for writing an answer up.
struct ExportMenu: View {
    let exports: [(String, String)]

    var body: some View {
        Menu {
            ForEach(Array(exports.enumerated()), id: \.offset) { _, export in
                Button {
                    UIPasteboard.general.string = export.1
                } label: {
                    Label("Copy as \(export.0)", systemImage: "doc.on.doc")
                }
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
        }
        .buttonStyle(.borderless)
    }
}
