//
//  AppViewModel.swift
//  RelationalAlgebra
//
//  Owns the editable text and derives every notation from it. Parsing runs
//  automatically (debounced) whenever the text changes; the query is parsed once
//  and translated into each notation from the same AST.
//
//  The input need not be SQL. Relational algebra typed into the editor is
//  translated *into* SQL first, and that SQL then runs through the very same
//  pipeline — so every notation the app can show is available whatever the
//  user typed, and SQL is the one hub every direction passes through.
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
    /// The SQL the input was translated into, or `nil` when the input *is* SQL.
    var sql: SQLGeneration? = nil
}

/// What the editor holds.
enum InputLanguage: String, CaseIterable, Identifiable {
    case sql = "SQL"
    case ra = "RA"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sql: return "SQL"
        case .ra:  return "Relational Algebra"
        }
    }

    var placeholder: String {
        switch self {
        case .sql: return "Type, paste, or import a SQL query…"
        case .ra:  return "Type relational algebra, e.g. π[name](σ[salary > 50000](Employee)) " +
                          "— or with words: pi[name](sigma[salary > 50000](Employee))"
        }
    }
}

@MainActor
final class AppViewModel: ObservableObject {

    @Published var sqlText: String = SampleQueries.all[0].text {
        didSet { if inputLanguage == .sql { scheduleParse() } }
    }

    /// The relational-algebra buffer. Each language keeps its own text, so
    /// switching back and forth never destroys anything.
    @Published var raText: String = SampleQueries.raBasics.queries[0].text {
        didSet { if inputLanguage == .ra { scheduleParse() } }
    }

    @Published var inputLanguage: InputLanguage {
        didSet {
            UserDefaults.standard.set(inputLanguage.rawValue, forKey: Self.inputLanguageKey)
            parseNow()
        }
    }

    private static let inputLanguageKey = "inputLanguage"

    /// The text of whichever language is being edited.
    var text: String {
        get {
            switch inputLanguage {
            case .sql: return sqlText
            case .ra:  return raText
            }
        }
        set {
            switch inputLanguage {
            case .sql: sqlText = newValue
            case .ra:  raText = newValue
            }
        }
    }

    /// Everything derived from the current text, if it parses.
    @Published private(set) var result: TranslationBundle? = nil
    /// A parse / lex error message, if any.
    @Published private(set) var errorMessage: String? = nil
    /// Character offset of the error, for highlighting.
    @Published private(set) var errorPosition: Int? = nil

    private var parseTask: Task<Void, Never>?

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.inputLanguageKey)
        inputLanguage = stored.flatMap(InputLanguage.init(rawValue:)) ?? .sql
        parseNow()
    }

    /// The relational-algebra translation, or `nil` when parsing failed.
    var translation: RATranslation? { result?.ra }

    /// The tuple-relational-calculus translation.
    var trc: CalcTranslation? { result?.trc }

    /// The domain-relational-calculus translation.
    var drc: CalcTranslation? { result?.drc }

    /// The calculus translation a notation shows, or `nil` for the notations
    /// that are not a single calculus — the algebra, and compare mode, which
    /// reads `result` directly because it shows all three at once.
    func calculus(_ notation: Notation) -> CalcTranslation? {
        switch notation {
        case .sql, .ra, .compare: return nil
        case .trc:          return trc
        case .drc:          return drc
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
        switch sample.language {
        case .sql: sqlText = sample.text
        case .ra:  raText = sample.text
        }
        inputLanguage = sample.language
    }

    func replaceText(_ text: String) {
        self.text = text
    }

    /// Carry the generated SQL into the SQL editor, which is the round trip
    /// made one tap: edit it there and watch the algebra follow.
    func editGeneratedSQL() {
        guard let generated = result?.sql else { return }
        sqlText = generated.text
        inputLanguage = .sql
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
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func parseNow() {
        let text = self.text
        // An empty editor is not an error — just show empty results.
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            result = nil
            errorMessage = nil
            errorPosition = nil
            return
        }
        do {
            switch inputLanguage {
            case .sql:
                result = AppViewModel.translate(try SQLParser.parseScript(text))
            case .ra:
                result = try AppViewModel.translate(ra: try RAParser.parseScript(text))
            }
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

    /// Relational algebra in: translate it to SQL, then run that SQL through the
    /// ordinary pipeline. The declarations travel along, so a schema typed above
    /// the algebra makes the domain calculus exact just as it does for SQL.
    nonisolated static func translate(ra script: RAScript) throws -> TranslationBundle {
        let generated = try RAToSQL.translate(script.expression)
        var bundle = translate(SQLScript(declarations: script.declarations,
                                         query: generated.query))
        bundle.sql = generated
        return bundle
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
