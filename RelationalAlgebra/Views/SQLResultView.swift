//
//  SQLResultView.swift
//  RelationalAlgebra
//
//  The SQL an algebra expression was translated into.
//
//  It is shown as text to copy and run, not as a derivation: the point of this
//  direction is "what would I type into the database?", and the other notations
//  — all derived from this same SQL — are one tap away for the "why".
//

import SwiftUI
import UIKit

struct SQLResultView: View {
    @EnvironmentObject private var viewModel: AppViewModel

    var body: some View {
        if let generated = viewModel.result?.sql {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Picker("Engine", selection: $viewModel.sqlDialect) {
                        ForEach(SQLDialect.allCases) { dialect in
                            Text(dialect.rawValue).tag(dialect)
                        }
                    }
                    .pickerStyle(.segmented)
                    FidelityBanner(diagnostics: generated.diagnostics)
                    SQLCard(sql: generated.text) {
                        viewModel.editGeneratedSQL()
                    }
                }
                .padding()
            }
        } else {
            EmptyResultView(systemImage: "text.alignleft",
                            message: "The SQL appears here once the input parses.")
        }
    }
}

/// The generated SQL in a copyable, monospaced block.
struct SQLCard: View {
    let sql: String
    /// Moves the SQL into the SQL editor.
    var onEdit: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Label("SQL", systemImage: "text.alignleft")
                        .font(.headline)
                    Text("Copy it into DuckDB or DataFusion and run it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    UIPasteboard.general.string = sql
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Copy SQL")
            }

            ScrollView(.horizontal, showsIndicators: true) {
                Text(SyntaxColors.attributed(sql, language: .sql))
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .lineSpacing(4)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(12)
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(.tertiarySystemGroupedBackground)))

            if let onEdit {
                Button(action: onEdit) {
                    Label("Edit as SQL", systemImage: "square.and.pencil")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
    }
}
