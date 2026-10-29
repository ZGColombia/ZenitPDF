import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing
@testable import ZPDFExport

/// Regression tests for the leaks found in the vector redaction (findings 1–19)
/// (NL-PDF-14 phase 2, ADR-0033). Each test rebuilds the leaking fixture and proves the
/// secret is gone from the file — not merely hidden — and, where a construct cannot be cut
/// exactly, that the sheet became a picture and said why.
///
/// The old behaviour is stated on each test: every one of them failed on the code before
/// r2-redaction-fix.
@Suite("Redaction hardening (r2-redaction-fix)", .sharedHeap, .serialized)
struct NLPDFR2RedactionHardeningTests {

    static func write(_ data: Data, to folder: URL, _ name: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func redact(_ data: Data, _ name: String, boxes: [CGRect], page: Int = 0) throws -> (source: URL, output: URL, outcome: RedactionOutcome, folder: URL) {
        let folder = try RedactionProof.folder()
        let source = try Self.write(data, to: folder, name + ".pdf")
        let output = folder.appendingPathComponent(name + " redacted.pdf")
        let outcome = try VectorRedactor.redact(source: source, marks: boxes.map { RedactionMark(pageIndex: page, rect: $0) }, to: output)
        RedactionProof.keep(output, as: name + ".pdf")
        return (source, output, outcome, folder)
    }

    // MARK: - Finding 1: text inside a tiling pattern

    /// Old: the pattern object was copied unchanged; “FALCON SALARY 98000” was in the output word
    /// for word and no check noticed.
    @Test("Finding 1 — text in a tiling pattern cell under the box is not in the file")
    func tilingPatternText() throws {
        let run = try redact(HardeningFixtures.tilingPatternText(), "tiling-text", boxes: [CGRect(x: 90, y: 690, width: 240, height: 40)])
        defer { try? FileManager.default.removeItem(at: run.folder) }
        let bytes = try RedactionProof.decompressed(run.output)
        for secret in ["FALCON", "SALARY", "98000"] {
            #expect(bytes.range(of: Data(secret.utf8)) == nil, "\(secret) is not in the file")
        }
        #expect(PDFDocument(url: run.output)?.page(at: 0)?.string?.contains("Public paragraph text.") == true)
        #expect(try RedactionProof.readbackViolations(run.output, page: 0, boxes: [CGRect(x: 90, y: 690, width: 240, height: 40)]).isEmpty)
    }

    /// Old: redact returned OK with the sheet vector and the pattern cell whole — the hex text and
    /// every picture sample under the boxes were still in the copy.
    @Test("Finding 15 — one tile over the whole sheet: the cell is cut for that tile, hex text and picture samples under the boxes go")
    func wholeSheetPattern() throws {
        let boxes = [CGRect(x: 90, y: 490, width: 200, height: 30), CGRect(x: 300, y: 100, width: 100, height: 40)]
        let run = try redact(HardeningFixtures.wholeSheetPattern(), "whole-sheet-pattern", boxes: boxes)
        defer { try? FileManager.default.removeItem(at: run.folder) }
        #expect(run.outcome.vectorPages == [0], "a single tile is cut exactly: \(run.outcome.rasterFallbacks)")
        let bytes = try RedactionProof.decompressed(run.output)
        for secret in ["PATSECRET", HardeningFixtures.hex("PATSECRET"), "PATTERNIMA"] {
            #expect(bytes.range(of: Data(secret.utf8)) == nil, "\(secret) is not in the file")
        }
        #expect(bytes.range(of: Data("GESECRET".utf8)) != nil, "the picture's samples outside the box are kept")
        #expect(bytes.range(of: Data("VISIBLE CELL TEXT".utf8)) != nil, "the cell's text outside the boxes is kept")
        #expect(try RedactionProof.readbackViolations(run.output, page: 0, boxes: boxes).isEmpty)
        #expect(try RedactionProof.changedShareOutside(source: run.source, output: run.output, page: 0, boxes: boxes) <= 0.002)
    }

    // MARK: - Finding 5: picture fill

    /// Old: the cell stream was kept verbatim (the red line across the box) and the picture whole —
    /// 400 of 400 samples under the box identical to the original.
    @Test("Finding 5 — a single-cell picture fill: the cell's picture is blanked and its line cut under the box, the original is not in the file")
    func pictureFill() throws {
        let box = CGRect(x: 200, y: 300, width: 200, height: 200)
        let run = try redact(HardeningFixtures.pictureFillPattern(), "picture-fill", boxes: [box])
        defer { try? FileManager.default.removeItem(at: run.folder) }
        #expect(run.outcome.vectorPages == [0], "\(run.outcome.rasterFallbacks)")
        let images = try HardeningProof.decodedImages(run.output)
        let original = HardeningFixtures.pictureFillSamples
        #expect(!images.contains(original), "the original picture is not in the file")
        let copy = try #require(images.first { $0.count == original.count })
        // 10 pt a sample in pattern space from (100, 200); the box covers columns and rows 10…29.
        var blanked = 0, kept = 0
        for row in 0..<40 {
            for column in 0..<40 {
                let offset = (row * 40 + column) * 3
                if (10...29).contains(row), (10...29).contains(column) {
                    if copy[offset..<(offset + 3)].allSatisfy({ $0 == 0 }) { blanked += 1 }
                } else if Array(copy[offset..<(offset + 3)]) == Array(original[offset..<(offset + 3)]) {
                    kept += 1
                }
            }
        }
        #expect(blanked == 400)
        #expect(kept == 1600 - 400)
        let bytes = try RedactionProof.decompressed(run.output)
        #expect(bytes.range(of: Data("50 200 m 350 200 l".utf8)) == nil, "the line across the box is cut")
        #expect(try RedactionProof.readbackViolations(run.output, page: 0, boxes: [box]).isEmpty)
        #expect(try RedactionProof.changedShareOutside(source: run.source, output: run.output, page: 0, boxes: [box], ignoring: [box.insetBy(dx: -12, dy: -12)]) <= 0.002)
    }

    /// Old: a repeating cell was kept whole as well; now the sheet becomes a picture and says why.
    @Test("Finding 5 — a repeating pattern painted across a box cannot be cut exactly: the sheet becomes a picture and says why")
    func repeatingPatternFallsBack() throws {
        let box = CGRect(x: 200, y: 300, width: 200, height: 200)
        let run = try redact(HardeningFixtures.pictureFillPattern(step: 100), "repeating-pattern", boxes: [box])
        defer { try? FileManager.default.removeItem(at: run.folder) }
        #expect(run.outcome.vectorPages.isEmpty)
        #expect(run.outcome.rasterFallbacks.first?.reason.contains("repeat") == true, "\(run.outcome.rasterFallbacks)")
        #expect(!(try HardeningProof.decodedImages(run.output)).contains(HardeningFixtures.pictureFillSamples))
    }

    // MARK: - Finding 6: smooth shadings

    /// Old: the shading and its 768 function samples were copied unchanged.
    @Test("Finding 6 — a sampled-function shading painted only under the box is removed with its samples")
    func sampledShading() throws {
        let box = CGRect(x: 200, y: 300, width: 200, height: 200)
        let run = try redact(HardeningFixtures.sampledShading(), "sampled-shading", boxes: [box])
        defer { try? FileManager.default.removeItem(at: run.folder) }
        #expect(run.outcome.vectorPages == [0])
        let bytes = try RedactionProof.decompressed(run.output)
        #expect(!HardeningProof.contains(bytes, Array(HardeningFixtures.sampledFunction.prefix(96))), "the function samples are not in the file")
        #expect(PDFDocument(url: run.output)?.page(at: 0)?.string?.contains("Caption outside") == true)
        #expect(try RedactionProof.readbackViolations(run.output, page: 0, boxes: [box]).isEmpty)
    }

    /// Old: the axial pattern and its stitching function (orange band only under the box) stayed.
    @Test("Finding 6 — a shading pattern painted partly under the box: the sheet becomes a picture, the orange band's function is not in the file")
    func axialShadingPattern() throws {
        let box = CGRect(x: 245, y: 40, width: 110, height: 120)
        let run = try redact(HardeningFixtures.axialShadingPattern(), "axial-shading", boxes: [box])
        defer { try? FileManager.default.removeItem(at: run.folder) }
        #expect(run.outcome.vectorPages.isEmpty)
        #expect(run.outcome.rasterFallbacks.first?.reason.contains("shading") == true, "\(run.outcome.rasterFallbacks)")
        let bytes = try RedactionProof.decompressed(run.output)
        #expect(bytes.range(of: Data("/C0 [1 0.5 0]".utf8)) == nil)
    }

    // MARK: - Finding 7: mesh through a pattern

    /// Old: assess said vectorQualifies=true and the mesh with its three vertices stayed in the copy.
    @Test("Finding 7 — a mesh shading used through a pattern falls back like one painted with sh")
    func meshThroughPattern() throws {
        let box = CGRect(x: 200, y: 300, width: 200, height: 200)
        let folder = try RedactionProof.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try Self.write(HardeningFixtures.meshPattern(), to: folder, "mesh.pdf")
        let marks = [RedactionMark(pageIndex: 0, rect: box)]
        let assessment = VectorRedactor.assess(source: source, marks: marks)
        #expect(!assessment.vectorQualifies)
        #expect(assessment.fallbacks.first?.reason.contains("mesh") == true, "\(assessment.fallbacks)")
        let output = folder.appendingPathComponent("mesh redacted.pdf")
        let outcome = try VectorRedactor.redact(source: source, marks: marks, to: output)
        #expect(outcome.vectorPages.isEmpty)
        #expect(!HardeningProof.contains(try RedactionProof.decompressed(output), HardeningFixtures.meshData))
    }

    // MARK: - Finding 4: shared resource dictionaries

    /// Old: in each case the copy was written with all checks passing and the secret image's 3072
    /// decoded bytes identical to the original.
    @Test("Finding 4 — a resource dictionary shared with another sheet, the page tree, a kept form or a fallback sheet does not carry the image under the box",
          arguments: [HardeningFixtures.SharedCase.twoSheets, .inheritedFromTree, .formOnOneSheet, .fallbackSheet])
    func sharedResources(_ variant: HardeningFixtures.SharedCase) throws {
        let box = CGRect(x: 190, y: 290, width: 220, height: 220)
        let run = try redact(HardeningFixtures.sharedResources(variant), "shared-\(variant)", boxes: [box])
        defer { try? FileManager.default.removeItem(at: run.folder) }
        if variant == .fallbackSheet {
            #expect(run.outcome.rasterFallbacks.first?.reason.contains("width table") == true)
        } else {
            #expect(run.outcome.vectorPages == [0])
        }
        #expect(!(try HardeningProof.decodedImages(run.output)).contains(HardeningFixtures.secretImage), "the secret image is not in the file")
        #expect(!HardeningProof.contains(try RedactionProof.decompressed(run.output), Array(HardeningFixtures.secretImage.prefix(96))))
        if variant != .formOnOneSheet {
            #expect((try HardeningProof.decodedImages(run.output)).contains(HardeningFixtures.publicImage), "the other sheet keeps its own picture")
        }
    }

    // MARK: - Finding 8: shared image or form drawn again, cropped

    /// Old: the complete original (3072 bytes) was kept for the cropped placement.
    @Test("Finding 8 — an image drawn under the box and again cropped elsewhere: the cropped placement gets a copy holding only what it shows")
    func croppedImage() throws {
        let box = CGRect(x: 190, y: 290, width: 220, height: 220)
        let run = try redact(HardeningFixtures.croppedImageFixture(), "cropped-image", boxes: [box])
        defer { try? FileManager.default.removeItem(at: run.folder) }
        #expect(run.outcome.vectorPages == [0])
        let images = try HardeningProof.decodedImages(run.output)
        let original = HardeningFixtures.croppedImage
        #expect(!images.contains(original), "the original is not in the file")
        let copy = try #require(images.first { $0.count == original.count })
        // Placed on (50…250)², 6.25 pt a sample, clipped to (50…150)²: columns 0…15, rows 16…31 show.
        for row in 0..<32 {
            for column in 0..<32 {
                let offset = (row * 32 + column) * 3
                let shown = column <= 15 && row >= 16
                let sample = Array(copy[offset..<(offset + 3)])
                #expect(shown ? sample == Array(original[offset..<(offset + 3)]) : sample == [0, 0, 0], "sample \(column),\(row)")
            }
        }
        #expect(try RedactionProof.changedShareOutside(source: run.source, output: run.output, page: 0, boxes: [box]) <= 0.002)
    }

    /// Old: viewport A's copy lost the X, but the original (kept for viewport B) still held it.
    @Test("Finding 8 — model space through two viewports: the X seen only under the box is in no copy of the form")
    func viewports() throws {
        let box = CGRect(x: 185, y: 285, width: 190, height: 190)
        let run = try redact(HardeningFixtures.viewportFixture(), "viewports", boxes: [box])
        defer { try? FileManager.default.removeItem(at: run.folder) }
        #expect(run.outcome.vectorPages == [0])
        let bytes = try RedactionProof.decompressed(run.output)
        #expect(bytes.range(of: Data("20 20 m 180 180 l".utf8)) == nil && bytes.range(of: Data("20 180 m 180 20 l".utf8)) == nil, "the X is gone")
        #expect(bytes.range(of: Data("380 200 l".utf8)) != nil, "viewport B keeps its blue line")
        #expect(try RedactionProof.readbackViolations(run.output, page: 0, boxes: [box]).isEmpty)
        #expect(try RedactionProof.changedShareOutside(source: run.source, output: run.output, page: 0, boxes: [box]) <= 0.002)
    }

    // MARK: - Finding 9: Type 3 glyph procedure

    /// Old: the content became `[-1000] TJ` but /sig (inline image and signature stroke) stayed in
    /// the font.
    @Test("Finding 9 — a Type 3 glyph drawn only under the box loses its glyph procedure")
    func type3Signature() throws {
        let box = CGRect(x: 240, y: 340, width: 120, height: 120)
        let run = try redact(HardeningFixtures.type3Signature(), "type3-signature", boxes: [box])
        defer { try? FileManager.default.removeItem(at: run.folder) }
        #expect(run.outcome.vectorPages == [0])
        let bytes = try RedactionProof.decompressed(run.output)
        #expect(bytes.range(of: Data("300 900 l 500 100 l".utf8)) == nil, "the signature stroke is not in the file")
        #expect(!HardeningProof.contains(bytes, HardeningFixtures.signatureImage), "nor its inline image")
        let scan = try PDFDocumentScan(data: try Data(contentsOf: run.output))
        let font = try HardeningProof.firstFont(scan, page: 0)
        let procs = try #require(scan.dictionary(font["CharProcs"]))
        #expect(Set(procs.keys) == ["a"], "\(procs.keys.sorted())")
        #expect(try RedactionProof.changedShareOutside(source: run.source, output: run.output, page: 0, boxes: [box]) <= 0.002)
    }

    // MARK: - Findings 10 and 17: associated files and attachments

    /// Old: the typed attachment made the verifier refuse the whole copy; with the untyped ones
    /// the copy was written carrying /AF, the original samples and both attachment payloads.
    @Test("Findings 10 and 17 — /AF, embedded files and file-attachment notes do not travel, typed or not, and do not refuse the copy")
    func attachments() throws {
        let box = CGRect(x: 260, y: 460, width: 120, height: 120)
        let run = try redact(HardeningFixtures.attachments(), "attachments", boxes: [box])
        defer { try? FileManager.default.removeItem(at: run.folder) }
        #expect(run.outcome.vectorPages == [0])
        let bytes = try RedactionProof.decompressed(run.output)
        for secret in ["ASSOCIATEDFILEDATA", "ATTACHEDSECRETDATA", "TYPEDATTACHMENTDATA", "/AF", "/EF", "orig.raw"] {
            #expect(bytes.range(of: Data(secret.utf8)) == nil, "\(secret) does not travel")
        }
        #expect(!(try HardeningProof.decodedImages(run.output)).contains(HardeningFixtures.associatedSamples), "the original samples are not in the file")
        #expect(PDFDocument(url: run.output)?.page(at: 0)?.annotations.isEmpty == true)
    }

    // MARK: - Finding 13: PostScript alternate

    /// Old: the rewritten form kept /PS; the PostScript stream with the line was in the copy.
    @Test("Finding 13 — a form's PostScript alternate does not travel")
    func postScriptAlternate() throws {
        let box = CGRect(x: 200, y: 300, width: 200, height: 200)
        let run = try redact(HardeningFixtures.postScriptAlternate(), "postscript", boxes: [box])
        defer { try? FileManager.default.removeItem(at: run.folder) }
        let bytes = try RedactionProof.decompressed(run.output)
        #expect(bytes.range(of: Data("secret linework".utf8)) == nil)
        #expect(bytes.range(of: Data("/Subtype2".utf8)) == nil)
    }

    // MARK: - Findings 11 and 12: revisions

    /// Old: the scan never read free entries, so the deleted picture came back byte for byte.
    @Test("Finding 11 — an object freed by an incremental update stays gone")
    func freedObject() throws {
        let box = CGRect(x: 60, y: 690, width: 300, height: 40)
        let run = try redact(HardeningFixtures.freedObject(), "freed", boxes: [box])
        defer { try? FileManager.default.removeItem(at: run.folder) }
        #expect(!(try HardeningProof.decodedImages(run.output)).contains(HardeningFixtures.secretImage))
        #expect(PDFDocument(url: run.output)?.page(at: 1)?.string?.contains("Sheet two") == true)
    }

    /// Old: the cross-reference stream's /Root overrode the later classic trailer; the copy showed
    /// revision 1's sheet 2 with the photo.
    @Test("Finding 12 — the latest trailer names the catalog, whichever kind of cross-reference section it is in")
    func latestTrailerWins() throws {
        let box = CGRect(x: 60, y: 690, width: 300, height: 40)
        let data = HardeningFixtures.mixedCrossReferenceChain()
        #expect(PDFDocument(data: data)?.page(at: 1)?.string?.contains("Revision two sheet") == true, "PDFKit shows revision 2")
        let scan = try PDFDocumentScan(data: data)
        #expect(scan.rootReference?.referenceValue?.number == 20)
        let run = try redact(data, "mixed-chain", boxes: [box])
        defer { try? FileManager.default.removeItem(at: run.folder) }
        #expect(PDFDocument(url: run.output)?.page(at: 1)?.string?.contains("Revision two sheet") == true)
        #expect(!(try HardeningProof.decodedImages(run.output)).contains(HardeningFixtures.photo))
    }

    // MARK: - Finding 2: hidden widget

    /// Old: widget 1 went, but the field survived through the hidden widget with /V (FALCON-7731).
    @Test("Finding 2 — a field value visible only under the box goes with every widget of the field, hidden ones included")
    func hiddenWidget() throws {
        let box = CGRect(x: 90, y: 690, width: 240, height: 40)
        let run = try redact(HardeningFixtures.hiddenWidget(), "hidden-widget", boxes: [box])
        defer { try? FileManager.default.removeItem(at: run.folder) }
        let bytes = try RedactionProof.decompressed(run.output)
        #expect(bytes.range(of: Data("FALCON".utf8)) == nil)
        let after = try #require(PDFDocument(url: run.output))
        #expect(!(after.page(at: 0)?.annotations ?? []).contains { $0.widgetStringValue?.contains("FALCON") == true })
        #expect(after.page(at: 0)?.string?.contains("Form sheet") == true)
    }

    // MARK: - Finding 3: bookmarks

    /// Old: “Project Falcon” (/XYZ null 724 null, title in another case) and “Heading again”
    /// (/FitH 720) were both kept.
    @Test("Finding 3 — a bookmark into the box goes when its left is null or it is a /FitH, and a title matching a removed word in any case goes")
    func bookmarks() throws {
        let box = CGRect(x: 90, y: 690, width: 340, height: 40)
        let run = try redact(HardeningFixtures.bookmarks(), "bookmarks", boxes: [box])
        defer { try? FileManager.default.removeItem(at: run.folder) }
        let after = try #require(PDFDocument(url: run.output))
        let labels = (0..<(after.outlineRoot?.numberOfChildren ?? 0)).compactMap { after.outlineRoot?.child(at: $0)?.label }
        #expect(labels == ["Body", "Other"], "\(labels)")
        let bytes = try RedactionProof.decompressed(run.output)
        #expect(bytes.range(of: Data("Falcon".utf8)) == nil && bytes.range(of: Data("FALCON".utf8)) == nil)
    }

    // MARK: - Finding 18: hex strings

    /// Old: the note written as a hex string travelled with the copy (redact returned OK); the
    /// same note as a literal string was refused.
    @Test("Finding 18 — a removed word repeated in a hex-encoded note is found and the copy refused, as for a literal string")
    func hexNote() throws {
        let folder = try RedactionProof.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try Self.write(HardeningFixtures.hexNote(), to: folder, "hex-note.pdf")
        let output = folder.appendingPathComponent("hex-note redacted.pdf")
        #expect(throws: RedactionRefusal.checkFailed("a removed word is still in the file")) {
            try VectorRedactor.redact(source: source, marks: [RedactionMark(pageIndex: 0, rect: NLPDFR2RedactionTests.secretRect)], to: output)
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    // MARK: - Findings 14 and 16: rotated and cropped sheets

    struct SheetGeometry: CustomTestStringConvertible, Sendable {
        var rotate: Int
        var crop: String?
        var testDescription: String { "rotate \(rotate)" + (crop.map { " crop \($0)" } ?? "") }
    }

    static let geometries = [
        SheetGeometry(rotate: 90, crop: nil), SheetGeometry(rotate: 180, crop: nil),
        SheetGeometry(rotate: 270, crop: nil), SheetGeometry(rotate: 0, crop: "[30 20 410 290]"),
        SheetGeometry(rotate: 90, crop: "[30 20 410 290]")
    ]

    /// Renders source and copy through Core Graphics' own drawing transform and proves the box
    /// covers the secret: black inside, and outside it as much ink as the source had.
    func expectCovered(source: URL, output: URL, _ label: String) throws {
        let before = try HardeningProof.coreGraphicsRender(source, page: 0)
        let after = try HardeningProof.coreGraphicsRender(output, page: 0)
        #expect(before.bitmap.width == after.bitmap.width && before.bitmap.height == after.bitmap.height, "\(label): same displayed size")
        let mark = HardeningFixtures.rotatedMark.applying(before.transform).standardized
        #expect(HardeningProof.brightestMean(after.bitmap, inside: mark.insetBy(dx: 2, dy: 2)) < 60, "\(label): the box is black where the secret was")
        let excluded = mark.insetBy(dx: -3, dy: -3)
        let inkBefore = HardeningProof.darkPixels(before.bitmap, outside: excluded)
        let inkAfter = HardeningProof.darkPixels(after.bitmap, outside: excluded)
        #expect(abs(inkBefore - inkAfter) <= max(20, inkBefore / 20), "\(label): outside the box the sheet carries the same ink (\(inkBefore) → \(inkAfter)); more means the secret moved out from under the box")
    }

    /// Old: RasterRedactor returned OK with its four checks and the bid figure fully readable beside
    /// the black box (dark pixels outside the mark 598 → 1297 on the cropped sheet).
    @Test("Finding 14 — phase 1 on a rotated or cropped sheet: the box covers the secret", arguments: NLPDFR2RedactionHardeningTests.geometries)
    func rasterRotated(_ geometry: SheetGeometry) throws {
        let folder = try RedactionProof.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try Self.write(HardeningFixtures.rotatedSheet(rotate: geometry.rotate, crop: geometry.crop, standardFont: true), to: folder, "rotated.pdf")
        let output = folder.appendingPathComponent("rotated raster.pdf")
        _ = try RasterRedactor.redact(source: source, marks: [RedactionMark(pageIndex: 0, rect: HardeningFixtures.rotatedMark)], to: output)
        try expectCovered(source: source, output: output, geometry.testDescription)
        let text = PDFDocument(url: output)?.page(at: 0)?.string ?? ""
        #expect(!text.contains("4820000"))
    }

    /// Old: the vector path was always refused (“a box on sheet 1 is not solid black”) on these
    /// sheets, and its per-sheet fallback leaked like phase 1.
    @Test("Finding 16 — vector redaction of a rotated or cropped sheet is accepted and covers the secret; so is its raster fallback", arguments: NLPDFR2RedactionHardeningTests.geometries)
    func vectorRotated(_ geometry: SheetGeometry) throws {
        for standardFont in [false, true] {
            let folder = try RedactionProof.folder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let source = try Self.write(HardeningFixtures.rotatedSheet(rotate: geometry.rotate, crop: geometry.crop, standardFont: standardFont), to: folder, "rotated.pdf")
            let output = folder.appendingPathComponent("rotated vector.pdf")
            let marks = [RedactionMark(pageIndex: 0, rect: HardeningFixtures.rotatedMark)]
            let outcome = try VectorRedactor.redact(source: source, marks: marks, to: output)
            #expect(outcome.vectorPages == (standardFont ? [] : [0]), "\(geometry.testDescription)")
            try expectCovered(source: source, output: output, geometry.testDescription + (standardFont ? " fallback" : " vector"))
            let text = PDFDocument(url: output)?.page(at: 0)?.string ?? ""
            #expect(!text.contains("4820000"))
            if !standardFont { #expect(text.contains("Tender summary"), "the rest of the sheet stays searchable") }
        }
    }

    // MARK: - Finding 19: fonts

    /// Old: the Helvetica subset kept non-zero widths, ToUnicode entries and glyph outlines for
    /// Q X Z J K 4 8 2 0 — characters that stood only in the removed text.
    @Test("Finding 19 — a font keeps widths, Unicode entries and glyph outlines only for the characters still shown")
    func fontsKeepOnlyShownCharacters() throws {
        let folder = try RedactionProof.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("fonts.pdf"), output = folder.appendingPathComponent("fonts redacted.pdf")
        try HardeningFixtures.coreTextFonts(at: source)
        let box = CGRect(x: 60, y: 140, width: 180, height: 32)
        let outcome = try VectorRedactor.redact(source: source, marks: [RedactionMark(pageIndex: 0, rect: box)], to: output)
        RedactionProof.keep(output, as: "fonts.pdf")
        #expect(outcome.vectorPages == [0])
        #expect(PDFDocument(url: output)?.page(at: 0)?.string?.contains("tender summary") == true)

        let shown = Set("tender summary".unicodeScalars.map { Int($0.value) })
        let removedOnly = Set("QXZJK4820".unicodeScalars.map { Int($0.value) })
        let scan = try PDFDocumentScan(data: try Data(contentsOf: output))
        let font = try HardeningProof.firstFont(scan, page: 0)
        let first = try #require(scan.object(font["FirstChar"])?.integerValue)
        let widths = try #require(scan.object(font["Widths"])?.arrayValue).map { scan.object($0)?.doubleValue ?? 0 }
        for (offset, width) in widths.enumerated() where width != 0 {
            #expect(shown.contains(first + offset), "code \(first + offset) keeps width \(width)")
        }
        if case let .stream(dictionary, data)? = scan.object(font["ToUnicode"]) {
            let map = try RedactionCMap(try RedactionStreamFilters.decode(dictionary: dictionary, data: data).data)
            for code in removedOnly {
                #expect(map.unicode(for: RedactionFont.Code(value: UInt32(code), length: 1)) == nil, "no Unicode entry for code \(code)")
            }
        }
        func outlines(_ url: URL) throws -> Int {
            let scan = try PDFDocumentScan(data: try Data(contentsOf: url))
            let font = try HardeningProof.firstFont(scan, page: 0)
            let descriptor = try #require(scan.dictionary(font["FontDescriptor"]))
            let program = try RedactionStreamFilters.decodeFully(scan.object(descriptor["FontFile2"]))
            let provider = try #require(CGDataProvider(data: program as CFData))
            let cgFont = try #require(CGFont(provider))
            let ctFont = CTFontCreateWithGraphicsFont(cgFont, 12, nil, nil)
            return (0..<cgFont.numberOfGlyphs).filter { gid in
                guard let path = CTFontCreatePathForGlyph(ctFont, CGGlyph(gid), nil) else { return false }
                return !path.isEmpty
            }.count
        }
        let before = try outlines(source), after = try outlines(output)
        // “tender summary” draws ten distinct glyphs; .notdef may carry an outline too.
        #expect(after <= 11, "outlines left: \(after)")
        #expect(before >= after + 9, "the nine removed-only glyphs lost their outlines (\(before) → \(after))")
        #expect(try RedactionProof.changedShareOutside(source: source, output: output, page: 0, boxes: [box]) <= 0.001)
    }

    /// Old: the CFF program kept every charstring, subroutine and charset name — Q X Z J K 4 8 2 0
    /// among them — although those glyphs stood only under the box.
    @Test("Finding 19 — a CFF program (simple and CID-keyed) keeps charstrings, subroutines and charset entries only for the glyphs still shown",
          arguments: ["KohinoorBangla-Regular", "HiraginoSans-W3"])
    func cffPrograms(_ fontName: String) throws {
        let folder = try RedactionProof.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("cff.pdf"), output = folder.appendingPathComponent("cff redacted.pdf")
        try HardeningFixtures.coreTextFonts(at: source, fontName: fontName)
        let box = CGRect(x: 60, y: 140, width: 200, height: 34)
        let outcome = try VectorRedactor.redact(source: source, marks: [RedactionMark(pageIndex: 0, rect: box)], to: output)
        RedactionProof.keep(output, as: "cff-\(fontName).pdf")
        #expect(outcome.vectorPages == [0])
        #expect(PDFDocument(url: output)?.page(at: 0)?.string?.contains("tender summary") == true)
        func program(_ url: URL) throws -> RedactionCFF.Font {
            let scan = try PDFDocumentScan(data: try Data(contentsOf: url))
            let font = try HardeningProof.firstFont(scan, page: 0)
            var descriptor = scan.dictionary(font["FontDescriptor"])
            if descriptor == nil, let descendant = scan.object(font["DescendantFonts"])?.arrayValue?.first {
                descriptor = scan.dictionary(scan.dictionary(descendant)?["FontDescriptor"])
            }
            let data = try RedactionStreamFilters.decodeFully(scan.object(try #require(descriptor)["FontFile3"]))
            return try RedactionCFF.parse([UInt8](data))
        }
        let before = try program(source), after = try program(output)
        let liveBefore = before.charStrings.filter { $0 != [14] }.count, liveAfter = after.charStrings.filter { $0 != [14] }.count
        // “tender summary”: ten letters and the space, plus .notdef.
        #expect(liveAfter <= 12, "live charstrings: \(liveAfter)")
        #expect(liveBefore >= liveAfter + 9, "the nine removed-only glyphs lost their charstrings (\(liveBefore) → \(liveAfter))")
        if let charset = after.charset {
            for (glyph, id) in charset.enumerated() where after.charStrings[glyph] == [14] && glyph > 0 {
                #expect(id == 0, "glyph \(glyph) keeps no name or CID")
            }
        }
        if !before.globalSubrs.isEmpty {
            #expect(after.globalSubrs.filter { $0 != [11] }.count < before.globalSubrs.count, "unused subroutines are emptied")
        }
        #expect(try RedactionProof.changedShareOutside(source: source, output: output, page: 0, boxes: [box]) <= 0.001)
    }

    /// Old: the Type 1 program kept /Q and the subroutine only /Q called.
    @Test("Finding 19 — a Type 1 program: the glyph drawn only under the box and the subroutine only it called are emptied; the rest is byte for byte")
    func type1Program() throws {
        let box = CGRect(x: 92, y: 170, width: 46, height: 70)
        let run = try redact(HardeningFixtures.type1Sheet(), "type1-program", boxes: [box])
        defer { try? FileManager.default.removeItem(at: run.folder) }
        #expect(run.outcome.vectorPages == [0])
        // The hand-built font does render: the second “A” (40…76 × 60…102) is ink on the source.
        let sourcePage = try #require(PDFDocument(url: run.source)?.page(at: 0))
        let bitmap = try #require(RasterRedactor.render(sourcePage, dpi: 100))
        let transform = RasterRedactor.pixelTransform(for: sourcePage, dpi: 100, height: bitmap.height)
        let letter = CGRect(x: 42, y: 62, width: 30, height: 38).applying(transform).standardized
        #expect(HardeningProof.darkPixels(bitmap, outside: .null) - HardeningProof.darkPixels(bitmap, outside: letter) > 50, "the Type 1 glyphs are drawn")

        func privatePart(_ url: URL) throws -> [UInt8] {
            let scan = try PDFDocumentScan(data: try Data(contentsOf: url))
            let font = try HardeningProof.firstFont(scan, page: 0)
            let descriptor = try #require(scan.dictionary(font["FontDescriptor"]))
            guard case let .stream(dictionary, raw)? = scan.object(descriptor["FontFile"]) else { throw RedactionUnsupported("no program") }
            let data = [UInt8](try RedactionStreamFilters.decode(dictionary: dictionary, data: raw).data)
            let length1 = try #require(scan.object(dictionary["Length1"])?.integerValue), length2 = try #require(scan.object(dictionary["Length2"])?.integerValue)
            return RedactionType1.decrypt(Array(data[length1..<(length1 + length2)]), key: RedactionType1.eexecKey)
        }
        func charstring(_ plain: [UInt8], _ marker: String) -> [UInt8]? {
            guard let found = PDFObjectParser.find(Array(marker.utf8), in: plain, from: 0) else { return nil }
            var cursor = found + marker.utf8.count
            var lengthText = ""
            while plain[cursor] == 0x20 { cursor += 1 }
            while plain[cursor] != 0x20 { lengthText.append(Character(UnicodeScalar(plain[cursor]))); cursor += 1 }
            let length = Int(lengthText) ?? 0
            cursor += 4 // " RD "
            return Array(RedactionType1.decrypt(Array(plain[cursor..<(cursor + length)]), key: RedactionType1.charstringKey).dropFirst(4))
        }
        let before = try privatePart(run.source), after = try privatePart(run.output)
        #expect(charstring(after, "/Q") == [139, 139, 13, 14], "Q draws nothing")
        #expect(charstring(after, "dup 4") == [11], "the subroutine only Q called is empty")
        #expect(charstring(after, "/A") == charstring(before, "/A"), "A is unchanged")
        #expect(charstring(after, "dup 5") == charstring(before, "dup 5"), "the subroutine A calls is unchanged")
        #expect(try RedactionProof.changedShareOutside(source: run.source, output: run.output, page: 0, boxes: [box], ignoring: [box.insetBy(dx: -10, dy: -10)]) <= 0.002)
    }

    /// Old: the whole OpenType program travelled — every glyph of the face, the removed ones
    /// included, and a character map naming them all.
    @Test("Finding 19 — an OpenType program with CFF outlines keeps outlines and character-map entries only for the glyphs still shown")
    func openTypeCFFProgram() throws {
        let box = CGRect(x: 60, y: 140, width: 220, height: 34)
        let run = try redact(try HardeningFixtures.openTypeCFFSheet(), "opentype-cff", boxes: [box])
        defer { try? FileManager.default.removeItem(at: run.folder) }
        #expect(run.outcome.vectorPages == [0])
        // The embedded program does draw: the kept line has ink on the source.
        let page = try #require(PDFDocument(url: run.source)?.page(at: 0))
        let bitmap = try #require(RasterRedactor.render(page, dpi: 100))
        let transform = RasterRedactor.pixelTransform(for: page, dpi: 100, height: bitmap.height)
        let line = CGRect(x: 70, y: 245, width: 150, height: 20).applying(transform).standardized
        #expect(HardeningProof.darkPixels(bitmap, outside: .null) - HardeningProof.darkPixels(bitmap, outside: line) > 100, "the OpenType glyphs are drawn")
        func program(_ url: URL) throws -> RedactionTrueType.Font {
            let scan = try PDFDocumentScan(data: try Data(contentsOf: url))
            let descriptor = try #require(scan.dictionary(try HardeningProof.firstFont(scan, page: 0)["FontDescriptor"]))
            return try RedactionTrueType.parse(try RedactionStreamFilters.decodeFully(scan.object(descriptor["FontFile3"])))
        }
        let before = try program(run.source), after = try program(run.output)
        let liveBefore = try RedactionCFF.parse(try #require(before.tables["CFF "])).charStrings.filter { $0 != [14] }.count
        let liveAfter = try RedactionCFF.parse(try #require(after.tables["CFF "])).charStrings.filter { $0 != [14] }.count
        #expect(liveAfter <= 12, "live charstrings: \(liveAfter)")
        #expect(liveBefore > liveAfter + 100, "the face's other glyphs lost their outlines (\(liveBefore) → \(liveAfter))")
        for (_, map) in try RedactionTrueType.characterMaps(after) {
            for character in "QXZJK4820".unicodeScalars { #expect(map[character.value] == nil, "no character-map entry for \(character)") }
        }
        #expect(try RedactionProof.changedShareOutside(source: run.source, output: run.output, page: 0, boxes: [box]) <= 0.001)
    }
}
