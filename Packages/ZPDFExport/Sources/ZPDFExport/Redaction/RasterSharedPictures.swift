import CoreGraphics
import CryptoKit
import Foundation
import PDFKit

/// Phase 1 and a picture shared between sheets (K-11; ADR-0033 §11.8, §12).
///
/// Phase 1 draws every sheet without a box afresh through Core Graphics, and Core Graphics writes
/// each picture it draws **whole** — even where the sheet shows only part of it through a clip. A
/// picture that lies under a box on a marked sheet and is shown, cropped, on an unmarked one would
/// therefore travel whole in the copy, the part under the box included. Such an unmarked sheet
/// becomes a picture of itself as well (with no box on it), so only what it shows travels.
///
/// A picture is an image XObject (`Do`) or an inline image (`BI … ID … EI`), drawn in the sheet's
/// content, in a form at any depth up to 24, in the cell of a tiling pattern the sheet selects, or
/// in an annotation's appearance. Core Graphics writes an inline image it redraws as an image
/// XObject, so both kinds must be seen, on both sides of the proof (it1r K-11).
///
/// Pictures are recognised by their decoded samples (Core Graphics' own reading: the width, the
/// height, the depth, then a SHA-256 of the decoded data), not by object number or by encoding, so
/// the check needs no object layer, works for an encrypted drawing — the whole-document fallback
/// of the vector path runs phase 1 for exactly those — and finds a picture again after Core
/// Graphics has re-compressed it into the copy (proof step 5). It errs towards more pictures: a
/// placement that touches a box counts as under it whatever the clip, and every picture in the
/// appearance of an annotation over a box, or in a pattern cell a marked sheet selects, counts.
enum RasterSharedPictures {

    /// What can be read without decoding: a picture whose shape differs is not the same picture.
    /// The encoded length is deliberately not part of it — the same samples compressed another way
    /// (by Core Graphics writing the copy, or once inline and once as an XObject) are the same
    /// picture.
    struct Shape: Hashable {
        var width: Int
        var height: Int
        var bitsPerComponent: Int
    }

    struct Key: Hashable {
        var shape: Shape
        var digest: Data
    }

    /// Zero-based unmarked sheets that draw a picture lying under a box on a marked sheet.
    static func unmarkedSheetsSharingPictures(_ document: PDFDocument, marks: [Int: [RedactionMark]]) -> Set<Int> {
        let under = picturesUnderBoxes(document, marks: marks)
        guard !under.isEmpty else { return [] }
        var out: Set<Int> = []
        for index in 0..<document.pageCount where marks[index] == nil {
            guard let page = document.page(at: index), !pictures(on: page, among: under).isEmpty else { continue }
            out.insert(index)
        }
        return out
    }

    /// Every picture drawn, at least partly, under a box of a marked sheet — in the sheet's content
    /// (through forms) or in the appearance of an annotation that reaches a box.
    static func picturesUnderBoxes(_ document: PDFDocument, marks: [Int: [RedactionMark]]) -> Set<Key> {
        var out: Set<Key> = []
        for (index, pageMarks) in marks {
            guard let page = document.page(at: index)?.pageRef else { continue }
            let boxes = pageMarks.map(\.rect)
            out.formUnion(scan(page: page, boxes: boxes, only: nil))
            for appearance in appearances(of: page) where boxes.contains(where: { $0.intersects(appearance.rect) }) {
                out.formUnion(scan(form: appearance.stream, on: page, only: nil))
            }
        }
        return out
    }

    /// Which of `among` the sheet draws, in its content or in any annotation appearance.
    static func pictures(on page: PDFPage, among: Set<Key>) -> Set<Key> {
        guard let reference = page.pageRef, !among.isEmpty else { return [] }
        let shapes = Set(among.map(\.shape))
        var drawn = scan(page: reference, boxes: nil, only: shapes)
        for appearance in appearances(of: reference) { drawn.formUnion(scan(form: appearance.stream, on: reference, only: shapes)) }
        return drawn.intersection(among)
    }

    // MARK: - Reading

    final class State {
        /// Only placements touching one of these count; `nil`: every placement.
        let boxes: [CGRect]?
        /// Only pictures of these shapes are digested; `nil`: every picture.
        let only: Set<Shape>?
        var ctm = CGAffineTransform.identity
        var stack: [CGAffineTransform] = []
        var contentStreams: [CGPDFContentStreamRef] = []
        var depth = 0
        var table: CGPDFOperatorTableRef?
        var found: Set<Key> = []
        /// Digests of image XObjects, by stream: those live as long as the document. An inline
        /// image's stream lives only for its `EI` callback, so it is never cached.
        var digests: [UnsafeRawPointer: Data] = [:]
        /// Above zero while a tiling pattern's cell is read: every placement in it counts.
        var unbounded = 0
        /// Pattern cells already read: a second reading of one finds nothing new.
        var patternsRead: Set<UnsafeRawPointer> = []

        init(boxes: [CGRect]?, only: Set<Shape>?) {
            self.boxes = boxes
            self.only = only
        }
    }

    static func scan(page: CGPDFPage, boxes: [CGRect]?, only: Set<Shape>?) -> Set<Key> {
        let content = CGPDFContentStreamCreateWithPage(page)
        defer { CGPDFContentStreamRelease(content) }
        return run(content, State(boxes: boxes, only: only))
    }

    /// An annotation appearance, every picture in it; the page's content stream is its parent,
    /// as Core Graphics' API wants one.
    static func scan(form stream: CGPDFStreamRef, on page: CGPDFPage, only: Set<Shape>?) -> Set<Key> {
        guard let dictionary = CGPDFStreamGetDictionary(stream) else { return [] }
        var resources: CGPDFDictionaryRef?
        _ = CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources)
        let parent = CGPDFContentStreamCreateWithPage(page)
        defer { CGPDFContentStreamRelease(parent) }
        let content = CGPDFContentStreamCreateWithStream(stream, resources ?? dictionary, parent)
        defer { CGPDFContentStreamRelease(content) }
        return run(content, State(boxes: nil, only: only))
    }

    private static func run(_ content: CGPDFContentStreamRef, _ state: State) -> Set<Key> {
        guard let table = makeTable() else { return [] }
        defer { CGPDFOperatorTableRelease(table) }
        state.table = table
        state.contentStreams.append(content)
        let scanner = CGPDFScannerCreate(content, table, Unmanaged.passUnretained(state).toOpaque())
        _ = CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        return state.found
    }

    /// The normal appearance stream of every annotation on the page, with its rectangle.
    static func appearances(of page: CGPDFPage) -> [(rect: CGRect, stream: CGPDFStreamRef)] {
        guard let dictionary = page.dictionary else { return [] }
        var annotations: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dictionary, "Annots", &annotations), let annotations else { return [] }
        var out: [(CGRect, CGPDFStreamRef)] = []
        for index in 0..<CGPDFArrayGetCount(annotations) {
            var annotation: CGPDFDictionaryRef?
            guard CGPDFArrayGetDictionary(annotations, index, &annotation), let annotation else { continue }
            var appearance: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(annotation, "AP", &appearance), let appearance else { continue }
            var rect = CGRect.null
            var array: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(annotation, "Rect", &array), let array, CGPDFArrayGetCount(array) == 4 {
                var v = [CGPDFReal](repeating: 0, count: 4)
                for item in 0..<4 { CGPDFArrayGetNumber(array, item, &v[item]) }
                rect = CGRect(x: min(v[0], v[2]), y: min(v[1], v[3]), width: abs(v[2] - v[0]), height: abs(v[3] - v[1]))
            }
            var normal: CGPDFStreamRef?
            if CGPDFDictionaryGetStream(appearance, "N", &normal), let normal {
                out.append((rect, normal))
                continue
            }
            // An appearance with states: every state's stream.
            var states: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(appearance, "N", &states), let states else { continue }
            final class Collector { var streams: [CGPDFStreamRef] = [] }
            let collector = Collector()
            CGPDFDictionaryApplyFunction(states, { _, object, info in
                var stream: CGPDFStreamRef?
                guard let info, CGPDFObjectGetValue(object, .stream, &stream), let stream else { return }
                Unmanaged<Collector>.fromOpaque(info).takeUnretainedValue().streams.append(stream)
            }, Unmanaged.passUnretained(collector).toOpaque())
            for stream in collector.streams { out.append((rect, stream)) }
        }
        return out
    }

    private static func state(_ info: UnsafeMutableRawPointer?) -> State {
        Unmanaged<State>.fromOpaque(info!).takeUnretainedValue()
    }

    private static func makeTable() -> CGPDFOperatorTableRef? {
        guard let table = CGPDFOperatorTableCreate() else { return nil }
        func on(_ name: String, _ callback: @escaping CGPDFOperatorCallback) {
            name.withCString { CGPDFOperatorTableSetCallback(table, $0, callback) }
        }
        on("q") { _, info in let s = RasterSharedPictures.state(info); s.stack.append(s.ctm) }
        on("Q") { _, info in let s = RasterSharedPictures.state(info); if let ctm = s.stack.popLast() { s.ctm = ctm } }
        on("cm") { scanner, info in
            var v = [CGPDFReal](repeating: 0, count: 6)
            for index in (0..<6).reversed() { guard CGPDFScannerPopNumber(scanner, &v[index]) else { return } }
            let s = RasterSharedPictures.state(info)
            s.ctm = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5]).concatenating(s.ctm)
        }
        on("Do") { scanner, info in
            var pointer: UnsafePointer<CChar>?
            guard CGPDFScannerPopName(scanner, &pointer), let pointer else { return }
            RasterSharedPictures.paintXObject(RasterSharedPictures.state(info), named: String(cString: pointer))
        }
        // An inline image: Core Graphics hands the whole `BI … ID … EI` over as a stream whose
        // dictionary may use the abbreviated keys.
        on("EI") { scanner, info in
            var stream: CGPDFStreamRef?
            guard CGPDFScannerPopStream(scanner, &stream), let stream else { return }
            RasterSharedPictures.paintImage(RasterSharedPictures.state(info), stream: stream, inline: true)
        }
        // A tiling pattern selected for filling or stroking: the pictures in its cell.
        for select in ["scn", "SCN"] {
            on(select) { scanner, info in
                var pointer: UnsafePointer<CChar>?
                guard CGPDFScannerPopName(scanner, &pointer), let pointer else { return }
                RasterSharedPictures.selectPattern(RasterSharedPictures.state(info), named: String(cString: pointer))
            }
        }
        return table
    }

    /// An integer entry under its full key or, in an inline image, its abbreviation.
    private static func integer(_ dictionary: CGPDFDictionaryRef, _ keys: String...) -> Int {
        for key in keys {
            var value: CGPDFInteger = 0
            if CGPDFDictionaryGetInteger(dictionary, key, &value) { return value }
        }
        return -1
    }

    private static func paintImage(_ s: State, stream: CGPDFStreamRef, inline: Bool) {
        guard let dictionary = CGPDFStreamGetDictionary(stream) else { return }
        let shape = inline
            ? Shape(width: integer(dictionary, "Width", "W"), height: integer(dictionary, "Height", "H"),
                    bitsPerComponent: integer(dictionary, "BitsPerComponent", "BPC"))
            : Shape(width: integer(dictionary, "Width"), height: integer(dictionary, "Height"),
                    bitsPerComponent: integer(dictionary, "BitsPerComponent"))
        if let only = s.only, !only.contains(shape) { return }
        if let boxes = s.boxes, s.unbounded == 0 {
            let corners = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)].map { $0.applying(s.ctm) }
            guard boxes.contains(where: { RedactionContentRewriter.quad(corners, intersects: $0) }) else { return }
        }
        let identity = unsafeBitCast(stream, to: UnsafeRawPointer.self)
        if !inline, let cached = s.digests[identity] {
            s.found.insert(Key(shape: shape, digest: cached))
            return
        }
        var format = CGPDFDataFormat.raw
        let data = (CGPDFStreamCopyData(stream, &format) as Data?) ?? Data()
        var hasher = SHA256()
        hasher.update(data: Data([UInt8(truncatingIfNeeded: format.rawValue)]))
        hasher.update(data: data)
        let digest = Data(hasher.finalize())
        if !inline { s.digests[identity] = digest }
        s.found.insert(Key(shape: shape, digest: digest))
    }

    /// A tiling pattern's cell is read like a form, with every placement in it counting: where
    /// its tiles land depends on the area filled, which this scan does not follow.
    private static func selectPattern(_ s: State, named name: String) {
        guard let content = s.contentStreams.last, let object = CGPDFContentStreamGetResource(content, "Pattern", name) else { return }
        var stream: CGPDFStreamRef?
        guard CGPDFObjectGetValue(object, .stream, &stream), let stream, let dictionary = CGPDFStreamGetDictionary(stream),
              integer(dictionary, "PatternType") == 1,
              s.patternsRead.insert(unsafeBitCast(stream, to: UnsafeRawPointer.self)).inserted else { return }
        s.unbounded += 1
        readForm(s, stream: stream, dictionary: dictionary, parent: content)
        s.unbounded -= 1
    }

    private static func readForm(_ s: State, stream: CGPDFStreamRef, dictionary: CGPDFDictionaryRef, parent content: CGPDFContentStreamRef) {
        guard s.depth < 24, let table = s.table else { return }
        var matrix = CGAffineTransform.identity
        var array: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(dictionary, "Matrix", &array), let array, CGPDFArrayGetCount(array) == 6 {
            var v = [CGPDFReal](repeating: 0, count: 6)
            for index in 0..<6 { CGPDFArrayGetNumber(array, index, &v[index]) }
            matrix = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
        }
        var resources: CGPDFDictionaryRef?
        _ = CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources)
        let saved = (s.ctm, s.stack)
        s.ctm = matrix.concatenating(s.ctm)
        s.stack = []
        s.depth += 1
        let inner = CGPDFContentStreamCreateWithStream(stream, resources ?? dictionary, content)
        s.contentStreams.append(inner)
        let scanner = CGPDFScannerCreate(inner, table, Unmanaged.passUnretained(s).toOpaque())
        _ = CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFContentStreamRelease(inner)
        s.contentStreams.removeLast()
        s.depth -= 1
        (s.ctm, s.stack) = saved
    }

    private static func paintXObject(_ s: State, named name: String) {
        guard let content = s.contentStreams.last, let object = CGPDFContentStreamGetResource(content, "XObject", name) else { return }
        var stream: CGPDFStreamRef?
        guard CGPDFObjectGetValue(object, .stream, &stream), let stream, let dictionary = CGPDFStreamGetDictionary(stream) else { return }
        var subtype: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype else { return }
        switch String(cString: subtype) {
        case "Image": paintImage(s, stream: stream, inline: false)
        case "Form": readForm(s, stream: stream, dictionary: dictionary, parent: content)
        default: return
        }
    }
}
