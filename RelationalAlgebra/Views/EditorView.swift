//
//  EditorView.swift
//  RelationalAlgebra
//
//  The SQL input surface. Supports typing, pasting from the clipboard, and
//  importing a `.sql` (or plain text) file via the document picker.
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct EditorView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @State private var showImporter = false
    @State private var showSchema = false
    @State private var importError: String?
    @FocusState private var editorFocused: Bool
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        VStack(spacing: 0) {
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
            if viewModel.sqlText.isEmpty {
                Text("Type, paste, or import a SQL query…")
                    .foregroundStyle(.secondary)
                    .font(.system(.body, design: .monospaced))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $viewModel.sqlText)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled(true)
                .textInputAutocapitalization(.never)
                .focused($editorFocused)
                .padding(12)
                .scrollContentBackground(.hidden)
                .background(Color(.secondarySystemGroupedBackground))
                // On the text editor itself, not in the screen's toolbar
                // builder alongside the primary-action group: a keyboard group
                // sharing a builder with other placements does not reliably
                // reach the accessory bar. The iPhone keyboard covers most of
                // the editor and has no hide key of its own, so this is the
                // only way back out of it.
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button {
                            editorFocused = false
                        } label: {
                            Image(systemName: "keyboard.chevron.compact.down")
                        }
                        .accessibilityLabel("Hide keyboard")
                    }
                }
        }
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
            Text("\(lineCount) lines · \(viewModel.sqlText.count) chars")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(.systemGroupedBackground))
    }

    private var lineCount: Int {
        viewModel.sqlText.isEmpty ? 0 : viewModel.sqlText.split(separator: "\n", omittingEmptySubsequences: false).count
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
            ForEach(SampleQueries.groups) { group in
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
            editorFocused = true
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
