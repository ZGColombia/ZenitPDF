import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFGeometry
import ZPDFUIPresentation
import ZenitPDFAppKit

/// The silent-wrongness guards that need a *fresh, uncalibrated* document — they cannot
/// run inside the main walk, whose whole point is to calibrate early.
///
/// Of CORE_LOOP's eight-item silent-wrongness list, the ones testable at this level are
/// asserted across this file and the main walk:
///
///   1. uncalibrated page refuses          → here, on a wholly uncalibrated document. The
///      harder half of item 1 — the uncalibrated *sibling sheet* of a calibrated document,
///      which was unreachable while the scale was document-wide — needs a multi-sheet set
///      and this sheet is one page, so it is asserted in `ZPDFAppCore`'s
///      `PerPageScaleTests` against the four-page `mixedPageSizes` fixture.
///   4. mixed units refuse to total        → main walk, guard section
///   5. double rounding absent             → main walk, probe + totals
///   7. filtered export labelled           → main walk, guard section
///   8. stale after geometry move          → main walk, guard section
///
/// Items 2 (Scale Regions), 3 (revision replacement) and 6 (slope direction, ADR-0004)
/// need product surfaces the loop deliberately does not touch on this drawing — the sheet
/// has one scale, one revision and no sloped measurement in the loop — and they keep
/// their own suites in `ZPDFMeasurementEngine` and `ZPDFAppCore`.
@Suite("Silent-wrongness guards on the uncalibrated roof plan")
struct SilentWrongnessGuardTests {

    @Test("An uncalibrated page refuses to produce a number, loudly")
    @MainActor
    func uncalibratedPageRefuses() async throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let url = try RoofPlanSheet.generate(in: scratch.url)
        let loaded = try await DocumentSessionLoader.load(pdfAt: url)
        defer { Task { await loaded.rasterSource.close() } }
        let page = loaded.pages[0]
        let session = try TakeoffSession(
            documentID: loaded.documentID,
            pages: loaded.pages,
            units: .metric
        )
        let environment = try await AppCoreEnvironment.make(
            session: session,
            documentID: loaded.documentID
        )

        // The engine itself refuses: measuring without a scale is an error, not a 1:1 guess.
        do {
            _ = try await session.measure(
                tool: .polylength,
                geometry: MeasurementGeometry(
                    pageID: page.id,
                    points: [PDFPoint(shown: RoofPlanSheet.polyA), PDFPoint(shown: RoofPlanSheet.polyB)]
                )
            )
            Issue.record("an uncalibrated page produced a measurement")
        } catch let error as DocumentCommandError {
            guard case .noScale = error else {
                Issue.record("expected .noScale, got \(error)")
                return
            }
        }

        // The palette flags it while drawing: no number, and a named missing-scale warning.
        let measurement = environment.measurement
        measurement.layout = PageViewLayout(zoom: 1, backingScale: 2)
        measurement.defaultSubject = "Unscaled probe"
        measurement.activate(kind: .polylength)
        measurement.placePoint(RoofPlanSheet.polyA)
        measurement.placePoint(RoofPlanSheet.polyB)
        await measurement.settlePlacements()
        measurement.schedulePreview()
        try await eventually("the missing-scale warning") {
            measurement.liveWarnings.contains(.missingScale)
        }
        #expect(measurement.liveFields.isEmpty, "no plausible number under the cursor")

        // The commit itself is refused: missing scale is a *blocking* warning, so the
        // palette will not let the measurement into the ledger at all.
        #expect(!measurement.canCommit, "an uncalibrated commit is refused, not stored quietly")
        measurement.commitActiveMeasurement()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await session.orderedMarkups.isEmpty, "the refused commit left nothing behind")

        // A markup forced in anyway — a project opened with stored geometry, say — lands
        // as geometry without a quantity: the row says nothing rather than something wrong,
        // and nothing totals.
        try await environment.commands.perform(.addMarkup(
            CoreLoopAcceptanceTests.polylineRecord(
                id: MarkupID(UUID()),
                documentID: loaded.documentID,
                pageID: page.id,
                subject: "Unscaled probe",
                points: [RoofPlanSheet.polyA, RoofPlanSheet.polyB]
            )
        ))
        await environment.ledger.refresh()
        let row = try CoreLoopAcceptanceTests.row(in: environment.ledger, subject: "Unscaled probe")
        #expect(row.quantity("planLength") == nil)
        #expect(row.displayValue("planLength").isEmpty)
        #expect(environment.ledger.grandTotals.total(LedgerColumnID("planLength")) == nil)
        print("CORE-LOOP GUARD-UNCALIBRATED-OK refused-and-flagged")
    }

    @Test("An absurd calibration asks for confirmation instead of accepting silently")
    @MainActor
    func extremeScaleAsksForConfirmation() async throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let loaded = try await DocumentSessionLoader.load(pdfAt: try RoofPlanSheet.generate(in: scratch.url))
        defer { Task { await loaded.rasterSource.close() } }
        let session = try TakeoffSession(
            documentID: loaded.documentID,
            pages: loaded.pages,
            units: .metric
        )

        // Two points 4.1 pt apart declared to span 50 000 km: beyond the sane range
        // (1 µm … 10 km per point), so the calibration must throw the
        // needs-confirmation error rather than install the scale.
        let first = PDFPoint(x: 100, y: 100)
        let second = PDFPoint(x: 104.1, y: 100)
        do {
            _ = try await session.calibrate(
                page: try #require(await session.firstPageID),
                first: first,
                second: second,
                knownLength: 50_000,
                knownLengthUnit: .kilometre
            )
            Issue.record("an absurd scale was accepted without confirmation")
        } catch let error as ScaleError {
            guard case .extremeScaleRequiresConfirmation = error else {
                Issue.record("expected extremeScaleRequiresConfirmation, got \(error)")
                return
            }
        }
        #expect(await session.firstPageScale == nil, "the refused scale left nothing behind")

        // The explicit confirmation is the `allowExtreme` bit the confirmation dialog sets.
        _ = try await session.calibrate(
            page: try #require(await session.firstPageID),
            first: first,
            second: second,
            knownLength: 50_000,
            knownLengthUnit: .kilometre,
            allowExtreme: true
        )
        #expect(await session.firstPageScale != nil, "confirmed, it installs")
        print("CORE-LOOP GUARD-EXTREME-SCALE-OK confirmation-required")
    }
}
