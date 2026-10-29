import Foundation
import Testing
@testable import ZPDFAppCore
import ZPDFContracts
import ZPDFPersistence
import ZPDFTestingSupport
import ZPDFUIPresentation

/// ADR-0031 (NL-AUTO-18) in the session: a detector's accepted area records how it was captured,
/// keeps it across a recalculation, and loses it — manual — when a person edits the geometry.
/// Values are hand-derived: a 200 × 100 pt rectangle at 100 pt = 1 m is 2 m²; at 50 pt = 1 m, 8 m².
@Suite("Capture method recording")
struct CaptureMethodRecordingTests {

    static func session(_ fixture: OpenedFixture) async throws -> (TakeoffSession, PageID) {
        let session = try TakeoffSession(documentID: fixture.documentID, pages: fixture.pages, units: .metric)
        let page = fixture.firstPage.id
        _ = try await session.calibrate(page: page, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
                                        knownLength: 1, knownLengthUnit: .metre)
        return (session, page)
    }

    static func area(_ fixture: OpenedFixture, page: PageID) -> ZPDFContracts.MarkupRecord {
        let now = Date(timeIntervalSince1970: 1_789_000_000)
        return ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: fixture.documentID, pageID: page, kind: .measurement, tool: .area,
            subject: "Room", label: "R1", author: "Estimator", style: .default,
            geometry: MeasurementGeometry(pageID: page, polygons: [PolygonGeometry(outer: PolygonRing(points: [
                PDFPoint(x: 100, y: 100), PDFPoint(x: 300, y: 100), PDFPoint(x: 300, y: 200), PDFPoint(x: 100, y: 200),
            ], isClosed: true))]),
            createdAt: now, modifiedAt: now)
    }

    @Test("A stamped trace is computed by the session with its capture kept; the stamp supplies no value")
    func stampedAreaKeepsCapture() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let fixture = try await OpenedFixture.open(.titleBlockSheet, in: directory.url)
        let (session, page) = try await Self.session(fixture)
        let record = Self.area(fixture, page: page)
        let stamped = CaptureStamp.stamped(record, method: .autoTraced(closureWidthsPoints: [25.4]))
        #expect(stamped.measurement?.values.isEmpty == true, "a stamp never carries a number")
        _ = try await session.apply(.addMarkup(stamped))

        let stored = try #require(await session.markup(record.id))
        #expect(stored.measurement?.values[.planArea]?.value == 2)
        let provenance = try #require(stored.measurement?.provenance)
        #expect(provenance.capture.kind == .autoTraced)
        #expect(provenance.capture.closureWidthsPoints == [25.4])
        #expect(provenance.engineVersion != "capture-stamp", "the session's own provenance, not the stamp")
        let facts = DerivationBridge.sections(for: provenance, pageLabel: nil, scaleName: nil).flatMap(\.facts)
        #expect(facts.contains(LedgerDerivationFact(key: "geometry.capture", value: "traced, 1 closing line 25.4 pt")))
    }

    @Test("A recalculation at a new scale keeps the capture; moving the geometry makes it manual")
    func carriedThenDropped() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let fixture = try await OpenedFixture.open(.titleBlockSheet, in: directory.url)
        let (session, page) = try await Self.session(fixture)
        let record = Self.area(fixture, page: page)
        _ = try await session.apply(.addMarkup(CaptureStamp.stamped(record, method: CaptureMethod(kind: .roomDetected))))

        _ = try await session.calibrate(page: page, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 50, y: 0),
                                        knownLength: 1, knownLengthUnit: .metre)
        _ = try await session.apply(.recalculateMeasurements(pageID: page))
        let recalculated = try #require(await session.markup(record.id))
        #expect(recalculated.measurement?.values[.planArea]?.value == 8)
        #expect(recalculated.measurement?.provenance?.capture.kind == .roomDetected)

        _ = try await session.apply(.moveMarkup(id: record.id, dx: 10, dy: 0))
        let moved = try #require(await session.markup(record.id))
        #expect(moved.measurement?.provenance?.captureMethod == nil)
        #expect(moved.measurement?.provenance?.capture == .manual)
    }

    @Test("An unstamped area is manual, and the derivation says it was drawn by hand")
    func manualByDefault() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let fixture = try await OpenedFixture.open(.titleBlockSheet, in: directory.url)
        let (session, page) = try await Self.session(fixture)
        let record = Self.area(fixture, page: page)
        _ = try await session.apply(.addMarkup(record))
        let provenance = try #require(await session.markup(record.id)?.measurement?.provenance)
        #expect(provenance.captureMethod == nil)
        #expect(CaptureDescription.text(provenance.capture) == "drawn by hand")
        #expect(CaptureDescription.text(CaptureMethod(kind: .symbolMatched, residualRatio: 0.031, isMirrored: true)) == "matched, residual 0.031, mirrored")
        #expect(CaptureDescription.text(CaptureMethod(kind: .fromScan, confidence: 0.62)) == "from the scan, 62 % sure")
        #expect(CaptureDescription.text(CaptureMethod(kind: .wallCentreline, wallThicknessMetres: Decimal(string: "0.15"))) == "wall centreline, 150 mm wall")
    }

    @Test("The capture survives a save and a reopen through the real package")
    func survivesSave() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let fixture = try await OpenedFixture.open(.titleBlockSheet, in: directory.url)
        let (session, page) = try await Self.session(fixture)
        let record = Self.area(fixture, page: page)
        _ = try await session.apply(.addMarkup(CaptureStamp.stamped(record, method: .autoTraced(closureWidthsPoints: [25.4, 30]))))
        let url = directory.url.appendingPathComponent("Capture.zpdfproj", isDirectory: true)
        let package = try await ProjectPackage.create(at: url, displayName: "Capture", originalPDF: fixture.url)
        try await TakeoffArchive.write(await session.takeoffState(), into: package)
        _ = try await package.save()
        try await package.close()
        guard case .opened(let reopened) = try await ProjectPackage.open(at: url) else {
            Issue.record("reopen required recovery")
            return
        }
        let stored = try #require(try await TakeoffArchive.read(from: reopened))
        try await reopened.close()
        let markup = try #require(stored.markups.first { $0.id == record.id })
        #expect(markup.measurement?.provenance?.capture.kind == .autoTraced)
        #expect(markup.measurement?.provenance?.capture.closureWidthsPoints == [25.4, 30])

        // Hydrated into a fresh session, as the app opens a project: recomputed, capture kept.
        let restored = try TakeoffSession(documentID: fixture.documentID,
                                          pages: TakeoffArchive.adoptingStoredPageIDs(fixture.pages, stored: stored), units: .metric)
        try await restored.hydrate(markups: stored.markups, scales: stored.scales, pageScaleIDs: stored.pageScaleIDs)
        let hydrated = try #require(await restored.markup(record.id))
        #expect(hydrated.measurement?.values[.planArea]?.value == 2)
        #expect(hydrated.measurement?.provenance?.capture.closureWidthsPoints == [25.4, 30])
        #expect(hydrated.measurement?.provenance?.engineVersion != "capture-stamp")
    }

    @Test("A room accepted on a sheet with no scale is still a detected room once the sheet is calibrated — across a save too")
    func setAsideUntilCalibrated() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let fixture = try await OpenedFixture.open(.titleBlockSheet, in: directory.url)
        let session = try TakeoffSession(documentID: fixture.documentID, pages: fixture.pages, units: .metric)
        let page = fixture.firstPage.id
        let record = Self.area(fixture, page: page)
        _ = try await session.apply(.addMarkup(CaptureStamp.stamped(record, method: CaptureMethod(kind: .roomDetected))))
        #expect(await session.markup(record.id)?.measurement == nil, "no scale, no number — and no stamp posing as one")
        #expect(await session.uncalibratedCapture(of: record.id)?.kind == .roomDetected)

        // Saved and reopened before the calibration: the set-aside method is in the file.
        let url = directory.url.appendingPathComponent("Uncalibrated.zpdfproj", isDirectory: true)
        let package = try await ProjectPackage.create(at: url, displayName: "Uncalibrated", originalPDF: fixture.url)
        try await TakeoffArchive.write(await session.takeoffState(), into: package)
        _ = try await package.save()
        try await package.close()
        guard case .opened(let reopened) = try await ProjectPackage.open(at: url) else {
            Issue.record("reopen required recovery")
            return
        }
        let stored = try #require(try await TakeoffArchive.read(from: reopened))
        try await reopened.close()
        let restored = try TakeoffSession(documentID: fixture.documentID,
                                          pages: TakeoffArchive.adoptingStoredPageIDs(fixture.pages, stored: stored), units: .metric)
        try await restored.hydrate(markups: stored.markups, scales: stored.scales, pageScaleIDs: stored.pageScaleIDs)
        #expect(await restored.uncalibratedCapture(of: record.id)?.kind == .roomDetected)

        // Calibrated at 100 pt = 1 m: the 200 × 100 pt room is 2 m², and it says it was detected.
        let restoredPage = try #require(await restored.markup(record.id)).pageID
        _ = try await restored.calibrate(page: restoredPage, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
                                         knownLength: 1, knownLengthUnit: .metre)
        _ = try await restored.apply(.recalculateMeasurements(pageID: restoredPage))
        let measured = try #require(await restored.markup(record.id))
        #expect(measured.measurement?.values[.planArea]?.value == 2)
        #expect(measured.measurement?.provenance?.capture.kind == .roomDetected)
        #expect(await restored.uncalibratedCapture(of: record.id) == nil)
    }

    @Test("Reshaped by hand while waiting for a scale, a detected room reads as drawn by hand")
    func setAsideDroppedOnEdit() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let fixture = try await OpenedFixture.open(.titleBlockSheet, in: directory.url)
        let session = try TakeoffSession(documentID: fixture.documentID, pages: fixture.pages, units: .metric)
        let page = fixture.firstPage.id
        let record = Self.area(fixture, page: page)
        _ = try await session.apply(.addMarkup(CaptureStamp.stamped(record, method: CaptureMethod(kind: .roomDetected))))
        _ = try await session.apply(.moveMarkup(id: record.id, dx: 10, dy: 0))
        #expect(await session.uncalibratedCapture(of: record.id) == nil)
        _ = try await session.calibrate(page: page, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
                                        knownLength: 1, knownLengthUnit: .metre)
        _ = try await session.apply(.recalculateMeasurements(pageID: page))
        #expect(await session.markup(record.id)?.measurement?.provenance?.capture == .manual)
    }

    @Test("A measurement read from a PDF annotation is measured by Zenit and says it was read from the file")
    func importedAnnotationIsTagged() async throws {
        let documentID = DocumentID(UUID())
        let pages = [ZPDFContracts.PageDescriptor(id: PageID(UUID()), documentID: documentID, index: 0, label: "A-0",
                                                  boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 1000, height: 1000)))]
        let session = try TakeoffSession(documentID: documentID, pages: pages)
        // 100 pt = 5 m: a 200 pt LineDimension is 10 m by Zenit's scale, whatever the file said.
        _ = try await session.calibrate(page: pages[0].id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
                                        knownLength: 5, knownLengthUnit: .metre)
        let annotations = [ImportedAnnotation(index: 0, pageIndex: 0, subtype: "Line", contents: "9.80 m",
                                              rect: PDFRect(x: 0, y: 0, width: 200, height: 10),
                                              points: [PDFPoint(x: 0, y: 0), PDFPoint(x: 200, y: 0)], intent: "LineDimension")]
        let plan = AnnotationImportPlanner.plan(annotations: annotations, pages: pages, documentID: documentID,
                                                existingMarkupIDs: [], existingReplyIDs: [], fileDigest: "abc")
        let converted = MeasuredAnnotationImport.converting(plan, annotations: annotations, fileDigest: "abc", calibratedPages: [pages[0].id])
        let line = try #require(converted.newMarkups.first)
        #expect(line.measurement?.values.isEmpty == true, "the file's number never enters as a value")
        _ = try await session.applyBatch(converted.newMarkups.map { .addMarkup($0) })
        let measured = try #require(await session.markup(line.id))
        #expect(measured.measurement?.values[.planLength]?.value == 10)
        let provenance = try #require(measured.measurement?.provenance)
        #expect(provenance.capture.kind == .importedAnnotation)
        #expect(CaptureDescription.text(provenance.capture) == "read from file")
    }
}
