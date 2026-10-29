import Foundation
import ZPDFContracts
import ZPDFUIPresentation

/// Suggests a symbol's type designation from the tag text printed beside it (NL-AUTO-06).
///
/// It reads positioned text lines — the page's embedded text today, OCR lines when the caller
/// has them — and returns the nearest token within `maximumDistance` that looks like a designation: one to three capital
/// letters, an optional separator, one to four digits and an optional letter (`D-12`, `F01`,
/// `DT 4A`). A prefill, never a decision: the person confirms or retypes it, and when nothing
/// legible is close enough it answers `nil` rather than guess.
public struct NearbyDesignationSuggester: Sendable {

    /// The default designation shape. Configurable per call site.
    public static let defaultPattern = "^[A-Z]{1,3}[-\u{2011}\u{2010} ]?[0-9]{1,4}[A-Z]?$"

    private let lines: [RecognisedTextLine]
    private let pattern: String

    public init(lines: [RecognisedTextLine], pattern: String = NearbyDesignationSuggester.defaultPattern) {
        self.lines = lines
        self.pattern = pattern
    }

    /// Text near `position` that looks like a designation, trimmed, or `nil` when nothing
    /// legible is within `maximumDistance` page points — never a guess dressed as a fact.
    public func suggestion(near position: PDFPoint, maximumDistance: Double) -> String? {
        guard maximumDistance.isFinite, maximumDistance >= 0,
              let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        var best: (distance: Double, text: String)?
        for line in lines {
            guard let bounds = line.boundsInPageSpace else { continue }
            let distance = Self.distance(from: position, to: bounds)
            guard distance <= maximumDistance else { continue }
            for token in Self.tokens(of: line.text) {
                let range = NSRange(token.startIndex..<token.endIndex, in: token)
                guard expression.firstMatch(in: token, range: range) != nil else { continue }
                if let current = best {
                    if distance < current.distance || (distance == current.distance && token < current.text) {
                        best = (distance, token)
                    }
                } else {
                    best = (distance, token)
                }
            }
        }
        return best?.text
    }

    /// The whole line first — "DT 4A" is one designation with a space in it — then each
    /// whitespace-separated word.
    static func tokens(of text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let words = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        return [trimmed] + (words.count > 1 ? words : [])
    }

    /// Distance from a point to a rectangle, zero inside it.
    static func distance(from point: PDFPoint, to rect: PDFRectValue) -> Double {
        let dx = Swift.max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = Swift.max(rect.minY - point.y, 0, point.y - rect.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }
}
