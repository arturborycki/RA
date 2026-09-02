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
    @AppStorage("appTheme") private var appTheme: AppTheme = .system
    @AppStorage("notation") private var notation: Notation = .ra
    @AppStorage("resultTab") private var selectedTab: ResultTab = .steps
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            EditorView()
                .navigationTitle("SQL")
                .navigationBarTitleDisplayMode(.inline)
        } detail: {
            ResultsView(notation: $notation, selectedTab: $selectedTab)
                .navigationTitle(notation.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        ThemePicker(theme: $appTheme)
                    }
                }
        }
        .navigationSplitViewStyle(.balanced)
        .preferredColorScheme(appTheme.colorScheme)
    }
}

/// A menu that lets the user pick System / Light / Dark appearance.
struct ThemePicker: View {
    @Binding var theme: AppTheme

    var body: some View {
        Menu {
            Picker("Appearance", selection: $theme) {
                ForEach(AppTheme.allCases) { option in
                    Label(option.label, systemImage: option.systemImage).tag(option)
                }
            }
        } label: {
            Label("Appearance", systemImage: theme.systemImage)
        }
        .help("Appearance: \(theme.label)")
    }
}

/// The right-hand results pane. Two orthogonal pickers: which notation to show,
/// and which view of it. The view picker is hidden when the selected notation
/// offers only one, so the chrome grows only as the notations do.
struct ResultsView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @Binding var notation: Notation
    @Binding var selectedTab: ResultTab

    private var tabs: [ResultTab] { notation.availableTabs }

    /// The selected tab, corrected to one this notation can actually show.
    private var activeTab: ResultTab {
        tabs.contains(selectedTab) ? selectedTab : (tabs.first ?? .formula)
    }

    var body: some View {
        // GeometryReader resolves to the detail area's *actual* finite size.
        // Hard-constraining the stack to that height gives the inner scroll
        // views a bounded viewport, so they scroll instead of overflowing.
        GeometryReader { geo in
            VStack(spacing: 0) {
                VStack(spacing: 10) {
                    NotationPicker(notation: $notation)

                    if tabs.count > 1 {
                        Picker("View", selection: $selectedTab) {
                            ForEach(tabs) { tab in
                                Label(tab.rawValue, systemImage: tab.systemImage).tag(tab)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }
                .padding()

                if let error = viewModel.errorMessage {
                    ErrorBanner(message: error)
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                }

                Divider()

                resultContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
        .background(Color(.systemGroupedBackground))
    }

    @ViewBuilder
    private var resultContent: some View {
        switch notation {
        case .ra:
            switch activeTab {
            case .steps:   StepsView()
            case .formula: FormulaView()
            case .diagram: TreeView()
            }
        case .trc:
            CalculusFormulaView()
        }
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
