import CoreGraphics
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFExport
import ZPDFGeometry
import ZPDFPDFKitBridge
import ZPDFPersistence
import ZPDFQuantityLedger
import ZPDFSnapEngine
import ZPDFTestingSupport
import ZPDFUIPresentation
import ZPDFVectorExtraction
import ZenitPDFAppKit

/// The CORE_LOOP acceptance test, on a heavy A1 roof plan (`RoofPlanSheet`).
///
/// `Docs/Design/CORE_LOOP.md`, "The acceptance test":
///
///     open fixture      → assert first-page render and unchanged input hash
///     calibrate         → assert the scale bit-exactly
///     draw a polyline length and a polygon area with one cutout
///                       → assert both against hand-derived values
///     read the ledger   → assert rows, units and totals
///     export CSV + PDF  → assert digit-for-digit equality with the ledger
///     undo everything   → assert the project returns to its opening state
///
/// plus the per-step action budgets (calibrate ≤ 4, export ≤ 3) and the silent-wrongness
/// guards that are testable at this level. Everything below runs on the shipping engines
/// and the same presenters the windows bind to; the only things a real session has that
/// this one does not are pixels.
@Suite("CORE_LOOP acceptance — the Synthetic Roof Plan")
struct CoreLoopAcceptanceTests {

    @Test("The whole loop, on the A1 roof plan")
    @MainActor
    func theLoop() async throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }

        // ══════════════════════════════════════════════════════════════════════════
        // 1 ─ OPEN: the app's own loader, the file's identity, and a real first render.
        // ══════════════════════════════════════════════════════════════════════════

        // Generated into this run's own scratch directory: nothing else can share the file.
        let url = try RoofPlanSheet.generate(in: scratch.url)
        try #require(FileManager.default.fileExists(atPath: url.path), "the sheet was not written at \(url.path)")

        // The identity of the input, computed here with CryptoKit — no shared code with
        // the bridge digest it is about to be compared against.
        // It must be the pinned, versioned sheet — the gate must not run against a different
        // drawing and call it the same sign-off.
        let before = try independentSHA256(of: url)
        #expect(before.hex == RoofPlanSheet.sha256, "\(RoofPlanSheet.identityName) is pinned to other bytes")
        #expect(before.byteCount == RoofPlanSheet.byteCount)

        let loaded = try await DocumentSessionLoader.load(pdfAt: url)
        #expect(loaded.digest.sha256 == RoofPlanSheet.sha256, "the loader saw the same bytes")
        #expect(loaded.digest.byteCount == RoofPlanSheet.byteCount)
        #expect(loaded.pages.count == 1)

        let page = loaded.pages[0]
        #expect(abs(page.boxes.crop.width - RoofPlanSheet.cropWidth) < 0.01)
        #expect(abs(page.boxes.crop.height - RoofPlanSheet.cropHeight) < 0.01)

        // First-page render through the app's raster source. Non-vacuous: the image must
        // have real pixels and real ink, not merely exist.
        let image = try await loaded.rasterSource.render(
            pageIndex: 0,
            displaySize: CGSize(width: RoofPlanSheet.cropWidth, height: RoofPlanSheet.cropHeight),
            requestedScale: 0.25
        )
        #expect(image.width >= 500 && image.height >= 350)
        #expect(Self.containsInk(image), "the rendered first page must not be blank")
        print("CORE-LOOP OPEN-OK fixture=\(RoofPlanSheet.identityName) sha256=\(loaded.digest.sha256) render=\(image.width)x\(image.height)")

        // The session and the presenters — the same composition `ZenitPDFProjectDocument`
        // builds for a window.
        let session = try TakeoffSession(
            documentID: loaded.documentID,
            pages: loaded.pages,
            units: .metric
        )
        let environment = try await AppCoreEnvironment.make(
            session: session,
            documentID: loaded.documentID
        )
        #expect(environment.ledger.isEmpty, "the ledger opens empty")
        #expect(await session.firstPageScale == nil, "the drawing opens uncalibrated")

        // Vector Snap over the real linework.
        let extraction = try await VectorExtractor().extract(documentAt: url, pageIndex: 0)
        #expect(extraction.primitives.count == RoofPlanSheet.primitiveCount, "the sheet's hand-counted primitives")
        let availability = try await session.buildSnapIndex(page: page, extraction: extraction)
        #expect(availability.allowsVectorCandidates, "the sheet is vector, so Vector Snap is live")

        let layout = PageViewLayout(zoom: 1, backingScale: 2)

        // ══════════════════════════════════════════════════════════════════════════
        // 2 ─ CALIBRATE: two snapped clicks on the sheet's 100 mm control ruler, one
        //     typed value, within CORE_LOOP's four-action budget.
        // ══════════════════════════════════════════════════════════════════════════

        var calibrateActions = ActionCounter(step: "Calibrate")

        // Action 1: arm the calibrate tool (menu item / toolbar button — one click).
        calibrateActions.tap("arm Calibrate")

        // Action 2: click near the left tick foot. The snap engine must land the point
        // exactly on the endpoint the file draws, and must say what it snapped to.
        calibrateActions.tap("click point A")
        let a = try await session.resolveSnap(
            pageID: page.id,
            pagePoint: RoofPlanSheet.clickNearLeft,
            layout: layout
        )
        let winnerA = try #require(a.winner, "the tick foot is 2.83 pt away — inside the radius")
        #expect(winnerA.kind == .endpoint, "the calibration anchor is a drawn endpoint")
        #expect(a.feedback != nil, "the snap kind is named on screen, not just highlighted")
        #expect(abs(a.resolvedPagePoint.x - RoofPlanSheet.stripLeft.x) < 1e-9)
        #expect(abs(a.resolvedPagePoint.y - RoofPlanSheet.stripLeft.y) < 1e-9)

        // Action 3: click near the right tick foot.
        calibrateActions.tap("click point B")
        let b = try await session.resolveSnap(
            pageID: page.id,
            pagePoint: RoofPlanSheet.clickNearRight,
            layout: layout
        )
        let winnerB = try #require(b.winner)
        #expect(winnerB.kind == .endpoint)
        #expect(abs(b.resolvedPagePoint.x - RoofPlanSheet.stripRight.x) < 1e-9)
        #expect(abs(b.resolvedPagePoint.y - RoofPlanSheet.stripRight.y) < 1e-9)

        // Action 4: type the known length — 5 000 mm, because the strip is 100 mm of
        // paper and the title block prints SKALA 1:50 with measurements in millimetres.
        calibrateActions.tap("type 5000 mm")
        try await environment.commands.calibrate(
            page: try #require(await session.firstPageID),
            first: a.resolvedPagePoint,
            second: b.resolvedPagePoint,
            knownLength: RoofPlanSheet.knownLengthMillimetres,
            knownLengthUnit: .millimetre,
            label: "Measurement-control ruler, 100 mm at 1:50"
        )
        calibrateActions.assertWithinBudget(4)

        let scale = try #require(await session.firstPageScale)
        #expect(scale.matrix.isUniform)
        // Hand-derivation: 5.0 m / 283.464566929134 pt = 0.01763888888888888 m/pt.
        let mpp = scale.matrix.metresPerPointX
        #expect(abs(mpp - RoofPlanSheet.metresPerPoint) < 1e-15)

        // The feedback is stated in words: the sheet's printed 1:50, recovered from
        // nothing but two snapped points and a typed length.
        await environment.refresh()
        #expect(environment.snapshot.firstPageScale?.displayString == "1:50")

        // Bit-exact reproducibility: a fresh session, the same two snapped points, the
        // same typed value — the same matrix, digit for digit, bit for bit.
        let replaySession = try TakeoffSession(
            documentID: loaded.documentID,
            pages: loaded.pages,
            units: .metric
        )
        _ = try await replaySession.calibrate(
            page: try #require(await replaySession.firstPageID),
            first: a.resolvedPagePoint,
            second: b.resolvedPagePoint,
            knownLength: RoofPlanSheet.knownLengthMillimetres,
            knownLengthUnit: .millimetre
        )
        let replayed = try #require(await replaySession.firstPageScale)
        #expect(replayed.matrix == scale.matrix, "same inputs, bit-identical scale")
        #expect(
            String(describing: replayed.matrix) == String(describing: scale.matrix),
            "and the same digits when printed"
        )
        print("CORE-LOOP CALIBRATE-OK actions=\(calibrateActions.count) scale=1:50 mpp=\(mpp)")

        // ══════════════════════════════════════════════════════════════════════════
        // 3 ─ MEASURE: a polyline length and a polygon area with one cutout, driven
        //     through the measurement presenter exactly as the canvas drives it.
        // ══════════════════════════════════════════════════════════════════════════

        let measurement = environment.measurement
        measurement.layout = layout
        measurement.author = "Acceptance test"

        // -- The polyline -------------------------------------------------------------
        measurement.defaultSubject = "Roof edge"
        measurement.activate(kind: .polylength)
        measurement.placePoint(RoofPlanSheet.polyA)
        measurement.placePoint(RoofPlanSheet.polyB)
        measurement.placePoint(RoofPlanSheet.polyC)
        await measurement.settlePlacements()

        // The picked vertices are ≥ 15 pt from all linework and ≥ 6 pt from the 36 pt
        // grid, so no snap may have moved them — the hand-derivation depends on it.
        #expect(measurement.placedPoints == [RoofPlanSheet.polyA, RoofPlanSheet.polyB, RoofPlanSheet.polyC])

        // The live readout runs while drawing, in the output unit. Previews supersede one
        // another, so wait for the three-point readout, not merely for any readout.
        measurement.schedulePreview()
        try await eventually("the live three-point polyline readout") {
            measurement.liveFields.first { $0.field == .planLength }?.displayText
                == RoofPlanSheet.expectedPolylineText
        }
        let liveLength = try #require(measurement.liveFields.first { $0.field == .planLength })
        #expect(liveLength.displayText == RoofPlanSheet.expectedPolylineText)
        #expect(liveLength.displayUnitSymbol == "m")

        #expect(measurement.canCommit)
        measurement.commitActiveMeasurement() // Return
        try await eventually("the polyline row") { await session.orderedMarkups.count == 1 }

        // -- The area -----------------------------------------------------------------
        measurement.defaultSubject = "Roof plane"
        measurement.activate(kind: .area)
        for corner in RoofPlanSheet.rectRing { measurement.placePoint(corner) }
        await measurement.settlePlacements()
        #expect(measurement.placedPoints == RoofPlanSheet.rectRing)
        #expect(measurement.canCommit)
        measurement.commitActiveMeasurement()
        try await eventually("the area row") { await session.orderedMarkups.count == 2 }

        let markups = await session.orderedMarkups
        let polylineID = try #require(markups.first { $0.subject == "Roof edge" }?.id)
        let areaID = try #require(markups.first { $0.subject == "Roof plane" }?.id)

        // -- The cutout, through the one door mutations go through ---------------------
        let cutoutID = MarkupID(UUID())
        try await environment.commands.perform(.addCutout(
            parent: areaID,
            cutout: Self.polygonRecord(
                id: cutoutID,
                documentID: loaded.documentID,
                pageID: page.id,
                tool: .polygonCutout,
                subject: "Roof opening",
                ring: RoofPlanSheet.cutoutRing
            )
        ))

        // -- The rounding probe (silent-wrongness guard 5 needs it in the ledger) ------
        let probeID = MarkupID(UUID())
        try await environment.commands.perform(.addMarkup(
            Self.polylineRecord(
                id: probeID,
                documentID: loaded.documentID,
                pageID: page.id,
                subject: "Rounding probe",
                points: [RoofPlanSheet.probeA, RoofPlanSheet.probeB]
            )
        ))

        // Engine values against the hand-derived ones (comments in RoofPlanSheet.swift).
        let storedPolyline = try #require(await session.markup(polylineID))
        try Self.expectQuantity(
            storedPolyline.measurement?[.planLength],
            equals: RoofPlanSheet.expectedPolylineMetres,
            "polyline plan length"
        )
        let storedArea = try #require(await session.markup(areaID))
        try Self.expectQuantity(
            storedArea.measurement?[.planArea],
            equals: RoofPlanSheet.expectedRectAreaSquareMetres,
            "rectangle plan area"
        )
        try Self.expectQuantity(
            storedArea.measurement?[.netArea],
            equals: RoofPlanSheet.expectedNetAreaSquareMetres,
            "net area after the cutout"
        )
        try Self.expectQuantity(
            storedArea.measurement?[.cutoutArea],
            equals: RoofPlanSheet.expectedCutoutAreaSquareMetres,
            "cutout area"
        )
        print("CORE-LOOP MEASURE-OK polyline=\(RoofPlanSheet.expectedPolylineText) area=\(RoofPlanSheet.expectedRectAreaText) net=14.50")

        // ══════════════════════════════════════════════════════════════════════════
        // 4 ─ READ THE LEDGER: rows, units, totals.
        // ══════════════════════════════════════════════════════════════════════════

        await environment.ledger.refresh()
        let ledger = environment.ledger
        #expect(ledger.rowCount == 4, "polyline, area, cutout, probe")

        let polylineRow = try Self.row(in: ledger, subject: "Roof edge")
        #expect(polylineRow.displayValue("planLength") == RoofPlanSheet.expectedPolylineText)
        #expect(polylineRow.displayValue("planArea").isEmpty, "a length has no area")

        let areaRow = try Self.row(in: ledger, subject: "Roof plane")
        // ADR-0016: the Plan Area cell is the net area, 15.00 − 0.50 = 14.50 (RoofPlanSheet).
        #expect(areaRow.displayValue("planArea") == RoofPlanSheet.expectedNetAreaText)
        #expect(areaRow.displayValue("perimeter") == RoofPlanSheet.expectedRectPerimeterText)

        let cutoutRow = try Self.row(in: ledger, subject: "Roof opening")
        // ADR-0018: a cutout row carries no quantity of its own — empty, not 0.50.
        #expect(cutoutRow.displayValue("planArea") == RoofPlanSheet.expectedCutoutRowAreaText)
        #expect(cutoutRow.displayValue("perimeter") == RoofPlanSheet.expectedCutoutRowAreaText)

        let probeRow = try Self.row(in: ledger, subject: "Rounding probe")
        #expect(probeRow.displayValue("planLength") == RoofPlanSheet.expectedProbeText)

        // Units reach the UI on the columns — the header and VoiceOver read these.
        #expect(ledger.column("planLength")?.displayUnitSymbol == "m")
        #expect(ledger.column("planArea")?.displayUnitSymbol == "m²")

        // Totals come from the aggregation core, summed as Decimals and rounded once.
        let totals = ledger.grandTotals
        print("CORE-LOOP totals quantities=\(totals.quantities.keys.map(\.rawValue).sorted()) incompatible=\(totals.incompatibleColumns.map(\.rawValue).sorted())")
        #expect(totals.displayValue(LedgerColumnID("planLength")) == RoofPlanSheet.expectedLengthTotalText)
        #expect(totals.displayValue(LedgerColumnID("planArea")) == RoofPlanSheet.expectedAreaTotalText)

        // Silent-wrongness guard 5, double rounding, on the probe and on the total. The
        // trap is armed: rounding these values twice would visibly change the last digit.
        #expect(RoofPlanSheet.expectedProbeText != RoofPlanSheet.expectedProbeDoubleRoundedText)
        #expect(Self.doubleRounded(RoofPlanSheet.expectedProbeMetres) == RoofPlanSheet.expectedProbeDoubleRoundedText,
                "the probe value must actually be a double-rounding trap")
        #expect(probeRow.displayValue("planLength") == RoofPlanSheet.expectedProbeText,
                "displayed once-rounded, never twice")
        #expect(totals.displayValue(LedgerColumnID("planLength")) == RoofPlanSheet.expectedLengthTotalText,
                "the total is rounded once, at the boundary, not per digit-stage")
        print("CORE-LOOP LEDGER-OK rows=4 lengthTotal=\(RoofPlanSheet.expectedLengthTotalText) areaTotal=\(RoofPlanSheet.expectedAreaTotalText)")

        // ══════════════════════════════════════════════════════════════════════════
        // 5 ─ EXPORT: CSV through the app's own exporter, the PDF summary through the
        //     export layer — each within the three-action budget, both digit-for-digit
        //     with the ledger on screen.
        // ══════════════════════════════════════════════════════════════════════════

        // -- CSV ------------------------------------------------------------------------
        var csvActions = ActionCounter(step: "Export CSV")
        csvActions.tap("File ▸ Export…")
        csvActions.tap("name the file")
        let csvURL = scratch.url.appendingPathComponent("Demo Roof.csv")
        csvActions.tap("click Save")
        try LedgerCSVExport.write(presenter: ledger, to: csvURL)
        csvActions.assertWithinBudget(3)

        let csvText = try String(contentsOf: csvURL, encoding: .utf8)
        // Read with the delimiter the app wrote with: `;` on a comma-decimal locale (BH-915).
        let records = CSVReader.parse(csvText, delimiter: LedgerCSVExport.delimiter(for: .current))
        let visible = ledger.visibleColumns
        #expect(records.count == 1 + ledger.rowCount, "one header, one record per row")
        #expect(records[0] == visible.map(\.title), "the header is the visible columns, in order")

        // Digit-for-digit: every cell in the file equals the cell on screen.
        for rowIndex in 0..<ledger.rowCount {
            let row = try #require(ledger.row(at: rowIndex))
            let record = records[rowIndex + 1]
            #expect(record.count == visible.count)
            for (columnIndex, column) in visible.enumerated() {
                // The Unit column stores nothing; on screen it reads the row's unit, and since
                // L-25 the file carries that unit instead of a blank cell.
                let stored = row.displayValue(column.id)
                let onScreen = column.id == .displayUnit && stored.isEmpty
                    ? LedgerDefaultColumns.unitText(for: row)
                    : stored
                #expect(
                    record[columnIndex] == onScreen,
                    "CSV row \(rowIndex), column \(column.id.rawValue) must match the screen"
                )
            }
        }
        // And the hand-derived digits are in the file itself.
        let lengthColumn = try #require(visible.firstIndex { $0.id == LedgerColumnID("planLength") })
        let areaColumn = try #require(visible.firstIndex { $0.id == LedgerColumnID("planArea") })
        let subjectColumn = try #require(visible.firstIndex { $0.id == LedgerColumnID("subject") })
        func csvRecord(subject: String) throws -> [String] {
            try #require(
                records.dropFirst().first { $0[subjectColumn] == subject },
                "no CSV record for \(subject)"
            )
        }
        #expect(try csvRecord(subject: "Roof edge")[lengthColumn] == RoofPlanSheet.expectedPolylineText)
        #expect(try csvRecord(subject: "Roof plane")[areaColumn] == RoofPlanSheet.expectedNetAreaText)
        #expect(try csvRecord(subject: "Roof opening")[areaColumn] == RoofPlanSheet.expectedCutoutRowAreaText)
        #expect(try csvRecord(subject: "Rounding probe")[lengthColumn] == RoofPlanSheet.expectedProbeText)

        // -- PDF summary ------------------------------------------------------------------
        var pdfActions = ActionCounter(step: "Export PDF summary")
        pdfActions.tap("File ▸ Export…")
        pdfActions.tap("choose PDF summary")
        let pdfURL = scratch.url.appendingPathComponent("Demo Roof — summary.pdf")
        pdfActions.tap("click Save")

        let report = try await Self.makeReport(
            session: session,
            pages: loaded.pages,
            title: "Demo Roof — Quantity Ledger"
        )
        let projection = try ExportProjector().project(
            report,
            options: ExportProjectionOptions(
                document: ExportDocumentContext(
                    projectName: "EXEMPELPROJEKT",
                    documentName: "synthetic-roof-plan.pdf (A-00-0-001)",
                    revision: "FIRST ISSUE 2026-01-15",
                    scaleDescription: "1:50, calibrated from the 100 mm control ruler (5 000 mm)",
                    unitsDescription: "metres and square metres, 2 decimals",
                    preparedBy: "Acceptance test"
                )
            )
        )
        _ = try PDFReportRenderer().render(projection, to: pdfURL)
        pdfActions.assertWithinBudget(3)

        // Digit-for-digit: the projection's finished strings equal the ledger's.
        let exportRows = projection.table.allRows()
        #expect(exportRows.count == ledger.rowCount)
        let exportColumns = projection.table.columns
        func projectionCell(subject: String, key: String) throws -> String {
            let subjectIndex = try #require(exportColumns.firstIndex { $0.key == "subject" })
            let columnIndex = try #require(exportColumns.firstIndex { $0.key == key })
            let row = try #require(exportRows.first { $0.cells[subjectIndex].text == subject })
            return row.cells[columnIndex].text
        }
        for (subject, key, expected) in [
            ("Roof edge", "planLength", RoofPlanSheet.expectedPolylineText),
            ("Roof plane", "planArea", RoofPlanSheet.expectedNetAreaText),
            ("Roof plane", "perimeter", RoofPlanSheet.expectedRectPerimeterText),
            ("Roof opening", "planArea", RoofPlanSheet.expectedCutoutRowAreaText),
            ("Rounding probe", "planLength", RoofPlanSheet.expectedProbeText)
        ] {
            #expect(try projectionCell(subject: subject, key: key) == expected,
                    "PDF summary \(subject)/\(key) must carry the ledger's digits")
        }

        // The rendered file itself: read the text back through the bridge and find every
        // ledger digit and the self-describing cover facts in it.
        let summaryText = try await Self.pdfText(of: pdfURL)
        for needle in [
            // The cutout row prints no area (ADR-0018), so its old "0.50" is not a needle;
            // the roof plane's net 14.50 is (ADR-0016).
            RoofPlanSheet.expectedPolylineText, RoofPlanSheet.expectedNetAreaText,
            RoofPlanSheet.expectedProbeText,
            RoofPlanSheet.expectedLengthTotalText, RoofPlanSheet.expectedAreaTotalText,
            "EXEMPELPROJEKT", "synthetic-roof-plan.pdf (A-00-0-001)", "1:50",
            "metres and square metres", "4 of 4"
        ] {
            #expect(summaryText.contains(needle), "the PDF summary must state “\(needle)”")
        }
        // The double-rounded wrong digits must NOT appear as these rows' values — checked
        // on the projection strings above; here we pin the two totals in the file.
        print("CORE-LOOP EXPORT-OK csvActions=\(csvActions.count) pdfActions=\(pdfActions.count)")

        // ══════════════════════════════════════════════════════════════════════════
        // 6 ─ GUARDS that mutate: filtered export is labelled; mixed units refuse to
        //     total; a moved geometry recomputes instead of going stale.
        // ══════════════════════════════════════════════════════════════════════════

        // Guard 7: exporting a filtered view says so in the file.
        let filteredReport = try await Self.makeReport(
            session: session,
            pages: loaded.pages,
            title: "Demo Roof — filtered",
            filterSubjectEquals: "Roof edge"
        )
        #expect(filteredReport.metadata.rowCount == 1)
        #expect(filteredReport.metadata.totalRowCountBeforeFilter == 4)
        #expect(!filteredReport.metadata.filterDescription.isEmpty)
        let filteredProjection = try ExportProjector().project(filteredReport)
        let filteredURL = scratch.url.appendingPathComponent("filtered-summary.pdf")
        _ = try PDFReportRenderer().render(filteredProjection, to: filteredURL)
        let filteredText = try await Self.pdfText(of: filteredURL)
        #expect(filteredText.contains("Filter"), "the filtered export names its filter")
        #expect(filteredText.contains("1 of 4"), "…and says the total is partial")

        // Guard 4: mixing units in a total refuses — visibly — instead of summing.
        // `unitCost` is user-editable; one row in SEK, one in EUR. Unit Cost is a rate and is
        // never summed (ADR-0020), so the refusal shows in Total Cost (quantity × Unit Cost):
        // a SEK amount and a EUR amount, and the column total becomes "Mixed units".
        let unitCostColumn = LedgerIdentifiers.columnID(for: .unitCost)
        let totalCostColumn = LedgerIdentifiers.columnID(for: .totalCost)
        try await environment.commands.perform(.editCustomValue(
            id: polylineID,
            column: unitCostColumn,
            value: .currency(amount: 100, code: "SEK")
        ))
        try await environment.commands.perform(.editCustomValue(
            id: areaID,
            column: unitCostColumn,
            value: .currency(amount: 50, code: "EUR")
        ))
        await environment.ledger.refresh()
        // The totals row shows no number for the mixed column…
        #expect(environment.ledger.grandTotals.total(LedgerColumnID("unitCost")) == nil)
        #expect(environment.ledger.grandTotals.total(LedgerColumnID("totalCost")) == nil)
        // …and the aggregation core's refusal is explicit, all the way into an export:
        // the running SEK total is discarded, not presented as a partial sum.
        let mixedReport = try await Self.makeReport(
            session: session,
            pages: loaded.pages,
            title: "mixed-units probe"
        )
        let unitCostTotal = try #require(
            mixedReport.grandTotals.first { $0.column == totalCostColumn && $0.function == .sum },
            "the plan sums Total Cost"
        )
        guard case .mixedDimensions = unitCostTotal.value else {
            Issue.record("SEK + EUR must refuse to total; got \(unitCostTotal.value)")
            throw CoreLoopFailure.missingRow("mixed-units refusal")
        }
        #expect(unitCostTotal.rawDecimal == nil, "a refusal carries no number at all")
        // Take the two edits back before the export state is disturbed further.
        await environment.commands.undo()
        await environment.commands.undo()
        await environment.ledger.refresh()

        // Guard 8: when a geometry moves, its number moves with it — no stale value.
        try await environment.commands.perform(.editVertices(
            id: probeID,
            geometry: MeasurementGeometry(
                pageID: page.id,
                points: [PDFPoint(shown: RoofPlanSheet.probeA), PDFPoint(shown: RoofPlanSheet.probeBMoved)]
            )
        ))
        await environment.ledger.refresh()
        let movedRow = try Self.row(in: environment.ledger, subject: "Rounding probe")
        #expect(movedRow.displayValue("planLength") == RoofPlanSheet.expectedMovedProbeText,
                "the row recomputed the moment the geometry moved")
        #expect(
            environment.ledger.grandTotals.displayValue(LedgerColumnID("planLength"))
                == RoofPlanSheet.expectedMovedLengthTotalText,
            "and the total followed"
        )
        let movedRecord = try #require(await session.markup(probeID))
        #expect(movedRecord.scaleVersion == scale.version, "the measurement is stamped current")
        print("CORE-LOOP GUARDS-OK filtered-labelled mixed-units-refused stale-recomputed")

        // ══════════════════════════════════════════════════════════════════════════
        // 6b ─ SAVE → REOPEN: the takeoff survives the round trip whole (ADR-0009).
        // ══════════════════════════════════════════════════════════════════════════
        // The state on screen right now — scale, four markups, one moved probe — is
        // written into a real .zpdfproj through the real save pipeline, the package is
        // reopened cold, a second session hydrates from it, and the two takeoffs must
        // be *identical*: every ledger display string digit for digit, every geometry
        // exactly, the same default scale.

        func ledgerStrings(of takeoffSession: TakeoffSession) async throws -> [[String]] {
            let projection = try await takeoffSession.ledgerProjection()
            var rows: [[String]] = []
            for index in 0..<projection.rowCount {
                guard let ledgerRow = projection.row(at: index) else { continue }
                rows.append(projection.columns.map { ledgerRow.displayValue($0.id) })
            }
            return rows
        }

        let stateBeforeSave = await session.takeoffState()
        let ledgerBeforeSave = try await ledgerStrings(of: session)
        let packageURL = scratch.url.appendingPathComponent("Demo Roof.zpdfproj", isDirectory: true)
        let savedPackage = try await ProjectPackage.create(
            at: packageURL, displayName: "Demo Roof", originalPDF: url
        )
        try await TakeoffArchive.write(stateBeforeSave, into: savedPackage)
        _ = try await savedPackage.save()
        try await savedPackage.close()

        guard case .opened(let reopenedPackage) = try await ProjectPackage.open(at: packageURL) else {
            Issue.record("a cleanly saved package must reopen without recovery")
            throw CoreLoopFailure.missingRow("save-reopen")
        }
        let storedTakeoff = try #require(
            try await TakeoffArchive.read(from: reopenedPackage),
            "the saved package holds no takeoff"
        )
        #expect(storedTakeoff.hasSavedTakeoff)

        // A cold open mints fresh page ids; the stored identity is adopted by index,
        // exactly as the shipping document load does.
        let reloadedDrawing = try await DocumentSessionLoader.load(pdfAt: url)
        let adoptedPages = TakeoffArchive.adoptingStoredPageIDs(
            reloadedDrawing.pages, stored: storedTakeoff
        )
        let restoredSession = try TakeoffSession(
            documentID: DocumentID(UUID()), pages: adoptedPages, units: .metric
        )
        try await restoredSession.hydrate(
            markups: storedTakeoff.markups,
            scales: storedTakeoff.scales,
            pageScaleIDs: storedTakeoff.pageScaleIDs,
            calibrationEvidence: storedTakeoff.calibrationEvidence
        )

        let restoredScale = try #require(await restoredSession.firstPageScale)
        #expect(restoredScale == scale, "the reopened scale is not the saved scale")
        let restoredMarkups = await restoredSession.takeoffState().markups
        #expect(restoredMarkups.map(\.id) == stateBeforeSave.markups.map(\.id),
                "identity or draw order changed across the round trip")
        for (original, hydrated) in zip(stateBeforeSave.markups, restoredMarkups) {
            #expect(hydrated.geometry == original.geometry,
                    "\(original.subject): geometry not exactly equal after reopen")
            #expect(hydrated.measurement?.values == original.measurement?.values,
                    "\(original.subject): values not digit-for-digit after reopen")
            #expect(hydrated.style == original.style)
            #expect(hydrated.parentMarkupID == original.parentMarkupID)
            #expect(hydrated.cutoutMarkupIDs == original.cutoutMarkupIDs)
        }
        let ledgerAfterReopen = try await ledgerStrings(of: restoredSession)
        #expect(ledgerAfterReopen == ledgerBeforeSave,
                "the reopened ledger does not equal the saved one digit for digit")
        await reloadedDrawing.rasterSource.close()
        try await reopenedPackage.close()
        print("CORE-LOOP SAVE-REOPEN-OK rows=\(ledgerAfterReopen.count) identical")

        // ══════════════════════════════════════════════════════════════════════════
        // 7 ─ UNDO EVERYTHING: back to the opening state, and the input untouched.
        // ══════════════════════════════════════════════════════════════════════════

        var undoSteps = 0
        while environment.commands.undoManager.canUndo, undoSteps < 32 {
            await environment.commands.undo()
            undoSteps += 1
        }
        #expect(!environment.commands.undoManager.canUndo, "the undo stack drained")
        // Exactly the six mutations still standing: calibrate, polyline, area, cutout,
        // probe, and the probe's vertex edit (the two currency edits were undone above).
        #expect(undoSteps == 6, "every mutation was one undo step; got \(undoSteps)")
        await environment.refresh()

        #expect(await session.orderedMarkups.isEmpty, "every markup is gone")
        #expect(await session.firstPageScale == nil, "the calibration is gone too")
        #expect(environment.ledger.rowCount == 0, "the ledger is as empty as it opened")
        #expect(environment.ledger.grandTotals.quantities.isEmpty)
        #expect(environment.canvas.visibleMarkups.isEmpty, "the canvas emptied with it")
        #expect(environment.snapshot.firstPageScale == nil)

        // The original file never changed: same bytes, same hash, before and after.
        let after = try independentSHA256(of: url)
        #expect(after.hex == RoofPlanSheet.sha256, "the input file is byte-identical")
        #expect(after.byteCount == RoofPlanSheet.byteCount)
        let reopened = try await DocumentSessionLoader.load(pdfAt: url)
        #expect(reopened.digest.sha256 == RoofPlanSheet.sha256)
        await reopened.rasterSource.close()
        await loaded.rasterSource.close()
        print("CORE-LOOP UNDO-OK steps=\(undoSteps) hash-unchanged")
    }

    // MARK: - Helpers

    /// The ledger row whose subject cell matches, or a recorded failure.
    @MainActor
    static func row(in ledger: AppLedgerPresenter, subject: String) throws -> LedgerRow {
        for index in 0..<ledger.rowCount {
            if let row = ledger.row(at: index), row.displayValue("subject") == subject {
                return row
            }
        }
        Issue.record("no ledger row with subject \(subject)")
        throw CoreLoopFailure.missingRow(subject)
    }

    /// Asserts a stored `Decimal` quantity against a hand-derived `Double`, to 1 nm / 1 nm².
    static func expectQuantity(_ quantity: Domain.Quantity?, equals expected: Double, _ what: String) throws {
        let value = try #require(quantity, "\(what) is missing").value
        let double = NSDecimalNumber(decimal: value).doubleValue
        #expect(abs(double - expected) < 1e-9, "\(what): engine \(double) vs hand-derived \(expected)")
    }

    /// The double-rounding trap: what the value would display as if it were rounded to
    /// three decimals first and to two decimals second. Shares no code with the product.
    static func doubleRounded(_ value: Double) -> String {
        let threePlaces = (value * 1000).rounded() / 1000
        let twoPlaces = (threePlaces * 100).rounded() / 100
        return String(format: "%.2f", twoPlaces)
    }

    /// A `LedgerReport` over the session's markups — the export layer's entry point,
    /// built from the same store the on-screen projection uses.
    static func makeReport(
        session: TakeoffSession,
        pages: [ZPDFContracts.PageDescriptor],
        title: String,
        filterSubjectEquals subject: String? = nil
    ) async throws -> LedgerReport {
        let columns = try LedgerColumnSet.standard(displayPolicy: DisplayUnitSelection.metric.domainPolicy)
        let store = try LedgerStore(
            markups: await session.orderedMarkups,
            columns: columns,
            names: ProjectNameTable.pages(pages).ledgerCatalog
        )
        var filter = LedgerFilterNode.all
        if let subject {
            let subjectID = LedgerIdentifiers.columnID(for: .subject)
            filter = .rule(ZPDFQuantityLedger.LedgerFilterRule(
                column: subjectID,
                op: .equals,
                value: .text(subject)
            ))
        }
        let view = store.makeView(LedgerViewSpec(
            filter: filter,
            aggregation: LedgerAggregationPlan.standard(for: columns)
        ))
        return LedgerReportBuilder(
            timestamps: FixedTimestampProvider(Date(timeIntervalSince1970: 1_787_000_000))
        ).makeReport(view, title: title)
    }

    /// All text of a PDF, read back through the same bridge the product reads with.
    static func pdfText(of url: URL) async throws -> String {
        let provider = PDFKitDocumentProvider(thumbnailCacheCapacity: 0)
        let opened = try await provider.open(.url(url), password: nil, limits: .standard)
        defer { Task { await provider.close(opened.handle) } }
        var text = ""
        for index in 0..<opened.descriptor.pageCount {
            text += try await provider.pageText(of: opened.handle, pageIndex: index).string
            text += "\n"
        }
        return text
    }

    /// Whether a rendered page image contains any non-white pixel.
    static func containsInk(_ image: CGImage) -> Bool {
        guard let data = image.dataProvider?.data as Data? else { return false }
        let bytesPerPixel = max(1, image.bitsPerPixel / 8)
        var index = 0
        while index + bytesPerPixel <= data.count {
            // Any channel meaningfully below white counts as ink.
            for channel in 0..<min(3, bytesPerPixel) where data[index + channel] < 0xC8 {
                return true
            }
            index += bytesPerPixel * 61 // sparse scan; plenty for an A1 sheet of linework
        }
        return false
    }

    /// A polygon markup record over a page-space ring.
    static func polygonRecord(
        id: MarkupID,
        documentID: DocumentID,
        pageID: PageID,
        tool: Domain.Tool,
        subject: String,
        ring: [PDFPointValue]
    ) -> ZPDFContracts.MarkupRecord {
        let stamp = Date(timeIntervalSince1970: 1_787_000_000)
        return ZPDFContracts.MarkupRecord(
            id: id,
            documentID: documentID,
            pageID: pageID,
            kind: .measurement,
            tool: tool,
            subject: subject,
            label: "",
            author: "Acceptance test",
            geometry: MeasurementGeometry(
                pageID: pageID,
                polygons: [PolygonGeometry(
                    outer: PolygonRing(points: ring.map { PDFPoint(shown: $0) }, isClosed: true)
                )]
            ),
            createdAt: stamp,
            modifiedAt: stamp
        )
    }

    /// A polyline markup record over page-space points.
    static func polylineRecord(
        id: MarkupID,
        documentID: DocumentID,
        pageID: PageID,
        subject: String,
        points: [PDFPointValue]
    ) -> ZPDFContracts.MarkupRecord {
        let stamp = Date(timeIntervalSince1970: 1_787_000_000)
        return ZPDFContracts.MarkupRecord(
            id: id,
            documentID: documentID,
            pageID: pageID,
            kind: .measurement,
            tool: .polylength,
            subject: subject,
            label: "",
            author: "Acceptance test",
            geometry: MeasurementGeometry(
                pageID: pageID,
                points: points.map { PDFPoint(shown: $0) }
            ),
            createdAt: stamp,
            modifiedAt: stamp
        )
    }
}

/// Failures the helper throws when a `#require` cannot express them.
enum CoreLoopFailure: Error {
    case missingRow(String)
}

/// A scratch directory for the exports this test writes.
struct ScratchDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-coreloop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
