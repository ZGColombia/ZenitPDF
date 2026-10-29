import Foundation
import GRDB
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFPersistence
import ZPDFTestingSupport
import ZPDFUIPresentation

/// ADR-0009 round-trip proof: save a takeoff, reopen it, and get *the same takeoff* —
/// every ledger value digit for digit, every geometry bit for bit, every label, style,
/// scale and cutout link. The archive is written into a real `.zpdfproj` through the
/// real save pipeline; nothing here stubs persistence.
struct TakeoffRoundTripTests {

    // MARK: Fixtures

    private func makeWorkspace(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-roundtrip-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A session over a real fixture page, calibrated 100 pt = 1 m, carrying one of every
    /// takeoff shape the app can produce: a polyline length, a polygon area with a cutout,
    /// and a count with stable point identities — plus non-default parameters on one
    /// markup, so the parameters sidecar is exercised.
    private func makePopulatedSession(
        fixture: OpenedFixture
    ) async throws -> (session: TakeoffSession, ids: [MarkupID]) {
        let session = try TakeoffSession(
            documentID: fixture.documentID,
            pages: fixture.pages,
            units: .metric
        )
        _ = try await session.calibrate(
            page: try #require(await session.firstPageID),
            first: PDFPoint(x: 0, y: 0),
            second: PDFPoint(x: 100, y: 0),
            knownLength: 1,
            knownLengthUnit: .metre
        )

        let pageID = fixture.firstPage.id
        let now = Date(timeIntervalSince1970: 1_787_000_000)
        let length = MarkupRecord(
            id: MarkupID(UUID()),
            documentID: fixture.documentID,
            pageID: pageID,
            kind: .measurement,
            tool: .polylength,
            subject: "Length",
            label: "Length A",
            comment: "corridor east",
            author: "Round Trip",
            style: MarkupStyle(color: RGBAColor(red: 0.3137, green: 0.8392, blue: 0.8706, alpha: 1)),
            geometry: MeasurementGeometry(
                pageID: pageID,
                points: [
                    PDFPoint(x: 10.125, y: 20.375),
                    PDFPoint(x: 110.0625, y: 20.375),
                    PDFPoint(x: 110.0625, y: 95.5)
                ]
            ),
            parameters: .default,
            createdAt: now,
            modifiedAt: now
        )
        let area = MarkupRecord(
            id: MarkupID(UUID()),
            documentID: fixture.documentID,
            pageID: pageID,
            kind: .measurement,
            tool: .area,
            subject: "Area",
            label: "Area A",
            author: "Round Trip",
            style: MarkupStyle(
                color: RGBAColor(red: 0.3137, green: 0.8392, blue: 0.8706, alpha: 1),
                fill: RGBAColor(red: 0.3137, green: 0.8392, blue: 0.8706, alpha: 0.18)
            ),
            geometry: MeasurementGeometry(
                pageID: pageID,
                polygons: [PolygonGeometry(outer: PolygonRing(points: [
                    PDFPoint(x: 200, y: 200),
                    PDFPoint(x: 400.25, y: 200),
                    PDFPoint(x: 400.25, y: 380.75),
                    PDFPoint(x: 200, y: 380.75)
                ], isClosed: true))]
            ),
            parameters: MeasurementParameters(perimeterPolicy: .outerPlusCutoutEdges),
            createdAt: now,
            modifiedAt: now
        )
        let cutout = MarkupRecord(
            id: MarkupID(UUID()),
            documentID: fixture.documentID,
            pageID: pageID,
            kind: .polygon,
            tool: .polygonCutout,
            subject: "Cutout",
            label: "Cutout A",
            author: "Round Trip",
            style: .default,
            geometry: MeasurementGeometry(
                pageID: pageID,
                polygons: [PolygonGeometry(outer: PolygonRing(points: [
                    PDFPoint(x: 250, y: 250),
                    PDFPoint(x: 300, y: 250),
                    PDFPoint(x: 300, y: 300),
                    PDFPoint(x: 250, y: 300)
                ], isClosed: true))]
            ),
            createdAt: now,
            modifiedAt: now
        )
        let count = MarkupRecord(
            id: MarkupID(UUID()),
            documentID: fixture.documentID,
            pageID: pageID,
            kind: .measurement,
            tool: .count,
            subject: "Count",
            label: "Count A",
            author: "Round Trip",
            style: .default,
            geometry: MeasurementGeometry(
                pageID: pageID,
                countPoints: [
                    CountPoint(id: CountPointID(UUID()), position: PDFPoint(x: 33.5, y: 44.25), sequenceNumber: 1),
                    CountPoint(id: CountPointID(UUID()), position: PDFPoint(x: 66.125, y: 77.875), sequenceNumber: 2)
                ]
            ),
            createdAt: now,
            modifiedAt: now
        )

        _ = try await session.apply(.addMarkup(length))
        _ = try await session.apply(.addMarkup(area))
        _ = try await session.apply(.addCutout(parent: area.id, cutout: cutout))
        _ = try await session.apply(.addMarkup(count))
        // A custom ledger cell with a high-precision decimal, so custom_values_json is
        // exercised end to end.
        _ = try await session.apply(.editCustomValue(
            id: length.id,
            column: ColumnID(UUID()),
            value: .currency(amount: Decimal(string: "1234.565", locale: nil)!, code: "SEK")
        ))
        return (session, [length.id, area.id, cutout.id, count.id])
    }

    private func ledgerStrings(of session: TakeoffSession) async throws -> [[String]] {
        let projection = try await session.ledgerProjection()
        var rows: [[String]] = []
        for index in 0..<projection.rowCount {
            guard let row = projection.row(at: index) else { continue }
            rows.append(projection.columns.map { row.displayValue($0.id) })
        }
        return rows
    }

    // MARK: Tests

    @Test("Save, reopen, compare: ledger values digit for digit, geometry exactly")
    func fullRoundTrip() async throws {
        let workspace = try makeWorkspace("full")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let fixture = try await OpenedFixture.open(.titleBlockSheet, in: workspace)
        let (session, ids) = try await makePopulatedSession(fixture: fixture)

        let stateBefore = await session.takeoffState()
        let ledgerBefore = try await ledgerStrings(of: session)
        #expect(ledgerBefore.count == 4, "expected four ledger rows before the save")

        // ── Save through the real package pipeline ─────────────────────────────────
        let packageURL = workspace.appendingPathComponent("RoundTrip.zpdfproj", isDirectory: true)
        let package = try await ProjectPackage.create(
            at: packageURL, displayName: "RoundTrip", originalPDF: fixture.url
        )
        try await TakeoffArchive.write(stateBefore, into: package)
        _ = try await package.save()
        try await package.close()

        // ── Reopen: fresh page ids adopt the stored identity, session hydrates ─────
        guard case .opened(let reopened) = try await ProjectPackage.open(at: packageURL) else {
            Issue.record("reopen required recovery")
            return
        }
        let stored = try await TakeoffArchive.read(from: reopened)
        let storedTakeoff = try #require(stored)
        #expect(storedTakeoff.hasSavedTakeoff)

        // A fresh open mints fresh page ids, exactly like the app does.
        let freshPages = fixture.pages.map { page in
            var fresh = page
            fresh.id = PageID(UUID())
            return fresh
        }
        let adopted = TakeoffArchive.adoptingStoredPageIDs(freshPages, stored: storedTakeoff)
        #expect(adopted.map(\.id) == fixture.pages.map(\.id),
                "stored page identity was not adopted")

        let restored = try TakeoffSession(
            documentID: DocumentID(UUID()),
            pages: adopted,
            units: .metric
        )
        try await restored.hydrate(
            markups: storedTakeoff.markups,
            scales: storedTakeoff.scales,
            pageScaleIDs: storedTakeoff.pageScaleIDs
        )

        // ── Scale ───────────────────────────────────────────────────────────────────
        let scaleBefore = try #require(await session.firstPageScale)
        let scaleAfter = try #require(await restored.firstPageScale)
        #expect(scaleAfter == scaleBefore, "the default scale did not round-trip exactly")

        // ── Markups: order, identity, geometry, style, text, links ─────────────────
        let before = stateBefore.markups
        let after = await restored.takeoffState().markups
        #expect(after.map(\.id) == before.map(\.id), "draw order or identity changed")
        for (original, hydrated) in zip(before, after) {
            #expect(hydrated.geometry == original.geometry,
                    "geometry of \(original.subject) is not exactly equal")
            #expect(hydrated.style == original.style)
            #expect(hydrated.subject == original.subject)
            #expect(hydrated.label == original.label)
            #expect(hydrated.comment == original.comment)
            #expect(hydrated.author == original.author)
            #expect(hydrated.kind == original.kind)
            #expect(hydrated.tool == original.tool)
            #expect(hydrated.parameters == original.parameters
                        || (hydrated.parameters == nil && original.parameters == .default),
                    "parameters of \(original.subject) did not round-trip")
            #expect(hydrated.parentMarkupID == original.parentMarkupID)
            #expect(hydrated.cutoutMarkupIDs == original.cutoutMarkupIDs)
            #expect(hydrated.customValues == original.customValues,
                    "custom ledger cells of \(original.subject) did not round-trip")
            #expect(hydrated.scaleID == original.scaleID)
            #expect(hydrated.scaleVersion == original.scaleVersion)
            #expect(hydrated.measurement?.values == original.measurement?.values,
                    "measured values of \(original.subject) are not digit-for-digit equal")
        }

        // ── Ledger: every display string digit for digit ────────────────────────────
        let ledgerAfter = try await ledgerStrings(of: restored)
        #expect(ledgerAfter == ledgerBefore, "the reopened ledger does not match the saved one")

        // ── The stored measurement_value strings equal the recomputed values ────────
        struct StoredValueRow: Sendable {
            let markupId: String
            let planLength: String?
            let planArea: String?
            let count: String?
        }
        let storedValues = try await reopened.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT markup_id, plan_length_si, plan_area_si, count_value FROM measurement_value"
            ).map { row in
                StoredValueRow(
                    markupId: row["markup_id"] ?? "",
                    planLength: row["plan_length_si"],
                    planArea: row["plan_area_si"],
                    count: row["count_value"]
                )
            }
        }
        #expect(storedValues.count == ids.count)
        for row in storedValues {
            let markupID = MarkupID(uuidString: row.markupId)
            let hydrated = await restored.markup(try #require(markupID))
            let record = try #require(hydrated)
            if let stored = row.planLength, let quantity = record.measurement?.values[.planLength] {
                #expect(ZPDFPersistence.DecimalString(quantity.value)?.canonicalText == stored)
            }
            if let stored = row.planArea, let quantity = record.measurement?.values[.planArea] {
                #expect(ZPDFPersistence.DecimalString(quantity.value)?.canonicalText == stored)
            }
            if let stored = row.count, let quantity = record.measurement?.values[.count] {
                #expect(ZPDFPersistence.DecimalString(quantity.value)?.canonicalText == stored)
            }
        }
        try await reopened.close()
    }

    @Test("Hydration registers no undo, and new commands undo cleanly on top of it")
    @MainActor
    func hydrationLeavesUndoFresh() async throws {
        let workspace = try makeWorkspace("undo")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let fixture = try await OpenedFixture.open(.titleBlockSheet, in: workspace)
        let (session, _) = try await makePopulatedSession(fixture: fixture)

        let packageURL = workspace.appendingPathComponent("Undo.zpdfproj", isDirectory: true)
        let package = try await ProjectPackage.create(
            at: packageURL, displayName: "Undo", originalPDF: fixture.url
        )
        try await TakeoffArchive.write(await session.takeoffState(), into: package)
        _ = try await package.save()
        try await package.close()

        guard case .opened(let reopened) = try await ProjectPackage.open(at: packageURL) else {
            Issue.record("reopen required recovery")
            return
        }
        let storedTakeoff = try #require(try await TakeoffArchive.read(from: reopened))
        let restoredDocumentID = DocumentID(UUID())
        let restored = try TakeoffSession(
            documentID: restoredDocumentID,
            pages: TakeoffArchive.adoptingStoredPageIDs(fixture.pages, stored: storedTakeoff),
            units: .metric
        )
        try await restored.hydrate(
            markups: storedTakeoff.markups,
            scales: storedTakeoff.scales,
            pageScaleIDs: storedTakeoff.pageScaleIDs
        )
        try await reopened.close()

        let environment = try await AppCoreEnvironment.make(
            session: restored, documentID: DocumentID(UUID())
        )
        // Undo starts fresh: nothing from before the open is on the stack.
        #expect(!environment.commands.undoManager.canUndo)

        // A new markup on top of the hydrated state is fully undoable and redoable.
        let hydratedCount = await restored.orderedMarkups.count
        let pageID = fixture.firstPage.id
        let fresh = MarkupRecord(
            id: MarkupID(UUID()),
            documentID: restoredDocumentID,
            pageID: pageID,
            kind: .measurement,
            tool: .polylength,
            subject: "New after reopen",
            geometry: MeasurementGeometry(
                pageID: pageID,
                points: [PDFPoint(x: 1, y: 1), PDFPoint(x: 51, y: 1)]
            ),
            createdAt: Date(),
            modifiedAt: Date()
        )
        _ = try await environment.commands.perform(.addMarkup(fresh))
        #expect(await restored.orderedMarkups.count == hydratedCount + 1)
        await environment.commands.undo()
        #expect(await restored.orderedMarkups.count == hydratedCount,
                "undo of a post-hydration command must remove only that command")
        await environment.commands.redo()
        #expect(await restored.orderedMarkups.count == hydratedCount + 1)
    }

    @Test("An uncalibrated saved takeoff hydrates its geometry and stays honestly valueless")
    func uncalibratedRoundTrip() async throws {
        let workspace = try makeWorkspace("noscale")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let fixture = try await OpenedFixture.open(.titleBlockSheet, in: workspace)
        let session = try TakeoffSession(documentID: fixture.documentID, pages: fixture.pages)
        let pageID = fixture.firstPage.id
        let record = MarkupRecord(
            id: MarkupID(UUID()),
            documentID: fixture.documentID,
            pageID: pageID,
            kind: .measurement,
            tool: .polylength,
            subject: "Unscaled",
            geometry: MeasurementGeometry(
                pageID: pageID,
                points: [PDFPoint(x: 0, y: 0), PDFPoint(x: 10, y: 0)]
            ),
            createdAt: Date(),
            modifiedAt: Date()
        )
        _ = try await session.apply(.addMarkup(record))

        let packageURL = workspace.appendingPathComponent("NoScale.zpdfproj", isDirectory: true)
        let package = try await ProjectPackage.create(
            at: packageURL, displayName: "NoScale", originalPDF: fixture.url
        )
        try await TakeoffArchive.write(await session.takeoffState(), into: package)
        _ = try await package.save()
        try await package.close()

        guard case .opened(let reopened) = try await ProjectPackage.open(at: packageURL) else {
            Issue.record("reopen required recovery")
            return
        }
        let storedTakeoff = try #require(try await TakeoffArchive.read(from: reopened))
        try await reopened.close()
        #expect(storedTakeoff.scales.isEmpty)
        #expect(storedTakeoff.pageScaleIDs.isEmpty)
        let restored = try TakeoffSession(
            documentID: DocumentID(UUID()),
            pages: TakeoffArchive.adoptingStoredPageIDs(fixture.pages, stored: storedTakeoff)
        )
        try await restored.hydrate(
            markups: storedTakeoff.markups,
            scales: storedTakeoff.scales,
            pageScaleIDs: [:]
        )
        let hydrated = try #require(await restored.markup(record.id))
        #expect(hydrated.geometry == record.geometry)
        #expect(hydrated.measurement == nil, "no scale must mean no invented number")
    }

    @Test("A read row's provenance and derivation survive save and reopen — never .measured")
    func readProvenanceRoundTrips() async throws {
        let workspace = try makeWorkspace("provenance")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let fixture = try await OpenedFixture.open(.titleBlockSheet, in: workspace)
        let session = try TakeoffSession(
            documentID: fixture.documentID,
            pages: fixture.pages,
            units: .metric
        )
        let pageID = fixture.firstPage.id
        let now = Date(timeIntervalSince1970: 1_787_000_000)
        let derivation = QuantityDerivation(
            sourceMarkupID: nil,
            formulaText: "D01  915 × 2 110",
            inputs: ["row": "3", "column": "Width"],
            originIdentifier: "page:1/region:10,10,200,80/row:3"
        )
        let readRow = MarkupRecord(
            id: MarkupID(UUID()),
            documentID: fixture.documentID,
            pageID: pageID,
            kind: .measurement,
            tool: .count,
            subject: "Door schedule row",
            geometry: MeasurementGeometry(
                pageID: pageID,
                points: [PDFPoint(x: 50, y: 60)]
            ),
            provenance: .read,
            derivation: derivation,
            createdAt: now,
            modifiedAt: now
        )
        let measuredRow = MarkupRecord(
            id: MarkupID(UUID()),
            documentID: fixture.documentID,
            pageID: pageID,
            kind: .measurement,
            tool: .count,
            subject: "Counted by hand",
            geometry: MeasurementGeometry(
                pageID: pageID,
                points: [PDFPoint(x: 80, y: 60)]
            ),
            createdAt: now,
            modifiedAt: now
        )
        _ = try await session.apply(.addMarkup(readRow))
        _ = try await session.apply(.addMarkup(measuredRow))

        let packageURL = workspace.appendingPathComponent("Provenance.zpdfproj", isDirectory: true)
        let package = try await ProjectPackage.create(
            at: packageURL, displayName: "Provenance", originalPDF: fixture.url
        )
        try await TakeoffArchive.write(await session.takeoffState(), into: package)
        _ = try await package.save()
        try await package.close()

        guard case .opened(let reopened) = try await ProjectPackage.open(at: packageURL) else {
            Issue.record("reopen required recovery")
            return
        }
        let storedTakeoff = try #require(try await TakeoffArchive.read(from: reopened))
        try await reopened.close()

        let readBack = try #require(storedTakeoff.markups.first { $0.id == readRow.id })
        // A read row rehydrating as .measured would silently upgrade its claim from
        // "printed on the sheet" to "someone measured this" — ADR-0012's whole point.
        #expect(readBack.provenance == .read)
        #expect(readBack.derivation == derivation,
                "the OCR text and origin must survive byte for byte")

        let measuredBack = try #require(storedTakeoff.markups.first { $0.id == measuredRow.id })
        #expect(measuredBack.provenance == .measured)
        #expect(measuredBack.derivation == nil)
    }
}
