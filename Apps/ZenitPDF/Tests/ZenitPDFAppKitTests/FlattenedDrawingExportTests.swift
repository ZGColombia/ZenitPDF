import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import Testing
import UniformTypeIdentifiers
import ZPDFAppCore
import ZPDFContracts
import ZPDFExport
import ZPDFRenderer
import ZPDFUIPresentation
@testable import ZenitPDFAppKit

/// The flattened export **through the application**: print, and the three export shapes.
///
/// ### The defect these tests exist for
///
/// `printDocument(_:)` rasterised each page and drew no markup at all. Every call in it
/// succeeded, so nothing was red and nothing was logged; an estimator pressed ⌘P and got the
/// architect's drawing back. A package test could not have caught it — `ZPDFExportTests` proves
/// the flatten path draws markups given markups, and says nothing about whether the print path
/// ever hands it any.
///
/// So every assertion below starts at the shipping entry point — the document's own print job
/// builder, the window controller's own export method — and ends at **bytes that were re-opened
/// and read**.
@MainActor
@Suite(.appTierSerialised)
struct FlattenedDrawingExportTests {

    // MARK: - Harness

    struct Harness {
        let document: ZenitPDFProjectDocument
        let core: AppCoreEnvironment
        let directory: URL
        let sourceURL: URL
        let pageID: PageID
        /// The length that must print.
        let printedSpan: (PDFPoint, PDFPoint)
        /// The length that must not: its record carries `printable == false`.
        let suppressedSpan: (PDFPoint, PDFPoint)
    }

    /// A loaded one-page document carrying three markups: two printable lengths and one that is
    /// not printable.
    ///
    /// The records are added through `core.commands`, the same door the canvas uses, because the
    /// question here is what the *print path* does with the session's records — not whether a
    /// click produces one, which `SnippetExportWiringTests` already drives end to end.
    private func makeHarness() async throws -> Harness {
        let url = try AppTestSupport.writeFixturePDF(named: "Print.pdf")
        let document = try AppTestSupport.makeDocument(opening: url)
        #expect(await AppTestSupport.wait {
            document.core != nil && document.drawing != nil
        })
        let core = try #require(document.core)
        let drawing = try #require(document.drawing)
        let page = try #require(drawing.pages.first)

        let printed = (PDFPoint(x: 120, y: 200), PDFPoint(x: 320, y: 200))
        let suppressed = (PDFPoint(x: 140, y: 500), PDFPoint(x: 340, y: 500))

        for (span, printable) in [(printed, true), (suppressed, false)] {
            _ = try await core.commands.perform(.addMarkup(MarkupRecord(
                id: MarkupID(UUID()),
                documentID: drawing.documentID,
                pageID: page.id,
                kind: .measurement,
                tool: .length,
                label: printable ? "Printed" : "Suppressed",
                printable: printable,
                geometry: MeasurementGeometry(pageID: page.id, points: [span.0, span.1]),
                createdAt: Date(),
                modifiedAt: Date()
            )))
        }
        await core.commands.settle()
        await core.refresh()

        return Harness(
            document: document,
            core: core,
            directory: url.deletingLastPathComponent(),
            sourceURL: url,
            pageID: page.id,
            printedSpan: printed,
            suppressedSpan: suppressed
        )
    }

    private func tearDown(_ harness: Harness) async {
        await harness.document.drawing?.rasterSource.close()
        harness.document.close()
        try? FileManager.default.removeItem(at: harness.directory)
    }

    // MARK: - The print path

    @Test("The print job carries the page's markups, and the print view is built from it")
    func printJobCarriesMarkups() async throws {
        let harness = try await makeHarness()
        defer { Task { await tearDown(harness) } }

        let job = try await FlattenedDrawingExport.job(for: harness.document)
        #expect(job.pages.count == harness.document.drawing?.pages.count)
        let sheet = try #require(job.pages.first)
        #expect(!sheet.markups.isEmpty, "printing must hand the flatten path some markups")

        // The sheet the printer would get, at the page's own size.
        let expected = try #require(harness.document.drawing?.pages.first?.rotatedVisibleSize)
        #expect(Double(sheet.sheetSize.width) == expected.width, "\(sheet.sheetSize) vs \(expected)")
        #expect(Double(sheet.sheetSize.height) == expected.height)

        // And the print view is built out of exactly those sheets — the wiring the old path
        // did not have. `DocumentPrintView` is the only thing between this and paper.
        let view = DocumentPrintView(
            sheets: job.pages.map(DocumentPrintView.Sheet.init(flatten:)),
            content: nil
        )
        var range = NSRange(location: 0, length: 0)
        #expect(view.knowsPageRange(&range))
        #expect(range.length == job.pages.count)
        #expect(view.rectForPage(1).size == sheet.sheetSize)
    }

    @Test("The print view paints the markups into the context it is given")
    func printViewPaintsMarkups() async throws {
        let harness = try await makeHarness()
        defer { Task { await tearDown(harness) } }

        let job = try await FlattenedDrawingExport.job(for: harness.document)
        let view = DocumentPrintView(
            sheets: job.pages.map(DocumentPrintView.Sheet.init(flatten:)),
            content: nil
        )
        let sheet = try #require(job.pages.first)

        // A PDF context stands in for the printer's, which is also a PDF context — that is what
        // `NSPrintOperation` hands a view, and it is why the markups stay vector on paper.
        let buffer = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: buffer as CFMutableData))
        var mediaBox = CGRect(origin: .zero, size: sheet.sheetSize)
        let context = try #require(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        context.beginPDFPage(nil)
        let graphics = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        view.draw(NSRect(origin: .zero, size: view.frame.size))
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()

        let stream = try #require(Self.contentStream(of: buffer as Data, page: 1))
        // The one thing the old path never produced: path geometry beyond the white ground.
        #expect(stream.contains(" S\n") || stream.contains(" S ") || stream.hasSuffix(" S"),
                "a printed sheet must contain stroked paths")
    }

    // MARK: - printable

    @Test("A markup whose record says printable == false never reaches the paper")
    func nonPrintableMarkupsAreLeftOff() async throws {
        let harness = try await makeHarness()
        defer { Task { await tearDown(harness) } }

        let records = await harness.core.session.orderedMarkups
        #expect(records.count == 2)
        #expect(records.contains { !$0.printable })

        let shapes = CanvasSceneBuilder.build(
            records: records,
            summaries: harness.core.snapshot.markups(onPage: harness.pageID.rawValue),
            pageID: harness.pageID.rawValue
        )
        #expect(shapes.count == 2, "both markups are on screen; only one belongs on paper")
        #expect(shapes.contains { !$0.printable })

        // Screen shows both. Paper shows one. One function decides it.
        let onScreen = SnippetSceneBuilder.renderables(from: shapes, for: .screen)
        let onPaper = SnippetSceneBuilder.renderables(from: shapes, for: .paper)
        #expect(!onScreen.isEmpty)
        #expect(onPaper.count < onScreen.count)

        // And the suppressed span's coordinates are nowhere in what paper is handed.
        let suppressed = harness.suppressedSpan
        #expect(!Self.mentions(onPaper, suppressed.0))
        #expect(!Self.mentions(onPaper, suppressed.1))
        #expect(Self.mentions(onPaper, harness.printedSpan.0))
        #expect(Self.mentions(onPaper, harness.printedSpan.1))
    }

    // MARK: - The written file

    @Test("Export Marked PDF writes a file whose content stream carries the markups")
    func markedExportCarriesMarkups() async throws {
        let harness = try await makeHarness()
        defer { Task { await tearDown(harness) } }

        let controller = ProjectWindowController(document: harness.document)
        let destination = harness.directory.appendingPathComponent("marked.pdf")
        let before = try Self.digest(of: harness.sourceURL)
        try await controller.writeDrawing(.flattened, for: harness.document, to: destination)

        // The drawing that was exported is byte-for-byte what it was.
        #expect(try Self.digest(of: harness.sourceURL) == before)

        let data = try Data(contentsOf: destination)
        let stream = try #require(Self.contentStream(of: data, page: 1))
        #expect(stream.contains("Do") || stream.contains(" S"),
                "the exported sheet must carry the drawing and the markups")

        // The printed span's endpoints are in the output; the suppressed span's are not.
        let points = Self.pathPoints(in: data, page: 1)
        #expect(Self.near(points, harness.printedSpan.0))
        #expect(Self.near(points, harness.printedSpan.1))
        #expect(!Self.near(points, harness.suppressedSpan.0))
        #expect(!Self.near(points, harness.suppressedSpan.1))
    }

    @Test("Export Clean PDF writes the drawing with none of the takeoff on it")
    func cleanExportCarriesNoMarkup() async throws {
        let harness = try await makeHarness()
        defer { Task { await tearDown(harness) } }

        let controller = ProjectWindowController(document: harness.document)
        let destination = harness.directory.appendingPathComponent("clean.pdf")
        try await controller.writeDrawing(.clean, for: harness.document, to: destination)

        let data = try Data(contentsOf: destination)
        let points = Self.pathPoints(in: data, page: 1)
        #expect(!Self.near(points, harness.printedSpan.0))
        #expect(!Self.near(points, harness.printedSpan.1))
        #expect(!Self.near(points, harness.suppressedSpan.0))
    }

    @Test("Export Annotated PDF writes annotations, and the bridge proves the source survived")
    func annotatedExportWritesAnnotations() async throws {
        let harness = try await makeHarness()
        defer { Task { await tearDown(harness) } }

        let controller = ProjectWindowController(document: harness.document)
        let destination = harness.directory.appendingPathComponent("annotated.pdf")
        let before = try Self.digest(of: harness.sourceURL)
        let receipt = try await controller.writeAnnotatedDrawing(
            for: harness.document, to: destination
        )
        #expect(receipt.sourceIsUnchanged)
        #expect(try Self.digest(of: harness.sourceURL) == before)

        // Re-open and count what is actually in the page tree.
        let reopened = try #require(PDFDocumentProbe(url: destination))
        #expect(reopened.annotationCount(onPage: 0) >= 1)
    }

    @Test("The three shapes are the same job with a different flag")
    func theThreeShapesShareOneJob() async throws {
        let harness = try await makeHarness()
        defer { Task { await tearDown(harness) } }

        // The annotated shape's annotations come off the same scene and the same paper rule the
        // two content-stream shapes are written from, so a markup left off paper is left out of
        // the annotations too.
        let job = try await StandardAnnotationExport.job(for: harness.document)
        let annotations = job.pages.flatMap(\.annotations)
        #expect(annotations.count == 1, "one printable length, one annotation")
        #expect(job.pages.allSatisfy { $0.sourcePageIndex == 0 })
        for annotation in annotations {
            if case let .polyLine(points) = annotation.geometry {
                #expect(!points.contains { abs($0.x - harness.suppressedSpan.0.x) < 1 && abs($0.y - harness.suppressedSpan.0.y) < 1 })
            }
        }
    }

    // MARK: - Reading a produced PDF

    static func digest(of url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    static func contentStream(of data: Data, page number: Int) -> String? {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider),
              let page = document.page(at: number),
              let dictionary = page.dictionary
        else { return nil }
        var contents: CGPDFObjectRef?
        guard CGPDFDictionaryGetObject(dictionary, "Contents", &contents), let contents
        else { return nil }
        var chunks = Data()
        var stream: CGPDFStreamRef?
        if CGPDFObjectGetValue(contents, .stream, &stream), let stream {
            var format = CGPDFDataFormat.raw
            if let bytes = CGPDFStreamCopyData(stream, &format) { chunks.append(bytes as Data) }
        } else {
            var array: CGPDFArrayRef?
            if CGPDFObjectGetValue(contents, .array, &array), let array {
                for index in 0..<CGPDFArrayGetCount(array) {
                    var element: CGPDFStreamRef?
                    var format = CGPDFDataFormat.raw
                    if CGPDFArrayGetStream(array, index, &element), let element,
                       let bytes = CGPDFStreamCopyData(element, &format) {
                        chunks.append(bytes as Data)
                    }
                }
            }
        }
        return String(decoding: chunks, as: UTF8.self)
    }

    /// Every `m`/`l` coordinate pair in the page's content stream, mapped through the CTM in
    /// force when it was written.
    ///
    /// A small interpreter rather than a substring search, because the renderer draws through a
    /// y flip: the numbers in the file are not the numbers the markup was authored with, and a
    /// test that searched for the raw digits would pass on an empty page and fail on a correct
    /// one.
    static func pathPoints(in data: Data, page number: Int) -> [CGPoint] {
        guard let text = contentStream(of: data, page: number) else { return [] }
        var points: [CGPoint] = []
        var ctm = CGAffineTransform.identity
        var stack: [CGAffineTransform] = []
        var operands: [Double] = []
        for token in text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\r" || $0 == "\t" }) {
            let word = String(token)
            if let value = Double(word) {
                operands.append(value)
                if operands.count > 16 { operands.removeFirst() }
                continue
            }
            switch word {
            case "q": stack.append(ctm)
            case "Q": if let previous = stack.popLast() { ctm = previous }
            case "cm":
                if operands.count >= 6 {
                    let v = Array(operands.suffix(6))
                    ctm = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
                        .concatenating(ctm)
                }
            case "m", "l":
                if operands.count >= 2 {
                    let v = Array(operands.suffix(2))
                    points.append(CGPoint(x: v[0], y: v[1]).applying(ctm))
                }
            default: break
            }
            operands.removeAll(keepingCapacity: true)
        }
        return points
    }

    /// Whether a page-space point appears in the output's sheet space.
    ///
    /// The fixture's crop box is its media box with the origin at zero, so sheet space and page
    /// space coincide and the comparison needs no offset.
    static func near(_ points: [CGPoint], _ point: PDFPoint, tolerance: Double = 1.0) -> Bool {
        points.contains {
            abs(Double($0.x) - point.x) <= tolerance && abs(Double($0.y) - point.y) <= tolerance
        }
    }

    /// Whether any renderable names this page point.
    static func mentions(_ markups: [RenderableMarkup], _ point: PDFPoint) -> Bool {
        markups.contains { markup in
            switch markup.shape {
            case let .polyline(polyline):
                polyline.points.contains { abs($0.x - point.x) < 0.5 && abs($0.y - point.y) < 0.5 }
            case let .filledPolygon(polygon):
                polygon.outer.contains { abs($0.x - point.x) < 0.5 && abs($0.y - point.y) < 0.5 }
            case let .dimensionLine(line):
                (abs(line.start.x - point.x) < 0.5 && abs(line.start.y - point.y) < 0.5)
                    || (abs(line.end.x - point.x) < 0.5 && abs(line.end.y - point.y) < 0.5)
            case let .countSymbol(symbol):
                abs(symbol.center.x - point.x) < 0.5 && abs(symbol.center.y - point.y) < 0.5
            case let .textLabel(label):
                abs(label.anchorPoint.x - point.x) < 0.5 && abs(label.anchorPoint.y - point.y) < 0.5
            case let .labelPill(pill):
                abs(pill.anchorPoint.x - point.x) < 0.5 && abs(pill.anchorPoint.y - point.y) < 0.5
            case let .image(image):
                // An inserted picture (ADR-0043, l8-exportior): named by its corners.
                image.corners.contains { abs($0.x - point.x) < 0.5 && abs($0.y - point.y) < 0.5 }
            }
        }
    }

    static func near(_ points: [CGPoint], _ point: PDFPoint) -> Bool {
        near(points, point, tolerance: 1.0)
    }
}

/// Counts annotations in a produced file, without PDFKit's document class reaching the app.
struct PDFDocumentProbe {
    private let document: CGPDFDocument

    init?(url: URL) {
        guard let document = CGPDFDocument(url as CFURL) else { return nil }
        self.document = document
    }

    func annotationCount(onPage index: Int) -> Int {
        guard let page = document.page(at: index + 1), let dictionary = page.dictionary
        else { return 0 }
        var annotations: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dictionary, "Annots", &annotations),
              let annotations
        else { return 0 }
        return CGPDFArrayGetCount(annotations)
    }
}
