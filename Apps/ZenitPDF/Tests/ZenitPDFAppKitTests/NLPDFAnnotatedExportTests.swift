import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFExport
import ZPDFPDFKitBridge
import ZPDFRenderer
import ZPDFUIPresentation
@testable import ZenitPDFAppKit

/// The nl-pdf app-tier regression tests: the annotated export from the shipping entry
/// point (`ProjectWindowController.writeAnnotatedDrawing`) to bytes re-read with Core Graphics,
/// and the report text. Each test names the old output.
@MainActor
@Suite(.appTierSerialised)
struct NLPDFAnnotatedExportTests {

    // MARK: - Report text (bug 1)

    @Test("A report with two notes is two lines, not one line with a literal \\n")
    func reportLinesAreRealLineFeeds() {
        var report = FlattenedDrawingExport.Report()
        report.rejectedMarkupCount = 1
        let message = FlattenedDrawingExport.reportMessage(
            report,
            notes: ["Annotations in the original PDF are not included on page(s) 3.", "Layers hidden."]
        )
        // Old output: "…from the file.\\nAnnotations…\\nLayers hidden." — backslash-n as text.
        #expect(message?.contains("\\n") == false)
        #expect(message?.split(separator: "\n").count == 3)
        #expect(FlattenedDrawingExport.reportMessage(FlattenedDrawingExport.Report(), notes: []) == nil)
    }

    // MARK: - Harness

    struct Harness {
        let document: ZenitPDFProjectDocument
        let directory: URL
        let sourceURL: URL
        let area: MarkupID
        let length: MarkupID
        let count: MarkupID
        let stamp: MarkupID
    }

    /// One page carrying a 20 %-filled area, a length, a three-mark count and a stamp.
    private func makeHarness() async throws -> Harness {
        let url = try AppTestSupport.writeFixturePDF(named: "Annotated.pdf")
        let document = try AppTestSupport.makeDocument(opening: url)
        #expect(await AppTestSupport.wait { document.core != nil && document.drawing != nil })
        let core = try #require(document.core)
        let drawing = try #require(document.drawing)
        let page = try #require(drawing.pages.first)
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let ink = RGBAColor(red: 0x1A / 255.0, green: 0x55 / 255.0, blue: 0xCF / 255.0, alpha: 1)
        let fill = RGBAColor(red: 0x1A / 255.0, green: 0x55 / 255.0, blue: 0xCF / 255.0, alpha: 0.2)

        func record(_ kind: ZPDFContracts.MarkupKind, tool: MeasurementTool?, geometry: MeasurementGeometry,
                    stamp: StampInstance? = nil, status: ZPDFContracts.MarkupStatus = .none) -> MarkupRecord {
            MarkupRecord(
                id: MarkupID(UUID()),
                documentID: drawing.documentID,
                pageID: page.id,
                kind: kind,
                tool: tool,
                subject: "Concrete",
                label: "Slab",
                author: "Estimator",
                status: status,
                style: MarkupStyle(color: ink, fill: fill),
                geometry: geometry,
                stamp: stamp,
                createdAt: now,
                modifiedAt: now
            )
        }
        let area = record(.measurement, tool: .area, geometry: MeasurementGeometry(
            pageID: page.id,
            polygons: [PolygonGeometry(outer: PolygonRing(points: [
                PDFPoint(x: 100, y: 100), PDFPoint(x: 300, y: 100),
                PDFPoint(x: 300, y: 250), PDFPoint(x: 100, y: 250)
            ], isClosed: true))]
        ), status: .accepted)
        let length = record(.measurement, tool: .length, geometry: MeasurementGeometry(
            pageID: page.id, points: [PDFPoint(x: 100, y: 400), PDFPoint(x: 400, y: 400)]
        ))
        let count = record(.measurement, tool: .count, geometry: MeasurementGeometry(
            pageID: page.id,
            countPoints: [PDFPoint(x: 350, y: 600), PDFPoint(x: 380, y: 620), PDFPoint(x: 410, y: 640)]
                .map { CountPoint(id: CountPointID(UUID()), position: $0) }
        ))
        let stamp = record(.stamp, tool: nil, geometry: MeasurementGeometry(
            pageID: page.id, points: [PDFPoint(x: 200, y: 700)]
        ), stamp: StampInstance(
            templateID: UUID(),
            templateName: "Approved",
            artworkDigest: nil,
            artworkKind: .vector,
            widthPoints: 120,
            heightPoints: 48,
            rotationDegrees: 0,
            fields: [StampFieldValue(kind: .date, resolvedText: "2026-09-23")],
            resolvedAt: now
        ))
        for value in [area, length, count, stamp] {
            _ = try await core.commands.perform(.addMarkup(value))
        }
        await core.commands.settle()
        await core.refresh()
        return Harness(
            document: document, directory: url.deletingLastPathComponent(), sourceURL: url,
            area: area.id, length: length.id, count: count.id, stamp: stamp.id
        )
    }

    private func tearDown(_ harness: Harness) async {
        await harness.document.drawing?.rasterSource.close()
        harness.document.close()
        try? FileManager.default.removeItem(at: harness.directory)
    }

    // MARK: - The written file (bugs 2, 4, 5, 6, 7, 8)

    @Test("One annotation per markup, named by the markup, the area translucent, the count a stamp")
    func oneNamedAnnotationPerMarkup() async throws {
        let harness = try await makeHarness()
        defer { Task { await tearDown(harness) } }

        let controller = ProjectWindowController(document: harness.document)
        // Not "annotated.pdf": on a case-insensitive volume that *is* the fixture "Annotated.pdf",
        // and the writer rightly refuses to land on the drawing it exports.
        let destination = harness.directory.appendingPathComponent("exported copy.pdf")
        let before = try Data(contentsOf: harness.sourceURL)
        let result = try await controller.writeAnnotatedDrawing(for: harness.document, to: destination)
        #expect(result.sourceIsUnchanged)
        guard case let .incremental(outcome) = result.writer else {
            Issue.record("the incremental writer should accept the fixture: \(result.writer)")
            return
        }
        #expect(outcome.writtenAnnotationCount == 4)

        let data = try Data(contentsOf: destination)
        // The drawing is the artefact's prefix, byte for byte: a signature over it survives.
        #expect(data.prefix(before.count) == before)
        let annotations = AnnotationProbe.annotations(in: data, page: 0)
        // Old output: the area as a Polygon plus a FreeText pill, the length as a PolyLine plus
        // its ticks and arrowheads, three Squares for the count, the stamp as a box and a
        // FreeText — none with a name. Now: four, plus the area's review reply.
        let named = annotations.filter { $0.name != nil && $0.inReplyTo == false }
        #expect(named.count == 4)
        for id in [harness.area, harness.length, harness.count, harness.stamp] {
            #expect(named.contains { $0.name == id.rawValue.uuidString }, "no /NM for \(id)")
        }
        let area = try #require(named.first { $0.name == harness.area.rawValue.uuidString })
        #expect(area.subtype == "Polygon")
        // Old output: no `/CA` — an opaque polygon over the drawing in other readers.
        #expect(area.constantOpacity.map { abs($0 - 0.2) < 0.001 } == true)
        #expect(area.hasAppearance)
        let count = try #require(named.first { $0.name == harness.count.rawValue.uuidString })
        // Old output: `/Square` per mark.
        #expect(count.subtype == "Stamp")
        #expect(!annotations.contains { $0.subtype == "Square" })
        let stamp = try #require(named.first { $0.name == harness.stamp.rawValue.uuidString })
        #expect(stamp.subtype == "Stamp")
        #expect(annotations.contains { $0.inReplyTo }, "the accepted area carries a review reply")
    }

    @Test("Exporting from an earlier export replaces Zenit's annotations instead of stacking them")
    func reExportDoesNotStack() async throws {
        let harness = try await makeHarness()
        defer { Task { await tearDown(harness) } }

        let job = try await StandardAnnotationExport.job(for: harness.document)
        let first = harness.directory.appendingPathComponent("first.pdf")
        _ = try await StandardAnnotationExport.write(job, to: first)
        let firstCount = AnnotationProbe.annotations(in: try Data(contentsOf: first), page: 0).count

        // The exported file becomes the drawing a second export starts from.
        var again = job
        again.sourceURL = first
        again.sourceDigest = nil
        let second = harness.directory.appendingPathComponent("second.pdf")
        _ = try await StandardAnnotationExport.write(again, to: second)
        let secondCount = AnnotationProbe.annotations(in: try Data(contentsOf: second), page: 0).count
        // Old behaviour (`.append`): the second file carried both sets.
        #expect(secondCount == firstCount)
        #expect(firstCount == 5)
    }

    @Test("The fallback report says the file was rewritten, and that a signature did not survive")
    func fallbackReportNamesTheSignature() throws {
        let receipt = DocumentWriteReceipt(
            destination: URL(fileURLWithPath: "/tmp/x.pdf"),
            digest: FileDigest(sha256: "00", byteCount: 1),
            pageCount: 1,
            sourceDigestBefore: nil,
            sourceDigestAfter: nil
        )
        let message = try #require(StandardAnnotationExport.reportMessage(for: .init(
            writer: .rewritten(reason: "the drawing is encrypted", receipt: receipt),
            sourceIsUnchanged: true,
            drawingIsSigned: true,
            annotationCount: 3
        )))
        #expect(message.contains("rewritten"))
        #expect(message.contains("signature"))
        // An incremental export of an unsigned drawing with nothing refused has nothing to say.
        var outcome = StandardAnnotationOutcome(pageCount: 1, preservedSourceBytes: 10)
        outcome.writtenAnnotationCount = 3
        #expect(StandardAnnotationExport.reportMessage(for: .init(
            writer: .incremental(outcome), sourceIsUnchanged: true, drawingIsSigned: false, annotationCount: 3
        )) == nil)
    }

    // MARK: - Mapping, without a document

    @Test("Each markup family maps to its standard subtype")
    func familiesMapToSubtypes() {
        let page = PageID(UUID())
        func shape(_ kind: ZPDFContracts.MarkupKind, points: [PDFPoint], lineStyle: LineStyle = .solid) -> CanvasMarkupShape? {
            let record = MarkupRecord(
                id: MarkupID(UUID()), documentID: DocumentID(UUID()), pageID: page, kind: kind,
                // r2-markup: an Arrow's head is its stored end (the tool stores `.closedArrow`), no
                // longer derived from the kind at export (NL-MARKUP-07).
                style: MarkupStyle(color: RGBAColor(red: 1, green: 0, blue: 0), lineStyle: lineStyle,
                                   endCap: kind == .arrow ? .closedArrow : .none),
                geometry: MeasurementGeometry(pageID: page, points: points),
                createdAt: Date(), modifiedAt: Date()
            )
            return CanvasSceneBuilder.build(records: [record], summaries: [], pageID: page.rawValue).first
        }
        let square = [PDFPoint(x: 10, y: 10), PDFPoint(x: 90, y: 60)]
        let cases: [(ZPDFContracts.MarkupKind, [PDFPoint], String)] = [
            (.rectangle, square, "Square"),
            (.ellipse, square, "Circle"),
            (.arrow, square, "Line"),
            (.line, square, "Line"),
            (.polyline, [PDFPoint(x: 0, y: 0), PDFPoint(x: 10, y: 10), PDFPoint(x: 20, y: 0)], "PolyLine"),
            (.freehand, [PDFPoint(x: 0, y: 0), PDFPoint(x: 10, y: 10), PDFPoint(x: 20, y: 0)], "Ink")
        ]
        for (kind, points, expected) in cases {
            guard let shape = shape(kind, points: points) else {
                Issue.record("no canvas shape for \(kind)")
                continue
            }
            let fragments = SnippetSceneBuilder.renderables(from: [shape], for: .paper)
            let annotation = StandardAnnotationExport.annotation(for: shape, record: nil, fragments: fragments)
            #expect(annotation.geometry.subtype == expected, "\(kind) exported as \(annotation.geometry.subtype)")
        }
        // An arrow's head is a line ending, not a separate polygon.
        if let arrow = shape(.arrow, points: square) {
            let annotation = StandardAnnotationExport.annotation(
                for: arrow, record: nil, fragments: SnippetSceneBuilder.renderables(from: [arrow], for: .paper)
            )
            #expect(annotation.endEnding == .closedArrow)
        }
    }
}

/// Reads a produced file's annotation dictionaries with Core Graphics, which is neither the
/// writer's own scanner nor PDFKit.
enum AnnotationProbe {
    struct Entry {
        var subtype: String?
        var name: String?
        var constantOpacity: Double?
        var hasAppearance: Bool
        var inReplyTo: Bool
    }

    static func annotations(in data: Data, page index: Int) -> [Entry] {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider),
              let page = document.page(at: index + 1),
              let dictionary = page.dictionary
        else { return [] }
        var array: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dictionary, "Annots", &array), let array else { return [] }
        var out: [Entry] = []
        for position in 0..<CGPDFArrayGetCount(array) {
            var annotation: CGPDFDictionaryRef?
            guard CGPDFArrayGetDictionary(array, position, &annotation), let annotation else { continue }
            var subtype: UnsafePointer<CChar>?
            CGPDFDictionaryGetName(annotation, "Subtype", &subtype)
            var name: CGPDFStringRef?
            CGPDFDictionaryGetString(annotation, "NM", &name)
            var opacity: CGPDFReal = 0
            let hasOpacity = CGPDFDictionaryGetNumber(annotation, "CA", &opacity)
            var appearance: CGPDFDictionaryRef?
            let hasAppearance = CGPDFDictionaryGetDictionary(annotation, "AP", &appearance)
            var parent: CGPDFDictionaryRef?
            let reply = CGPDFDictionaryGetDictionary(annotation, "IRT", &parent)
            out.append(Entry(
                subtype: subtype.map { String(cString: $0) },
                name: name.flatMap { CGPDFStringCopyTextString($0) as String? },
                constantOpacity: hasOpacity ? Double(opacity) : nil,
                hasAppearance: hasAppearance,
                inReplyTo: reply
            ))
        }
        return out
    }
}

/// nl-ux hand-off: an original the person made editable (NL-UX-04) is hidden on the canvas, and
/// the annotated export must not write it next to the markup that replaced it.
@MainActor
@Suite(.appTierSerialised)
struct NLPDFAdoptedOriginalExportTests {

    /// A one-page drawing carrying one reviewer's square, named so its identity is stable.
    static func drawingWithReviewerSquare() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenitpdf-apptests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Reviewed.pdf")
        let content = "2 w 0 0 0 RG 72 72 m 372 72 l 372 272 l 72 272 l h S"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 4 0 R /Annots [5 0 R] >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream",
            "<< /Type /Annot /Subtype /Square /Rect [100 100 200 160] /C [1 0 0] /NM (reviewer-square) /T (Reviewer) /F 4 >>"
        ]
        var pdf = Data("%PDF-1.7\n".utf8)
        var offsets: [Int] = []
        for (index, body) in objects.enumerated() {
            offsets.append(pdf.count)
            pdf.append(Data("\(index + 1) 0 obj\n\(body)\nendobj\n".utf8))
        }
        let xref = pdf.count
        var table = "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { table += String(format: "%010d 00000 n \n", offset) }
        table += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        pdf.append(Data(table.utf8))
        try pdf.write(to: url)
        return url
    }

    @Test("The adopted original is left out of the annotated export; the markup made from it is written")
    func adoptedOriginalIsNotWrittenTwice() async throws {
        let url = try Self.drawingWithReviewerSquare()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let document = try AppTestSupport.makeDocument(opening: url)
        defer { document.close() }
        #expect(await AppTestSupport.wait { document.core != nil && document.drawing != nil })
        let core = try #require(document.core)
        let drawing = try #require(document.drawing)
        let page = try #require(drawing.pages.first)

        // What adoption leaves behind: the reading, the touched identity, and a markup with it.
        let reading = try ReviewAnnotationReader.read(url: url)
        let original = try #require(reading.annotations.first)
        let identity = AnnotationImportPlanner.identity(of: original, fileDigest: reading.digest)
        _ = try await core.commands.perform(.addMarkup(MarkupRecord(
            id: identity,
            documentID: drawing.documentID,
            pageID: page.id,
            kind: .rectangle,
            geometry: MeasurementGeometry(pageID: page.id, points: [PDFPoint(x: 100, y: 100), PDFPoint(x: 200, y: 160)]),
            createdAt: Date(),
            modifiedAt: Date()
        )))
        await core.commands.settle()
        await core.refresh()
        document.adoptionReading = reading
        document.adoptionTouchedIDs = [identity.rawValue]

        let job = try await StandardAnnotationExport.job(for: document)
        let destination = url.deletingLastPathComponent().appendingPathComponent("export copy.pdf")
        let result = try await StandardAnnotationExport.write(job, to: destination)
        guard case let .incremental(outcome) = result.writer else {
            Issue.record("expected the incremental writer")
            return
        }
        // Old behaviour: the reviewer's square stayed in /Annots beside the markup made from it.
        #expect(outcome.adoptedOriginalCount == 1)
        let annotations = AnnotationProbe.annotations(in: try Data(contentsOf: destination), page: 0)
        #expect(!annotations.contains { $0.name == "reviewer-square" })
        #expect(annotations.contains { $0.name == identity.rawValue.uuidString })
    }
}
