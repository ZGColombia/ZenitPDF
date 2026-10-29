import Foundation
import ZPDFContracts
import ZPDFUIPresentation

/// The printed room-area check (NL-AUTO-09): "Sovrum 12,3 m²" printed inside a room against
/// the area measured for it.
///
/// Two independent methods that must agree. A wrong scale, a wrong trace or a forgotten cutout
/// all show up as a room whose measured area differs from the area the architect printed in it —
/// the error an estimator fears most, caught for the cost of reading the label.
///
/// The rules follow the dimension check's: opt-in (it runs inside Check Against Drawn
/// Dimensions), a tolerance the person can see, and **silence on anything uncertain** — a room
/// with no area printed inside it, or with two different areas printed inside it, says nothing.
/// A label is paired with the room that contains its centre, never by distance.
public enum PrintedAreaCheck {

    /// A printed area and where it was printed.
    public struct PrintedArea: Sendable, Hashable {
        /// Square metres, exactly as printed and converted.
        public let squareMetres: Decimal
        public let text: String
        public let bounds: PDFRectValue
    }

    /// One room compared.
    public struct Finding: Sendable, Hashable {
        public let markupID: MarkupID
        public let printed: Decimal
        public let measured: Decimal
        /// |measured − printed| / printed.
        public let relativeDifference: Decimal
        public let agrees: Bool
    }

    /// An area markup as the check sees it.
    public struct Room: Sendable, Hashable {
        public let markupID: MarkupID
        public let ring: [PDFPoint]
        public let measuredSquareMetres: Decimal

        public init(markupID: MarkupID, ring: [PDFPoint], measuredSquareMetres: Decimal) {
            self.markupID = markupID
            self.ring = ring
            self.measuredSquareMetres = measuredSquareMetres
        }
    }

    /// The default tolerance: 3 %. A printed area is rounded to 0.1 m² and measured to a wall
    /// face the drawing may place differently; a wrong scale is off by tens of percent.
    public static let defaultTolerance: Decimal = Decimal(string: "0.03")!

    /// One square foot in square metres, exactly (0.3048² = 0.09290304).
    static let squareMetresPerSquareFoot = Decimal(string: "0.09290304")!

    /// Every area notation in `lines`: "12,3 m²", "12.3 m2", "12,3 kvm", "132 sq ft", "132 sf".
    public static func printedAreas(in lines: [RecognisedTextLine]) -> [PrintedArea] {
        let pattern = #"(\d{1,5}(?:[.,]\d{1,3})?)\s?(m²|m2|kvm|sq\.?\s?ft|sf|ft²)(?![A-Za-z0-9])"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        var result: [PrintedArea] = []
        for line in lines {
            guard let bounds = line.boundsInPageSpace else { continue }
            let text = line.text
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in expression.matches(in: text, range: range) {
                guard let numberRange = Range(match.range(at: 1), in: text),
                      let unitRange = Range(match.range(at: 2), in: text),
                      let value = Decimal(string: text[numberRange].replacingOccurrences(of: ",", with: "."),
                                          locale: Locale(identifier: "en_US_POSIX")),
                      value > 0
                else { continue }
                let unit = text[unitRange].lowercased()
                let metres = unit.hasPrefix("m") || unit == "kvm" ? value : value * squareMetresPerSquareFoot
                result.append(PrintedArea(squareMetres: metres, text: String(text[numberRange]) + " " + unit, bounds: bounds))
            }
        }
        return result
    }

    /// Compares each room with the one area printed inside it.
    public static func check(rooms: [Room], lines: [RecognisedTextLine], tolerance: Decimal = defaultTolerance) -> [Finding] {
        let printed = printedAreas(in: lines)
        var findings: [Finding] = []
        for room in rooms where room.ring.count >= 3 && room.measuredSquareMetres > 0 {
            let inside = printed.filter { area in
                let centre = PDFPoint(
                    x: area.bounds.minX + area.bounds.size.width / 2,
                    y: area.bounds.minY + area.bounds.size.height / 2
                )
                return contains(room.ring, centre)
            }
            // Two different areas in one room: which one is this room's is not ours to guess.
            let distinct = Set(inside.map(\.squareMetres))
            guard distinct.count == 1, let value = distinct.first else { continue }
            var difference = room.measuredSquareMetres - value
            if difference < 0 { difference = -difference }
            let relative = difference / value
            findings.append(Finding(
                markupID: room.markupID,
                printed: value,
                measured: room.measuredSquareMetres,
                relativeDifference: relative,
                agrees: relative <= tolerance
            ))
        }
        return findings
    }

    /// Even-odd containment.
    static func contains(_ ring: [PDFPoint], _ point: PDFPoint) -> Bool {
        var inside = false
        var j = ring.count - 1
        for i in ring.indices {
            let a = ring[i], b = ring[j]
            if (a.y > point.y) != (b.y > point.y) {
                let x = a.x + (point.y - a.y) * (b.x - a.x) / (b.y - a.y)
                if point.x < x { inside.toggle() }
            }
            j = i
        }
        return inside
    }
}
