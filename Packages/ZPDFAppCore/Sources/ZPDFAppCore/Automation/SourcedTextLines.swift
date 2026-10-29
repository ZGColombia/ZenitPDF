import CoreGraphics
import Foundation
import ZPDFUIPresentation

/// One line of a page's text and where it came from (NL-AUTO-03): the drawing's own text, the
/// project's stored recognition, or a region recognised for the command at hand — each with the
/// confidence a reader needs to stay silent on a weak read.
public struct SourcedTextLine: Sendable, Hashable {

    public enum Source: String, Sendable, Hashable {
        /// Text the PDF carries. Confidence 1: it is the drawing's own.
        case embedded
        /// The project's stored recognition (OCR is opt-in per project).
        case ocr
        /// A region recognised on this Mac for this one command; nothing is stored.
        case regionOCR
    }

    public let text: String
    public let boundsInPageSpace: PDFRectValue
    public let confidence: Double
    public let source: Source

    public init(text: String, boundsInPageSpace: PDFRectValue, confidence: Double, source: Source) {
        self.text = text
        self.boundsInPageSpace = boundsInPageSpace
        self.confidence = confidence
        self.source = source
    }

    /// The line in the form the table, scale and name readers take.
    public var recognisedTextLine: RecognisedTextLine {
        RecognisedTextLine(text: text, boundsInPageSpace: boundsInPageSpace)
    }
}

/// The order of sources, as pure functions (NL-AUTO-03): embedded text first; where a region has
/// none, the stored recognition; where there is none of that either, region recognition.
public enum SourcedTextLines {

    /// Stored recognised words grouped into lines, each line as confident as its weakest word.
    public static func lines(fromRecognisedWords words: [DocumentSearchIndex.RecognisedWord]) -> [SourcedTextLine] {
        let merged = BaselineLineMerger.merge(words.map {
            RecognisedTextLine(text: $0.text, boundsInPageSpace: PDFRectValue(x: $0.bounds.origin.x, y: $0.bounds.origin.y,
                                                                            width: $0.bounds.width, height: $0.bounds.height))
        })
        return merged.compactMap { line in
            guard let box = line.boundsInPageSpace else { return nil }
            let rect = CGRect(x: box.minX, y: box.minY, width: box.size.width, height: box.size.height).insetBy(dx: -0.5, dy: -0.5)
            let inside = words.filter { rect.contains(CGPoint(x: $0.bounds.midX, y: $0.bounds.midY)) }
            return SourcedTextLine(text: line.text, boundsInPageSpace: box,
                                   confidence: inside.map(\.confidence).min() ?? 0, source: .ocr)
        }
    }

    /// The lines inside `region` (all of them when `region` is `nil`).
    public static func within(_ region: PDFRectValue?, _ lines: [SourcedTextLine]) -> [SourcedTextLine] {
        guard let region else { return lines }
        let area = CGRect(x: region.minX, y: region.minY, width: region.size.width, height: region.size.height)
        return lines.filter {
            let box = $0.boundsInPageSpace
            return area.contains(CGPoint(x: box.minX + box.size.width / 2, y: box.minY + box.size.height / 2))
        }
    }

    /// The first source that has text in `region`: embedded, then stored recognition. `nil` when
    /// neither has any, which is when a caller that may recognise a region does so.
    public static func choose(embedded: [SourcedTextLine], stored: [SourcedTextLine], region: PDFRectValue?) -> [SourcedTextLine]? {
        let own = within(region, embedded)
        if !own.isEmpty { return own }
        let recognised = within(region, stored)
        return recognised.isEmpty ? nil : recognised
    }
}
