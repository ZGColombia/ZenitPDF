import Foundation
import Testing
import ZPDFContracts
import ZPDFMeasurementEngine
import ZPDFPersistence
import ZPDFUIPresentation
@testable import ZPDFAppCore

/// Manual-test findings: L-104 (the Temporary Measure's decimal point), L-102 (Radius on
/// a sheet with separate X and Y scales, and raw engine text in the tray), L-87 (Colour on an area
/// left its fill behind), L-70 (Merge kept the split part's label) and L-99 (a Note logged as
/// "Measured"). Each test drives the presenter or the session path the manual test went through.
@Suite("Manual-test findings — application core (L-70, L-87, L-99, L-102, L-104)")
struct Live8AppCoreTests {

    // MARK: Fixture

    /// One 612 × 792 sheet, calibrated 100 pt = 10 m (0.1 m per point), or with separate X and Y
    /// scales (X: 100 pt = 10 m, Y: 100 pt = 20 m) when `separateAxes` is set.
    @MainActor
    static func environment(
        locale: String = "en_US_POSIX",
        separateAxes: Bool = false
    ) async throws -> (AppCoreEnvironment, TakeoffSession, ZPDFContracts.PageDescriptor) {
        let documentID = DocumentID(UUID())
        let page = ZPDFContracts.PageDescriptor(
            id: PageID(UUID()), documentID: documentID, index: 0, label: "Plan-A",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 612, height: 792))
        )
        let session = try TakeoffSession(documentID: documentID, pages: [page], localeIdentifier: locale)
        if separateAxes {
            _ = try await session.calibrateXY(
                page: page.id,
                xFirst: PDFPoint(x: 0, y: 0), xSecond: PDFPoint(x: 100, y: 0), xKnownLength: 10,
                yFirst: PDFPoint(x: 0, y: 0), ySecond: PDFPoint(x: 0, y: 100), yKnownLength: 20,
                knownLengthUnit: .metre
            )
        } else {
            _ = try await session.calibrate(
                page: page.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
                knownLength: 10, knownLengthUnit: .metre
            )
        }
        let environment = try await AppCoreEnvironment.make(session: session, documentID: documentID)
        _ = try await session.buildSnapIndex(page: page, extraction: nil)
        await environment.refresh()
        return (environment, session, page)
    }

    static func record(
        _ page: ZPDFContracts.PageDescriptor,
        kind: ZPDFContracts.MarkupKind = .measurement,
        tool: MeasurementTool?,
        geometry: MeasurementGeometry,
        subject: String = "Floor",
        label: String = "",
        style: MarkupStyle = .default
    ) -> ZPDFContracts.MarkupRecord {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        return ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: page.documentID, pageID: page.id, kind: kind, tool: tool,
            subject: subject, label: label, author: "A. Berg", style: style, geometry: geometry,
            createdAt: stamp, modifiedAt: stamp
        )
    }

    static func rectangle(_ page: PageID, x0: Double, y0: Double, x1: Double, y1: Double) -> MeasurementGeometry {
        MeasurementGeometry(pageID: page, polygons: [PolygonGeometry(outer: PolygonRing(points: [
            PDFPoint(x: x0, y: y0), PDFPoint(x: x1, y: y0), PDFPoint(x: x1, y: y1), PDFPoint(x: x0, y: y1)
        ], isClosed: true))])
    }

    // MARK: L-104

    /// 52 pt at 0.1 m per point is 5.2 m, shown at the metric default of two decimals.
    @Test("L-104: the Temporary Measure and the live value use the session's decimal separator")
    @MainActor
    func temporaryMeasureUsesTheLocale() async throws {
        let (environment, _, _) = try await Self.environment(locale: "sv_SE")
        let measurement = environment.measurement
        measurement.activate(kind: .temporaryMeasure)
        measurement.placePoint(PDFPointValue(x: 10, y: 10))
        measurement.placePoint(PDFPointValue(x: 62, y: 10))
        await measurement.settlePlacements()
        await measurement.settlePreviewsForTesting()
        // Old output: "5.20 m" — `QuantityFormatter(units:)` defaults to en_US_POSIX.
        #expect(measurement.livePrimaryField?.displayTextWithUnit == "5,20 m")

        measurement.commitActiveMeasurement()
        await measurement.settleTemporaryMeasurementsForTesting()
        let tape = try #require(measurement.temporaryMeasurements.first)
        // Old output: nil — the committed tape carried no measurement, so the reading the canvas
        // draws beside it was gone the moment the live readout ("5.20 m") was.
        #expect(tape.primaryField?.displayTextWithUnit == "5,20 m")
        #expect(measurement.temporaryOverlayRecords.first?.measurement?[.planLength]?.value == Decimal(string: "5.2"))
    }

    @Test("L-104: a committed length reads the same in the ledger and on the live readout")
    @MainActor
    func liveValueMatchesTheLedger() async throws {
        let (environment, _, _) = try await Self.environment(locale: "sv_SE")
        let measurement = environment.measurement
        measurement.activate(kind: .length)
        measurement.placePoint(PDFPointValue(x: 10, y: 10))
        measurement.placePoint(PDFPointValue(x: 62, y: 10))
        await measurement.settlePlacements()
        await measurement.settlePreviewsForTesting()
        let live = try #require(measurement.livePrimaryField?.displayTextWithUnit)
        measurement.commitActiveMeasurement()
        await environment.commands.settle()
        for _ in 0..<8 { await Task.yield() }
        await environment.refresh()
        let committed = try #require(environment.snapshot.markups.first?.primaryField?.displayTextWithUnit)
        #expect(live == "5,20 m")
        #expect(committed == live)
    }

    // MARK: L-102

    @Test("L-102: Radius on a sheet with separate X and Y scales says why before the first click")
    @MainActor
    func radiusRefusedBeforeTheClicks() async throws {
        let (environment, _, _) = try await Self.environment(separateAxes: true)
        let measurement = environment.measurement
        #expect(measurement.activeScale?.isUniform == false)
        let reason = MeasurementWarningSummary.circleNeedsUniformScale.message

        // Old behaviour: armed with no word; both clicks landed; the commit then failed.
        measurement.activate(kind: .radius)
        #expect(measurement.liveWarnings == [.circleNeedsUniformScale])
        #expect(measurement.toolUnavailableReason == reason)
        #expect(measurement.armedToolNote == reason, "what the status line says on arming")
        #expect(measurement.commitRefusalReason == reason, "not \"Radius needs 2 more points\"")

        // The canvas asks before routing the first click: refused, nothing placed, said in words.
        #expect(measurement.refusesForMissingScale())
        #expect(measurement.placedPoints.isEmpty)
        #expect(measurement.uniformScaleRefusals == 1)
        #expect(environment.status.snapshot.activeToolNote == reason)
        #expect(!measurement.canCommit)

        // Escape keeps the tool armed on the same sheet, and the reason with it.
        measurement.cancelActiveMeasurement()
        #expect(measurement.liveWarnings == [.circleNeedsUniformScale])

        // Diameter and Three-Point Circle share the rule; Length and Area do not.
        for kind in [Shown.Kind.diameter, .threePointCircle] {
            measurement.activate(kind: kind)
            #expect(measurement.toolUnavailableReason == reason, "\(kind)")
        }
        for kind in [Shown.Kind.length, .area] {
            measurement.activate(kind: kind)
            #expect(measurement.toolUnavailableReason == nil, "\(kind)")
            #expect(!measurement.liveWarnings.contains(.circleNeedsUniformScale), "\(kind)")
            #expect(!measurement.refusesForMissingScale(), "\(kind)")
        }
    }

    @Test("L-102: Radius on a uniform sheet is not refused")
    @MainActor
    func radiusOnAUniformSheet() async throws {
        let (environment, _, _) = try await Self.environment()
        environment.measurement.activate(kind: .radius)
        #expect(environment.measurement.toolUnavailableReason == nil)
        #expect(environment.measurement.liveWarnings.isEmpty)
        #expect(!environment.measurement.refusesForMissingScale())
    }

    /// The path the manual test reached: a radius committed on the X/Y sheet.
    @Test("L-102: a refused commit says why in words, never in the engine's case names")
    @MainActor
    func refusedCommitIsPlainWords() async throws {
        let (environment, session, page) = try await Self.environment(separateAxes: true)
        let radius = Self.record(page, tool: .radius, geometry: MeasurementGeometry(
            pageID: page.id, points: [PDFPoint(x: 50, y: 50), PDFPoint(x: 60, y: 50)]
        ))
        await environment.commit(radius, family: .measurement)
        let warning = try #require(environment.document.warnings.first { $0.id == AppCoreEnvironment.commitFailureWarningID })
        // Old output: "Nothing was added to the drawing or the ledger. The engine reported: measurement
        // failed: scaleApplication(ZPDFGeometry.ScaleApplicationError.directionRequiredForNonUniformScale(7F32…))"
        #expect(warning.message == "Nothing was added to the drawing or the ledger. "
            + MeasurementWarningSummary.circleNeedsUniformScale.message)
        for raw in ["scaleApplication", "ScaleApplicationError", "directionRequired", "engine reported", "measurement failed"] {
            #expect(!warning.message.contains(raw), "\(raw)")
        }
        #expect(await session.orderedMarkups.isEmpty)

        // The session's own refusal carries the same words, so `description` is not raw either.
        do {
            _ = try await session.measure(tool: .radius, geometry: radius.geometry!)
            Issue.record("a radius under separate X and Y scales must be refused")
        } catch let error as DocumentCommandError {
            #expect(error == .measurementFailed(MeasurementWarningSummary.circleNeedsUniformScale.message))
        }
    }

    @Test("L-102: the refusal sentences name what to do, and keep a detail written in words")
    func refusalSentences() {
        #expect(UserFacingRefusal.sentence(for: DocumentCommandError.markupLocked(MarkupID(UUID())))
            == "The markup is locked. Unlock it to change it.")
        #expect(UserFacingRefusal.sentence(for: DocumentCommandError.measurementFailed("a cutout cannot be its own parent"))
            == "A cutout cannot be its own parent.")
        #expect(UserFacingRefusal.sentence(for: AreaSplitRefusal.lineMissesArea) == AreaSplitRefusal.lineMissesArea.message)
        #expect(UserFacingRefusal.sentence(for: MeasurementEngineError.measurement(.missingParameter(.depth)))
            == "This measurement needs a depth. Enter it in the tool options and try again.")
        struct Opaque: Error {}
        #expect(UserFacingRefusal.sentence(for: Opaque()) == "Zenit could not complete this change.")
    }

    // MARK: L-102 re-fix — the scale where the circle is drawn

    /// Waits, bounded, until the session holds `count` markups (a commit runs in a task that
    /// awaits the Scale Region decision before the command is queued).
    @MainActor
    static func waitForMarkups(_ session: TakeoffSession, count: Int) async -> [ZPDFContracts.MarkupRecord] {
        for _ in 0..<400 {
            let markups = await session.orderedMarkups
            if markups.count >= count { return markups }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return await session.orderedMarkups
    }

    static func double(_ value: Decimal?) -> Double? {
        value.map { NSDecimalNumber(decimal: $0).doubleValue }
    }

    /// 1:20 in metres per point: 20 × 0.0254 m / 72.
    static let detailMetresPerPoint = 20 * 0.0254 / 72

    /// Adds a 1:20 detail over (0, 0)–(200, 200) and turns snapping off, so a click lands where
    /// it is made — the region's outline is a snap target (U-086) and would move a point near it.
    @MainActor
    static func addDetail(_ environment: AppCoreEnvironment, _ session: TakeoffSession, _ page: ZPDFContracts.PageDescriptor) async throws
        -> (outcome: DocumentBatchOutcome, scaleID: ScaleID, regionID: ScaleRegionID) {
        let detail = try await session.addRegionPresetScale(
            page: page.id, ratioDenominator: 20,
            boundary: [PDFPoint(x: 0, y: 0), PDFPoint(x: 200, y: 0), PDFPoint(x: 200, y: 200), PDFPoint(x: 0, y: 200)],
            name: "Detail 3"
        )
        var snap = await session.currentSnapSettings
        snap.enabledKinds = []
        try await session.setSnapSettings(snap)
        await environment.refresh()
        return detail
    }

    /// The checker's case: a sheet calibrated with separate X and Y scales that holds a detail
    /// calibrated as one scale. The first L-102 fix refused every circle on it — the region's too.
    @Test("L-102: on an X/Y sheet a radius inside a uniform Scale Region measures at its scale; outside it is refused in words")
    @MainActor
    func radiusInsideAUniformRegion() async throws {
        let (environment, session, page) = try await Self.environment(separateAxes: true)
        let detail = try await Self.addDetail(environment, session, page)
        let measurement = environment.measurement
        #expect(measurement.activeScale?.isUniform == false)

        measurement.activate(kind: .radius)
        // Old output: toolUnavailableReason "This sheet has separate X and Y scales, so a circle
        // drawn on it has no single radius. Calibrate one scale for both directions to measure
        // circles." and a blocking warning on arming — on a sheet whose detail measures circles.
        #expect(measurement.toolUnavailableReason == nil)
        #expect(measurement.liveWarnings.isEmpty)
        #expect(measurement.armedToolNote
            == "Outside its Scale Regions this sheet has separate X and Y scales. Measure circles inside a Scale Region that has one scale for both directions.")

        // Outside the detail the sheet's own X/Y scale applies: refused up front, in words.
        let here = MeasurementWarningSummary.circleNeedsUniformScaleHere
        #expect(measurement.refusesForMissingScale(at: PDFPointValue(x: 400, y: 400)))
        #expect(measurement.placedPoints.isEmpty)
        #expect(measurement.liveWarnings == [here])
        #expect(measurement.uniformScaleRefusals == 1)
        #expect(environment.status.snapshot.activeToolNote == here.message)
        #expect(!here.message.contains("Calibrate"), "no advice to recalibrate a sheet that measures circles in part")

        // Inside it the region's uniform scale applies. Old output: refused (refusesForMissingScale true).
        #expect(!measurement.refusesForMissingScale(at: PDFPointValue(x: 100, y: 100)))
        #expect(measurement.uniformScaleRefusals == 1)
        measurement.placePoint(PDFPointValue(x: 100, y: 100))
        measurement.placePoint(PDFPointValue(x: 150, y: 100))
        await measurement.settlePlacements()
        await measurement.settlePreviewsForTesting()
        #expect(!measurement.liveWarnings.contains(here))
        #expect(!measurement.liveWarnings.contains(.circleNeedsUniformScale))
        #expect(measurement.canCommit)
        // A 50 pt radius at 1:20 is 0.3528 m, live — before, no live value at all (sheet scale).
        #expect(measurement.livePrimaryField?.displayTextWithUnit == "0.35 m")

        measurement.commitActiveMeasurement()
        let stored = try #require(await Self.waitForMarkups(session, count: 1).first)
        #expect(stored.tool == .radius)
        #expect(stored.scaleRegionID == detail.regionID)
        #expect(stored.scaleID == detail.scaleID)
        let radius = try #require(Self.double(stored.measurement?.values[.radius]?.value))
        #expect(abs(radius - 50 * Self.detailMetresPerPoint) < 1e-9, "\(radius)")
        #expect(!environment.document.warnings.contains { $0.id == AppCoreEnvironment.commitFailureWarningID })
    }

    /// The commit path for a radius outside the region still refuses in words, not raw text.
    @Test("L-102: on the same sheet a radius committed outside the region is refused with the sentence")
    @MainActor
    func radiusOutsideTheRegionIsRefusedInWords() async throws {
        let (environment, session, page) = try await Self.environment(separateAxes: true)
        _ = try await Self.addDetail(environment, session, page)
        let outside = Self.record(page, tool: .radius, geometry: MeasurementGeometry(
            pageID: page.id, points: [PDFPoint(x: 400, y: 400), PDFPoint(x: 450, y: 400)]
        ))
        await environment.commit(outside, family: .measurement)
        let warning = try #require(environment.document.warnings.first { $0.id == AppCoreEnvironment.commitFailureWarningID })
        #expect(warning.message == "Nothing was added to the drawing or the ledger. "
            + MeasurementWarningSummary.circleNeedsUniformScale.message)
        #expect(await session.orderedMarkups.isEmpty)
    }

    /// The live value is read at the scale the commit uses — inside a region, the region's.
    @Test("L-102: a length drawn inside a Scale Region reads its live value at the region's scale")
    @MainActor
    func liveValueInsideARegionUsesItsScale() async throws {
        let (environment, session, page) = try await Self.environment()
        _ = try await Self.addDetail(environment, session, page)
        let measurement = environment.measurement
        measurement.activate(kind: .length)
        measurement.placePoint(PDFPointValue(x: 10, y: 10))
        measurement.placePoint(PDFPointValue(x: 110, y: 10))
        await measurement.settlePlacements()
        await measurement.settlePreviewsForTesting()
        // 100 pt × 0.007056 m/pt = 0.71 m. Old output: "10.00 m", the sheet's 0.1 m/pt.
        #expect(measurement.livePrimaryField?.displayTextWithUnit == "0.71 m")
        measurement.commitActiveMeasurement()
        let stored = try #require(await Self.waitForMarkups(session, count: 1).first)
        let length = try #require(Self.double(stored.measurement?.values[.planLength]?.value))
        #expect(abs(length - 100 * Self.detailMetresPerPoint) < 1e-9, "\(length)")
    }

    static func scaleSummary(uniform: Bool) -> ScaleSummary {
        ScaleSummary(id: UUID(), name: "s", displayString: "1:50", isUniform: uniform,
                     sx: 0.1, sy: uniform ? 0.1 : 0.2, unit: .metre, version: 1, locked: false)
    }

    static func regionSummary(_ page: PageID, _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double,
                              scale: ScaleSummary, priority: Int = 1) -> ScaleRegionSummary {
        ScaleRegionSummary(
            id: UUID(), name: "R", pageID: page.rawValue, pageLabel: "Plan-A", scale: scale,
            boundary: [PDFPointValue(x: x0, y: y0), PDFPointValue(x: x1, y: y0), PDFPointValue(x: x1, y: y1), PDFPointValue(x: x0, y: y1)],
            priority: priority, locked: false, colorRGBA: ColorRGBA(red: 0, green: 1, blue: 1, alpha: 1)
        )
    }

    @Test("L-102: where a circle can be read, region by region")
    func uniformScaleCoverageRule() {
        let page = PageID(UUID())
        let uniform = Self.scaleSummary(uniform: true)
        let separate = Self.scaleSummary(uniform: false)
        let inside = PDFPointValue(x: 50, y: 50)
        let outside = PDFPointValue(x: 400, y: 400)

        // X/Y sheet, uniform detail: inside yes, outside no, the edge counts as inside.
        let detailOnXY = UniformScaleCoverage(pageID: page, pageScale: separate, regions: [Self.regionSummary(page, 0, 0, 100, 100, scale: uniform)])
        #expect(!detailOnXY.circlesImpossibleOnSheet)
        #expect(detailOnXY.admitsCircle(at: inside))
        #expect(detailOnXY.admitsCircle(at: PDFPointValue(x: 100, y: 50)))
        #expect(!detailOnXY.admitsCircle(at: outside))

        // X/Y sheet with no region, or only an X/Y region: nowhere.
        #expect(UniformScaleCoverage(pageID: page, pageScale: separate, regions: []).circlesImpossibleOnSheet)
        #expect(UniformScaleCoverage(pageID: page, pageScale: separate, regions: [Self.regionSummary(page, 0, 0, 100, 100, scale: separate)]).circlesImpossibleOnSheet)
        // A uniform region on another page does not help this one.
        #expect(UniformScaleCoverage(pageID: page, pageScale: separate, regions: [Self.regionSummary(PageID(UUID()), 0, 0, 100, 100, scale: uniform)]).circlesImpossibleOnSheet)

        // Uniform sheet, X/Y region: refused inside the region only.
        let xyRegion = UniformScaleCoverage(pageID: page, pageScale: uniform, regions: [Self.regionSummary(page, 0, 0, 100, 100, scale: separate)])
        #expect(!xyRegion.circlesImpossibleOnSheet)
        #expect(!xyRegion.admitsCircle(at: inside))
        #expect(xyRegion.admitsCircle(at: outside))

        // Two overlapping regions: the person is asked at the commit, so one uniform candidate admits.
        let overlap = UniformScaleCoverage(pageID: page, pageScale: separate, regions: [
            Self.regionSummary(page, 0, 0, 100, 100, scale: separate, priority: 2),
            Self.regionSummary(page, 50, 0, 150, 100, scale: uniform, priority: 1),
        ])
        #expect(overlap.admitsCircle(at: PDFPointValue(x: 75, y: 50)))
        #expect(!overlap.admitsCircle(at: PDFPointValue(x: 25, y: 50)))

        // No scale at all is the missing-scale rule's refusal, not this one's.
        let unscaled = UniformScaleCoverage(pageID: page, pageScale: nil, regions: [])
        #expect(!unscaled.circlesImpossibleOnSheet)
        #expect(unscaled.admitsCircle(at: inside))
    }

    /// The other raw paths the checker named: the Scale Regions panel's refusal (app tier) and the
    /// session details that carried identifiers.
    @Test("L-102: session refusal details carry no identifiers")
    @MainActor
    func sessionRefusalDetailsCarryNoIdentifiers() async throws {
        let (environment, session, page) = try await Self.environment()
        let foreignScale = ScaleID(UUID())
        // A region naming a scale the document does not hold.
        let orphan = ScaleRegionDefinition(
            id: ScaleRegionID(UUID()), pageID: page.id, name: "Stair Detail",
            boundary: [PDFPoint(x: 0, y: 0), PDFPoint(x: 100, y: 0), PDFPoint(x: 100, y: 100)],
            scaleID: foreignScale, priority: 1, colorRGBA: ColorRGBA(red: 0, green: 1, blue: 1, alpha: 1)
        )
        do {
            try await environment.commands.perform(.setScaleRegions([orphan]))
            Issue.record("a region naming a scale the document does not hold must be refused")
        } catch {
            let sentence = UserFacingRefusal.sentence(for: error)
            // Old output: "Scale Region Stair Detail names scale <UUID> which this document does not hold".
            #expect(sentence == "The Scale Region “Stair Detail” uses a scale this document no longer holds. Choose one of the sheet's scales for it.")
            #expect(!String(describing: error).contains(foreignScale.rawValue.uuidString))
        }

        // Markups assigned to a scale or a region that is not there.
        let length = Self.record(page, tool: .length, geometry: MeasurementGeometry(
            pageID: page.id, points: [PDFPoint(x: 10, y: 10), PDFPoint(x: 60, y: 10)]
        ))
        try await environment.commands.perform(.addMarkup(length))
        let missingRegion = ScaleRegionID(UUID())
        let refusals: [(DocumentCommand, String, UUID)] = [
            (.setMarkupScaleRegion(ids: [length.id], regionID: nil, scaleID: foreignScale),
             "That scale is no longer in this document. Choose one of the sheet's scales.", foreignScale.rawValue),
            (.setMarkupScaleRegion(ids: [length.id], regionID: missingRegion, scaleID: nil),
             "That Scale Region is no longer on the sheet.", missingRegion.rawValue),
        ]
        for (command, expected, id) in refusals {
            do {
                try await environment.commands.perform(command)
                Issue.record("\(expected)")
            } catch {
                // Old output: "measurement failed: scale <UUID> is not held by this document" and
                // "ledger rebuild failed: no Scale Region <UUID>" ("The ledger could not be updated.").
                #expect(UserFacingRefusal.sentence(for: error) == expected)
                #expect(!String(describing: error).contains(id.uuidString))
            }
        }
    }

    // MARK: L-87

    @Test("L-87: Colour on an area takes its tinted fill along; a fill chosen apart stays")
    @MainActor
    func colourTakesTheTintedFillAlong() async throws {
        let (environment, session, page) = try await Self.environment()
        let blue = RGBAColor(red: 0.12, green: 0.38, blue: 0.86)
        let green = ColorRGBA(red: 0.2, green: 0.6, blue: 0.3, alpha: 1)
        // An area as the tool stores it: the fill is the stroke's colour at 20 %.
        let tinted = Self.record(page, tool: .area, geometry: Self.rectangle(page.id, x0: 10, y0: 10, x1: 110, y1: 90),
                                 style: MarkupStyle(color: blue, fill: AppMeasurementToolPresenter.measurementFill(for: blue)))
        // A rectangle whose fill was picked on its own: red under a blue outline.
        let chosen = Self.record(page, kind: .rectangle, tool: nil, geometry: Self.rectangle(page.id, x0: 200, y0: 10, x1: 300, y1: 90),
                                 style: MarkupStyle(color: blue, fill: RGBAColor(red: 1, green: 0, blue: 0, alpha: 0.5)))
        try await environment.commands.perform(.addMarkup(tinted))
        try await environment.commands.perform(.addMarkup(chosen))

        let receipt = await environment.applyBulkEdit(LedgerBulkEditRequest(
            markupIDs: [tinted.id.rawValue, chosen.id.rawValue],
            style: MarkupStyleEdit(color: green)
        ))
        #expect(receipt.failureDescription == nil)
        let area = try #require(await session.markup(tinted.id))
        let rectangle = try #require(await session.markup(chosen.id))
        #expect(area.style.color == RGBAColor(shown: green))
        // Old output: fill still (0.12, 0.38, 0.86, 0.2) — a blue area under a green pill.
        #expect(area.style.fill == RGBAColor(red: 0.2, green: 0.6, blue: 0.3, alpha: AppMeasurementToolPresenter.measurementFillAlpha))
        #expect(rectangle.style.color == RGBAColor(shown: green))
        #expect(rectangle.style.fill == RGBAColor(red: 1, green: 0, blue: 0, alpha: 0.5), "a fill chosen apart is kept")

        // An explicit fill in the same edit still wins.
        let orange = ColorRGBA(red: 1, green: 0.5, blue: 0, alpha: 0.3)
        var both = MarkupStyleEdit(color: ColorRGBA(red: 0, green: 0, blue: 1, alpha: 1))
        both.fill = orange
        _ = await environment.applyBulkEdit(LedgerBulkEditRequest(markupIDs: [tinted.id.rawValue], style: both))
        #expect(await session.markup(tinted.id)?.style.fill == RGBAColor(shown: orange))
    }

    @Test("L-87: only a fill that tints the old colour follows; no fill stays none")
    func fillFollowRule() {
        let blue = RGBAColor(red: 0.12, green: 0.38, blue: 0.86)
        let green = RGBAColor(red: 0.2, green: 0.6, blue: 0.3)
        #expect(MarkupStyleFit.fill(RGBAColor(red: 0.12, green: 0.38, blue: 0.86, alpha: 0.2), followingColourFrom: blue, to: green)
            == RGBAColor(red: 0.2, green: 0.6, blue: 0.3, alpha: 0.2))
        #expect(MarkupStyleFit.fill(nil, followingColourFrom: blue, to: green) == nil)
        let red = RGBAColor(red: 1, green: 0, blue: 0, alpha: 0.4)
        #expect(MarkupStyleFit.fill(red, followingColourFrom: blue, to: green) == red)
    }

    // MARK: L-70

    /// A 200 × 80 pt area at 0.1 m per point is 20 × 8 m = 160 m²; split at x = 100 it is two
    /// halves of 80 m² each, and merged it is 160 m² again.
    @Test("L-70: merging the two halves of a split gives the original label back")
    @MainActor
    func mergeRestoresTheLabel() async throws {
        let (environment, session, page) = try await Self.environment()
        let area = Self.record(page, tool: .area, geometry: Self.rectangle(page.id, x0: 0, y0: 0, x1: 200, y1: 80),
                               label: "Kitchen floor")
        try await environment.commands.perform(.addMarkup(area))
        _ = try await environment.commands.performBatch(
            try await session.splitCommands(markup: area.id, along: [PDFPoint(x: 100, y: -10), PDFPoint(x: 100, y: 90)]),
            actionName: "Split Area"
        )
        let halves = await session.orderedMarkups
        #expect(halves.map(\.label) == ["Kitchen floor.1", "Kitchen floor.2"])
        #expect(halves.compactMap { $0.measurement?[.netArea]?.value } == [80, 80])

        let plan = try await session.mergePlan(markups: halves.map(\.id))
        _ = try await environment.commands.performBatch(plan.commands, actionName: "Merge Areas")
        let merged = await session.orderedMarkups
        #expect(merged.count == 1)
        // Old output: "Kitchen floor.1".
        #expect(merged.first?.label == "Kitchen floor")
        #expect(merged.first?.measurement?[.netArea]?.value == 160)

        // One ⌘Z takes the merge back, the part's label with it.
        await environment.commands.undo()
        await environment.commands.settle()
        #expect(Set(await session.orderedMarkups.map(\.label)) == ["Kitchen floor.1", "Kitchen floor.2"])
    }

    @Test("L-70: only labels a split made are folded back")
    func mergedLabelRule() {
        #expect(TakeoffSession.mergedLabel(["Kitchen floor.1", "Kitchen floor.2"]) == "Kitchen floor")
        #expect(TakeoffSession.mergedLabel(["Kitchen floor", "Kitchen floor.2"]) == "Kitchen floor")
        #expect(TakeoffSession.mergedLabel(["Area A.1.1", "Area A.1.2"]) == "Area A.1")
        #expect(TakeoffSession.mergedLabel(["Kitchen", "Hall"]) == nil)
        #expect(TakeoffSession.mergedLabel(["Kitchen.1", "Hall.2"]) == nil)
        #expect(TakeoffSession.mergedLabel(["Kitchen", "Kitchen"]) == nil, "nothing was split")
        #expect(TakeoffSession.mergedLabel(["", ""]) == nil)
        #expect(TakeoffSession.mergedLabel([".1", ".2"]) == nil)
    }

    // MARK: L-99

    @Test("L-99: a Note is Added in History, a measurement is Measured")
    @MainActor
    func noteIsAddedNotMeasured() async throws {
        let (environment, _, page) = try await Self.environment()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenit-l8-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try await ProjectDatabaseActor.open(at: directory.appendingPathComponent("history.sqlite"))
        environment.history.attach(database: database, projectID: page.documentID.rawValue.uuidString)

        var note = Self.record(page, kind: .note, tool: nil, geometry: MeasurementGeometry(
            pageID: page.id, points: [PDFPoint(x: 40, y: 40)]
        ), subject: "Notes")
        note.caption = "Sticky note text"
        let area = Self.record(page, tool: .area, geometry: Self.rectangle(page.id, x0: 0, y0: 0, x1: 100, y1: 80))
        try await environment.commands.perform(.addMarkup(note))
        try await environment.commands.perform(.addMarkup(area))
        await environment.history.settle()

        let noteRow = try #require(environment.history.events.first { $0.markupID == note.id.rawValue })
        let areaRow = try #require(environment.history.events.first { $0.markupID == area.id.rawValue })
        // Old output: "Measured" for both.
        #expect(noteRow.action == LedgerAuditEvent.markupAddedAction)
        #expect(noteRow.actionDisplayName == "Added")
        #expect(areaRow.action == "markup_created")
        #expect(areaRow.actionDisplayName == "Measured")
        // The filter offers the two apart, and each finds its own row.
        #expect(environment.history.auditActions.contains(LedgerAuditEvent.markupAddedAction))
        #expect(environment.history.auditEvents(matching: LedgerAuditFilter(action: LedgerAuditEvent.markupAddedAction))
            .map(\.markupID) == [note.id.rawValue])
    }
}
