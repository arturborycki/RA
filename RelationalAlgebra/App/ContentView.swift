//
//  ContentView.swift
//  RelationalAlgebra
//
//  Two-column iPad layout: the SQL editor on the left, the derived relational
//  algebra (steps / formula / diagram) on the right.
//

import SwiftUI

enum ResultTab: String, CaseIterable, Identifiable {
    case steps = "Steps"
    case formula = "Formula"
    case diagram = "Diagram"
    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .steps:   return "list.number"
        case .formula: return "function"
        case .diagram: return "point.topleft.down.to.point.bottomright.curvepath"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @State private var selectedTab: ResultTab = .steps
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            EditorView()
                .navigationTitle("SQL")
                .navigationBarTitleDisplayMode(.inline)
        } detail: {
            ResultsView(selectedTab: $selectedTab)
                .navigationTitle("Relational Algebra")
                .navigationBarTitleDisplayMode(.inline)
        }
        .navigationSplitViewStyle(.balanced)
    }
}

/// The right-hand results pane with a tab picker and error banner.
struct ResultsView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @Binding var selectedTab: ResultTab

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $selectedTab) {
                ForEach(ResultTab.allCases) { tab in
                    Label(tab.rawValue, systemImage: tab.systemImage).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding()

            if let error = viewModel.errorMessage {
                ErrorBanner(message: error)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }

            Divider()

            Group {
                switch selectedTab {
                case .steps:   StepsView()
                case .formula: FormulaView()
                case .diagram: TreeView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(.systemGroupedBackground))
    }
}

struct ErrorBanner: View {
    let message: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Could not parse SQL").font(.subheadline).bold()
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.12)))
    }
}

#Preview {
    ContentView().environmentObject(AppViewModel())
}
