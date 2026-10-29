import Foundation
import ZPDFContracts

/// Turns formula source into tokens.
///
/// The lexer is deliberately locale-free. `Decimal(string:locale: nil)` is the only number path,
/// the decimal separator is always `.`, and `,` is only ever an argument separator. `1,5` lexes as
/// `1` `,` `5` and fails in the parser rather than quietly becoming one-and-a-half in Sweden and
/// one-then-five in the United States.
public struct FormulaLexer: Sendable {

    private let characters: [Character]

    public init(_ source: String) {
        self.characters = Array(source)
    }

    /// Lexes the whole source. The final token is always ``FormulaTokenKind/endOfInput``.
    public func tokenize() throws -> [FormulaToken] {
        var tokens: [FormulaToken] = []
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character.isWhitespace {
                index += 1
                continue
            }
            let start = index
            switch character {
            case "(":
                index += 1
                tokens.append(token(.leftParenthesis, start, index))
            case ")":
                index += 1
                tokens.append(token(.rightParenthesis, start, index))
            case ",":
                index += 1
                tokens.append(token(.comma, start, index))
            case "+", "-", "*", "/", "%", "^":
                index += 1
                // Every one of these is a single-character operator with a raw value equal to
                // itself, so the force-free lookup below cannot fail.
                guard let symbol = FormulaOperator(rawValue: String(character)) else {
                    throw error(.unexpectedCharacter(character), start, index)
                }
                tokens.append(token(.op(symbol), start, index))
            case "=":
                guard index + 1 < characters.count, characters[index + 1] == "=" else {
                    throw error(.unexpectedCharacter("="), start, index + 1)
                }
                index += 2
                tokens.append(token(.op(.equal), start, index))
            case "!":
                guard index + 1 < characters.count, characters[index + 1] == "=" else {
                    throw error(.unexpectedCharacter("!"), start, index + 1)
                }
                index += 2
                tokens.append(token(.op(.notEqual), start, index))
            case "<":
                if index + 1 < characters.count, characters[index + 1] == "=" {
                    index += 2
                    tokens.append(token(.op(.lessThanOrEqual), start, index))
                } else {
                    index += 1
                    tokens.append(token(.op(.lessThan), start, index))
                }
            case ">":
                if index + 1 < characters.count, characters[index + 1] == "=" {
                    index += 2
                    tokens.append(token(.op(.greaterThanOrEqual), start, index))
                } else {
                    index += 1
                    tokens.append(token(.op(.greaterThan), start, index))
                }
            case "[":
                tokens.append(try lexBracketReference(&index))
            case "\"":
                tokens.append(try lexString(&index))
            default:
                if FormulaLexer.isDigit(character) {
                    tokens.append(try lexNumber(&index))
                } else if character.isLetter || character == "_" {
                    tokens.append(lexIdentifier(&index))
                } else {
                    throw error(.unexpectedCharacter(character), start, start + 1)
                }
            }
        }
        tokens.append(
            FormulaToken(
                kind: .endOfInput,
                span: FormulaSourceSpan(start: characters.count, end: characters.count),
                text: ""
            )
        )
        return tokens
    }

    // MARK: - Pieces

    /// Only ASCII `0`-`9` are digits. `Character.isNumber` is also true for superscripts,
    /// vulgar fractions and other scripts' digits (`²`, `½`, `٣`, `１`), and
    /// `Decimal(string:locale:)` parses a numeric *prefix*, so `10²` used to lex as one token and
    /// evaluate as `10` with no error (BH-156).
    static func isDigit(_ character: Character) -> Bool {
        character.isASCII && character.isWholeNumber
    }

    private func lexNumber(_ index: inout Int) throws -> FormulaToken {
        let start = index
        while index < characters.count, FormulaLexer.isDigit(characters[index]) { index += 1 }
        if index < characters.count, characters[index] == "." {
            let dot = index
            index += 1
            guard index < characters.count, FormulaLexer.isDigit(characters[index]) else {
                throw error(
                    .malformedNumber(String(characters[start...dot])),
                    start,
                    index
                )
            }
            while index < characters.count, FormulaLexer.isDigit(characters[index]) { index += 1 }
        }
        // A second '.', a trailing letter or a non-ASCII numeric character (`10²`, `1٣`) is a
        // typo or a paste artefact, not two tokens.
        if index < characters.count,
           characters[index] == "." || characters[index].isLetter || characters[index].isNumber {
            let bad = index
            throw error(.malformedNumber(String(characters[start...bad])), start, bad + 1)
        }
        let text = String(characters[start..<index])
        // `text` is only ASCII digits with at most one inner '.', so this parses all of it.
        guard let value = Decimal(string: text, locale: nil) else {
            throw error(.malformedNumber(text), start, index)
        }
        return token(.number(value), start, index, text: text)
    }

    private func lexIdentifier(_ index: inout Int) -> FormulaToken {
        let start = index
        while index < characters.count,
              characters[index].isLetter || characters[index].isNumber || characters[index] == "_" {
            index += 1
        }
        let text = String(characters[start..<index])
        switch text.lowercased() {
        case "and": return token(.op(.and), start, index, text: text)
        case "or": return token(.op(.or), start, index, text: text)
        case "not": return token(.op(.not), start, index, text: text)
        case "true": return token(.boolean(true), start, index, text: text)
        case "false": return token(.boolean(false), start, index, text: text)
        default: return token(.identifier(text), start, index, text: text)
        }
    }

    /// `[name]`. Brackets inside the name nest, so a title that carries its unit —
    /// `[Cost [SEK]]`, `[Area [m2]]` — is one reference; an unbalanced bracket is written `\]` or
    /// `\[` (BH-544). A backslash before anything else is an ordinary character.
    private func lexBracketReference(_ index: inout Int) throws -> FormulaToken {
        let start = index
        index += 1
        var inner = ""
        var depth = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\\", index + 1 < characters.count,
               characters[index + 1] == "[" || characters[index + 1] == "]" {
                inner.append(characters[index + 1])
                index += 2
                continue
            }
            if character == "[" {
                depth += 1
            } else if character == "]" {
                if depth == 0 { break }
                depth -= 1
            }
            inner.append(character)
            index += 1
        }
        guard index < characters.count else {
            throw error(.unterminatedColumnReference, start, characters.count)
        }
        index += 1
        let trimmed = inner.trimmingCharacters(in: .whitespaces)
        return token(.bracketReference(trimmed), start, index, text: String(characters[start..<index]))
    }

    private func lexString(_ index: inout Int) throws -> FormulaToken {
        let start = index
        index += 1
        var inner = ""
        while index < characters.count, characters[index] != "\"" {
            inner.append(characters[index])
            index += 1
        }
        guard index < characters.count else {
            throw error(.unterminatedString, start, characters.count)
        }
        index += 1
        return token(.string(inner), start, index, text: String(characters[start..<index]))
    }

    // MARK: - Helpers

    private func token(
        _ kind: FormulaTokenKind,
        _ start: Int,
        _ end: Int,
        text: String? = nil
    ) -> FormulaToken {
        FormulaToken(
            kind: kind,
            span: FormulaSourceSpan(start: start, end: end),
            text: text ?? String(characters[Swift.min(start, characters.count)..<Swift.min(end, characters.count)])
        )
    }

    private func error(
        _ code: FormulaEngineErrorCode,
        _ start: Int,
        _ end: Int
    ) -> FormulaEngineError {
        FormulaEngineError(code: code, span: FormulaSourceSpan(start: start, end: end))
    }
}
