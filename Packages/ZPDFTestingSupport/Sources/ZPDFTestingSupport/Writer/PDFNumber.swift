import Foundation

/// Deterministic PDF number formatting.
///
/// The whole point of this corpus is that the number in the manifest and the number in
/// the file are the *same* number. `string(_:)` therefore emits a representation that
/// parses back to the identical `Double`, and never uses exponent notation, which the
/// PDF number grammar does not accept.
public enum PDFNumber {

    /// The largest magnitude a fixture coordinate may have. PDF 1.7 Annex C gives
    /// 3.403 × 10³⁸ as the largest real, but a drawing coordinate above this bound is
    /// a generator bug, so it is rejected rather than emitted.
    public static let maximumMagnitude: Double = 1e12

    /// Formats `value` for a PDF content stream or object.
    ///
    /// - Integral values become plain integers (`"144"`), which keeps content streams
    ///   readable and small.
    /// - Everything else uses Swift's shortest round-tripping description when that
    ///   description is exponent-free, and otherwise the same digits with the decimal
    ///   point moved by hand (`fixed(_:)`), so the value still round-trips.
    ///
    /// Non-finite values and values beyond `maximumMagnitude` collapse to `"0"`; the
    /// generator never produces one, and `PDFNumber.roundTrips(_:)` is asserted over
    /// every manifest coordinate in the test target so a regression cannot slip past.
    public static func string(_ value: Double) -> String {
        guard value.isFinite, abs(value) <= maximumMagnitude else { return "0" }
        if value == value.rounded(), abs(value) < 1e15 {
            // `value` is integral and within Int64's exact range.
            return String(Int64(value))
        }
        let shortest = "\(value)"
        if !shortest.contains("e"), !shortest.contains("E") {
            return shortest
        }
        return fixed(value)
    }

    /// The exponent-free spelling of Swift's shortest round-tripping description.
    ///
    /// Swift switches to exponent form below 1e-4 (`"1.2345678901e-05"`). Rather than
    /// re-rounding through `%.12f` — which drops digits beyond the twelfth decimal and
    /// collapses anything below 5e-13 to `"0"` — the decimal point is moved by hand, so
    /// the digits written are exactly the shortest round-tripping digits and the value
    /// parses back to the identical `Double`.
    static func fixed(_ value: Double) -> String {
        let description = "\(value)"
        let parts = description.lowercased().split(separator: "e", maxSplits: 1)
        guard parts.count == 2, let exponent = Int(parts[1]) else { return description }

        var mantissa = Substring(parts[0])
        var sign = ""
        if mantissa.hasPrefix("-") {
            sign = "-"
            mantissa = mantissa.dropFirst()
        }
        let pieces = mantissa.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let integerDigits = String(pieces[0])
        let fractionDigits = pieces.count > 1 ? String(pieces[1]) : ""
        var digits = integerDigits + fractionDigits
        // Position of the decimal point within `digits` after applying the exponent.
        var point = integerDigits.count + exponent

        // Strip leading zeros of the digit string, keeping the point in place.
        while digits.count > 1, digits.hasPrefix("0") {
            digits.removeFirst()
            point -= 1
        }
        // Strip trailing zeros, which carry no information.
        while digits.count > 1, digits.hasSuffix("0") {
            digits.removeLast()
        }

        let text: String
        if point <= 0 {
            text = "0." + String(repeating: "0", count: -point) + digits
        } else if point >= digits.count {
            text = digits + String(repeating: "0", count: point - digits.count)
        } else {
            let index = digits.index(digits.startIndex, offsetBy: point)
            text = String(digits[..<index]) + "." + String(digits[index...])
        }
        return sign + text
    }

    /// `true` when `string(value)` parses back to exactly `value`.
    ///
    /// Every coordinate that appears in a manifest is required to satisfy this, so a
    /// consumer comparing an extracted coordinate to a manifest coordinate at 1e-9
    /// page points is comparing like with like.
    public static func roundTrips(_ value: Double) -> Bool {
        guard value.isFinite else { return false }
        guard let parsed = Double(string(value)) else { return false }
        return parsed == value
    }

    /// Formats a point as `"x y"`.
    public static func string(_ point: FixturePoint) -> String {
        "\(string(point.x)) \(string(point.y))"
    }

    /// Formats a box as the PDF array `[llx lly urx ury]`.
    public static func array(_ rect: FixtureRect) -> String {
        "[\(string(rect.llx)) \(string(rect.lly)) \(string(rect.urx)) \(string(rect.ury))]"
    }

    /// Formats a matrix as `"a b c d e f"`, the operand list of `cm` and the value of
    /// a form XObject `/Matrix`.
    public static func string(_ matrix: FixtureMatrix) -> String {
        [matrix.a, matrix.b, matrix.c, matrix.d, matrix.e, matrix.f]
            .map(string)
            .joined(separator: " ")
    }
}
