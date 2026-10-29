import CoreGraphics
import Foundation
import PDFKit

extension VectorRedactor {

    /// Pixel tolerances for the comparison outside the boxes. A vector sheet is drawn by the same
    /// renderer from the same geometry, so it must match closely; a sheet that fell back is a
    /// 300-dpi picture and gets phase 1's allowance.
    static let vectorPixelDelta = 32
    static let vectorPixelShare = 0.002
    static let rasterPixelDelta = 48
    static let rasterPixelShare = 0.01

    /// Proves the copy before it is kept; any failure refuses it and nothing is written.
    static func verify(_ built: Built, prepared: Prepared) throws -> [String] {
        let source = prepared.document
        guard let output = PDFDocument(data: built.bytes), output.pageCount == source.pageCount,
              let provider = CGDataProvider(data: built.bytes as CFData), let readback = CGPDFDocument(provider),
              readback.numberOfPages == source.pageCount
        else { throw RedactionRefusal.checkFailed("the copy does not open with every sheet") }
        var checks: [String] = []
        let vectorPages = Set(prepared.rewritten.keys)

        // 1. One fresh revision; nothing the original carried at document level.
        let bytes = [UInt8](built.bytes)
        guard let scan = try? PDFDocumentScan(data: built.bytes),
              count(Array("startxref".utf8), in: bytes) == 1, count(Array("%%EOF".utf8), in: bytes) == 1, scan.trailer["Prev"] == nil
        else { throw RedactionRefusal.checkFailed("the copy is not a single fresh revision") }
        if let catalog = scan.dictionary(scan.rootReference) {
            for key in ["Metadata", "OpenAction", "AA", "AF", "StructTreeRoot", "MarkInfo", "Collection", "Perms", "PieceInfo"] where catalog[key] != nil {
                throw RedactionRefusal.checkFailed("the copy carries /\(key)")
            }
            if let names = scan.dictionary(catalog["Names"]), names.keys.contains(where: { $0 != "Dests" }) {
                throw RedactionRefusal.checkFailed("the copy carries a name tree other than destinations")
            }
            if scan.dictionary(catalog["AcroForm"])?["XFA"] != nil { throw RedactionRefusal.checkFailed("the copy carries XFA form data") }
        }
        if let info = scan.dictionary(scan.trailer["Info"]), info.keys.contains(where: { $0 != "Producer" }) {
            throw RedactionRefusal.checkFailed("the copy carries document information")
        }
        for entry in scan.objects.values {
            try Self.refuseCarriedFiles(entry.object, depth: 0)
        }
        checks.append("the copy is one fresh revision with no metadata, scripts, attachments, tagged structure or earlier versions")

        // 1b. Nothing cut under a box travels in its original form — through a resource
        // dictionary another sheet shares, a form kept elsewhere, a cropped placement or a
        // fallback sheet (findings 4, 8) — unless a use of it shows it whole.
        guard built.writtenSources.intersection(built.tainted).subtracting(built.justified).isEmpty else {
            throw RedactionRefusal.checkFailed("the original of a picture, form, pattern, shading or font cut under a box is still in the file")
        }
        checks.append("nothing cut under a box travels in its original form, except where another use shows it whole")

        // 2. Sheets that fell back: no text at all, as in phase 1.
        for index in built.rasterPages {
            let text = output.page(at: index)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard text.isEmpty else { throw RedactionRefusal.checkFailed("text is still extractable on sheet \(index + 1)") }
        }

        // 3. Nothing selectable under a box (PDFKit), and no annotation over one.
        for index in vectorPages {
            guard let page = output.page(at: index) else { continue }
            for mark in prepared.byPage[index] ?? [] {
                let selected = page.selection(for: mark.rect)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard selected.isEmpty else { throw RedactionRefusal.checkFailed("text can still be selected under a box on sheet \(index + 1)") }
                if page.annotations.contains(where: { $0.bounds.intersects(mark.rect.insetBy(dx: 0.5, dy: 0.5)) }) {
                    throw RedactionRefusal.checkFailed("sheet \(index + 1) still carries an annotation over a box")
                }
            }
        }
        checks.append("no text can be selected under a box, and no annotation lies over one")

        // 4. Core Graphics' own reading: no path, glyph or image sample inside a box.
        var readbackText: [Int: String] = [:]
        for index in 0..<source.pageCount {
            // An unmarked sheet is read back only when there are words to look for on it.
            if prepared.byPage[index] == nil, built.words.isEmpty { continue }
            guard let page = readback.page(at: index + 1) else { continue }
            let boxes = vectorPages.contains(index) ? (prepared.byPage[index]?.map(\.rect) ?? []) : []
            let result = RedactionCGReadback.scan(page: page, boxes: boxes)
            readbackText[index] = result.text
            if let violation = result.violations.first {
                throw RedactionRefusal.checkFailed("\(violation) on sheet \(index + 1)")
            }
        }
        checks.append("no path, glyph or image sample lies inside a box, read back through Core Graphics")

        // 5. The removed words: in no extraction path, on no other sheet — and not in any string the
        // file carries, a hex-encoded one included (finding 18), in any case (finding 3). Only in
        // strings — text values, hex or literal, in dictionaries and in content streams — never in
        // the raw bytes, names, operators, picture samples or font programs, where every file
        // carries "Page", "Type" and "Length" (R-098). Whole words only (R-099).
        let strings = RedactionWordSearch.fileStrings(scan)
        func carried(_ word: String, caseInsensitive: Bool) -> Bool {
            strings.contains { RedactionWordSearch.contains(word, in: $0, caseInsensitive: caseInsensitive) }
        }
        let outputTexts = (0..<output.pageCount).map { output.page(at: $0)?.string ?? "" }
        for word in built.words {
            var before = 0, under = 0, beforeAnyCase = 0, underAnyCase = 0
            for index in 0..<source.pageCount {
                let beforeHere = RedactionWordSearch.occurrences(of: word, in: prepared.texts.text(index))
                let underHere = underBoxCount(word, prepared: prepared, page: index)
                before += beforeHere
                under += underHere
                beforeAnyCase += RedactionWordSearch.occurrences(of: word, in: prepared.texts.text(index), caseInsensitive: true)
                underAnyCase += underBoxCount(word, prepared: prepared, page: index, caseInsensitive: true)
                let afterKit = RedactionWordSearch.occurrences(of: word, in: outputTexts[index])
                let afterReadback = RedactionWordSearch.occurrences(of: word, in: readbackText[index] ?? "")
                if underHere == 0 {
                    if afterKit > 0 || afterReadback > 0 {
                        throw RedactionRefusal.checkFailed("“\(word)” is still readable on sheet \(index + 1); mark it there as well")
                    }
                } else {
                    let allowed = max(0, beforeHere - underHere)
                    if afterKit > allowed || afterReadback > allowed {
                        throw RedactionRefusal.checkFailed("“\(word)” is still readable on sheet \(index + 1)")
                    }
                }
            }
            // A word that stood only under the boxes must not be anywhere in the file.
            if before <= under, carried(word, caseInsensitive: false) {
                throw RedactionRefusal.checkFailed("a removed word is still in the file")
            }
            if beforeAnyCase <= underAnyCase, carried(word, caseInsensitive: true) {
                throw RedactionRefusal.checkFailed("a removed word is still in the file")
            }
        }
        checks.append(built.words.isEmpty
            ? "no text stood under the boxes"
            : "none of the \(built.words.count) removed words can be read, by PDFKit, by Core Graphics or in any string in the file")

        // 5b. A form value that showed only under a box is nowhere in the file (finding 2): not in
        // a field another widget keeps, nor in an appearance, unless a visible widget shows it.
        if !built.removedFieldValues.isEmpty {
            // What visible widgets show: the value of the field each belongs to (read from the
            // copy itself; a hidden or non-viewable widget shows nothing).
            var shown = outputTexts
            for entry in (try? scan.pages()) ?? [] {
                for item in scan.object(entry.dictionary["Annots"])?.arrayValue ?? [] {
                    guard let annotation = scan.dictionary(item), annotation["Subtype"]?.nameValue == "Widget" else { continue }
                    let flags = scan.object(annotation["F"])?.integerValue ?? 0
                    guard flags & 2 == 0, flags & 32 == 0 else { continue }
                    var node: [String: PDFObject]? = annotation
                    var depth = 0
                    while let current = node, depth < 32 {
                        if let value = fieldText(current["V"], { scan.object($0) }) { shown.append(value); break }
                        node = scan.dictionary(current["Parent"])
                        depth += 1
                    }
                }
            }
            for value in built.removedFieldValues where value.trimmingCharacters(in: .whitespaces).count >= 3 {
                if shown.contains(where: { RedactionWordSearch.contains(value, in: $0, caseInsensitive: true) }) { continue }
                if carried(value, caseInsensitive: true) { throw RedactionRefusal.checkFailed("a removed form value is still in the file") }
            }
            checks.append("no form value that showed only under a box is in the file")
        }

        // 6. Nothing painted under a box once the boxes are taken away.
        if !vectorPages.isEmpty {
            guard let unboxed = PDFDocument(data: built.unboxed) else { throw RedactionRefusal.checkFailed("the copy cannot be checked under its boxes") }
            for index in vectorPages {
                guard let page = unboxed.page(at: index), let bitmap = RasterRedactor.render(page, dpi: 100) else { continue }
                let transform = RasterRedactor.pixelTransform(for: page, dpi: 100, height: bitmap.height)
                for mark in prepared.byPage[index] ?? [] {
                    let rect = mark.rect.applying(transform).standardized.insetBy(dx: 2, dy: 2)
                    guard let span = Self.wholePixelSpan(of: rect, width: bitmap.width, height: bitmap.height) else { continue }
                    for y in span.rows {
                        for x in span.columns {
                            let offset = (y * bitmap.width + x) * 4
                            let lowest = min(bitmap.pixels[offset], bitmap.pixels[offset + 1], bitmap.pixels[offset + 2])
                            guard lowest >= 245 else { throw RedactionRefusal.checkFailed("something is still painted under a box on sheet \(index + 1)") }
                        }
                    }
                }
            }
            checks.append("with the boxes taken away, nothing is painted where they were")
        }

        // 7. Black inside the boxes; outside them the sheet looks as before — through PDFKit and
        // again through Core Graphics' own drawing transform (finding 14/16: one path applying the
        // page transform twice agreed with itself).
        for (index, marks) in prepared.byPage {
            let isVector = vectorPages.contains(index)
            let supersample = isVector ? 1 : RasterRedactor.pictureSupersample
            guard let before = source.page(at: index), let after = output.page(at: index),
                  let a = RasterRedactor.render(before, dpi: 100, supersample: supersample),
                  let b = RasterRedactor.render(after, dpi: 100, supersample: supersample),
                  a.width == b.width, a.height == b.height
            else { throw RedactionRefusal.checkFailed("sheet \(index + 1) could not be compared") }
            let transform = RasterRedactor.pixelTransform(for: before, dpi: 100, height: a.height)
            let glyphRects = (built.removedGlyphQuads[index] ?? []).map { quad -> CGRect in
                let xs = quad.map(\.x), ys = quad.map(\.y)
                return CGRect(x: xs.min() ?? 0, y: ys.min() ?? 0, width: (xs.max() ?? 0) - (xs.min() ?? 0), height: (ys.max() ?? 0) - (ys.min() ?? 0))
                    .insetBy(dx: -1.1, dy: -1.1)
            }
            let delta = isVector ? vectorPixelDelta : rasterPixelDelta
            let share = isVector ? vectorPixelShare : rasterPixelShare
            try RasterRedactor.compare(a, b, boxes: marks.map { $0.rect.applying(transform).standardized },
                                       ignoring: glyphRects.map { $0.applying(transform).standardized }, delta: delta, share: share, sheet: index)
            try RasterRedactor.compareCoreGraphics(before, after, boxes: marks.map(\.rect), ignoring: glyphRects,
                                                   delta: delta, share: share, dpi: 100, supersample: supersample, sheet: index)
        }
        checks.append("inside every box is black; outside them the sheets look as before")

        // 8. Every sheet without a box looks as it did: one rewritten because it shares something
        // with a redacted area, one whose fonts were reduced — and one taken from another
        // revision, which passed every other check (finding 12).
        for index in 0..<source.pageCount where prepared.byPage[index] == nil {
            guard let before = source.page(at: index), let after = output.page(at: index),
                  let a = RasterRedactor.render(before, dpi: unmarkedProofDPI), let b = RasterRedactor.render(after, dpi: unmarkedProofDPI)
            else { throw RedactionRefusal.checkFailed("sheet \(index + 1) could not be compared") }
            let transform = RasterRedactor.pixelTransform(for: before, dpi: unmarkedProofDPI, height: a.height)
            let ignoring = (built.removedAnnotationRects[index] ?? []).map { $0.applying(transform).standardized.insetBy(dx: -2, dy: -2) }
            try RasterRedactor.compare(a, b, boxes: [], ignoring: ignoring, delta: vectorPixelDelta, share: vectorPixelShare, sheet: index)
        }
        if prepared.byPage.count < source.pageCount {
            checks.append("every sheet without a box looks as it did")
        }
        return checks
    }

    /// Resolution the sheets without a box are compared at.
    static let unmarkedProofDPI = 50.0

    /// The pixels of a `width` × `height` bitmap that lie wholly inside `rect` (pixel space), or
    /// `nil` when there are none. The rect is clipped to the bitmap first, so a box partly or
    /// wholly outside the crop box, or one of any size, never converts an out-of-range value.
    ///
    /// Step 6 used to build `Int(minY.rounded(.up))..<Int(maxY.rounded(.down))` directly: a box
    /// between about 2.9 and 3.6 pt tall at 100 dpi, inset by 2 px on each side, spans less than
    /// one pixel with no whole pixel coordinate inside (100.2…100.8 gave 101..<100), and Swift
    /// trapped with "Range requires lowerBound <= upperBound" (T-040).
    static func wholePixelSpan(of rect: CGRect, width: Int, height: Int) -> (rows: Range<Int>, columns: Range<Int>)? {
        guard width > 0, height > 0, rect.minX.isFinite, rect.minY.isFinite, rect.maxX.isFinite, rect.maxY.isFinite else { return nil }
        let clipped = rect.standardized.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return nil }
        let x0 = Int(clipped.minX.rounded(.up)), x1 = Int(clipped.maxX.rounded(.down))
        let y0 = Int(clipped.minY.rounded(.up)), y1 = Int(clipped.maxY.rounded(.down))
        guard x0 < x1, y0 < y1 else { return nil }
        return (y0..<y1, x0..<x1)
    }

    /// Refuses a script, a metadata stream, or anything that carries a file: an embedded file
    /// with or without its optional `/Type` (findings 10, 17), an associated file, a
    /// file-attachment or media annotation, or PostScript (finding 13) — looked for in every
    /// dictionary, direct or not.
    static func refuseCarriedFiles(_ object: PDFObject, depth: Int) throws {
        guard depth < 64 else { return }
        switch object {
        case let .array(values):
            for value in values { try refuseCarriedFiles(value, depth: depth + 1) }
        case .dictionary, .stream:
            guard let dictionary = object.dictionaryValue else { return }
            if dictionary["JS"] != nil || dictionary["S"]?.nameValue == "JavaScript" { throw RedactionRefusal.checkFailed("the copy carries a script") }
            if ["EmbeddedFile", "Metadata"].contains(dictionary["Type"]?.nameValue ?? "") {
                throw RedactionRefusal.checkFailed("the copy carries an attachment or metadata stream")
            }
            for key in ["EF", "AF", "RF", "EmbeddedFiles"] where dictionary[key] != nil {
                throw RedactionRefusal.checkFailed("the copy carries an attachment or associated file")
            }
            if let subtype = dictionary["Subtype"]?.nameValue, droppedAnnotationKinds.contains(subtype) || subtype == "PS" {
                throw RedactionRefusal.checkFailed("the copy carries an attachment, media or PostScript")
            }
            if dictionary["Subtype2"] != nil || (dictionary["Subtype"]?.nameValue == "Form" && dictionary["PS"] != nil) {
                throw RedactionRefusal.checkFailed("the copy carries a PostScript alternate")
            }
            for value in dictionary.values { try refuseCarriedFiles(value, depth: depth + 1) }
        default:
            return
        }
    }

    private static func count(_ needle: [UInt8], in haystack: [UInt8]) -> Int {
        var total = 0
        var position = 0
        while let found = PDFObjectParser.find(needle, in: haystack, from: position) {
            total += 1
            position = found + needle.count
        }
        return total
    }
}
