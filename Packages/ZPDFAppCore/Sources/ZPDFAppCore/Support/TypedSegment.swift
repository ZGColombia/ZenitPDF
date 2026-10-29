import Foundation
import ZPDFContracts

/// Typed length and angle while drawing (NL-MEASURE-18): "4,2" places the next vertex 4.2 m
/// along the pointer's direction, "4,2<90" at 90°.
///
/// The foundation, pure and tested: the entry grammar and the placement through the page's
/// scale. The placement works in **real** space and maps back through the inverse matrix, so a
/// separate X/Y scale puts "4 m at 90°" 4 m up the building, not 4 m worth of page points.
public enum TypedSegment {

    /// A parsed entry: the length in metres and an optional angle in degrees, counter-clockwise
    /// from the drawing's +x axis.
    public struct Entry: Equatable, Sendable {
        public let metres: Decimal
        public let angleDegrees: Double?
    }

    /// Parses `length` or `length<angle`. The length is a number in `unit` or, for imperial
    /// units, feet and inches (`12'6"`). The number grammar is injected — the app passes the one
    /// whole-string, locale-independent parser every Zenit field shares — so `4,2` and `4.2`
    /// are the same entry on any Mac. `nil` for anything else.
    public static func parse(
        _ raw: String,
        unit: LengthUnit,
        number: (String) -> Decimal?,
        feetAndInches: (String) -> Decimal? = { _ in nil }
    ) -> Entry? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let parts = text.split(separator: "<", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let lengthText = parts[0].trimmingCharacters(in: .whitespaces)
        var angle: Double?
        if parts.count == 2 {
            guard let value = number(parts[1].trimmingCharacters(in: .whitespaces)) else { return nil }
            angle = NumericPolicy.double(from: value)
        }
        let metres: Decimal
        if let value = number(lengthText) {
            metres = unit.toBase(value)
        } else if let inches = feetAndInches(lengthText) {
            metres = LengthUnit.inch.toBase(inches)
        } else {
            return nil
        }
        guard metres > 0 else { return nil }
        return Entry(metres: metres, angleDegrees: angle)
    }

    /// The page point `entry` places from `anchor`: along `angleDegrees` in real space when the
    /// entry has one, else toward `pointer`. `nil` without a direction (no angle, and the
    /// pointer on the anchor) or on a singular scale.
    public static func point(
        from anchor: PDFPoint,
        toward pointer: PDFPoint?,
        entry: Entry,
        scale: ScaleTransform
    ) -> PDFPoint? {
        let matrix = scale.matrix
        guard let inverse = try? matrix.inverted() else { return nil }
        let direction: (x: Double, y: Double)
        if let degrees = entry.angleDegrees {
            let radians = degrees * .pi / 180
            direction = (cos(radians), sin(radians))
        } else {
            guard let pointer else { return nil }
            let delta = matrix.mapDelta(dx: pointer.x - anchor.x, dy: pointer.y - anchor.y)
            let length = (delta.dx * delta.dx + delta.dy * delta.dy).squareRoot()
            guard length > 0, length.isFinite else { return nil }
            direction = (delta.dx / length, delta.dy / length)
        }
        let metres = NumericPolicy.double(from: entry.metres)
        let pageDelta = inverse.mapDelta(dx: direction.x * metres, dy: direction.y * metres)
        return PDFPoint(x: anchor.x + pageDelta.dx, y: anchor.y + pageDelta.dy)
    }
}
