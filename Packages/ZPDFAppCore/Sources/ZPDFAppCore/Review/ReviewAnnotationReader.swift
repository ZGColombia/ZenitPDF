import CoreGraphics
import CryptoKit
import Foundation
import ZPDFContracts

/// Reads a reviewer's annotations out of a PDF for the review import (NL-COLLAB-08).
///
/// Through CoreGraphics' `CGPDF` dictionaries rather than PDFKit's annotation objects, for two
/// measured reasons (probe on macOS 26, 2026-09-23):
///
/// - PDFKit does not expose `/IRT` at all — `value(forAnnotationKey: "/IRT")` is `nil` on a reply —
///   so a reply could not be told from a note. `CGPDFDictionaryGetDictionary(_, "IRT")` returns the
///   parent's dictionary, whose identity finds the parent among the page's annotations.
/// - PDFKit returns a Line's end points and a highlight's quad points **relative to `/Rect`'s
///   origin**; the raw arrays are page space, which is what a markup stores.
///
/// Nothing is executed: actions, JavaScript and appearance streams are not read. Counts and
/// sizes are capped as ``AnnotationImportPlanner`` documents, and every number is checked finite.
///
/// One budget per read (U-032): at most ``AnnotationImportPlanner/maximumTotalPoints`` points over
/// the whole file, and ``AnnotationImportPlanner/maximumVertices`` per Ink annotation across all
/// its strokes. The caps used to be per array only, and CGPDF resolves indirect references, so
/// one shared 20 000-number array named by a thousand strokes of ten thousand annotations
/// expanded a small file into billions of points — on project open, which reads the drawing.
/// Reading stops at the annotation that would overrun it; the rest are counted, not read.
public enum ReviewAnnotationReader {

    /// The result of reading one file.
    public struct Reading: Sendable {
        public var annotations: [ImportedAnnotation]
        public var pageCount: Int
        /// Page sizes (media box), to check the file is the drawing on screen.
        public var pageSizes: [PDFSize]
        /// SHA-256 of the file, hex — the key a second import of the same file is recognised by.
        public var digest: String
        /// Annotations not read because the file's geometry budget ran out before them (U-032).
        public var annotationsOverBudget = 0
    }

    public enum ReadError: Error, Equatable {
        case unreadable
        case encrypted
        case tooLarge
    }

    /// Files larger than this are refused before parsing (1 GiB): a drawing set can be big, a
    /// review file bigger than that is not one.
    public static let maximumFileBytes = 1 << 30

    public static func read(url: URL) throws -> Reading {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maximumFileBytes else { throw ReadError.tooLarge }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { throw ReadError.unreadable }
        return try read(data: data)
    }

    public static func read(data: Data) throws -> Reading {
        guard data.count <= maximumFileBytes else { throw ReadError.tooLarge }
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider)
        else { throw ReadError.unreadable }
        if document.isEncrypted, !document.unlockWithPassword("") { throw ReadError.encrypted }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()

        var annotations: [ImportedAnnotation] = []
        var sizes: [PDFSize] = []
        var budget = AnnotationImportPlanner.maximumTotalPoints
        var overBudget = 0
        let pageCount = document.numberOfPages
        for pageNumber in 1...max(pageCount, 1) where pageCount > 0 {
            guard let page = document.page(at: pageNumber) else { sizes.append(PDFSize(width: 0, height: 0)); continue }
            let box = page.getBoxRect(.mediaBox)
            sizes.append(PDFSize(width: Double(box.width), height: Double(box.height)))
            guard let pageDictionary = page.dictionary else { continue }
            var annots: CGPDFArrayRef?
            guard CGPDFDictionaryGetArray(pageDictionary, "Annots", &annots), let annots else { continue }
            let count = CGPDFArrayGetCount(annots)
            var pageDictionaries: [(CGPDFDictionaryRef, Int)] = []
            var pendingParents: [(annotationIndex: Int, parent: CGPDFDictionaryRef)] = []
            for slot in 0..<count {
                guard annotations.count + overBudget < AnnotationImportPlanner.maximumAnnotations + 1 else { break }
                var entry: CGPDFDictionaryRef?
                guard CGPDFArrayGetDictionary(annots, slot, &entry), let entry else { continue }
                // Once the budget is spent every later annotation is counted, not read: a prefix
                // of the file, so each kept annotation keeps its place on its page.
                guard overBudget == 0 else { overBudget += 1; continue }
                let index = annotations.count
                var annotation = parse(entry, index: index, pageIndex: pageNumber - 1)
                let cost = annotation.points.count + annotation.quadPoints.count
                    + annotation.inkPaths.reduce(0) { $0 + $1.count }
                guard cost <= budget else { overBudget = 1; continue }
                budget -= cost
                var parent: CGPDFDictionaryRef?
                if CGPDFDictionaryGetDictionary(entry, "IRT", &parent), let parent {
                    pendingParents.append((index, parent))
                    annotation.inReplyToIndex = -1 // resolved below
                }
                pageDictionaries.append((entry, index))
                annotations.append(annotation)
            }
            for pending in pendingParents {
                let parentIndex = pageDictionaries.first { $0.0 == pending.parent }?.1
                annotations[pending.annotationIndex].inReplyToIndex = parentIndex
                if parentIndex == nil {
                    // A reply whose parent is not on this page's list: kept as a reply to nothing,
                    // which the planner reports rather than turning it into a stray note.
                    annotations[pending.annotationIndex].inReplyToIndex = Int.min
                }
            }
        }
        var reading = Reading(annotations: annotations, pageCount: pageCount, pageSizes: sizes, digest: digest)
        reading.annotationsOverBudget = overBudget
        return reading
    }

    // MARK: - One dictionary

    static func parse(_ dictionary: CGPDFDictionaryRef, index: Int, pageIndex: Int) -> ImportedAnnotation {
        let rect = numbers(dictionary, "Rect")
        let bounds: PDFRect = rect.count == 4
            ? PDFRect(corner: PDFPoint(x: rect[0], y: rect[1]), opposite: PDFPoint(x: rect[2], y: rect[3]))
            : PDFRect(x: 0, y: 0, width: 0, height: 0)
        let subtype = name(dictionary, "Subtype") ?? ""
        var points: [PDFPoint] = []
        switch subtype {
        case "Line": points = pairs(slots(dictionary, "L"))
        case "FreeText": points = pairs(slots(dictionary, "CL"))
        default: points = pairs(slots(dictionary, "Vertices"))
        }
        // At most `maximumVertices` points over all of an Ink's strokes, as documented (U-032).
        var ink: [[PDFPoint]] = []
        var inkList: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(dictionary, "InkList", &inkList), let inkList {
            var remaining = AnnotationImportPlanner.maximumVertices
            for slot in 0..<min(CGPDFArrayGetCount(inkList), 1_000) where remaining > 0 {
                var stroke: CGPDFArrayRef?
                guard CGPDFArrayGetArray(inkList, slot, &stroke), let stroke else { continue }
                let values = slots(stroke, limit: remaining * 2)
                remaining -= values.count / 2
                ink.append(pairs(values))
            }
        }
        var width: Double?
        var borderStyle: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(dictionary, "BS", &borderStyle), let borderStyle {
            width = number(borderStyle, "W")
        } else {
            let border = numbers(dictionary, "Border")
            if border.count >= 3 { width = border[2] }
        }
        var cloudy = false
        var effect: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(dictionary, "BE", &effect), let effect {
            cloudy = name(effect, "S") == "C"
        }
        var ownerObject: CGPDFObjectRef?
        let owned = CGPDFDictionaryGetObject(dictionary, "ZPDFMarkup", &ownerObject)
        return ImportedAnnotation(
            index: index,
            pageIndex: pageIndex,
            subtype: subtype,
            name: text(dictionary, "NM") ?? text(dictionary, "ZPDFName"),
            author: text(dictionary, "T"),
            contents: text(dictionary, "Contents"),
            subject: text(dictionary, "Subj"),
            creationDate: date(dictionary, "CreationDate"),
            modificationDate: date(dictionary, "M"),
            color: color(numbers(dictionary, "C")),
            interiorColor: color(numbers(dictionary, "IC")),
            lineWidth: width.flatMap { $0.isFinite ? $0 : nil },
            rect: bounds,
            points: points,
            inkPaths: ink,
            // A quad with a bad corner keeps it, not-a-number, so the planner drops that quad whole.
            quadPoints: positionalPairs(slots(dictionary, "QuadPoints")),
            lineEndings: names(dictionary, "LE"),
            cloudy: cloudy,
            intent: name(dictionary, "IT"),
            stateModel: text(dictionary, "StateModel"),
            state: text(dictionary, "State"),
            zenitOwned: owned
        )
    }

    // MARK: - Values

    /// The finite numbers of a small array (`/Rect`, `/C`, `/Border`), anything else left out.
    private static func numbers(_ dictionary: CGPDFDictionaryRef, _ key: String) -> [Double] {
        slots(dictionary, key).filter(\.isFinite)
    }

    private static func slots(_ dictionary: CGPDFDictionaryRef, _ key: String) -> [Double] {
        var array: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dictionary, key, &array), let array else { return [] }
        return slots(array)
    }

    /// Every slot of a coordinate array, in place: a null, a name or a non-finite number is kept
    /// as not-a-number, so the coordinates after it stay paired as the file wrote them (U-033).
    /// Dropping it shifted every later x into a y.
    static func slots(_ array: CGPDFArrayRef, limit: Int = AnnotationImportPlanner.maximumVertices * 2) -> [Double] {
        let count = min(CGPDFArrayGetCount(array), max(0, limit))
        var values: [Double] = []
        values.reserveCapacity(count)
        for slot in 0..<count {
            var real: CGPDFReal = 0
            if CGPDFArrayGetNumber(array, slot, &real), real.isFinite {
                values.append(Double(real))
            } else {
                values.append(.nan)
            }
        }
        return values
    }

    private static func number(_ dictionary: CGPDFDictionaryRef, _ key: String) -> Double? {
        var real: CGPDFReal = 0
        return CGPDFDictionaryGetNumber(dictionary, key, &real) ? Double(real) : nil
    }

    /// The points of a coordinate array; a point with a bad coordinate costs that point only.
    static func pairs(_ values: [Double]) -> [PDFPoint] {
        positionalPairs(values).filter { $0.x.isFinite && $0.y.isFinite }
    }

    /// The points of a coordinate array with every position kept, bad ones not-a-number.
    static func positionalPairs(_ values: [Double]) -> [PDFPoint] {
        stride(from: 0, to: values.count - 1, by: 2).map { PDFPoint(x: values[$0], y: values[$0 + 1]) }
    }

    private static func name(_ dictionary: CGPDFDictionaryRef, _ key: String) -> String? {
        var pointer: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dictionary, key, &pointer), let pointer else { return nil }
        return String(cString: pointer)
    }

    private static func names(_ dictionary: CGPDFDictionaryRef, _ key: String) -> [String] {
        var array: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dictionary, key, &array), let array else { return [] }
        return (0..<min(CGPDFArrayGetCount(array), 4)).compactMap { slot in
            var pointer: UnsafePointer<CChar>?
            guard CGPDFArrayGetName(array, slot, &pointer), let pointer else { return nil }
            return String(cString: pointer)
        }
    }

    /// A text string (`(…)` or `<…>`), or a name for keys some writers spell as one (`/State`).
    private static func text(_ dictionary: CGPDFDictionaryRef, _ key: String) -> String? {
        var string: CGPDFStringRef?
        if CGPDFDictionaryGetString(dictionary, key, &string), let string,
           let value = CGPDFStringCopyTextString(string) as String? {
            return String(value.prefix(AnnotationImportPlanner.maximumTextLength))
        }
        return name(dictionary, key)
    }

    private static func date(_ dictionary: CGPDFDictionaryRef, _ key: String) -> Date? {
        var string: CGPDFStringRef?
        guard CGPDFDictionaryGetString(dictionary, key, &string), let string,
              let date = CGPDFStringCopyDate(string) as Date?
        else { return nil }
        return date
    }

    private static func color(_ components: [Double]) -> RGBAColor? {
        let clamped = components.map { max(0, min(1, $0)) }
        switch clamped.count {
        case 1: return RGBAColor(red: clamped[0], green: clamped[0], blue: clamped[0], alpha: 1)
        case 3: return RGBAColor(red: clamped[0], green: clamped[1], blue: clamped[2], alpha: 1)
        case 4:
            let (c, m, y, k) = (clamped[0], clamped[1], clamped[2], clamped[3])
            return RGBAColor(red: (1 - c) * (1 - k), green: (1 - m) * (1 - k), blue: (1 - y) * (1 - k), alpha: 1)
        default: return nil
        }
    }
}
