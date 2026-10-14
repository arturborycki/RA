//
//  EditorView.swift
//  RelationalAlgebra
//
//  The input surface. Holds SQL or relational algebra — a picker at the top
//  switches between them, each with its own buffer — and supports typing,
//  pasting from the clipboard, and importing a `.sql` (or plain text) file.
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct EditorView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @State private var showImporter = false
    @State private var showSchema = false
    @State private var importError: String?
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        VStack(spacing: 0) {
            Picker("Input", selection: $viewModel.inputLanguage) {
                ForEach(InputLanguage.allCases) { language in
                    Text(language.rawValue).tag(language)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(.systemGroupedBackground))
            Divider()
            editor
            Divider()
            statusBar
        }
        .toolbar { toolbarContent }
        .sheet(isPresented: $showSchema) {
            SchemaInspectorView().environmentObject(viewModel)
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: Self.importTypes,
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        .alert("Import failed", isPresented: .constant(importError != nil)) {
            Button("OK") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
    }

    // MARK: Editor

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            HighlightingEditor(text: $viewModel.text,
                               language: viewModel.inputLanguage,
                               errorOffset: errorOffset,
                               symbols: SymbolBar.symbols(for: viewModel.inputLanguage))
            if viewModel.text.isEmpty {
                // Over the text view, inset to where its first character goes.
                Text(viewModel.inputLanguage.placeholder)
                    .foregroundStyle(.secondary)
                    .font(.system(.body, design: .monospaced))
                    .padding(.horizontal, 17)
                    .padding(.vertical, 16)
                    .allowsHitTesting(false)
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
    }

    /// Where the parse error is, as an offset into the editor's text. The SQL
    /// parser counts from the first non-blank character; the others from the
    /// start of the buffer.
    private var errorOffset: Int? {
        guard let position = viewModel.errorPosition else { return nil }
        guard viewModel.inputLanguage == .sql else { return position }
        return position + viewModel.text.prefix { $0.isWhitespace }.count
    }

    // MARK: Status bar

    private var statusBar: some View {
        HStack {
            if viewModel.isEmpty {
                Label("Empty", systemImage: "text.cursor")
                    .foregroundStyle(.secondary)
            } else if viewModel.errorMessage == nil {
                Label("Parsed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Label("Syntax error", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
            }
            Spacer()
            Text("\(lineCount) lines · \(viewModel.text.count) chars")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(.systemGroupedBackground))
    }

    private var lineCount: Int {
        viewModel.text.isEmpty ? 0 : viewModel.text.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            // Five buttons fit an iPad's navigation bar and crowd a phone's.
            // Examples earns its place either way — it is how most people load
            // a query — and the rest collapse behind one overflow button.
            examplesMenu
            if sizeClass == .compact {
                Menu {
                    editorActions
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            } else {
                editorActions
            }
        }
    }

    private var examplesMenu: some View {
        Menu {
            ForEach(SampleQueries.groups(for: viewModel.inputLanguage)) { group in
                Menu {
                    Section(group.note) {
                        ForEach(group.queries) { sample in
                            Button(sample.title) { viewModel.load(sample: sample) }
                        }
                    }
                } label: {
                    Text(group.title)
                }
            }
        } label: {
            Label("Examples", systemImage: "text.book.closed")
        }
    }

    /// The same buttons whether they sit in the bar or in the overflow menu.
    @ViewBuilder
    private var editorActions: some View {
        if viewModel.inputLanguage != .sql {
            Button {
                viewModel.prettify()
            } label: {
                Label("Prettify", systemImage: "wand.and.stars")
            }
            .disabled(viewModel.errorMessage != nil || viewModel.isEmpty)
        }

        Button {
            showSchema = true
        } label: {
            Label("Schema", systemImage: "tablecells")
        }

        Button {
            paste()
        } label: {
            Label("Paste", systemImage: "doc.on.clipboard")
        }

        Button {
            showImporter = true
        } label: {
            Label("Import", systemImage: "square.and.arrow.down")
        }

        Button(role: .destructive) {
            viewModel.replaceText("")
        } label: {
            Label("Clear", systemImage: "trash")
        }
    }

    // MARK: Actions

    private func paste() {
        if let string = UIPasteboard.general.string {
            viewModel.replaceText(string)
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            guard let url = urls.first else { return }
            let needsStop = url.startAccessingSecurityScopedResource()
            defer { if needsStop { url.stopAccessingSecurityScopedResource() } }
            do {
                let contents = try String(contentsOf: url, encoding: .utf8)
                viewModel.replaceText(contents)
            } catch {
                // Retry with a lenient encoding for non-UTF-8 files.
                if let data = try? Data(contentsOf: url),
                   let text = String(data: data, encoding: .isoLatin1) {
                    viewModel.replaceText(text)
                } else {
                    importError = error.localizedDescription
                }
            }
        case let .failure(error):
            importError = error.localizedDescription
        }
    }

    static var importTypes: [UTType] {
        var types: [UTType] = [.plainText, .text, .data]
        if let sql = UTType(filenameExtension: "sql") {
            types.insert(sql, at: 0)
        }
        return types
    }
}

#Preview {
    NavigationStack {
        EditorView().environmentObject(AppViewModel())
    }
}

/// Glyph keys above the keyboard for typing relational algebra. Every glyph
/// also has a typed word (`sigma`, `join`, …), so the bar is a shortcut, not a
/// requirement.
///
/// A key inserts at the editor's cursor.
struct SymbolBar: View {
    let symbols: [String]
    /// What a key does. The editor inserts at its cursor directly.
    var insert: (String) -> Void = { symbol in
        UIApplication.shared.sendAction(#selector(UIKeyInput.insertText(_:)),
                                        to: nil, from: symbol, for: nil)
    }

    static func symbols(for language: InputLanguage) -> [String]? {
        switch language {
        case .sql:
            return nil
        case .ra:
            return ["σ", "π", "ρ", "⋈", "×", "∪", "∩", "−", "÷", "γ", "τ", "δ", "⟕", "⟖", "⟗",
                    "[", "]", "→", "∧", "∨", "¬", "≠", "≤", "≥", "↑", "↓", "←"]
        case .trc, .drc:
            return ["{", "}", "|", "∃", "∀", "∧", "∨", "¬", "→", "∈", "⟨", "⟩",
                    "≠", "≤", "≥", "…", "∪", "∩", "−", "↑", "↓"]
        }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(symbols, id: \.self) { symbol in
                    Button {
                        insert(symbol)
                    } label: {
                        Text(symbol)
                            .font(.system(.title3, design: .serif))
                            .frame(minWidth: 30)
                    }
                    .accessibilityLabel("Insert \(symbol)")
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}
