//
//  Token.swift
//  RelationalAlgebra
//

import Foundation

enum TokenKind: Equatable {
    case keyword       // SELECT, FROM, WHERE, ...
    case identifier    // table / column names
    case number        // 42, 3.14
    case string        // 'text'
    case op            // = <> < > <= >= + - * / etc.
    case comma
    case dot
    case leftParen
    case rightParen
    case star          // bare *
    case semicolon
    case eof
}

struct Token: Equatable {
    let kind: TokenKind
    let text: String
    /// Character offset in the original source, for error reporting.
    let position: Int
}
