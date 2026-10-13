//
//  HighlightingEditor.swift
//  RelationalAlgebra
//
//  The editor's text view, with syntax colouring.
//
//  SwiftUI's TextEditor cannot show attributed text on iOS 17, so this wraps a
//  UITextView and recolours its text storage after every edit — the text and
//  the cursor stay where they are; only attributes change. Owning the text view
//  brings three more things the plain editor could not do:
//
//    · smart quotes and dashes are off, so a typed ' stays a quote SQL reads;
//    · the glyph keys insert at the cursor directly;
//    · the position a parse error names is underlined in place.
//

import SwiftUI
import UIKit

/// The colours, for both the editor and read-only SQL. System colours, so they
/// follow light and dark mode. Columns keep the text colour: they are the most
/// common word, and colouring them too would leave nothing standing out.
enum SyntaxColors {
    static var font: UIFont {
        UIFont.monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize,
                                    weight: .regular)
    }

    static func color(for kind: SyntaxClass) -> UIColor {
        switch kind {
        case .keyword:  return .systemPink
        case .symbol:   return .systemOrange
        case .relation: return .systemBlue
        case .column:   return .label
        case .variable: return .systemPurple
        case .string:   return .systemRed
        case .number:   return .systemIndigo
        case .comment:  return .secondaryLabel
        }
    }

    static var base: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: UIColor.label]
    }

    static func attributes(for kind: SyntaxClass) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color(for: kind)]
        if kind == .keyword {
            attributes[.font] = UIFont.monospacedSystemFont(ofSize: font.pointSize, weight: .semibold)
        }
        return attributes
    }

    /// Coloured text for a read-only view, such as the generated SQL.
    static func attributed(_ text: String, language: InputLanguage) -> AttributedString {
        var result = AttributedString(text)
        for token in SyntaxHighlighter.tokens(in: text, language: language) {
            guard let lower = AttributedString.Index(token.range.lowerBound, within: result),
                  let upper = AttributedString.Index(token.range.upperBound, within: result)
            else { continue }
            result[lower..<upper].foregroundColor = Color(uiColor: color(for: token.kind))
            if token.kind == .keyword { result[lower..<upper].font = .system(.callout, design: .monospaced).weight(.semibold) }
        }
        return result
    }
}

struct HighlightingEditor: UIViewRepresentable {
    @Binding var text: String
    var language: InputLanguage
    /// Character offset of a parse error to underline, if any.
    var errorOffset: Int?
    /// Glyph keys for the bar above the keyboard, or nil for none.
    var symbols: [String]?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.font = SyntaxColors.font
        view.backgroundColor = .clear
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.spellCheckingType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        view.alwaysBounceVertical = true
        view.keyboardDismissMode = .interactive
        view.delegate = context.coordinator
        view.text = text
        context.coordinator.textView = view
        context.coordinator.installAccessory(on: view)
        context.coordinator.highlight()
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if view.text != text {
            view.text = text
            coordinator.highlight()
        } else if coordinator.highlightedLanguage != language
                    || coordinator.highlightedError != errorOffset {
            coordinator.highlight()
        }
        coordinator.updateAccessory()
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: HighlightingEditor
        weak var textView: UITextView?
        private(set) var highlightedLanguage: InputLanguage?
        private(set) var highlightedError: Int?
        private var accessory: UIHostingController<EditorAccessory>?

        init(_ parent: HighlightingEditor) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            // Mid-composition (a multi-key character being entered), recolouring
            // would disturb the marked text; the next change will catch up.
            if textView.markedTextRange == nil { highlight() }
        }

        func highlight() {
            guard let textView else { return }
            highlightedLanguage = parent.language
            highlightedError = parent.errorOffset

            let text = textView.text ?? ""
            let storage = textView.textStorage
            let selection = textView.selectedRange
            storage.beginEditing()
            storage.setAttributes(SyntaxColors.base, range: NSRange(location: 0, length: storage.length))
            for token in SyntaxHighlighter.tokens(in: text, language: parent.language) {
                storage.addAttributes(SyntaxColors.attributes(for: token.kind),
                                      range: NSRange(token.range, in: text))
            }
            if let offset = parent.errorOffset,
               let range = SyntaxHighlighter.errorRange(in: text, at: offset) {
                storage.addAttributes([.underlineStyle: NSUnderlineStyle.thick.rawValue,
                                       .underlineColor: UIColor.systemRed],
                                      range: NSRange(range, in: text))
            }
            storage.endEditing()
            textView.selectedRange = selection
            textView.typingAttributes = SyntaxColors.base
        }

        // MARK: Keyboard accessory

        func installAccessory(on view: UITextView) {
            let host = UIHostingController(rootView: makeAccessory())
            host.view.frame = CGRect(x: 0, y: 0, width: 320, height: 44)
            host.view.autoresizingMask = [.flexibleWidth]
            host.view.backgroundColor = .secondarySystemBackground
            view.inputAccessoryView = host.view
            accessory = host
        }

        func updateAccessory() {
            accessory?.rootView = makeAccessory()
        }

        private func makeAccessory() -> EditorAccessory {
            EditorAccessory(
                symbols: parent.symbols,
                insert: { [weak self] symbol in
                    guard let self, let textView = self.textView else { return }
                    textView.insertText(symbol)
                    // insertText reports the change on its own on current iOS;
                    // this covers the versions where it does not.
                    if textView.text != self.parent.text { self.textViewDidChange(textView) }
                },
                dismiss: { [weak self] in self?.textView?.resignFirstResponder() })
        }
    }
}

/// The bar above the keyboard: glyph keys for the notation being typed, and a
/// key to put the keyboard away — the iPhone keyboard has none of its own.
struct EditorAccessory: View {
    let symbols: [String]?
    let insert: (String) -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let symbols {
                SymbolBar(symbols: symbols, insert: insert)
            } else {
                Spacer()
            }
            Button(action: dismiss) {
                Image(systemName: "keyboard.chevron.compact.down")
            }
            .accessibilityLabel("Hide keyboard")
            .padding(.trailing, 12)
        }
        .frame(height: 44)
    }
}
