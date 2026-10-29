import CoreGraphics
import CryptoKit
import Foundation
import Testing
import ZPDFContracts
import ZPDFRenderer
@testable import ZPDFExport

/// ADR-0013 §3's verification bar, which is the feature.
///
/// The ADR says it in one line — *"it opened" is not proof (the printing precedent)* — and then
/// lists what proof is: the group is in `/OCProperties`, every markup operator is inside the
/// `BDC`/`EMC` span, the span count matches the markup count, and a render with the layer forced
/// off produces the clean sheet. Every test below opens the produced bytes and reads one of those
/// four. Nothing here asserts that a call returned without throwing.
@Suite(.sharedHeap)
struct LayeredMarkupExportTests {

    // MARK: - Fixtures

    static func job(rotation: PageRotation = .degrees0) -> FlattenPage {
        let page = FlattenedPDFWriterTests.page(rotation: rotation)
        return FlattenPage(
            page: page,
            sourcePageIndex: 0,
            markups: [
                FlattenedPDFWriterTests.polyline(
                    from: PDFPoint(x: 60, y: 80),
                    to: PDFPoint(x: 300, y: 250)
                ),
                FlattenedPDFWriterTests.filledTriangle(at: PDFPoint(x: 120, y: 120), size: 60),
                FlattenedPDFWriterTests.countSymbol(at: PDFPoint(x: 320, y: 100))
            ]
        )
    }

    static func write(_ data: Data, named name: String) throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("zenit-layered-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    static func contains(_ data: Data, _ text: String) -> Bool {
        let needle = [UInt8](text.utf8)
        let bytes = [UInt8](data)
        guard needle.count <= bytes.count else { return false }
        for start in 0...(bytes.count - needle.count) {
            var matched = true
            for offset in 0..<needle.count where bytes[start + offset] != needle[offset] {
                matched = false
                break
            }
            if matched { return true }
        }
        return false
    }

    // MARK: - 1. The catalog carries the group, and it is on

    @Test("The layered artefact declares one optional-content group, on by default")
    func artefactDeclaresTheGroup() throws {
        let source = LayeredSourceFixtures.plain()
        let produced = try LayeredMarkupExporter().data(source: source, pages: [Self.job()])

        #expect(Self.contains(produced.data, "/OCProperties"), "no /OCProperties in the bytes")
        #expect(Self.contains(produced.data, "/OCG"), "no optional-content group object")

        let inspector = try #require(OptionalContentInspector(data: produced.data))
        #expect(inspector.hasOptionalContent)
        #expect(inspector.groupNames == ["Zenit Markups"])
        #expect(inspector.onNames == ["Zenit Markups"], "the group is not on by default")
        #expect(!inspector.offNames.contains("Zenit Markups"))
        #expect(inspector.orderNames == ["Zenit Markups"], "the layer panel would not list it")
        #expect(produced.outcome.visibleByDefault)
        #expect(produced.outcome.markupSpanCount == 3)
        #expect(produced.outcome.rejectedMarkupCount == 0)
    }

    // MARK: - 2. Every markup operator is inside a span bound to the group

    @Test("Every markup operator sits inside a BDC/EMC span bound to the group, one span each")
    func everyMarkupOperatorIsInsideItsOwnSpan() throws {
        let source = LayeredSourceFixtures.plain()
        let job = Self.job()
        let produced = try LayeredMarkupExporter().data(source: source, pages: [job])

        let inspector = try #require(OptionalContentInspector(data: produced.data))
        let page = try #require(inspector.pages.first)
        #expect(page.markedContentIsBalanced, "a BDC was left open or an EMC had no BDC")

        // The span count is the markup count, not the page count: ADR-0013 §3 asks for the
        // markups to be countable in the artefact, which is only true one span at a time.
        #expect(page.spans.count == job.markups.count)
        let bindings = Set(page.spans.map(\.propertyName))
        #expect(bindings.count == 1, "the page uses more than one properties name")
        let name = try #require(bindings.first)
        #expect(
            page.propertyGroupNames[name] == "Zenit Markups",
            "/\(name) does not resolve through /Resources /Properties to the group"
        )
        for span in page.spans {
            #expect(!span.paintOperators.isEmpty, "a span was opened around nothing")
        }

        // Nothing leaked. The operators outside every span are exactly the drawing's own, which
        // is the other half of "the underlying drawing is untouched" — it is not enough that the
        // markups are inside the span if the drawing's ink was moved in with them.
        let original = try #require(PDFContentStreamInspector(data: source))
        #expect(page.paintOperatorsOutsideSpans == original.pages[0].paintOperators)

        // And the ink is where the estimator put it: the polyline's ends, in page space, through
        // the placement matrix the appended stream carries.
        let points = page.spans.flatMap(\.points)
        #expect(
            PDFContentStreamInspector.contains(points, CGPoint(x: 60, y: 80), tolerance: 1),
            "the polyline's start is not in any optional-content span"
        )
        #expect(
            PDFContentStreamInspector.contains(points, CGPoint(x: 300, y: 250), tolerance: 1),
            "the polyline's end is not in any optional-content span"
        )
    }

    // MARK: - 3. The layer switched off is the clean sheet

    @Test("Rendered with the group forced off, the artefact is the clean export pixel for pixel")
    func theLayerSwitchedOffRendersTheCleanSheet() throws {
        let source = LayeredSourceFixtures.plain()
        let sourceURL = try Self.write(source, named: "drawing.pdf")
        let job = Self.job()
        let produced = try LayeredMarkupExporter().data(source: source, pages: [job])

        let content = try #require(CGPDFPageContentSource(url: sourceURL))
        let clean = try FlattenedPDFWriter().data(shape: .clean, pages: [job], content: content)

        let cleanRaster = try #require(PageRaster.render(clean, pageIndex: 0))
        let onRaster = try #require(PageRaster.render(produced.data, pageIndex: 0))
        #expect(
            PageRaster.difference(onRaster, cleanRaster) > 0.005,
            "the layer is on and yet the sheet matches the clean export — nothing was drawn"
        )

        let flipped = try #require(
            PageRaster.flipDefaultConfigurationOff(produced.data),
            "the /ON entry could not be flipped to /OFF"
        )
        let flippedInspector = try #require(OptionalContentInspector(data: flipped))
        #expect(flippedInspector.offNames == ["Zenit Markups"])
        #expect(flippedInspector.onNames.isEmpty)

        // Measured on this build: **zero** differing pixels. The tolerance is here because a
        // rasteriser is allowed to change its antialiasing between OS releases, not because the
        // two images are nearly the same.
        let offRaster = try #require(PageRaster.render(flipped, pageIndex: 0))
        let difference = PageRaster.difference(offRaster, cleanRaster)
        #expect(
            difference < 0.001,
            "with the layer off the sheet still differs from the clean export in \(difference * 100)% of its pixels"
        )
    }

    // MARK: - 4. A drawing that already has layers keeps them

    @Test("A drawing with its own optional content keeps it and gains ours: both in /OCGs")
    func existingOptionalContentIsAppendedTo() throws {
        let source = LayeredSourceFixtures.withOwnLayer()
        let produced = try LayeredMarkupExporter().data(source: source, pages: [Self.job()])

        let inspector = try #require(OptionalContentInspector(data: produced.data))
        #expect(inspector.groupNames.count == 2)
        #expect(inspector.groupNames.contains("Drawing Layer"))
        #expect(inspector.groupNames.contains("Zenit Markups"))
        #expect(inspector.onNames.contains("Drawing Layer"), "the drawing's layer was switched off")
        #expect(inspector.onNames.contains("Zenit Markups"))
        #expect(inspector.orderNames.contains("Drawing Layer"), "the drawing's layer left the panel")
        #expect(inspector.orderNames.contains("Zenit Markups"))

        // The drawing's own marked content still binds to the drawing's own group, and ours to
        // ours: the two `/Properties` entries did not collide.
        let page = try #require(inspector.pages.first)
        let ours = page.spans.filter { page.propertyGroupNames[$0.propertyName] == "Zenit Markups" }
        let theirs = page.spans.filter { page.propertyGroupNames[$0.propertyName] == "Drawing Layer" }
        #expect(ours.count == 3)
        #expect(theirs.count == 1, "the drawing's own optional content did not survive")
    }

    // MARK: - The drawing itself is not rewritten

    @Test("The artefact begins with the drawing, byte for byte")
    func theDrawingIsNotRewritten() throws {
        let source = LayeredSourceFixtures.withOwnLayer()
        let produced = try LayeredMarkupExporter().data(source: source, pages: [Self.job()])

        #expect(produced.outcome.preservedSourceBytes == source.count)
        let prefix = produced.data.prefix(source.count)
        #expect(
            Data(SHA256.hash(data: prefix)) == Data(SHA256.hash(data: source)),
            "the drawing's own bytes were modified"
        )
        #expect(produced.data.count > source.count)
        #expect(produced.outcome.modificationStatement.contains("\(source.count) bytes"))
        #expect(produced.outcome.modificationStatement.contains("Zenit Markups"))
        #expect(produced.outcome.modificationStatement.contains("on by default"))
    }

    // MARK: - A rotated sheet lands where the flatten path puts it

    @Test("On a /Rotate 90 sheet the layer lands where the flatten path paints it")
    func rotatedSheetsPlaceTheInkTheSameWayTheFlattenPathDoes() throws {
        let source = LayeredSourceFixtures.plain(rotate: 90)
        let sourceURL = try Self.write(source, named: "rotated.pdf")
        let job = Self.job(rotation: .degrees90)
        let produced = try LayeredMarkupExporter().data(source: source, pages: [job])

        let content = try #require(CGPDFPageContentSource(url: sourceURL))
        let flattened = try FlattenedPDFWriter().data(
            shape: .flattened,
            pages: [job],
            content: content
        )
        let layered = try #require(PageRaster.render(produced.data, pageIndex: 0))
        let flat = try #require(PageRaster.render(flattened, pageIndex: 0))
        #expect(layered.width == flat.width)
        #expect(layered.height == flat.height)
        // Measured on this build: 0.12% of pixels, all of them on antialiased edges. That is the
        // answer to the one thing this shape does differently from the flatten path — painting
        // each markup on its own scratch page so it can have its own span.
        let difference = PageRaster.difference(layered, flat)
        #expect(
            difference < 0.005,
            "the layered sheet and the flattened sheet differ in \(difference * 100)% of pixels"
        )
    }

    // MARK: - Two sheets sharing one resource object

    @Test("Two sheets sharing one /Resources object each get their own layer binding")
    func sheetsSharingResourcesDoNotShareMarkups() throws {
        let source = LayeredSourceFixtures.sharedResourcePair()
        let first = Self.job()
        let second = FlattenPage(
            page: FlattenedPDFWriterTests.page(index: 1),
            sourcePageIndex: 1,
            markups: [
                FlattenedPDFWriterTests.polyline(
                    from: PDFPoint(x: 80, y: 100),
                    to: PDFPoint(x: 200, y: 260)
                ),
                FlattenedPDFWriterTests.countSymbol(at: PDFPoint(x: 250, y: 140))
            ]
        )
        let produced = try LayeredMarkupExporter().data(source: source, pages: [first, second])
        #expect(produced.outcome.pageCount == 2)
        #expect(produced.outcome.markedPageCount == 2)
        #expect(produced.outcome.markupSpanCount == 5)

        let inspector = try #require(OptionalContentInspector(data: produced.data))
        // One group for the document, not one per sheet.
        #expect(inspector.groupNames == ["Zenit Markups"])
        #expect(inspector.pages.count == 2)
        #expect(inspector.pages[0].spans.count == 3)
        #expect(inspector.pages[1].spans.count == 2)
        for page in inspector.pages {
            for span in page.spans {
                #expect(
                    page.propertyGroupNames[span.propertyName] == "Zenit Markups",
                    "a span on one sheet does not resolve to the group on that sheet"
                )
            }
        }

        // Sheet 2's markups must not appear on sheet 1. Its polyline runs to (200, 260) in page
        // space; the shared `/Resources` object is exactly what would have carried it across.
        let strayed = PDFContentStreamInspector.contains(
            inspector.pages[0].spans.flatMap(\.points),
            CGPoint(x: 200, y: 260),
            tolerance: 1
        )
        #expect(!strayed, "a markup from sheet 2 was painted on sheet 1")
    }

    // MARK: - The shape modern producers actually write

    @Test("A drawing whose catalog is inside an object stream gains the layer all the same")
    func objectStreamsAndCrossReferenceStreamsAreHandled() throws {
        let source = LayeredSourceFixtures.modern()
        // The fixture is only worth anything if it really is the modern shape.
        #expect(Self.contains(source, "/ObjStm"), "the fixture has no object stream")
        #expect(Self.contains(source, "/Type /XRef"), "the fixture has no cross-reference stream")
        #expect(!Self.contains(source, "\nxref\n"), "the fixture still has a table")

        let job = Self.job()
        let produced = try LayeredMarkupExporter().data(source: source, pages: [job])
        // The update must be a cross-reference stream too: a table chained to a stream is a file
        // strict readers reject (ISO 32000 permits only hybrid-reference files to mix the two), and
        // Core Graphics would not tell us.
        let appended = produced.data.suffix(from: source.count)
        #expect(Self.contains(appended, "/Type /XRef"), "the update appended a table, not a stream")

        let inspector = try #require(
            OptionalContentInspector(data: produced.data),
            "the artefact could not be reopened"
        )
        #expect(inspector.groupNames == ["Zenit Markups"])
        #expect(inspector.onNames == ["Zenit Markups"])
        let page = try #require(inspector.pages.first)
        #expect(page.spans.count == job.markups.count)
        #expect(page.markedContentIsBalanced)

        let sourceURL = try Self.write(source, named: "modern.pdf")
        let content = try #require(CGPDFPageContentSource(url: sourceURL))
        let clean = try FlattenedPDFWriter().data(shape: .clean, pages: [job], content: content)
        let flipped = try #require(PageRaster.flipDefaultConfigurationOff(produced.data))
        let offRaster = try #require(PageRaster.render(flipped, pageIndex: 0))
        let cleanRaster = try #require(PageRaster.render(clean, pageIndex: 0))
        #expect(PageRaster.difference(offRaster, cleanRaster) < 0.001)
    }

    // MARK: - Failure is honest (ADR-0013 §2)

    @Test("An encrypted drawing is refused with a sentence, not flattened silently")
    func encryptedDrawingsAreRefused() throws {
        var text = String(decoding: LayeredSourceFixtures.plain(), as: UTF8.self)
        text = text.replacingOccurrences(of: "/Root 1 0 R", with: "/Root 1 0 R /Encrypt 6 0 R")
        let source = Data(text.utf8)

        var caught: ExportError?
        do {
            _ = try LayeredMarkupExporter().data(source: source, pages: [Self.job()])
        } catch let error as ExportError {
            caught = error
        }
        let error = try #require(caught, "an encrypted drawing was accepted")
        guard case let .layeredSourceUnreadable(message) = error else {
            Issue.record("expected layeredSourceUnreadable, got \(error)")
            return
        }
        #expect(message.contains("encrypted"))
        #expect(message.hasSuffix("."), "the refusal is not a sentence: \(message)")
    }

    @Test("A drawing with no cross-reference section is refused rather than rebuilt")
    func drawingsWithNoCrossReferenceSectionAreRefused() throws {
        let full = LayeredSourceFixtures.plain()
        let text = String(decoding: full, as: UTF8.self)
        let cut = try #require(text.range(of: "startxref"))
        let source = Data(text[text.startIndex..<cut.lowerBound].utf8)

        var caught: ExportError?
        do {
            _ = try LayeredMarkupExporter().data(source: source, pages: [Self.job()])
        } catch let error as ExportError {
            caught = error
        }
        let error = try #require(caught, "a drawing with no startxref was accepted")
        guard case let .layeredSourceUnreadable(message) = error else {
            Issue.record("expected layeredSourceUnreadable, got \(error)")
            return
        }
        #expect(message.contains("startxref"))
    }

    @Test("A catalog the group cannot be appended to fails, and names the catalog as the reason")
    func hostileCatalogsAreRefused() throws {
        var caught: ExportError?
        do {
            _ = try LayeredMarkupExporter().data(
                source: LayeredSourceFixtures.hostileOptionalContent(),
                pages: [Self.job()]
            )
        } catch let error as ExportError {
            caught = error
        }
        let error = try #require(caught, "a catalog with a malformed /OCProperties was accepted")
        guard case let .layeredCatalogUnreachable(message) = error else {
            Issue.record("expected layeredCatalogUnreachable, got \(error)")
            return
        }
        #expect(message.contains("/OCProperties"))
        #expect(message.contains("flattened"), "the refusal does not say it did not fall back")
    }

    @Test("Markups measured on a different sheet size are refused, not placed anyway")
    func aSheetSizeMismatchIsRefused() throws {
        let job = FlattenPage(
            page: FlattenedPDFWriterTests.page(width: 500),
            sourcePageIndex: 0,
            markups: [
                FlattenedPDFWriterTests.polyline(
                    from: PDFPoint(x: 60, y: 80),
                    to: PDFPoint(x: 300, y: 250)
                )
            ]
        )
        var caught: ExportError?
        do {
            _ = try LayeredMarkupExporter().data(
                source: LayeredSourceFixtures.plain(),
                pages: [job]
            )
        } catch let error as ExportError {
            caught = error
        }
        let error = try #require(caught, "markups from another drawing were placed anyway")
        guard case let .layeredSourceUnreadable(message) = error else {
            Issue.record("expected layeredSourceUnreadable, got \(error)")
            return
        }
        #expect(message.contains("400 x 300"))
        #expect(message.contains("500 x 300"))
        #expect(message.contains("wrong drawing"))
    }

    @Test("An export onto the drawing it is exporting is refused")
    func theExportRefusesToOverwriteTheDrawing() throws {
        let sourceURL = try Self.write(LayeredSourceFixtures.plain(), named: "drawing.pdf")
        var caught: Error?
        do {
            _ = try LayeredMarkupExporter().write(
                source: sourceURL,
                pages: [Self.job()],
                to: sourceURL
            )
        } catch {
            caught = error
        }
        let error = try #require(caught as? PDFFlattenError)
        guard case let .fileWriteFailed(_, reason) = error else {
            Issue.record("expected fileWriteFailed, got \(error)")
            return
        }
        #expect(reason.contains("the drawing being exported"))
    }
}

/// Rasters, and the one byte-level edit the verification bar asks for.
enum PageRaster {

    struct Image {
        let width: Int
        let height: Int
        let pixels: [UInt8]
    }

    /// Draws a page the way `CGPDFPageContentSource` draws one: the crop box, `/Rotate` folded
    /// in by `getDrawingTransform`, on white.
    static func render(_ data: Data, pageIndex: Int, scale: Double = 1) -> Image? {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider),
              pageIndex + 1 <= document.numberOfPages,
              let page = document.page(at: pageIndex + 1)
        else { return nil }
        let box = page.getBoxRect(.cropBox)
        let rotation = ((Int(page.rotationAngle) % 360) + 360) % 360
        let swaps = rotation == 90 || rotation == 270
        let width = Int((Double(swaps ? box.height : box.width) * scale).rounded())
        let height = Int((Double(swaps ? box.width : box.height) * scale).rounded())
        guard width > 0, height > 0 else { return nil }
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.saveGState()
        context.concatenate(
            page.getDrawingTransform(.cropBox, rect: rect, rotate: 0, preserveAspectRatio: true)
        )
        context.clip(to: box)
        context.drawPDFPage(page)
        context.restoreGState()
        guard let buffer = context.data else { return nil }
        let bytes = buffer.bindMemory(to: UInt8.self, capacity: width * height * 4)
        return Image(
            width: width,
            height: height,
            pixels: Array(UnsafeBufferPointer(start: bytes, count: width * height * 4))
        )
    }

    /// The fraction of pixels that differ by more than `tolerance` in any channel.
    static func difference(_ first: Image, _ second: Image, tolerance: Int = 8) -> Double {
        guard first.width == second.width, first.height == second.height else { return 1 }
        let total = first.width * first.height
        guard total > 0 else { return 1 }
        var differing = 0
        for pixel in 0..<total {
            let offset = pixel * 4
            for channel in 0..<3
            where abs(Int(first.pixels[offset + channel]) - Int(second.pixels[offset + channel]))
                > tolerance {
                differing += 1
                break
            }
        }
        return Double(differing) / Double(total)
    }

    /// Moves the group from the default configuration's `/ON` array into its `/OFF` array, in a
    /// copy of the bytes.
    ///
    /// The two arrays are swapped in place and the edit is **the same length**, so every
    /// cross-reference offset in the file stays correct and the copy is a valid PDF that differs
    /// from the artefact in exactly one thing: whether the layer is on. That is what makes the
    /// comparison against the clean export mean something — nothing else about the file changed.
    static func flipDefaultConfigurationOff(_ data: Data) -> Data? {
        var bytes = [UInt8](data)
        let opening = Array("/OFF []/ON [".utf8)
        guard let start = index(of: opening, in: bytes) else { return nil }
        var close = start + opening.count
        while close < bytes.count, bytes[close] != UInt8(ascii: "]") { close += 1 }
        guard close < bytes.count else { return nil }
        let reference = Array(bytes[(start + opening.count)..<close])
        let replacement = Array("/OFF [".utf8) + reference + Array("]/ON []".utf8)
        guard replacement.count == close + 1 - start else { return nil }
        bytes.replaceSubrange(start...close, with: replacement)
        return Data(bytes)
    }

    private static func index(of needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard !needle.isEmpty, needle.count <= haystack.count else { return nil }
        for start in 0...(haystack.count - needle.count) {
            var matched = true
            for offset in 0..<needle.count where haystack[start + offset] != needle[offset] {
                matched = false
                break
            }
            if matched { return start }
        }
        return nil
    }
}
