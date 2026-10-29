import CoreGraphics
import Foundation

/// One viewport a PDF declares with a rectilinear measure: "inside this box, one point is this
/// many metres".
public struct PDFMeasureViewport: Sendable, Equatable {
    /// Zero-based page index.
    public let pageIndex: Int
    /// The viewport's box in default user space; `nil` when the viewport gives none (whole page).
    public let bbox: CGRect?
    public let name: String?
    /// The human scale text the producer wrote (`/R`), e.g. "1 in = 8 ft".
    public let ratioText: String?
    /// The unit the first number format names (`/U`), as written.
    public let unitLabel: String
    /// Metres per PDF point, from the first number format's conversion factor and its unit.
    public let metresPerPoint: Double

    /// The drawing ratio 1 : N this is, with N = metresPerPoint ÷ (0.0254 / 72), rounded to the
    /// nearest 1/1000 so a producer's six-digit factor reads as the round ratio it stands for.
    public var ratioDenominator: Decimal {
        let raw = metresPerPoint / (0.0254 / 72)
        let rounded = (raw * 1000).rounded() / 1000
        return Decimal(string: String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), rounded)) ?? Decimal(rounded)
    }

    /// ``ratioDenominator`` on a page that declares `/UserUnit` (X-052): the viewport's factor is
    /// per default user-space unit, and a preset ratio is multiplied by the page's user unit, so
    /// the ratio that measures the same is N ÷ userUnit. One place for the division, for the
    /// scale the offer applies and the label it carries alike. A unit that is not finite and
    /// positive is treated as the specification's default, 1.
    public func ratioDenominator(userUnit: Double) -> Decimal {
        guard userUnit.isFinite, userUnit > 0, userUnit != 1 else { return ratioDenominator }
        return ratioDenominator / Decimal(userUnit)
    }

    /// Area of the box, or `nil` for a whole-page viewport.
    public var area: Double? { bbox.map { abs($0.width * $0.height) } }
}

/// Reads `/VP` → `/Measure` (`/Subtype /RL`) from a PDF's pages.
///
/// ISO 32000-1 §12.9, Table 261: the first number format in `/X` carries `/C`, the factor from
/// default user-space units to its unit `/U`; later formats only subdivide for display. So metres
/// per point = C × metres(U). `/D` and `/A` convert *from the units of `/X`* (distance and area
/// display), not from user space, so they never set the scale on their own: a `/D` factor is used
/// only through `/X` (X.C × D.C × metres(D.U)) or, for a producer that leaves `/X` out, as the
/// user-space factor it then has to be. Unknown units, non-finite or non-positive factors, and
/// geospatial measures (`/Subtype /GEO`) are ignored, never guessed.
public enum PDFMeasureReader {

    public static func viewports(in document: CGPDFDocument, maximumPages: Int = 10_000) -> [PDFMeasureViewport] {
        guard !document.isEncrypted || document.isUnlocked else { return [] }
        let count = min(document.numberOfPages, maximumPages)
        guard count > 0 else { return [] }
        var result: [PDFMeasureViewport] = []
        for number in 1...count {
            guard let page = document.page(at: number), let dictionary = page.dictionary else { continue }
            var array: CGPDFArrayRef?
            guard CGPDFDictionaryGetArray(dictionary, "VP", &array), let viewports = array else { continue }
            for index in 0..<min(CGPDFArrayGetCount(viewports), 256) {
                var viewport: CGPDFDictionaryRef?
                guard CGPDFArrayGetDictionary(viewports, index, &viewport), let viewport,
                      let parsed = parse(viewport, pageIndex: number - 1) else { continue }
                result.append(parsed)
            }
        }
        return result
    }

    static func parse(_ viewport: CGPDFDictionaryRef, pageIndex: Int) -> PDFMeasureViewport? {
        var measure: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(viewport, "Measure", &measure), let measure else { return nil }
        if let subtype = name(measure, "Subtype"), subtype != "RL" { return nil }
        let x = firstFormat(measure, "X")
        let d = firstFormat(measure, "D")
        let unit: String
        let metresPerPoint: Double
        if let x {
            // Spec path. /X alone sets the scale; its unit may be one we cannot name (a producer's
            // own label) only when /D names one, reached through the /X factor.
            if let metres = metres(perUnit: x.unit) {
                unit = x.unit
                metresPerPoint = x.factor * metres
            } else if let d, let metres = metres(perUnit: d.unit) {
                unit = d.unit
                metresPerPoint = x.factor * d.factor * metres
            } else {
                return nil
            }
        } else if let d, let metres = metres(perUnit: d.unit) {
            // Non-conforming producer without /X: its /D can only be meant from user space.
            unit = d.unit
            metresPerPoint = d.factor * metres
        } else {
            return nil
        }
        guard metresPerPoint.isFinite, metresPerPoint > 0 else { return nil }
        return PDFMeasureViewport(pageIndex: pageIndex, bbox: rect(viewport, "BBox"), name: string(viewport, "Name"),
                                  ratioText: string(measure, "R"), unitLabel: unit, metresPerPoint: metresPerPoint)
    }

    /// The first number format of `key` with a positive, finite `/C` and a `/U`.
    static func firstFormat(_ measure: CGPDFDictionaryRef, _ key: String) -> (factor: Double, unit: String)? {
        var formats: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(measure, key, &formats), let formats, CGPDFArrayGetCount(formats) > 0 else { return nil }
        var first: CGPDFDictionaryRef?
        guard CGPDFArrayGetDictionary(formats, 0, &first), let first else { return nil }
        var factor: CGPDFReal = 0
        guard CGPDFDictionaryGetNumber(first, "C", &factor), factor.isFinite, factor > 0,
              let unit = string(first, "U") else { return nil }
        return (Double(factor), unit)
    }

    /// Metres in one of the unit labels producers write; `nil` for anything else.
    public static func metres(perUnit label: String) -> Double? {
        switch label.trimmingCharacters(in: .whitespaces).lowercased() {
        case "m", "meter", "meters", "metre", "metres": return 1
        case "mm", "millimeter", "millimeters", "millimetre", "millimetres": return 0.001
        case "cm", "centimeter", "centimeters", "centimetre", "centimetres": return 0.01
        case "dm": return 0.1
        case "km": return 1000
        case "in", "inch", "inches", "\"": return 0.0254
        case "ft", "foot", "feet", "'": return 0.3048
        case "yd", "yard", "yards": return 0.9144
        case "mi", "mile", "miles": return 1609.344
        case "pt", "point", "points": return 0.0254 / 72
        default: return nil
        }
    }

    // MARK: - CGPDF helpers

    static func name(_ dictionary: CGPDFDictionaryRef, _ key: String) -> String? {
        var value: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dictionary, key, &value), let value else { return nil }
        return String(cString: value)
    }

    static func string(_ dictionary: CGPDFDictionaryRef, _ key: String) -> String? {
        var value: CGPDFStringRef?
        guard CGPDFDictionaryGetString(dictionary, key, &value), let value, let text = CGPDFStringCopyTextString(value) else { return nil }
        return text as String
    }

    static func rect(_ dictionary: CGPDFDictionaryRef, _ key: String) -> CGRect? {
        var array: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dictionary, key, &array), let array, CGPDFArrayGetCount(array) == 4 else { return nil }
        var values = [CGPDFReal](repeating: 0, count: 4)
        for index in 0..<4 { guard CGPDFArrayGetNumber(array, index, &values[index]), values[index].isFinite else { return nil } }
        return CGRect(x: min(values[0], values[2]), y: min(values[1], values[3]),
                      width: abs(values[2] - values[0]), height: abs(values[3] - values[1]))
    }
}
