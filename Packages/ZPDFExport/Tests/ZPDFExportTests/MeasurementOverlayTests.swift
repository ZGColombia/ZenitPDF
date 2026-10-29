import Foundation
import Testing
import ZPDFContracts
import ZPDFQuantityLedger
@testable import ZPDFExport

/// Feature 6 — measurements as a shareable file.
///
/// A `.zpdfoverlay` carries the measurements and the identity of the drawing they were measured
/// against. The three things that have to be true: it round-trips a measurement exactly, it
/// refuses a different drawing with the difference stated, and it accepts the same drawing under
/// a new name.
@Suite("Measurement overlay", .sharedHeap)
struct MeasurementOverlayTests {

    // MARK: - Fixtures

    static let sourceDigest = String(repeating: "a1b2", count: 16)
    static let otherDigest = String(repeating: "f0e9", count: 16)

    static let source = ZenitOverlayDocument.Source(
        fileName: "A-101.pdf",
        pageCount: 23,
        digestSHA256: sourceDigest,
        digestByteCount: 4_812_003
    )

    /// Every shape kind at once, with coordinates chosen so that a lossy encoding shows up: a
    /// value that no short decimal represents, a negative, and one past a `Float`'s precision.
    static func geometry() -> MeasurementGeometry {
        let page = PageID(ExportFixture.uuid(-2))
        return MeasurementGeometry(
            pageID: page,
            points: [
                PDFPoint(x: 0.1 + 0.2, y: -0.004),
                PDFPoint(x: 1_234_567.891_234_5, y: 8.125)
            ],
            segments: [
                SegmentGeometry(
                    start: PDFPoint(x: 12.5, y: 33.25),
                    end: PDFPoint(x: -99.125, y: 0.333_333_333_333_333_3)
                )
            ],
            polygons: [
                PolygonGeometry(
                    outer: PolygonRing(
                        points: [
                            PDFPoint(x: 0, y: 0),
                            PDFPoint(x: 100, y: 0),
                            PDFPoint(x: 100, y: 50.75),
                            PDFPoint(x: 0, y: 50.75)
                        ],
                        isClosed: true
                    ),
                    holes: [
                        PolygonRing(
                            points: [
                                PDFPoint(x: 10, y: 10),
                                PDFPoint(x: 20, y: 10),
                                PDFPoint(x: 20, y: 20)
                            ],
                            isClosed: true
                        )
                    ]
                )
            ],
            arcs: [
                ArcGeometry(
                    center: PDFPoint(x: 5, y: 5),
                    radius: 2.5,
                    startAngle: 0.523_598_775_598_298_9,
                    sweepAngle: -1.047_197_551_196_597_8
                )
            ],
            circles: [CircleGeometry(center: PDFPoint(x: -1.5, y: 2.25), radius: 7.125)],
            countPoints: [
                CountPoint(
                    id: CountPointID(ExportFixture.uuid(901)),
                    position: PDFPoint(x: 3.5, y: 4.5),
                    sequenceNumber: 7,
                    groupID: CountGroupID(ExportFixture.uuid(902)),
                    symbolID: nil
                )
            ]
        )
    }

    static func geometryByMarkup() -> [String: MeasurementGeometry] {
        [MarkupID(ExportFixture.uuid(1)).rawValue.uuidString: geometry()]
    }

    static func overlayData(grouped: Bool = false) throws -> Data {
        let projection = try ExportFixture.projection(
            try ExportFixture.goldenReport(grouped: grouped)
        )
        return ZenitOverlayExporter().export(
            projection,
            source: source,
            geometry: geometryByMarkup()
        )
    }

    // MARK: - Round trip

    @Test("An overlay round-trips every measurement's geometry, subject, label and value")
    func roundTripIdentity() throws {
        let projection = try ExportFixture.projection(try ExportFixture.goldenReport())
        let exporter = ZenitOverlayExporter()
        let original = exporter.document(
            from: projection,
            source: Self.source,
            geometry: Self.geometryByMarkup()
        )
        let data = exporter.encode(original)
        let read = try ZenitOverlayImporter().document(from: data)

        #expect(read.source == Self.source)
        #expect(read.measurements.count == projection.table.rows.count)
        #expect(read == original)
        // And the file the reader would write back is the file it read.
        #expect(exporter.encode(read) == data)

        // Geometry, to the bit. `MeasurementGeometry` is `Hashable` over `Double`s, so this is
        // exact equality and not a tolerance.
        let drawn = try #require(read.measurements.first { $0.geometry != nil })
        #expect(drawn.geometry == Self.geometry())
        #expect(try #require(drawn.geometry).points[0].x == 0.1 + 0.2)

        // Subject, label and value: the ledger cells, positional against `columns`.
        let subject = try #require(read.columns.firstIndex { $0.key == "subject" })
        let label = try #require(read.columns.firstIndex { $0.key == "label" })
        let golden = try #require(read.columns.firstIndex { $0.key == "golden" })
        // The cell's unit, not the column's: a dimensionless count carries the base symbol "1".
        let goldenUnit = try #require(projection.table.rows[0].cells[golden].number?.unitSymbol)
        for (index, measurement) in read.measurements.enumerated() {
            #expect(measurement.row.cells[subject] == .text(index % 2 == 0 ? "Concrete" : "Steel"))
            #expect(measurement.row.cells[label] == .text("L\(index)"))
            #expect(measurement.row.cells[golden] == .number(.init(
                raw: ExportFixture.goldenValues[index].description,
                display: ExportFixture.expectedGoldenText[index],
                unit: goldenUnit
            )))
        }
    }

    @Test("A grouped ledger exports every row, not only the ungrouped ones")
    func groupedLedgerExportsEveryRow() throws {
        let read = try ZenitOverlayImporter().document(from: try Self.overlayData(grouped: true))
        #expect(read.measurements.count == ExportFixture.goldenValues.count)
        // Rows only. An overlay carries measurements, never subtotals or a grand total.
        let text = String(decoding: try Self.overlayData(grouped: true), as: UTF8.self)
        #expect(!text.contains("\"grandTotals\""))
        #expect(!text.contains("\"subtotals\""))
        #expect(!text.contains("\"groups\""))
    }

    @Test("The overlay names its source drawing by file name, page count and digest")
    func namesTheDrawing() throws {
        let text = String(decoding: try Self.overlayData(), as: UTF8.self)
        #expect(text.contains("\"format\": \"zenit.measurement.overlay\""))
        #expect(text.contains("\"fileName\": \"A-101.pdf\""))
        #expect(text.contains("\"pageCount\": 23"))
        #expect(text.contains("\"algorithm\": \"SHA-256\""))
        #expect(text.contains("\"sha256\": \"\(Self.sourceDigest)\""))
        #expect(text.contains("\"byteCount\": 4812003"))
        #expect(ZenitOverlayDocument.fileExtension == "zpdfoverlay")
    }

    // MARK: - Import onto the same drawing

    @Test("Importing onto the drawing it was measured on succeeds")
    func matchingDigestImports() throws {
        let result = try ZenitOverlayImporter().import(try Self.overlayData(), onto: Self.source)
        #expect(result.match == .identical)
        #expect(result.document.measurements.count == ExportFixture.goldenValues.count)
    }

    @Test("The same file under a new name is the same drawing, and is allowed")
    func renameIsAllowed() throws {
        let renamed = ZenitOverlayDocument.Source(
            fileName: "A-40 rev C (Anna's copy).pdf",
            pageCount: Self.source.pageCount,
            digestSHA256: Self.source.digestSHA256,
            digestByteCount: Self.source.digestByteCount
        )
        let result = try ZenitOverlayImporter().import(try Self.overlayData(), onto: renamed)
        #expect(result.match == .renamed(
            from: "A-101.pdf",
            to: "A-40 rev C (Anna's copy).pdf"
        ))
        guard case .renamed = result.match else {
            Issue.record("a renamed drawing was not reported as renamed")
            return
        }
        // Renaming changes nothing about what was imported.
        #expect(result.document.measurements.count == ExportFixture.goldenValues.count)
    }

    // MARK: - Refusal

    @Test("A different drawing is refused, with both file names and the difference stated")
    func mismatchIsRefused() throws {
        let other = ZenitOverlayDocument.Source(
            fileName: "B-12-1-50.pdf",
            pageCount: 12,
            digestSHA256: Self.otherDigest,
            digestByteCount: 900_100
        )
        let data = try Self.overlayData()

        var thrown: ExportError?
        do {
            _ = try ZenitOverlayImporter().import(data, onto: other)
            Issue.record("an overlay was imported onto a different drawing")
        } catch let error as ExportError {
            thrown = error
        }

        let error = try #require(thrown)
        guard case .overlaySourceMismatch(let message) = error else {
            Issue.record("expected an overlaySourceMismatch, got \(error)")
            return
        }

        // Both files, named.
        #expect(message.contains("A-101.pdf"))
        #expect(message.contains("B-12-1-50.pdf"))
        // Both digests, shortened enough to compare by eye.
        #expect(message.contains(String(Self.sourceDigest.prefix(12))))
        #expect(message.contains(String(Self.otherDigest.prefix(12))))
        // The difference, stated — all three of them here.
        #expect(message.contains("their contents differ"))
        #expect(message.contains("4812003 and 900100 bytes"))
        #expect(message.contains("23 and 12 pages"))
        #expect(message.contains("not the same drawing"))
        #expect(message.contains("were not imported"))
        // The error's own description is the message; nothing wraps it into a shrug.
        #expect(error.description == message)
    }

    @Test("A drawing with the same page count but different bytes is still refused")
    func editedDrawingIsRefused() throws {
        let edited = ZenitOverlayDocument.Source(
            fileName: Self.source.fileName,
            pageCount: Self.source.pageCount,
            digestSHA256: Self.otherDigest,
            digestByteCount: Self.source.digestByteCount
        )
        #expect(throws: ExportError.self) {
            _ = try ZenitOverlayImporter().import(try Self.overlayData(), onto: edited)
        }
        // The same name, the same page count, one different byte: still a refusal, because the
        // digest is the only thing this decision is allowed to trust.
        do {
            _ = try ZenitOverlayImporter().check(Self.source, against: edited)
            Issue.record("an edited drawing was accepted")
        } catch let error as ExportError {
            guard case .overlaySourceMismatch(let message) = error else {
                Issue.record("expected an overlaySourceMismatch, got \(error)")
                return
            }
            #expect(message.contains("their contents differ"))
            // Only the real difference is stated. The page count and the byte count match, so
            // neither is listed as a reason.
            #expect(!message.contains("they have"))
            #expect(!message.contains("bytes"))
        }
    }

    // MARK: - Malformed input

    @Test("A file that is not an overlay is refused rather than half-read")
    func malformedIsRefused() throws {
        let importer = ZenitOverlayImporter()
        // A `.zpdfjson` is a different format and must not be read as an overlay.
        let ledger = ZenitJSONExporter().export(
            try ExportFixture.projection(try ExportFixture.goldenReport())
        )
        #expect(throws: ExportError.self) { _ = try importer.document(from: ledger) }

        // A geometry whose coordinate is not a decimal string is a corrupt file, not a zero.
        let broken = String(decoding: try Self.overlayData(), as: UTF8.self)
            .replacingOccurrences(of: "\"x\": \"12.5\"", with: "\"x\": \"\"")
        #expect(throws: ExportError.self) {
            _ = try importer.document(from: Data(broken.utf8))
        }
    }
}
