//
//  AppViewModel.swift
//  RelationalAlgebra
//
//  Owns the editable SQL text and derives every notation from it. Parsing runs
//  automatically (debounced) whenever the text changes; the query is parsed once
//  and translated into each notation from the same AST.
//

import Foundation
import Combine

/// Everything derived from one successful parse. The translators are pure and
/// walk trees of at most a few hundred nodes, so producing all notations up
/// front costs microseconds — well inside the debounce — and keeps switching
/// notations instant.
struct TranslationBundle {
    var ra: RATranslation
    var trc: CalcTranslation
    var drc: CalcTranslation
    var schema: QuerySchema
}

@MainActor
final class AppViewModel: ObservableObject {

    @Published var sqlText: String = SampleQueries.all[0].text {
        didSet { scheduleParse() }
    }

    /// Everything derived from the current text, if it parses.
    @Published private(set) var result: TranslationBundle? = nil
    /// A parse / lex error message, if any.
    @Published private(set) var errorMessage: String? = nil
    /// Character offset of the error, for highlighting.
    @Published private(set) var errorPosition: Int? = nil

    private var parseTask: Task<Void, Never>?

    init() {
        parseNow()
    }

    /// The relational-algebra translation, or `nil` when parsing failed.
    var translation: RATranslation? { result?.ra }

    /// The tuple-relational-calculus translation.
    var trc: CalcTranslation? { result?.trc }

    /// The domain-relational-calculus translation.
    var drc: CalcTranslation? { result?.drc }

    func calculus(_ notation: Notation) -> CalcTranslation? {
        switch notation {
        case .ra:  return nil
        case .trc: return trc
        case .drc: return drc
        }
    }

    /// What the translator worked out about each relation.
    var schema: QuerySchema? { result?.schema }

    /// The final one-line RA formula, or `nil` when parsing failed.
    var finalFormula: String? {
        translation?.finalExpression.formula
    }

    /// The tree for the visual canvas.
    var tree: DiagramNode? {
        translation?.finalExpression.tree
    }

    func load(sample: SampleQuery) {
        // `text`, not `sql`: a sample that carries table declarations loads them
        // too, which is what makes its domain-calculus atoms exact.
        sqlText = sample.text
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
            result = nil
            errorMessage = nil
            errorPosition = nil
            return
        }
        do {
            let script = try SQLParser.parseScript(text)
            result = AppViewModel.translate(script)
            errorMessage = nil
            errorPosition = nil
        } catch let error as ParseError {
            result = nil
            errorMessage = error.message
            errorPosition = error.position
        } catch let error as LexError {
            result = nil
            errorMessage = error.message
            errorPosition = error.position
        } catch {
            result = nil
            errorMessage = error.localizedDescription
            errorPosition = nil
        }
    }

    /// The whole translation pipeline, as a pure function.
    ///
    /// `nonisolated` because it reads no actor state — it takes a parsed script
    /// and returns a value. That is what lets a test drive it directly, and it
    /// is also true: nothing here needs the main actor.
    nonisolated static func translate(_ script: SQLScript) -> TranslationBundle {
        let query = script.query
        let inference = SchemaInference.infer(query, declarations: script.declarations)

        var trc = TRCTranslator().translate(query, schema: inference.schema).simplifying()
        var drc = DRCLowering.lower(trc).simplifying()

        // Schema ambiguities are as much a fidelity note as a translation
        // fallback, and safety findings belong beside them: all three are
        // reasons not to take the rendered formula entirely at face value.
        trc.diagnostics = (inference.diagnostics + trc.diagnostics
                           + SafetyChecker.check(trc)).deduplicated
        drc.diagnostics = (inference.diagnostics + drc.diagnostics
                           + SafetyChecker.check(drc)).deduplicated

        return TranslationBundle(ra: RATranslator().translate(query),
                                 trc: trc,
                                 drc: drc,
                                 schema: inference.schema)
    }
}
