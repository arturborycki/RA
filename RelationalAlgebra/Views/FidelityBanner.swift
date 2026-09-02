//
//  FidelityBanner.swift
//  RelationalAlgebra
//
//  Shows which parts of a query were not translated exactly, and why.
//
//  This is the honesty guarantee that makes the calculus views trustworthy: a
//  formula that quietly drops ORDER BY, or presents an inferred arity as fact,
//  is one a grader would mark wrong. The banner collapses to a summary line and
//  expands to the full list; when everything was exact it does not appear.
//

import SwiftUI

struct FidelityBanner: View {
    let diagnostics: [CalcDiagnostic]
    @State private var expanded = false

    private var entries: [CalcDiagnostic] { diagnostics.presentationOrder }
    private var warnings: Int { diagnostics.warningCount }

    var body: some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: warnings > 0 ? "exclamationmark.triangle.fill" : "info.circle.fill")
                            .foregroundStyle(warnings > 0 ? Color.orange : Color.accentColor)
                        Text(summary)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(expanded ? 0 : -90))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if expanded {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(entries) { entry in
                            DiagnosticRow(diagnostic: entry)
                        }
                    }
                    .padding(.top, 12)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill((warnings > 0 ? Color.orange : Color.accentColor).opacity(0.10))
            )
        }
    }

    private var summary: String {
        let constructs = entries.prefix(3).map(\.construct).joined(separator: " · ")
        let more = entries.count > 3 ? " · +\(entries.count - 3) more" : ""
        if warnings == 0 {
            return "Translated exactly. \(constructs)\(more)"
        }
        let noun = warnings == 1 ? "note" : "notes"
        return "\(warnings) \(noun): \(constructs)\(more)"
    }
}

private struct DiagnosticRow: View {
    let diagnostic: CalcDiagnostic

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(diagnostic.badge)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(tint.opacity(0.18)))
                .foregroundStyle(tint)
                .fixedSize()

            VStack(alignment: .leading, spacing: 2) {
                Text(diagnostic.construct)
                    .font(.caption.weight(.semibold).monospaced())
                Text(diagnostic.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var tint: Color {
        if diagnostic.kind == .safety { return .red }
        switch diagnostic.fidelity {
        case .exact:     return .green
        case .extended:  return .orange
        case .annotated: return .purple
        }
    }
}
