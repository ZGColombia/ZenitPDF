import Foundation
import ZPDFContracts
import ZPDFUIPresentation

/// Names a detected room from the text printed inside it (NL-AUTO-08), and reads the area printed
/// there for the two-methods check (NL-AUTO-09).
///
/// The name is the first line inside the room, top to bottom, that is not an area, a scale or a
/// bare number — "Sovrum 2" over "12,3 m²" names the room "Sovrum 2". A room with nothing printed
/// in it has no name; the review shows it unnamed rather than inventing one.
public enum RoomLabelPairing {

    public struct Label: Sendable, Hashable {
        public let name: String?
        /// The area printed in the room, square metres, when exactly one is printed.
        public let printedSquareMetres: Decimal?
    }

    public static func label(for ring: [PDFPoint], lines: [RecognisedTextLine]) -> Label {
        let inside = BaselineLineMerger.merge(lines).filter { line in
            guard let bounds = line.boundsInPageSpace else { return false }
            let centre = PDFPoint(x: bounds.minX + bounds.size.width / 2, y: bounds.minY + bounds.size.height / 2)
            return PrintedAreaCheck.contains(ring, centre)
        }.sorted { ($0.boundsInPageSpace?.minY ?? 0) > ($1.boundsInPageSpace?.minY ?? 0) }
        let areas = Set(PrintedAreaCheck.printedAreas(in: inside).map(\.squareMetres))
        let name = inside.lazy.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.first { text in
            guard text.rangeOfCharacter(from: .letters) != nil else { return false }
            if !PrintedAreaCheck.printedAreas(in: [RecognisedTextLine(text: text, boundsInPageSpace: PDFRectValue(x: 0, y: 0, width: 1, height: 1))]).isEmpty {
                // "Sovrum 12,3 m²" on one line: the words before the figure are the name.
                return text.range(of: #"^[^\d]*[A-Za-zÅÄÖåäö]"#, options: .regularExpression) != nil
            }
            return ScaleNotationParser().candidates(inLine: text).isEmpty
        }.map { text -> String in
            // Strip a trailing area from a one-line label.
            let stripped = text.replacingOccurrences(
                of: #"\s*\d{1,5}(?:[.,]\d{1,3})?\s?(m²|m2|kvm|sq\.?\s?ft|sf|ft²)\s*$"#,
                with: "", options: [.regularExpression, .caseInsensitive]
            )
            return stripped.isEmpty ? text : stripped
        }
        return Label(name: name, printedSquareMetres: areas.count == 1 ? areas.first : nil)
    }
}
