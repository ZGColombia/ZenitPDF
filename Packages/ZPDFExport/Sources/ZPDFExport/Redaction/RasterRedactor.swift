import CoreGraphics
import Foundation
import PDFKit
import ZPDFPDFKitBridge

/// One area to remove, in the page's own space (default user space, before `/Rotate`).
public struct RedactionMark: Sendable, Hashable, Codable {
    public var pageIndex: Int
    public var rect: CGRect

    public init(pageIndex: Int, rect: CGRect) {
        self.pageIndex = pageIndex
        self.rect = rect.standardized
    }
}

/// How a redaction removes what lies under the boxes.
public enum RedactionMethod: String, Sendable, Hashable, Codable {
    /// Phase 1: every marked sheet becomes a picture of itself with the boxes painted black.
    case raster
    /// Phase 2: the sheet stays vector; only what lies under the boxes is cut out of it.
    case vector
}

/// A marked sheet the vector rewriter could not handle exactly, so it became a picture instead,
/// and the sentence that says why.
public struct RedactionFallback: Sendable, Hashable, Codable {
    public var pageIndex: Int
    public var reason: String

    public init(pageIndex: Int, reason: String) {
        self.pageIndex = pageIndex
        self.reason = reason
    }
}

/// What a redaction did, and what it proved afterwards.
public struct RedactionOutcome: Sendable, Hashable {
    /// Zero-based indices of every marked sheet.
    public var redactedPages: [Int]
    public var markCount: Int
    /// The words that stood under the boxes, proved absent from the output.
    public var removedWordCount: Int
    /// The checks that passed, in words, for the report.
    public var checks: [String]
    /// The method that was asked for.
    public var method: RedactionMethod = .raster
    /// Marked sheets kept as vector (empty for a raster redaction).
    public var vectorPages: [Int] = []
    /// Marked sheets that became pictures although vector was asked for, with the reason.
    public var rasterFallbacks: [RedactionFallback] = []

    public init(
        redactedPages: [Int], markCount: Int, removedWordCount: Int, checks: [String],
        method: RedactionMethod = .raster, vectorPages: [Int] = [], rasterFallbacks: [RedactionFallback] = []
    ) {
        self.redactedPages = redactedPages
        self.markCount = markCount
        self.removedWordCount = removedWordCount
        self.checks = checks
        self.method = method
        self.vectorPages = vectorPages
        self.rasterFallbacks = rasterFallbacks
    }
}

/// Why a redaction was refused. A redaction that leaks is worse than none, so every refusal
/// happens before the file is kept.
public enum RedactionRefusal: Error, Equatable, CustomStringConvertible {
    case noMarks
    case unreadable
    case locked
    case markOutsidePage(Int)
    case checkFailed(String)
    /// The chosen file is the drawing the copy is made from (R-103).
    case outputIsSource
    /// One drawing of several could not be redacted into its copy, so no copy of any of them was
    /// kept in the folder (C-09, ``RedactionCopySet``).
    case copyFailed(drawing: String, reason: String)

    public var description: String {
        switch self {
        case .noMarks: "there is nothing marked for redaction"
        case .unreadable: "the drawing could not be read"
        case .locked: "the drawing is locked and the password did not open it"
        case let .markOutsidePage(page): "a box on sheet \(page + 1) lies outside the sheet"
        case let .checkFailed(reason): "the redacted copy failed a check (\(reason)), so it was deleted and nothing was written"
        case .outputIsSource: "the redacted copy cannot replace the drawing it is made from; choose another name or folder"
        case let .copyFailed(drawing, reason): "the redacted copy of “\(drawing)” could not be made (\(reason)), so no redacted copy of any marked drawing was kept"
        }
    }
}

/// Redaction, phase 1: a sheet with a box on it becomes a picture of itself with the box
/// painted solid black, so nothing under the box survives in any form — no text to extract, no
/// vector to lift, no annotation, no form value (NL-PDF-14).
///
/// # Always a new file, and checked before it is kept
///
/// The copy is written from nothing: every sheet is drawn fresh (unmarked sheets as vector, with
/// the drawing's own annotation appearances burned in), so the copy carries no metadata, no
/// attachments, no scripts, no form fields and no links from the original. Then it is opened
/// again and **proved**:
///
/// 1. the marked sheets have no extractable text at all;
/// 2. no word that stood under a box is in any string the output carries (decoded, literal or
///    hex, in objects and content streams), nor readable on any sheet — as a whole word;
/// 3. the marked sheets carry no annotations, and the file no metadata, attachments or form;
/// 4. every pixel inside a box is black, and outside the boxes the sheet looks as it did.
///
/// If any check fails the file is deleted and the redaction refused — the tool never calls a
/// page redacted that it has not checked. Phase 2, which keeps the sheet vector and cuts out only
/// what lies under the boxes, is ``VectorRedactor``; it hands any sheet it cannot cut exactly
/// back to the raster drawing here.
public enum RasterRedactor {

    /// Resolution the marked sheets are rendered at.
    public static let defaultDPI: Double = 300

    /// How much finer a sheet that became a picture is drawn for the proof before it is averaged
    /// down to the proof's 100 dpi.
    static let pictureSupersample = 3

    public static func redact(
        source: URL,
        password: String? = nil,
        marks: [RedactionMark],
        to output: URL,
        dpi: Double = defaultDPI
    ) throws -> RedactionOutcome {
        guard !marks.isEmpty else { throw RedactionRefusal.noMarks }
        try StagedFileReplacement.refuseOverwriting([source], with: output, refusal: RedactionRefusal.outputIsSource)
        guard let document = PDFDocument(url: source) else { throw RedactionRefusal.unreadable }
        if document.isLocked {
            guard let password, document.unlock(withPassword: password), !document.isLocked else { throw RedactionRefusal.locked }
        }
        let byPage = Dictionary(grouping: marks, by: \.pageIndex)
        for (index, pageMarks) in byPage {
            guard let page = document.page(at: index) else { throw RedactionRefusal.markOutsidePage(index) }
            let media = page.bounds(for: .mediaBox)
            for mark in pageMarks where !mark.rect.intersects(media) { throw RedactionRefusal.markOutsidePage(index) }
        }

        // What stood under the boxes, to prove it gone afterwards.
        let words = Set(wordsUnderMarks(document, marks: marks))
        // An unmarked sheet that draws a picture lying under a box becomes a picture too: drawn
        // afresh it would carry the whole picture, the part under the box included (K-11).
        let pictured = RasterSharedPictures.unmarkedSheetsSharingPictures(document, marks: byPage)

        let data = NSMutableData()
        // No title and no creator: the document information carries only what Core Graphics
        // itself writes (producer and dates). The title was the output's file name, which
        // repeats the drawing's name — and so the title-block words a box is drawn over (R-098).
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil)
        else { throw RedactionRefusal.unreadable }
        let scale = dpi / 72
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let displayed = displayedSize(of: page)
            var box = CGRect(origin: .zero, size: displayed)
            context.beginPage(mediaBox: &box)
            if let pageMarks = byPage[index] {
                try drawRaster(page, marks: pageMarks, index: index, scale: scale, into: context, box: box)
            } else if pictured.contains(index) {
                try drawRaster(page, marks: [], index: index, scale: scale, into: context, box: box)
            } else {
                // `draw(with:to:)` applies the page's own transform (crop-box origin, /Rotate)
                // itself; concatenating `transform(for:)` first applied it twice (finding 14).
                context.saveGState()
                page.draw(with: .cropBox, to: context)
                context.restoreGState()
            }
            context.endPage()
        }
        context.closePDF()
        let bytes = data as Data

        let checks = try verify(bytes, source: document, marks: byPage, words: words, pictured: pictured)
        try StagedFileReplacement.write(
            to: output, protecting: [source], refusal: RedactionRefusal.outputIsSource, stagingPrefix: ".zpdf-redact-"
        ) { staging in
            try bytes.write(to: staging, options: .atomic)
        }
        return RedactionOutcome(
            redactedPages: byPage.keys.sorted(),
            markCount: marks.count,
            removedWordCount: words.count,
            checks: checks
        )
    }

    /// Draws `page` as a picture of itself with the boxes painted black, filling `box`.
    static func drawRaster(_ page: PDFPage, marks: [RedactionMark], index: Int, scale: Double, into context: CGContext, box: CGRect) throws {
        let displayed = displayedSize(of: page)
        let pixels = CGSize(width: max(1, (displayed.width * scale).rounded()), height: max(1, (displayed.height * scale).rounded()))
        guard pixels.width * pixels.height <= 400_000_000,
              let raster = CGContext(data: nil, width: Int(pixels.width), height: Int(pixels.height), bitsPerComponent: 8,
                                     bytesPerRow: Int(pixels.width) * 4, space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw RedactionRefusal.checkFailed("sheet \(index + 1) is too large to render") }
        raster.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        raster.fill(CGRect(origin: .zero, size: pixels))
        raster.scaleBy(x: pixels.width / displayed.width, y: pixels.height / displayed.height)
        raster.saveGState()
        page.draw(with: .cropBox, to: raster)
        raster.restoreGState()
        // The boxes are in page space; the page's transform places them where the drawing put
        // the page (it is applied once here, and once — inside `draw` — to the page).
        raster.concatenate(page.transform(for: .cropBox))
        raster.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        for mark in marks { raster.fill(mark.rect) }
        guard let image = raster.makeImage() else { throw RedactionRefusal.checkFailed("sheet \(index + 1) did not render") }
        context.interpolationQuality = .none
        context.draw(image, in: box)
    }

    /// One marked sheet as a single-page picture document, for a vector redaction whose sheet
    /// fell back.
    static func rasterPageDocument(_ page: PDFPage, marks: [RedactionMark], index: Int, dpi: Double) throws -> Data {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: displayedSize(of: page))
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil)
        else { throw RedactionRefusal.unreadable }
        context.beginPage(mediaBox: &box)
        try drawRaster(page, marks: marks, index: index, scale: dpi / 72, into: context, box: box)
        context.endPage()
        context.closePDF()
        return data as Data
    }

    /// The words under the boxes as PDFKit selects them, three characters or longer.
    static func wordsUnderMarks(_ document: PDFDocument, marks: [RedactionMark]) -> [String] {
        var words: [String] = []
        for mark in marks {
            guard let page = document.page(at: mark.pageIndex),
                  let text = page.selection(for: mark.rect)?.string else { continue }
            for word in text.components(separatedBy: .whitespacesAndNewlines) {
                let trimmed = word.trimmingCharacters(in: .punctuationCharacters)
                if trimmed.count >= 3 { words.append(trimmed) }
            }
        }
        return words
    }

    /// The crop box's size with `/Rotate` applied: the size the sheet is seen at.
    static func displayedSize(of page: PDFPage) -> CGSize {
        let crop = page.bounds(for: .cropBox)
        return page.rotation % 180 == 0 ? crop.size : CGSize(width: crop.height, height: crop.width)
    }

    // MARK: - The proof

    static func verify(
        _ bytes: Data, source: PDFDocument, marks: [Int: [RedactionMark]], words: Set<String>, pictured: Set<Int> = []
    ) throws -> [String] {
        guard let output = PDFDocument(data: bytes), output.pageCount == source.pageCount else {
            throw RedactionRefusal.checkFailed("the copy does not open with every sheet")
        }
        var checks: [String] = []

        // 1. No text on a marked sheet.
        for index in marks.keys {
            let text = output.page(at: index)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard text.isEmpty else { throw RedactionRefusal.checkFailed("text is still extractable on sheet \(index + 1)") }
        }
        checks.append("no text can be extracted from the redacted sheets")

        // 2. No removed word in any string the file carries — decoded, in object bodies and in
        // content-stream operands. Only where text lives: a name, an operator or the dates Core
        // Graphics writes are not text, and searching the raw bytes refused every box over
        // "Date", "Page", "Type" or "Size" (R-098). Whole words only (R-099).
        guard let scan = try? PDFDocumentScan(data: bytes) else {
            throw RedactionRefusal.checkFailed("the copy cannot be read back")
        }
        let strings = RedactionWordSearch.fileStrings(scan)
        for word in words where strings.contains(where: { RedactionWordSearch.contains(word, in: $0) }) {
            throw RedactionRefusal.checkFailed("a removed word is still in the file")
        }
        // …and none is readable on a sheet that was not marked: the same figure elsewhere in the
        // set is the same secret, and a redaction that leaves it there has not redacted it. A
        // whole word: "and" under a box is not "standard" on the next sheet (R-099).
        for index in 0..<output.pageCount {
            guard let text = output.page(at: index)?.string, !text.isEmpty else { continue }
            if let word = words.sorted().first(where: { RedactionWordSearch.contains($0, in: text) }) {
                throw RedactionRefusal.checkFailed("“\(word)” is still readable on sheet \(index + 1); mark it there as well")
            }
        }
        checks.append(words.isEmpty ? "no text stood under the boxes" : "none of the \(words.count) removed words is anywhere in the file")

        // 3. No annotations on marked sheets; no metadata, attachments or form in the file.
        for index in marks.keys where !(output.page(at: index)?.annotations.isEmpty ?? true) {
            throw RedactionRefusal.checkFailed("sheet \(index + 1) still carries annotations")
        }
        if let catalog = scan.dictionary(scan.rootReference) {
            for key in ["Metadata", "AcroForm", "Names", "AF", "OpenAction", "AA"] where catalog[key] != nil {
                throw RedactionRefusal.checkFailed("the copy carries /\(key)")
            }
        }
        checks.append("no annotations, form fields, attachments or metadata travel with the copy")

        // 4. Black inside the boxes; unchanged outside them — through PDFKit (annotations
        // included) and again through Core Graphics' own drawing transform, so a page transform
        // applied twice by one path cannot agree with itself (finding 14).
        let proofDPI = 100.0
        for (index, pageMarks) in marks {
            // The marked sheets are 300-dpi pictures: both sides are drawn three times finer and
            // averaged down, as a picture must be compared with the drawing it came from.
            guard let before = source.page(at: index), let after = output.page(at: index),
                  let a = render(before, dpi: proofDPI, supersample: pictureSupersample),
                  let b = render(after, dpi: proofDPI, supersample: pictureSupersample)
            else { throw RedactionRefusal.checkFailed("sheet \(index + 1) could not be compared") }
            let transform = pixelTransform(for: before, dpi: proofDPI, height: a.height)
            try compare(a, b, boxes: pageMarks.map { $0.rect.applying(transform).standardized }, ignoring: [],
                        delta: 48, share: 0.01, sheet: index)
            try compareCoreGraphics(before, after, boxes: pageMarks.map(\.rect), ignoring: [], delta: 48, share: 0.01, dpi: proofDPI,
                                    supersample: pictureSupersample, sheet: index)
        }
        checks.append("inside every box is black; outside them the sheets look as before")

        // 5. A picture that lay under a box is nowhere in the copy whole: not on a marked sheet,
        // and not on a sheet without a box that showed part of it — which became a picture of
        // what it shows, and must still look as it did (K-11).
        let under = RasterSharedPictures.picturesUnderBoxes(source, marks: marks)
        if !under.isEmpty {
            for index in 0..<output.pageCount {
                guard let page = output.page(at: index), RasterSharedPictures.pictures(on: page, among: under).isEmpty else {
                    throw RedactionRefusal.checkFailed("a picture that lay under a box is still whole on sheet \(index + 1)")
                }
            }
            for index in pictured.sorted() {
                guard let before = source.page(at: index), let after = output.page(at: index),
                      let a = render(before, dpi: proofDPI, supersample: pictureSupersample),
                      let b = render(after, dpi: proofDPI, supersample: pictureSupersample)
                else { throw RedactionRefusal.checkFailed("sheet \(index + 1) could not be compared") }
                try compare(a, b, boxes: [], ignoring: [], delta: 48, share: 0.01, sheet: index)
            }
            checks.append(pictured.isEmpty
                ? "no picture that lay under a box travels whole"
                : "no picture that lay under a box travels whole; "
                    + (pictured.count == 1 ? "sheet " : "sheets ") + pictured.sorted().map { String($0 + 1) }.joined(separator: ", ")
                    + " showed part of one and became a picture as well")
        }
        return checks
    }

    struct Bitmap {
        var width: Int
        var height: Int
        var pixels: [UInt8]
    }

    /// Two renders of the same sheet, in pixels: black inside every box (inset one pixel), and
    /// outside them (grown two pixels, and outside `ignoring`) at most `share` of the pixels
    /// differing by more than `delta` in any channel from every neighbour within one pixel.
    static func compare(
        _ a: Bitmap, _ b: Bitmap, boxes: [CGRect], ignoring: [CGRect], delta: Int, share: Double, sheet index: Int
    ) throws {
        guard a.width == b.width, a.height == b.height else { throw RedactionRefusal.checkFailed("sheet \(index + 1) could not be compared") }
        var outside = 0, differing = 0
        for y in 0..<a.height {
            for x in 0..<a.width {
                let point = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)
                let offset = (y * a.width + x) * 4
                if boxes.contains(where: { $0.insetBy(dx: 1, dy: 1).contains(point) }) {
                    let luminance = (Int(b.pixels[offset]) + Int(b.pixels[offset + 1]) + Int(b.pixels[offset + 2])) / 3
                    guard luminance < 40 else { throw RedactionRefusal.checkFailed("a box on sheet \(index + 1) is not solid black") }
                    continue
                }
                if boxes.contains(where: { $0.insetBy(dx: -2, dy: -2).contains(point) }) { continue }
                if ignoring.contains(where: { $0.contains(point) }) { continue }
                outside += 1
                // A vector edge and the same edge resampled from 300 dpi can land a pixel apart; a
                // pixel differs only when no neighbour within one pixel matches it.
                var matched = false
                search: for dy in -1...1 {
                    for dx in -1...1 {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, ny >= 0, nx < b.width, ny < b.height else { continue }
                        let other = (ny * b.width + nx) * 4
                        let difference = max(abs(Int(a.pixels[offset]) - Int(b.pixels[other])),
                                             abs(Int(a.pixels[offset + 1]) - Int(b.pixels[other + 1])),
                                             abs(Int(a.pixels[offset + 2]) - Int(b.pixels[other + 2])))
                        if difference <= delta { matched = true; break search }
                    }
                }
                if !matched { differing += 1 }
            }
        }
        guard outside == 0 || Double(differing) / Double(outside) <= share else {
            throw RedactionRefusal.checkFailed("sheet \(index + 1) changed outside the boxes")
        }
    }

    /// The sheet drawn by Core Graphics itself — its own drawing transform, not PDFKit's, and
    /// no annotations — top row first, with the map from page space into that grid.
    static func renderCoreGraphics(_ page: PDFPage, dpi: Double, supersample: Int = 1) -> (bitmap: Bitmap, transform: CGAffineTransform)? {
        guard let cgPage = page.pageRef else { return nil }
        let crop = cgPage.getBoxRect(.cropBox)
        guard crop.width > 0, crop.height > 0 else { return nil }
        let displayed = cgPage.rotationAngle % 180 == 0 ? crop.size : CGSize(width: crop.height, height: crop.width)
        // Asked for the displayed size itself, the drawing transform only rotates and moves the
        // crop box to the origin; the scale to pixels is applied by the renderer.
        let drawing = cgPage.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: displayed), rotate: 0, preserveAspectRatio: true)
        guard let bitmap = renderBanded(size: displayed, dpi: dpi, supersample: supersample, draw: { context in
            context.concatenate(drawing)
            context.clip(to: crop)
            context.drawPDFPage(cgPage)
        }) else { return nil }
        let transform = drawing
            .concatenating(CGAffineTransform(scaleX: CGFloat(bitmap.width) / displayed.width, y: CGFloat(bitmap.height) / displayed.height))
            .concatenating(CGAffineTransform(scaleX: 1, y: -1))
            .concatenating(CGAffineTransform(translationX: 0, y: CGFloat(bitmap.height)))
        return (bitmap, transform)
    }

    /// The same proof through Core Graphics' renders. Core Graphics draws no annotations, so the
    /// source's annotation rectangles are left out of the comparison (phase 1 burns their
    /// appearances into its pictures).
    static func compareCoreGraphics(
        _ before: PDFPage, _ after: PDFPage, boxes: [CGRect], ignoring: [CGRect], delta: Int, share: Double, dpi: Double,
        supersample: Int = 1, sheet index: Int
    ) throws {
        guard let a = renderCoreGraphics(before, dpi: dpi, supersample: supersample),
              let b = renderCoreGraphics(after, dpi: dpi, supersample: supersample) else {
            throw RedactionRefusal.checkFailed("sheet \(index + 1) could not be compared")
        }
        let annotations = before.annotations.map { $0.bounds.applying(a.transform).standardized.insetBy(dx: -3, dy: -3) }
        try compare(a.bitmap, b.bitmap, boxes: boxes.map { $0.applying(a.transform).standardized },
                    ignoring: annotations + ignoring.map { $0.applying(a.transform).standardized }, delta: delta, share: share, sheet: index)
    }

    /// The page drawn as it is seen, top row first.
    ///
    /// `supersample` > 1 draws it that many times finer and averages each block of pixels down:
    /// how a sheet that became a 300-dpi picture must be compared with the drawing it came from.
    /// A renderer point-samples a picture it shrinks while it area-averages vector edges, and on
    /// a sheet dense with 2-pt lines that alone differs by more than phase 1's allowance.
    static func render(_ page: PDFPage, dpi: Double, supersample: Int = 1) -> Bitmap? {
        renderBanded(size: displayedSize(of: page), dpi: dpi, supersample: supersample) { context in
            page.draw(with: .cropBox, to: context)
        }
    }

    /// Draws a sheet of `size` points at `dpi`, `supersample` times finer in bands of at most
    /// about 64 MB, and averages each `supersample`² block into one pixel. `draw` paints the sheet
    /// in its displayed coordinates (origin bottom left, points).
    static func renderBanded(size: CGSize, dpi: Double, supersample: Int, draw: (CGContext) -> Void) -> Bitmap? {
        let width = max(1, Int((size.width * dpi / 72).rounded())), height = max(1, Int((size.height * dpi / 72).rounded()))
        let factor = max(1, supersample)
        let fineWidth = width * factor, fineHeight = height * factor
        let rowsPerBand = max(1, min(height, 64 * 1024 * 1024 / max(1, fineWidth * 4 * factor)))
        var out = [UInt8](repeating: 255, count: width * height * 4)
        var band = [UInt8](repeating: 255, count: fineWidth * rowsPerBand * factor * 4)
        var bandStart = 0
        while bandStart < height {
            let rows = min(rowsPerBand, height - bandStart)
            let fineRows = rows * factor
            let drawn: Bool = band.withUnsafeMutableBytes { buffer in
                guard let context = CGContext(data: buffer.baseAddress, width: fineWidth, height: fineRows, bitsPerComponent: 8,
                                              bytesPerRow: fineWidth * 4, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
                else { return false }
                context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: fineWidth, height: fineRows))
                // The band holds fine rows [bandStart·f, (bandStart + rows)·f) counted from the top.
                context.translateBy(x: 0, y: -CGFloat(fineHeight - (bandStart + rows) * factor))
                context.scaleBy(x: CGFloat(fineWidth) / size.width, y: CGFloat(fineHeight) / size.height)
                draw(context)
                return true
            }
            guard drawn else { return nil }
            let area = factor * factor
            for row in 0..<rows {
                for column in 0..<width {
                    var sums = (0, 0, 0)
                    for dy in 0..<factor {
                        let base = ((row * factor + dy) * fineWidth + column * factor) * 4
                        for dx in 0..<factor {
                            let offset = base + dx * 4
                            sums.0 += Int(band[offset]); sums.1 += Int(band[offset + 1]); sums.2 += Int(band[offset + 2])
                        }
                    }
                    let target = ((bandStart + row) * width + column) * 4
                    out[target] = UInt8(sums.0 / area); out[target + 1] = UInt8(sums.1 / area); out[target + 2] = UInt8(sums.2 / area)
                }
            }
            bandStart += rows
        }
        return Bitmap(width: width, height: height, pixels: out)
    }

    /// Page space → the top-row-first pixel grid of ``render(_:dpi:)``.
    static func pixelTransform(for page: PDFPage, dpi: Double, height: Int) -> CGAffineTransform {
        let size = displayedSize(of: page)
        let scaleX = (size.width * dpi / 72).rounded() / size.width
        let scaleY = (size.height * dpi / 72).rounded() / size.height
        return page.transform(for: .cropBox)
            .concatenating(CGAffineTransform(scaleX: scaleX, y: scaleY))
            .concatenating(CGAffineTransform(scaleX: 1, y: -1))
            .concatenating(CGAffineTransform(translationX: 0, y: CGFloat(height)))
    }
}

extension RedactionRefusal: LocalizedError {
    public var errorDescription: String? { description }
}
