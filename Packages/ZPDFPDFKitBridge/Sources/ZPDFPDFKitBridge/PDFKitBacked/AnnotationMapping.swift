import CoreGraphics
import Foundation
import PDFKit
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Translating between `PDFAnnotation` and ``NeutralAnnotation``.
///
/// Kept apart from the provider because it is the only place PDFKit's annotation object
/// model leaks in, and because the colour conversion has to be explicit: PDFKit hands
/// back whatever colour space the file used — DeviceGray for a plain black square — and
/// the ledger stores sRGB.
enum AnnotationMapping {

    // MARK: - Reading

    static func neutral(_ annotation: PDFAnnotation, pageIndex: Int) -> NeutralAnnotation {
        let kind = AnnotationKind(pdfSubtype: annotation.type ?? "Unknown")
        var points: [CGPoint] = []
        switch kind {
        case .line:
            points = [annotation.startPoint, annotation.endPoint]
        case .polygon, .polyLine:
            points = pointList(annotation.value(forAnnotationKey: PDFAnnotationKeys.vertices))
        default:
            break
        }

        var neutral = NeutralAnnotation(
            pageIndex: pageIndex,
            kind: kind,
            bounds: annotation.bounds,
            contents: nonEmpty(annotation.contents),
            subject: nonEmpty(annotation.value(forAnnotationKey: PDFAnnotationKeys.subject) as? String),
            author: nonEmpty(annotation.userName),
            color: color(fromCGColor: annotation.color.cgColor),
            interiorColor: annotation.interiorColor.map(\.cgColor).flatMap(color(fromCGColor:)),
            borderWidth: annotation.border.map { Double($0.lineWidth) },
            points: points,
            inkPaths: inkPaths(
                annotation.value(forAnnotationKey: PDFAnnotationKeys.inkList),
                origin: annotation.bounds.origin
            ),
            quadPoints: pointList(annotation.quadrilateralPoints),
            action: summary(of: annotation),
            modificationDate: annotation.modificationDate,
            creationDate: date(annotation.value(forAnnotationKey: PDFAnnotationKeys.creationDate)),
            name: nonEmpty(annotation.value(forAnnotationKey: PDFAnnotationKeys.name) as? String)
                ?? nonEmpty(annotation.value(forAnnotationKey: PDFAnnotationKeys.zenitName) as? String),
            isZenitOwned: annotation.value(forAnnotationKey: PDFAnnotationKeys.zenitOwner) != nil
        )
        // Where a GoTo link lands on its page (NL-DOCS-09): each axis only when the
        // destination names it — an unspecified one keeps the reader's position.
        if let goTo = annotation.action as? PDFActionGoTo {
            let point = goTo.destination.point
            neutral.destinationLeft = Self.specified(point.x)
            neutral.destinationTop = Self.specified(point.y)
        }
        return neutral
    }

    /// A destination coordinate, or `nil` for PDFKit's "unspecified" marker or a non-finite value.
    static func specified(_ value: CGFloat) -> Double? {
        guard value.isFinite, value != kPDFDestinationUnspecifiedValue, abs(value) < 1_000_000 else { return nil }
        return Double(value)
    }

    /// What the annotation *would* do, recorded so it can be shown and never performed.
    private static func summary(of annotation: PDFAnnotation) -> AnnotationActionSummary? {
        guard let action = annotation.action else { return nil }
        switch action {
        case let goTo as PDFActionGoTo:
            return .goToPage(pageIndex: pageIndex(of: goTo.destination.page))
        case let url as PDFActionURL:
            return .uri(url.url?.absoluteString ?? "")
        case let remote as PDFActionRemoteGoTo:
            return .remoteGoTo(fileName: remote.url.lastPathComponent)
        case let named as PDFActionNamed:
            return .named(String(describing: named.name))
        default:
            let type = action.type
            if type.localizedCaseInsensitiveContains("javascript") { return .javaScript }
            if type.localizedCaseInsensitiveContains("launch") { return .launch(fileName: nil) }
            return .other(type)
        }
    }

    /// The page's index in its document, or `nil` when PDFKit cannot place it.
    ///
    /// `index(for:)` answers `NSNotFound` (`Int.max`) for a page it cannot find; passing that
    /// through presented an absurd index as a real target (BH-570). The outline reader applies
    /// the same filter.
    static func pageIndex(of page: PDFPage?) -> Int? {
        guard let page, let document = page.document else { return nil }
        return validPageIndex(document.index(for: page), pageCount: document.pageCount)
    }

    /// `index` when it names a page of a `pageCount`-page document, otherwise `nil`.
    static func validPageIndex(_ index: Int, pageCount: Int) -> Int? {
        guard index != NSNotFound, index >= 0, index < pageCount else { return nil }
        return index
    }

    private static func nonEmpty(_ string: String?) -> String? {
        guard let string, !string.isEmpty else { return nil }
        return string
    }

    /// A `/CreationDate` read back from an annotation. PDFKit returns the raw PDF date *string*
    /// for this key (it has no bridged `Date` property the way `/M` does), so a plain `as? Date`
    /// silently loses it; parse the PDF date syntax, still accepting a `Date` for safety (CR-93).
    private static func date(_ value: Any?) -> Date? {
        if let date = value as? Date { return date }
        if let string = value as? String { return pdfDate(from: string) }
        return nil
    }

    /// Formats a `Date` as a PDF date string in UTC (`D:YYYYMMDDHHmmSSZ`, §7.9.4). This is the
    /// spelling PDFKit accepts through `setValue(_:forAnnotationKey:)` — a `Date` is rejected —
    /// and the one ``pdfDate(from:)`` reads back.
    static func pdfDateString(from date: Date) -> String {
        PDFDateFormatting.string(from: date)
    }

    /// Parses a PDF date string (`D:YYYYMMDDHHmmSSOHH'mm'`, §7.9.4). Every field after the year
    /// is optional; the time-zone marker is `Z`, `+`, `-`, or absent (treated as UTC).
    static func pdfDate(from string: String) -> Date? {
        var body = Substring(string)
        if body.hasPrefix("D:") { body = body.dropFirst(2) }
        let characters = Array(body)
        guard characters.count >= 4 else { return nil }

        func field(_ start: Int, _ length: Int, default fallback: Int) -> Int {
            guard start + length <= characters.count else { return fallback }
            return Int(String(characters[start..<start + length])) ?? fallback
        }
        guard let year = Int(String(characters[0..<4])) else { return nil }

        var components = DateComponents()
        components.year = year
        components.month = field(4, 2, default: 1)
        components.day = field(6, 2, default: 1)
        components.hour = field(8, 2, default: 0)
        components.minute = field(10, 2, default: 0)
        components.second = field(12, 2, default: 0)

        var timeZone = TimeZone(identifier: "UTC") ?? .current
        if characters.count > 14 {
            let marker = characters[14]
            if marker == "+" || marker == "-" {
                let offsetHours = field(15, 2, default: 0)
                // Minutes follow a `'` separator: +HH'mm'. The non-conformant but common
                // spelling +HHmm has no separator, so its minutes start one character
                // earlier; reading from 18 regardless lost the first minute digit (BH-571).
                let minuteStart = min(
                    characters.count > 17 && characters[17] == "'" ? 18 : 17,
                    characters.count
                )
                let minuteDigits = characters[minuteStart...]
                    .prefix { $0.isNumber }
                    .prefix(2)
                let offsetMinutes = Int(String(minuteDigits)) ?? 0
                let sign = marker == "-" ? -1 : 1
                if let zone = TimeZone(secondsFromGMT: sign * (offsetHours * 3600 + offsetMinutes * 60)) {
                    timeZone = zone
                }
            }
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: components)
    }

    /// A point array, in either of the two shapes PDFKit hands one back in.
    ///
    /// `quadrilateralPoints` arrives as `[NSValue]`; a raw `/Vertices` array arrives as the
    /// flat `[x0, y0, x1, y1, …]` number array the PDF file actually holds. Both are read
    /// here so neither shape is silently dropped.
    ///
    /// The `NSValue` unwrap goes through the Foundation overlay's `CGPoint` bridge rather
    /// than `pointValue` (macOS only) or `cgPointValue` (iOS only); the bridge is the one
    /// spelling that exists on both platforms.
    ///
    /// **The number shape is tested first.** `NSNumber` is a subclass of `NSValue`, so a flat
    /// number array also satisfies `as? [NSValue]`; every element then failed the `CGPoint`
    /// unwrap and a polygon's vertices came back as `[]` before the number branch could run
    /// (BH-028).
    static func pointList(_ value: Any?) -> [CGPoint] {
        guard let elements = value as? [Any] else { return [] }
        if elements.allSatisfy({ $0 is NSNumber }) {
            return pairs(elements.compactMap { $0 as? NSNumber })
        }
        return elements.compactMap { element -> CGPoint? in
            guard !(element is NSNumber), let boxed = element as? NSValue else { return nil }
            return boxed as? CGPoint
        }
    }

    /// Ink strokes, in every shape PDFKit hands `/InkList` back in.
    ///
    /// Measured on macOS 26: PDFKit returns `/InkList` as an array of **Bézier paths** whose
    /// coordinates are relative to the annotation's bounds origin, so neither of the number
    /// branches this reader had ever matched a real file. A raw array of number arrays (in page
    /// space) and of boxed points are read too, and the number shape is tested before the
    /// boxed one: the old `as? [[NSValue]]` cast also matched `[[NSNumber]]` and produced N
    /// empty paths (BH-170).
    static func inkPaths(_ value: Any?, origin: CGPoint = .zero) -> [[CGPoint]] {
        guard let paths = value as? [Any] else { return [] }
        return paths.compactMap { path -> [CGPoint]? in
            if let cgPath = bezierCGPath(path) {
                return vertices(of: cgPath, offsetBy: origin)
            }
            guard path is [Any] else { return nil }
            return pointList(path)
        }
    }

    private static func bezierCGPath(_ value: Any) -> CGPath? {
        #if os(macOS)
        return (value as? NSBezierPath)?.cgPath
        #else
        return (value as? UIBezierPath)?.cgPath
        #endif
    }

    /// The on-curve vertices of a path — move, line and curve end points — offset by `origin`.
    private static func vertices(of path: CGPath, offsetBy origin: CGPoint) -> [CGPoint] {
        var points: [CGPoint] = []
        path.applyWithBlock { element in
            let pointer = element.pointee.points
            let end: CGPoint?
            switch element.pointee.type {
            case .moveToPoint, .addLineToPoint: end = pointer[0]
            case .addQuadCurveToPoint: end = pointer[1]
            case .addCurveToPoint: end = pointer[2]
            case .closeSubpath: end = nil
            @unknown default: end = nil
            }
            if let end {
                points.append(CGPoint(x: end.x + origin.x, y: end.y + origin.y))
            }
        }
        return points
    }

    /// `[x0, y0, x1, y1, …]` as points. A trailing odd number is dropped rather than
    /// paired with a fabricated zero.
    private static func pairs(_ numbers: [NSNumber]) -> [CGPoint] {
        stride(from: 0, to: numbers.count - 1, by: 2).map {
            CGPoint(x: numbers[$0].doubleValue, y: numbers[$0 + 1].doubleValue)
        }
    }

    /// Converts any PDFKit colour into sRGB components.
    ///
    /// The parameter is a `CGColor`, not the platform colour class PDFKit's `color`
    /// property is typed as (`NSColor` on macOS, `UIColor` on iOS). Callers pass
    /// `annotation.color.cgColor`, which is spelled identically on both platforms, so a
    /// DeviceGray or CMYK annotation colour still comes out as four sRGB numbers and this
    /// engine names no AppKit or UIKit type (ADR-0005).
    static func color(fromCGColor cgColor: CGColor) -> AnnotationColor? {
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = cgColor.converted(to: srgb, intent: .defaultIntent, options: nil),
              let components = converted.components,
              components.count >= 3
        else {
            return nil
        }
        return AnnotationColor(
            red: Double(components[0]),
            green: Double(components[1]),
            blue: Double(components[2]),
            alpha: components.count >= 4 ? Double(components[3]) : 1
        )
    }

    // MARK: - Writing

    /// The PDFKit subtype for a kind, or `nil` for kinds this bridge refuses to write.
    ///
    /// PDFKit ships named constants for thirteen subtypes; `Polygon`, `PolyLine`,
    /// `Squiggly` and `FileAttachment` are real PDF subtypes without one, so they are
    /// built from their `/Name`, which is what the constants are underneath.
    static func subtype(for kind: AnnotationKind) -> PDFAnnotationSubtype? {
        switch kind {
        case .text: return .text
        case .link: return .link
        case .freeText: return .freeText
        case .line: return .line
        case .square: return .square
        case .circle: return .circle
        case .polygon: return PDFAnnotationSubtype(rawValue: "/Polygon")
        case .polyLine: return PDFAnnotationSubtype(rawValue: "/PolyLine")
        case .highlight: return .highlight
        case .underline: return .underline
        case .squiggly: return PDFAnnotationSubtype(rawValue: "/Squiggly")
        case .strikeOut: return .strikeOut
        case .stamp: return .stamp
        case .ink: return .ink
        case .popup: return .popup
        case .fileAttachment: return PDFAnnotationSubtype(rawValue: "/FileAttachment")
        case .widget: return .widget
        case .redact: return nil
        case .other: return nil
        }
    }

    /// Builds a `PDFAnnotation` from a neutral value.
    ///
    /// - Throws: ``PDFBridgeError/unsupported(_:)`` for annotation kinds this bridge
    ///   refuses to write rather than write badly — redactions, any subtype PDFKit does not
    ///   model, and ink strokes on a platform without PDFKit's Bézier-path API.
    static func annotation(from neutral: NeutralAnnotation) throws -> PDFAnnotation {
        guard let subtype = subtype(for: neutral.kind) else {
            throw PDFBridgeError.unsupported("writing a \(neutral.kind.pdfSubtype) annotation")
        }
        #if !canImport(AppKit) && !canImport(UIKit)
        if neutral.kind == .ink, !neutral.inkPaths.isEmpty {
            throw PDFBridgeError.unsupported("writing ink annotation strokes")
        }
        #endif

        let annotation = PDFAnnotation(bounds: neutral.bounds, forType: subtype, withProperties: nil)
        if let contents = neutral.contents { annotation.contents = contents }
        if let author = neutral.author { annotation.userName = author }
        if let subject = neutral.subject {
            annotation.setValue(subject, forAnnotationKey: PDFAnnotationKeys.subject)
        }
        if let name = neutral.name {
            annotation.setValue(name, forAnnotationKey: PDFAnnotationKeys.name)
            // PDFKit drops `/NM` on write; this key survives, and the reader falls back to it.
            annotation.setValue(name, forAnnotationKey: PDFAnnotationKeys.zenitName)
        }
        if neutral.isZenitOwned {
            annotation.setValue(true, forAnnotationKey: PDFAnnotationKeys.zenitOwner)
        }
        if let color = neutral.color {
            setColor(color, interior: false, on: annotation)
        }
        if let interior = neutral.interiorColor {
            setColor(interior, interior: true, on: annotation)
        }
        if let width = neutral.borderWidth {
            let border = PDFBorder()
            border.lineWidth = CGFloat(width)
            annotation.border = border
        }
        if let modified = neutral.modificationDate { annotation.modificationDate = modified }
        // Write `/CreationDate` back so an annotation keeps its creation date through a
        // round trip (CR-93). PDFKit rejects a `Date` for this key, so write the PDF date string.
        if let created = neutral.creationDate {
            annotation.setValue(pdfDateString(from: created), forAnnotationKey: PDFAnnotationKeys.creationDate)
        }

        switch neutral.kind {
        case .line where neutral.points.count >= 2:
            annotation.startPoint = neutral.points[0]
            annotation.endPoint = neutral.points[1]
        case .polygon, .polyLine:
            if !neutral.points.isEmpty {
                // The flat `[x0, y0, x1, y1, …]` array the PDF `/Vertices` entry is defined
                // as. PDFKit rejects an `[NSValue]` here — "Could not create array value for
                // key: /Vertices" — so this is both the portable spelling and the one that
                // actually writes.
                annotation.setValue(
                    neutral.points.flatMap { [NSNumber(value: $0.x), NSNumber(value: $0.y)] },
                    forAnnotationKey: PDFAnnotationKeys.vertices
                )
            }
        case .highlight, .underline, .squiggly, .strikeOut:
            if !neutral.quadPoints.isEmpty {
                annotation.quadrilateralPoints = neutral.quadPoints.map { $0 as NSValue }
            }
        case .ink:
            addInkPaths(neutral.inkPaths, to: annotation)
        default:
            break
        }
        return annotation
    }

    /// Adds ink strokes the one way PDFKit accepts them: platform Bézier paths whose coordinates
    /// are relative to the annotation's bounds origin — the mirror of ``inkPaths(_:origin:)``.
    private static func addInkPaths(_ paths: [[CGPoint]], to annotation: PDFAnnotation) {
        let origin = annotation.bounds.origin
        for stroke in paths where stroke.count >= 2 {
            #if os(macOS)
            let path = NSBezierPath()
            #else
            let path = UIBezierPath()
            #endif
            path.move(to: CGPoint(x: stroke[0].x - origin.x, y: stroke[0].y - origin.y))
            for point in stroke.dropFirst() {
                let relative = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
                #if os(macOS)
                path.line(to: relative)
                #else
                path.addLine(to: relative)
                #endif
            }
            annotation.add(path)
        }
    }

    /// The one place a colour goes back into PDFKit — **with its alpha**.
    ///
    /// Written through the platform colour, because that is the only route by which PDFKit puts
    /// alpha anywhere: it cannot set `/CA` (`setValue(_:forAnnotationKey: "/CA")` is refused) but
    /// it paints a translucent colour into the appearance stream it generates, with an ExtGState
    /// carrying `/CA` or `/ca`. The `/C` array route it replaced wrote three numbers, so a 20 %
    /// area fill left as an opaque polygon over the drawing in every other reader (nl-pdf bug 2).
    private static func setColor(_ color: AnnotationColor, interior: Bool, on annotation: PDFAnnotation) {
        #if os(macOS)
        let platform = NSColor(
            srgbRed: CGFloat(color.red), green: CGFloat(color.green),
            blue: CGFloat(color.blue), alpha: CGFloat(color.alpha)
        )
        #else
        let platform = UIColor(
            red: CGFloat(color.red), green: CGFloat(color.green),
            blue: CGFloat(color.blue), alpha: CGFloat(color.alpha)
        )
        #endif
        if interior {
            annotation.interiorColor = platform
        } else {
            annotation.color = platform
        }
    }
}

/// The `/Subj`, `/Vertices`, `/InkList` and `/CreationDate` keys.
///
/// PDFKit's `PDFAnnotationKey` is a raw-representable wrapper around the PDF key name,
/// and it ships constants for most but not all of them. Naming the missing ones here,
/// once, is better than scattering string literals through the mapping.
enum PDFAnnotationKeys {
    static let subject = PDFAnnotationKey(rawValue: "/Subj")
    static let vertices = PDFAnnotationKey(rawValue: "/Vertices")
    static let creationDate = PDFAnnotationKey(rawValue: "/CreationDate")
    static let inkList = PDFAnnotationKey.inklist
    static let name = PDFAnnotationKey.name
    static let zenitOwner = PDFAnnotationKey(rawValue: "/" + ZenitAnnotationOwnership.ownerKey)
    static let zenitName = PDFAnnotationKey(rawValue: "/" + ZenitAnnotationOwnership.nameKey)
}
