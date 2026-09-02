//
//  SchemaInspectorView.swift
//  RelationalAlgebra
//
//  What the app knows about each relation, and how to fix it when that is not
//  enough.
//
//  Attribute *order* is the point of this screen. A tuple-calculus atom names
//  one variable and does not care; a domain-calculus atom is positional, so a
//  relation whose columns were reconstructed from the query's own references
//  cannot be written exactly. The inspector says which relations are in that
//  state and offers the one thing that fixes it — a `CREATE TABLE` pasted above
//  the query.
//

import SwiftUI

struct SchemaInspectorView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    private var relations: [RelationSchema] { viewModel.schema?.sortedRelations ?? [] }
    private var incomplete: [RelationSchema] { relations.filter { !$0.arityKnown } }

    var body: some View {
        NavigationStack {
            List {
                if relations.isEmpty {
                    Section {
                        Text("No relations yet — the schema appears here once the SQL parses.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        ForEach(relations, id: \.name) { relation in
                            RelationRow(relation: relation)
                        }
                    } header: {
                        Text("Relations")
                    } footer: {
                        Text("Columns are shown in the order a domain-calculus atom would use " +
                             "them. A trailing … marks a list that may be incomplete.")
                    }
                }

                if !incomplete.isEmpty {
                    Section {
                        Text(templateHint)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                        Button {
                            insertTemplate()
                        } label: {
                            Label("Insert CREATE TABLE template", systemImage: "text.badge.plus")
                        }
                    } header: {
                        Text("Make the domain calculus exact")
                    } footer: {
                        Text(incompleteFooter)
                    }
                }
            }
            .navigationTitle("Schema")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var incompleteFooter: String {
        let subject = incomplete.count == 1
            ? "One relation was"
            : "\(incomplete.count) relations were"
        return "\(subject) reconstructed from the query's column references, so the arity and "
            + "order are a guess. Declaring the table replaces that guess."
    }

    /// A skeleton for every relation whose columns are only inferred, with the
    /// columns the query does mention pre-filled in the order they were seen.
    private var templateHint: String {
        incomplete.map { relation in
            let columns = relation.attributes.isEmpty
                ? ["column_name"]
                : relation.attributes
            let body = columns.map { "    \($0)," }.joined(separator: "\n")
            return "CREATE TABLE \(relation.name) (\n\(body)\n);"
        }.joined(separator: "\n\n")
    }

    private func insertTemplate() {
        viewModel.replaceText(templateHint + "\n\n" + viewModel.sqlText)
        dismiss()
    }
}

private struct RelationRow: View {
    let relation: RelationSchema

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(relation.name)
                    .font(.headline.monospaced())
                Text(relation.source.label)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(tint.opacity(0.18)))
                    .foregroundStyle(tint)
                Spacer(minLength: 0)
                Text(arity)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if relation.attributes.isEmpty {
                Text("No columns of this relation are named anywhere in the query.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                // Numbered, because the number *is* the position in a DRC atom.
                ForEach(Array(relation.attributes.enumerated()), id: \.offset) { index, attribute in
                    HStack(spacing: 10) {
                        Text("\(index + 1)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 16, alignment: .trailing)
                        Text(attribute)
                            .font(.system(.subheadline, design: .monospaced))
                        Spacer(minLength: 0)
                    }
                }
                if !relation.arityKnown {
                    Text("…  more columns may exist")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var tint: Color { relation.arityKnown ? .green : .orange }

    private var arity: String {
        relation.arityKnown ? "\(relation.attributes.count) columns"
                            : "\(relation.attributes.count)+ columns"
    }
}
