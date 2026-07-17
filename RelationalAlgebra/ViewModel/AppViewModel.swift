//
//  AppViewModel.swift
//  RelationalAlgebra
//
//  Owns the editable SQL text and derives the relational-algebra translation
//  from it. Parsing runs automatically (debounced) whenever the text changes.
//

import Foundation
import Combine

@MainActor
final class AppViewModel: ObservableObject {

    @Published var sqlText: String = SampleQueries.all[0].sql {
        didSet { scheduleParse() }
    }

    /// The successful translation, if the current text parses.
    @Published private(set) var translation: RATranslation? = nil
    /// A parse / lex error message, if any.
    @Published private(set) var errorMessage: String? = nil
    /// Character offset of the error, for highlighting.
    @Published private(set) var errorPosition: Int? = nil

    private var parseTask: Task<Void, Never>?

    init() {
        parseNow()
    }

    /// The final one-line RA formula, or `nil` when parsing failed.
    var finalFormula: String? {
        translation?.finalExpression.formula
    }

    /// The tree for the visual canvas.
    var tree: RATreeNode? {
        translation?.finalExpression.tree
    }

    func load(sample: SampleQuery) {
        sqlText = sample.sql
    }

    func replaceText(_ text: String) {
        sqlText = text
    }

    // MARK: - Parsing

    private func scheduleParse() {
        parseTask?.cancel()
        parseTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000) // 250 ms debounce
            guard !Task.isCancelled else { return }
            self?.parseNow()
        }
    }

    /// Whether the editor is empty (ignoring whitespace).
    var isEmpty: Bool {
        sqlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func parseNow() {
        let text = sqlText
        // An empty editor is not an error — just show empty results.
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            translation = nil
            errorMessage = nil
            errorPosition = nil
            return
        }
        do {
            let query = try SQLParser.parse(text)
            let result = RATranslator().translate(query)
            translation = result
            errorMessage = nil
            errorPosition = nil
        } catch let error as ParseError {
            translation = nil
            errorMessage = error.message
            errorPosition = error.position
        } catch let error as LexError {
            translation = nil
            errorMessage = error.message
            errorPosition = error.position
        } catch {
            translation = nil
            errorMessage = error.localizedDescription
            errorPosition = nil
        }
    }
}
