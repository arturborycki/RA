//
//  ContentView.swift
//  RelationalAlgebra
//
//  Two-column iPad layout: the editor on the left — SQL or relational algebra —
//  and every notation derived from it on the right.
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
    @Environment(\.horizontalSizeClass) private var sizeClass
    @AppStorage("appTheme") private var appTheme: AppTheme = .system
    @AppStorage("notation") private var notation: Notation = .ra
    @AppStorage("resultTab") private var selectedTab: ResultTab = .steps
    @AppStorage("phoneTab") private var phoneTab: PhoneTab = .sql
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        Group {
            // A two-column split view collapses on a phone, and what it
            // collapses to is the editor alone — the notations, which are the
            // point of the app, are behind a back button most people never
            // look for. At compact width the two panes become two tabs
            // instead, so switching to a notation is one obvious tap.
            if sizeClass == .compact {
                phoneLayout
            } else {
                splitLayout
            }
        }
        .preferredColorScheme(appTheme.colorScheme)
        // Typing algebra is asking for its SQL, so show that first. Switching
        // back to SQL needs nothing: the SQL notation is simply not offered
        // there, and the results pane falls back to the algebra.
        .onChange(of: viewModel.inputLanguage) { _, language in
            if language != .sql { notation = .sql }
        }
    }

    /// The notation actually shown: the stored one when this input offers it.
    private var shownNotation: Notation {
        Notation.options(for: viewModel.inputLanguage).contains(notation) ? notation : .ra
    }

    private var splitLayout: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            EditorView()
                .navigationTitle(viewModel.inputLanguage.title)
                .navigationBarTitleDisplayMode(.inline)
        } detail: {
            ResultsView(notation: $notation, selectedTab: $selectedTab)
                .navigationTitle(shownNotation.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        ThemePicker(theme: $appTheme)
                    }
                }
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var phoneLayout: some View {
        TabView(selection: $phoneTab) {
            NavigationStack {
                EditorView()
                    .navigationTitle(viewModel.inputLanguage.title)
                    .navigationBarTitleDisplayMode(.inline)
            }
            .tabItem { Label(viewModel.inputLanguage.rawValue, systemImage: PhoneTab.sql.systemImage) }
            .tag(PhoneTab.sql)

            NavigationStack {
                ResultsView(notation: $notation, selectedTab: $selectedTab)
                    .navigationTitle(shownNotation.title)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            ThemePicker(theme: $appTheme)
                        }
                    }
            }
            .tabItem { Label(PhoneTab.result.label, systemImage: PhoneTab.result.systemImage) }
            .tag(PhoneTab.result)
        }
    }
}

/// The two halves of the iPad layout, as tabs for a phone.
enum PhoneTab: String, CaseIterable, Identifiable {
    case sql
    case result

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sql:    return "SQL"
        case .result: return "Notation"
        }
    }

    var systemImage: String {
        switch self {
        case .sql:    return "text.alignleft"
        case .result: return "function"
        }
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

    private var options: [Notation] { Notation.options(for: viewModel.inputLanguage) }

    /// The selected notation, corrected to one this input offers.
    private var activeNotation: Notation {
        options.contains(notation) ? notation : .ra
    }

    private var notationSelection: Binding<Notation> {
        Binding(get: { activeNotation }, set: { notation = $0 })
    }

    private var tabs: [ResultTab] { activeNotation.availableTabs }

    /// The selected tab, corrected to one this notation can actually show.
    private var activeTab: ResultTab {
        tabs.contains(selectedTab) ? selectedTab : (tabs.first ?? .formula)
    }

    /// Compare mode shows every notation at once, so it has no view axis.
    private var showsViewPicker: Bool { tabs.count > 1 }

    var body: some View {
        // GeometryReader resolves to the detail area's *actual* finite size.
        // Hard-constraining the stack to that height gives the inner scroll
        // views a bounded viewport, so they scroll instead of overflowing.
        GeometryReader { geo in
            VStack(spacing: 0) {
                VStack(spacing: 10) {
                    NotationPicker(notation: notationSelection, options: options)

                    if showsViewPicker {
                        Picker("View", selection: $selectedTab) {
                            ForEach(tabs) { tab in
                                Label(tab == .diagram ? activeNotation.diagramLabel : tab.rawValue,
                                      systemImage: tab.systemImage).tag(tab)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }
                .padding()

                if let error = viewModel.errorMessage {
                    ErrorBanner(title: viewModel.inputLanguage == .sql
                                       ? "Could not parse SQL"
                                       : "Could not read the \(viewModel.inputLanguage.title.lowercased())",
                                message: error)
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
        switch activeNotation {
        case .sql:
            switch activeTab {
            case .steps: SQLStepsView()
            default:     SQLResultView()
            }
        case .ra:
            switch activeTab {
            case .steps:   StepsView()
            case .formula: FormulaView()
            case .diagram: TreeView(root: viewModel.tree)
            }
        case .compare:
            CompareView()

        case .trc, .drc:
            if let translation = viewModel.calculus(activeNotation) {
                switch activeTab {
                case .steps:   CalculusStepsView(translation: translation)
                case .diagram: TreeView(root: translation.simplified.scopeTree)
                default:       CalculusFormulaView(translation: translation)
                }
            } else {
                EmptyResultView(systemImage: "function",
                                message: "The \(activeNotation.title.lowercased()) expression " +
                                         "appears here once the input parses.")
            }
        }
    }
}

struct ErrorBanner: View {
    var title: String = "Could not parse SQL"
    let message: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline).bold()
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
