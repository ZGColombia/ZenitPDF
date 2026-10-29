import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFPersistence
import ZPDFTestingSupport
import ZPDFUIPresentation

/// A scale belongs to a page (spec 10.5, spec 1.1 item 7).
///
/// The behaviour these tests pin is the last entry on CORE_LOOP's silent-wrongness list —
/// *"measuring on a page that was never calibrated"* — and the reason it survived so long is
/// that it was **unreachable**: `TakeoffSession` held one document-wide default scale, so once
/// any sheet was calibrated every other sheet resolved to that sheet's ratio and the refusal
/// could never fire. Worse, calibrating a second sheet revised the *same* scale and silently
/// recomputed the first sheet's numbers under the new one.
///
/// The fixture is a real four-page PDF whose sheets are four different sizes — the shape of a
/// drawing set that mixes a plan and a detail. Nothing here stubs the engine or the archive.
struct PerPageScaleTests {

    // MARK: Fixtures

    private func makeWorkspace(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-perpage-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A 100 pt horizontal run, as a length markup on `page`.
    private func lengthMarkup(
        page: ZPDFContracts.PageDescriptor,
        documentID: DocumentID,
        subject: String
    ) -> ZPDFContracts.MarkupRecord {
        let now = Date(timeIntervalSince1970: 1_787_000_000)
        return ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()),
            documentID: documentID,
            pageID: page.id,
            kind: .measurement,
            tool: .polylength,
            subject: subject,
            label: subject,
            author: "Per Page",
            style: .default,
            geometry: MeasurementGeometry(
                pageID: page.id,
                points: [PDFPoint(x: 10, y: 10), PDFPoint(x: 110, y: 10)]
            ),
            parameters: .default,
            createdAt: now,
            modifiedAt: now
        )
    }

    private func planLength(of record: ZPDFContracts.MarkupRecord) -> Decimal? {
        record.measurement?.values[ZPDFContracts.MeasurementField.planLength]?.value
    }

    // MARK: 1 — two pages, two scales

    @Test("Two sheets at different scales measure at their own scale, not at each other's")
    func twoPagesTwoScales() async throws {
        let workspace = try makeWorkspace("two-scales")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let fixture = try await OpenedFixture.open(.mixedPageSizes, in: workspace)
        #expect(fixture.pages.count >= 2, "the fixture must have at least two sheets")
        let plan = fixture.pages[0]
        let detail = fixture.pages[1]

        let session = try TakeoffSession(
            documentID: fixture.documentID,
            pages: fixture.pages,
            units: .metric
        )
        // The plan sheet: 100 pt = 10 m. The detail sheet: 100 pt = 1 m — a tenfold difference,
        // so a leak between them is a factor of ten and not a rounding argument.
        _ = try await session.calibrate(
            page: plan.id,
            first: PDFPoint(x: 0, y: 0),
            second: PDFPoint(x: 100, y: 0),
            knownLength: 10,
            knownLengthUnit: .metre
        )
        _ = try await session.calibrate(
            page: detail.id,
            first: PDFPoint(x: 0, y: 0),
            second: PDFPoint(x: 100, y: 0),
            knownLength: 1,
            knownLengthUnit: .metre
        )

        let planScale = try #require(await session.pageScale(plan.id))
        let detailScale = try #require(await session.pageScale(detail.id))
        #expect(planScale.id != detailScale.id,
                "calibrating a second sheet must mint a second scale, not revise the first")
        #expect(planScale.pageID == plan.id)
        #expect(detailScale.pageID == detail.id)

        let onPlan = lengthMarkup(page: plan, documentID: fixture.documentID, subject: "Plan run")
        let onDetail = lengthMarkup(page: detail, documentID: fixture.documentID, subject: "Detail run")
        _ = try await session.apply(.addMarkup(onPlan))
        _ = try await session.apply(.addMarkup(onDetail))

        let storedPlan = try #require(await session.markup(onPlan.id))
        let storedDetail = try #require(await session.markup(onDetail.id))
        // The identical 100 pt run: 10 m on the plan, 1 m on the detail.
        #expect(planLength(of: storedPlan) == 10)
        #expect(planLength(of: storedDetail) == 1)
        #expect(storedPlan.scaleID == planScale.id)
        #expect(storedDetail.scaleID == detailScale.id)
    }

    @Test("Calibrating a third sheet leaves the first sheet's numbers untouched")
    func calibratingAnotherSheetDoesNotRewriteThisOne() async throws {
        let workspace = try makeWorkspace("late-calibration")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let fixture = try await OpenedFixture.open(.mixedPageSizes, in: workspace)
        #expect(fixture.pages.count >= 3)
        let first = fixture.pages[0]
        let third = fixture.pages[2]

        let session = try TakeoffSession(
            documentID: fixture.documentID, pages: fixture.pages, units: .metric
        )
        _ = try await session.calibrate(
            page: first.id,
            first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
            knownLength: 10, knownLengthUnit: .metre
        )
        let measured = lengthMarkup(page: first, documentID: fixture.documentID, subject: "Wall")
        _ = try await session.apply(.addMarkup(measured))
        let before = try #require(await session.markup(measured.id))
        #expect(planLength(of: before) == 10)

        // The scenario the release document describes: a user measures on page 1, then goes and
        // calibrates page 3. Before per-page scale this produced version 2 of the *one* shared
        // scale and restamped the page-1 measurement at page 3's ratio.
        _ = try await session.calibrate(
            page: third.id,
            first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
            knownLength: 1, knownLengthUnit: .metre
        )

        let after = try #require(await session.markup(measured.id))
        #expect(planLength(of: after) == 10, "page 3's calibration rewrote page 1's number")
        #expect(after.scaleID == before.scaleID)
        #expect(after.scaleVersion == before.scaleVersion,
                "page 1's scale was revised by a calibration that did not touch page 1")
    }

    // MARK: 2 — the refusal

    @Test("A measurement on an uncalibrated sheet of a calibrated document is refused, with a reason")
    func uncalibratedSiblingPageIsRefused() async throws {
        let workspace = try makeWorkspace("refusal")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let fixture = try await OpenedFixture.open(.mixedPageSizes, in: workspace)
        let calibrated = fixture.pages[0]
        let bare = fixture.pages[1]

        let session = try TakeoffSession(
            documentID: fixture.documentID, pages: fixture.pages, units: .metric
        )
        _ = try await session.calibrate(
            page: calibrated.id,
            first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
            knownLength: 10, knownLengthUnit: .metre
        )
        #expect(await session.isCalibrated(page: calibrated.id))
        #expect(await session.isCalibrated(page: bare.id) == false)

        // The engine refuses, and the refusal names the page.
        let geometry = MeasurementGeometry(
            pageID: bare.id,
            points: [PDFPoint(x: 10, y: 10), PDFPoint(x: 110, y: 10)]
        )
        var refusal: DocumentCommandError?
        do {
            _ = try await session.measure(tool: .polylength, geometry: geometry)
        } catch let error as DocumentCommandError {
            refusal = error
        }
        #expect(refusal == .noScale(bare.id))
        #expect(try #require(refusal).description.contains("has no scale"))

        // The live preview says nothing rather than showing a plausible figure.
        #expect(await session.preview(tool: .polylength, geometry: geometry) == nil)

        // Committing it stores the geometry and refuses the number: a row that says
        // "no scale", never a row that says ten metres because another sheet is 1:100.
        let record = lengthMarkup(page: bare, documentID: fixture.documentID, subject: "Unscaled")
        _ = try await session.apply(.addMarkup(record))
        let stored = try #require(await session.markup(record.id))
        #expect(stored.geometry == record.geometry, "the geometry is kept")
        #expect(stored.measurement == nil, "a value was invented on an uncalibrated sheet")
        #expect(stored.scaleVersion == nil)
    }

    @Test("A scale from another page cannot be borrowed by naming it")
    func namingAnotherPagesScaleDoesNotBorrowIt() async throws {
        let workspace = try makeWorkspace("no-borrow")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let fixture = try await OpenedFixture.open(.mixedPageSizes, in: workspace)
        let calibrated = fixture.pages[0]
        let bare = fixture.pages[1]

        let session = try TakeoffSession(
            documentID: fixture.documentID, pages: fixture.pages, units: .metric
        )
        _ = try await session.calibrate(
            page: calibrated.id,
            first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
            knownLength: 10, knownLengthUnit: .metre
        )
        let foreign = try #require(await session.pageScale(calibrated.id)).id

        // A markup on the bare sheet carrying the other sheet's scale identifier — the shape a
        // stale record, a copy-paste across pages or a hand-edited file produces.
        var borrowed = lengthMarkup(page: bare, documentID: fixture.documentID, subject: "Borrowed")
        borrowed.scaleID = foreign
        _ = try await session.apply(.addMarkup(borrowed))
        let stored = try #require(await session.markup(borrowed.id))
        #expect(stored.measurement == nil,
                "a scale belonging to another page was honoured on this one")

        // And the resolver says the same thing directly.
        #expect(await session.scale(onPage: bare.id, scaleID: foreign) == nil)

        // Refusing to calibrate that scale *onto* the bare page is the matching guard.
        await #expect(throws: DocumentCommandError.scaleBelongsToAnotherPage(
            scale: foreign, page: bare.id
        )) {
            _ = try await session.calibrate(
                page: bare.id,
                first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
                knownLength: 1, knownLengthUnit: .metre,
                scaleID: foreign
            )
        }
    }

    // MARK: 3 — the derivation names the page

    @Test("The derivation names the sheet the scale was calibrated on")
    func derivationNamesTheRightPage() async throws {
        let workspace = try makeWorkspace("derivation")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let fixture = try await OpenedFixture.open(.mixedPageSizes, in: workspace)
        #expect(fixture.pages.count >= 3)
        let plan = fixture.pages[0]
        let third = fixture.pages[2]

        let session = try TakeoffSession(
            documentID: fixture.documentID, pages: fixture.pages, units: .metric
        )
        for page in [plan, third] {
            _ = try await session.calibrate(
                page: page.id,
                first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
                knownLength: page.id == plan.id ? 10 : 1,
                knownLengthUnit: .metre
            )
        }
        let onThird = lengthMarkup(page: third, documentID: fixture.documentID, subject: "Detail")
        _ = try await session.apply(.addMarkup(onThird))

        let stored = try #require(await session.markup(onThird.id))
        let provenance = try #require(stored.measurement?.provenance)
        #expect(provenance.scalePageID == third.id,
                "the derivation names the wrong sheet's scale")
        #expect(provenance.scaleID == (await session.pageScale(third.id))?.id)
        #expect(provenance.scaleSource == ZPDFContracts.ScaleSource.calibrationTwoPoint)
        // The evidence behind that calibration, so the panel can show the picked points.
        let evidence = try #require(provenance.calibrationEvidence)
        #expect(evidence.points == [PDFPoint(x: 0, y: 0), PDFPoint(x: 100, y: 0)])
        #expect(evidence.enteredLength.value == 1)

        // And the disclosure the Inspector renders says it in the page's printed label.
        let snapshot = try await session.snapshot()
        let sections = try #require(snapshot.derivations[onThird.id.rawValue])
        let scaleSection = try #require(sections.first { $0.key == "scale" })
        let pageFact = try #require(scaleSection.facts.first { $0.key == "scale.page" })
        #expect(pageFact.value == third.label)
        let ratioFact = try #require(scaleSection.facts.first { $0.key == "scale.id" })
        // 100 pt = 1 m is 0.01 m per point, and a point is 1/72 inch, so the printed
        // ratio is 0.01 x 72 / 0.0254 = 1:28.35, written 1:28.3 — one decimal below 1:100, the
        // Calibrate sheet's rule every `1:n` follows since L-38 (it read "1:28"). The plan
        // sheet's is 1:283.
        #expect(ratioFact.value == "1:28.3", "the detail sheet's own ratio, not the plan sheet's")
    }

    // MARK: 4 — save, reopen, identical

    @Test("Two scales on two sheets survive save and reopen, values digit for digit")
    func perPageScalesRoundTrip() async throws {
        let workspace = try makeWorkspace("round-trip")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let fixture = try await OpenedFixture.open(.mixedPageSizes, in: workspace)
        let plan = fixture.pages[0]
        let detail = fixture.pages[1]
        let bare = fixture.pages[2]

        let session = try TakeoffSession(
            documentID: fixture.documentID, pages: fixture.pages, units: .metric
        )
        _ = try await session.calibrate(
            page: plan.id,
            first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
            knownLength: 10, knownLengthUnit: .metre
        )
        _ = try await session.calibrate(
            page: detail.id,
            first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
            knownLength: 1, knownLengthUnit: .metre
        )
        let onPlan = lengthMarkup(page: plan, documentID: fixture.documentID, subject: "Plan run")
        let onDetail = lengthMarkup(page: detail, documentID: fixture.documentID, subject: "Detail run")
        let onBare = lengthMarkup(page: bare, documentID: fixture.documentID, subject: "Unscaled run")
        for record in [onPlan, onDetail, onBare] {
            _ = try await session.apply(.addMarkup(record))
        }
        let before = await session.takeoffState()

        let packageURL = workspace.appendingPathComponent("PerPage.zpdfproj", isDirectory: true)
        let package = try await ProjectPackage.create(
            at: packageURL, displayName: "PerPage", originalPDF: fixture.url
        )
        try await TakeoffArchive.write(before, into: package)
        _ = try await package.save()
        try await package.close()

        guard case .opened(let reopened) = try await ProjectPackage.open(at: packageURL) else {
            Issue.record("reopen required recovery")
            return
        }
        let stored = try #require(try await TakeoffArchive.read(from: reopened))
        try await reopened.close()

        #expect(stored.pageScaleIDs.count == 2, "exactly the two calibrated sheets carry a scale")
        #expect(stored.pageScaleIDs[plan.id] != nil)
        #expect(stored.pageScaleIDs[detail.id] != nil)
        #expect(stored.pageScaleIDs[bare.id] == nil, "an uncalibrated sheet reopens uncalibrated")
        for scale in stored.scales {
            #expect(scale.pageID != nil, "a stored scale must carry its page")
        }

        let restored = try TakeoffSession(
            documentID: DocumentID(UUID()),
            pages: TakeoffArchive.adoptingStoredPageIDs(fixture.pages, stored: stored),
            units: .metric
        )
        try await restored.hydrate(
            markups: stored.markups,
            scales: stored.scales,
            pageScaleIDs: stored.pageScaleIDs,
            calibrationEvidence: stored.calibrationEvidence
        )

        let after = await restored.takeoffState()
        #expect(after.pageScaleIDs == before.pageScaleIDs)
        for (original, hydrated) in zip(before.markups, after.markups) {
            #expect(hydrated.id == original.id)
            #expect(planLength(of: hydrated) == planLength(of: original),
                    "\(original.subject) changed across save and reopen")
            #expect(hydrated.scaleID == original.scaleID)
        }
        #expect(planLength(of: after.markups[0]) == 10)
        #expect(planLength(of: after.markups[1]) == 1)
        #expect(after.markups[2].measurement == nil,
                "the uncalibrated sheet's markup gained a number across a reopen")

        // The derivation still names the sheet after the round trip.
        let provenance = try #require(after.markups[1].measurement?.provenance)
        #expect(provenance.scalePageID == detail.id)
        #expect(provenance.calibrationEvidence?.enteredLength.value == 1)
    }

    @Test("A Scale Region may not carry a scale calibrated on another sheet")
    func regionCannotCarryAForeignPagesScale() async throws {
        let workspace = try makeWorkspace("region-page")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let fixture = try await OpenedFixture.open(.mixedPageSizes, in: workspace)
        let plan = fixture.pages[0]
        let other = fixture.pages[1]

        let session = try TakeoffSession(
            documentID: fixture.documentID, pages: fixture.pages, units: .metric
        )
        _ = try await session.calibrate(
            page: plan.id,
            first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
            knownLength: 10, knownLengthUnit: .metre
        )
        let planScale = try #require(await session.pageScale(plan.id)).id

        // A region drawn on the *other* sheet, pointed at the plan sheet's scale. The
        // resolution would drop it, so the region would measure at the other sheet's own ratio
        // while its panel row named the plan's — a number and a provenance that disagree.
        let region = ScaleRegionDefinition(
            id: ScaleRegionID(UUID()),
            pageID: other.id,
            name: "Borrowed",
            boundary: [
                PDFPoint(x: 0, y: 0), PDFPoint(x: 200, y: 0),
                PDFPoint(x: 200, y: 200), PDFPoint(x: 0, y: 200)
            ],
            scaleID: planScale,
            priority: 10,
            colorRGBA: ColorRGBA(red: 0, green: 0, blue: 0, alpha: 1)
        )
        await #expect(throws: DocumentCommandError.scaleBelongsToAnotherPage(
            scale: planScale, page: other.id
        )) {
            _ = try await session.apply(.setScaleRegions([region]))
        }
        #expect(await session.scaleRegionDefinitions.isEmpty,
                "a refused command must leave the document exactly as it was")
    }
}
