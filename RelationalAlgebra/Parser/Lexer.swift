//
//  Lexer.swift
//  RelationalAlgebra
//
//  Hand-written scanner that turns a SQL string into a flat token stream.
//  Comments (`--` and `/* */`) are skipped; string literals keep their raw
//  contents (without the surrounding quotes) in the token text.
//

import Foundation

struct LexError: Error, LocalizedError {
    let message: String
    let position: Int
    var errorDescription: String? { message }
}

/// The set of reserved words the parser recognises. Everything else is treated
/// as an identifier. Comparison is case-insensitive.
enum SQLKeyword {
    static let all: Set<String> = [
        "SELECT", "DISTINCT", "ALL", "FROM", "WHERE", "GROUP", "BY", "HAVING",
        "ORDER", "ASC", "DESC", "AS", "JOIN", "INNER", "LEFT", "RIGHT", "FULL",
        "OUTER", "CROSS", "ON", "USING", "AND", "OR", "NOT", "IN", "IS", "NULL",
        "BETWEEN", "LIKE", "UNION", "INTERSECT", "EXCEPT", "LIMIT", "TRUE",
        "FALSE", "COUNT", "SUM", "AVG", "MIN", "MAX", "EXISTS", "FOR"
    ]
}

struct Lexer {
    private let scalars: [Character]
    private var index = 0

    init(_ source: String) {
        self.scalars = Array(source)
    }

    func tokenize() throws -> [Token] {
        var copy = self
        return try copy.run()
    }

    private mutating func run() throws -> [Token] {
        var tokens: [Token] = []
        while true {
            skipWhitespaceAndComments()
            guard index < scalars.count else {
                tokens.append(Token(kind: .eof, text: "", position: index))
                return tokens
            }
            let start = index
            let c = scalars[index]

            if c == "'" || c == "\"" {
                tokens.append(try scanString(quote: c))
            } else if c.isNumber || (c == "." && peekNext()?.isNumber == true) {
                tokens.append(scanNumber())
            } else if c.isLetter || c == "_" {
                tokens.append(scanIdentifierOrKeyword())
            } else {
                switch c {
                case ",":
                    tokens.append(Token(kind: .comma, text: ",", position: start)); index += 1
                case "(":
                    tokens.append(Token(kind: .leftParen, text: "(", position: start)); index += 1
                case ")":
                    tokens.append(Token(kind: .rightParen, text: ")", position: start)); index += 1
                case ";":
                    tokens.append(Token(kind: .semicolon, text: ";", position: start)); index += 1
                case ".":
                    tokens.append(Token(kind: .dot, text: ".", position: start)); index += 1
                case "*":
                    tokens.append(Token(kind: .star, text: "*", position: start)); index += 1
                default:
                    tokens.append(try scanOperator())
                }
            }
        }
    }

    // MARK: Character helpers

    private func peek() -> Character? { index < scalars.count ? scalars[index] : nil }
    private func peekNext() -> Character? { index + 1 < scalars.count ? scalars[index + 1] : nil }

    private mutating func skipWhitespaceAndComments() {
        while index < scalars.count {
            let c = scalars[index]
            if c.isWhitespace {
                index += 1
            } else if c == "-" && peekNext() == "-" {
                while index < scalars.count && scalars[index] != "\n" { index += 1 }
            } else if c == "/" && peekNext() == "*" {
                index += 2
                while index + 1 < scalars.count && !(scalars[index] == "*" && scalars[index + 1] == "/") {
                    index += 1
                }
                index = min(index + 2, scalars.count)
            } else {
                break
            }
        }
    }

    private mutating func scanString(quote: Character) throws -> Token {
        let start = index
        index += 1 // consume opening quote
        var value = ""
        while index < scalars.count {
            let c = scalars[index]
            if c == quote {
                // Support doubled-quote escaping ('' -> ').
                if peekNext() == quote {
                    value.append(quote)
                    index += 2
                    continue
                }
                index += 1 // consume closing quote
                return Token(kind: .string, text: value, position: start)
            }
            value.append(c)
            index += 1
        }
        throw LexError(message: "Unterminated string literal", position: start)
    }

    private mutating func scanNumber() -> Token {
        let start = index
        var text = ""
        var seenDot = false
        while index < scalars.count {
            let c = scalars[index]
            if c.isNumber {
                text.append(c); index += 1
            } else if c == "." && !seenDot {
                seenDot = true; text.append(c); index += 1
            } else {
                break
            }
        }
        return Token(kind: .number, text: text, position: start)
    }

    private mutating func scanIdentifierOrKeyword() -> Token {
        let start = index
        var text = ""
        while index < scalars.count {
            let c = scalars[index]
            if c.isLetter || c.isNumber || c == "_" {
                text.append(c); index += 1
            } else {
                break
            }
        }
        let isKeyword = SQLKeyword.all.contains(text.uppercased())
        return Token(kind: isKeyword ? .keyword : .identifier, text: text, position: start)
    }

    private mutating func scanOperator() throws -> Token {
        let start = index
        let c = scalars[index]
        let next = peekNext()
        // Two-character operators.
        if c == "<" && next == "=" { index += 2; return Token(kind: .op, text: "<=", position: start) }
        if c == ">" && next == "=" { index += 2; return Token(kind: .op, text: ">=", position: start) }
        if c == "<" && next == ">" { index += 2; return Token(kind: .op, text: "<>", position: start) }
        if c == "!" && next == "=" { index += 2; return Token(kind: .op, text: "!=", position: start) }
        if c == "|" && next == "|" { index += 2; return Token(kind: .op, text: "||", position: start) }

        switch c {
        case "=", "<", ">", "+", "-", "/", "%":
            index += 1
            return Token(kind: .op, text: String(c), position: start)
        default:
            throw LexError(message: "Unexpected character '\(c)'", position: start)
        }
    }
}
