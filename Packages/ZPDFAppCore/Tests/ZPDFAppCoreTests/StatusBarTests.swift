import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFSnapEngine
import ZPDFUIPresentation

/// The status bar line.
///
/// The line is six segments in a fixed order joined by ` │ `. It is binding for layout, so it
/// is asserted verbatim here rather than described.
@Suite("Status bar")
struct StatusBarTests {

    static func snapshot(
        pageIndex: Int = 0,
        pageCount: Int = 4,
        scale: String = "1:100 @ 1.00 m",
        unit: String = "m",
        cursor: PDFPointValue? = PDFPointValue(x: 124.5, y: 331),
        zoom: String = "145%",
        grid: Bool = false,
        vector: Bool = true,
        markup: Bool = true,
        index: GeometryIndexStatus = .ready
    ) -> StatusBarSnapshot {
        StatusBarSnapshot(
            pageLabel: "A-101",
            pageIndex: pageIndex,
            pageCount: pageCount,
            pageDimensionsText: "841 × 594 mm",
            activeScaleDisplay: scale,
            outputUnitSymbol: unit,
            cursorPagePoint: cursor,
            cursorDisplayText: AppStatusPresenter.cursorText(cursor),
            zoomDisplayString: zoom,
            gridSnapEnabled: grid,
            vectorSnapEnabled: vector,
            markupSnapEnabled: markup,
            geometryIndexStatus: index
        )
    }

    @Test("The line is the reference's six segments, in order, separated by ' │ '")
    func theLine() {
        let line = AppStatusPresenter.line(Self.snapshot())
        #expect(line == "Page: 1 of 4 │ Scale: 1:100 @ 1.00 m │ Unit: m │ Snap: Vector, Markup │ Coord: (124.5, 331.0) │ Zoom: 145%")
        #expect(AppStatusPresenter.segments(Self.snapshot()).count == 6)
    }

    @Test("The snap segment names its sources in words, never by colour alone")
    func snapSegmentIsText() {
        #expect(AppStatusPresenter.snapSourceText(Self.snapshot()) == "Vector, Markup")
        #expect(AppStatusPresenter.snapSourceText(Self.snapshot(grid: true)) == "Vector, Markup, Grid")
        #expect(AppStatusPresenter.snapSourceText(Self.snapshot(vector: false)) == "Markup")
        #expect(
            AppStatusPresenter.snapSourceText(Self.snapshot(vector: false, markup: false)) == "Off",
            "an empty segment would read as 'snap is on and found nothing'"
        )
    }

    @Test("A page with no vector content cannot claim Vector Snap")
    func vectorSnapNeedsVectorContent() {
        // Even with the toggle on, a scanned sheet reports no vector source: the segment
        // states what the next click will actually do (spec 13.11).
        let scanned = Self.snapshot(vector: true, index: .unavailable)
        #expect(AppStatusPresenter.snapSourceText(scanned) == "Markup")
    }

    @Test("The Vector Snap switch refuses to turn on where it would do nothing")
    @MainActor
    func vectorSnapSwitchRefuses() {
        let presenter = AppStatusPresenter(snapshot: Self.snapshot(vector: false, index: .unavailable))
        presenter.setVectorSnapEnabled(true)
        #expect(presenter.snapshot.vectorSnapEnabled == false)

        presenter.updateGeometryIndex(.ready)
        presenter.setVectorSnapEnabled(true)
        #expect(presenter.snapshot.vectorSnapEnabled)
    }

    @Test("The cursor readout is one decimal and empties when the pointer leaves the page")
    @MainActor
    func cursorReadout() {
        let presenter = AppStatusPresenter(snapshot: Self.snapshot())
        #expect(presenter.snapshot.cursorDisplayText == "(124.5, 331.0)")

        presenter.updateCursor(PDFPointValue(x: 0.04, y: -12.349))
        #expect(presenter.snapshot.cursorDisplayText == "(0.0, -12.3)")

        presenter.updateCursor(nil)
        #expect(presenter.snapshot.cursorDisplayText.isEmpty)
        #expect(AppStatusPresenter.line(presenter.snapshot).contains("Coord: —"))
    }

    @Test("The scale segment states the ratio and what one output unit measures")
    func scaleSegment() throws {
        let scale = try ScaleTransform.uniform(
            id: ScaleID(UUID()),
            metresPerPoint: Decimal(string: "0.0176388888888888888888888888888888888")!,
            units: .metric,
            source: .preset
        )
        // 1 pt = 1/72 in = 0.0003527 m, so 0.01764 m per point is very nearly 1:50.
        #expect(ScaleBridge.ratioText(for: scale) == "1:50")
        // L-38: the unit is spaced from its number, as every other value in the app is.
        #expect(ScaleBridge.statusText(for: scale, units: .metric) == "1:50 @ 1.00 m")
        // Old output: "1:50 @ 0.30ft" — a foot's size in metres printed with the foot's symbol,
        // i.e. a claim that a foot is 0.30 ft (BH-093). One output unit is 1.00 of itself.
        #expect(ScaleBridge.statusText(for: scale, units: .imperial) == "1:50 @ 1.00 ft")
    }

    @Test("The status presenter emits the new scale string after a calibration commit")
    @MainActor
    func scaleReadoutFollowsCalibration() async throws {
        // The assembled app calibrated correctly (2,99 m rows landed in
        // the ledger) while the status bar kept saying "No scale" — the scale was fetched
        // asynchronously and every layout pass clobbered it back to the empty state first.
        // The readout is now a synchronous function of the document snapshot, so a
        // calibration commit followed by any number of status refreshes must show the
        // scale, deterministically.
        let documentID = DocumentID(UUID())
        let page = ZPDFContracts.PageDescriptor(
            id: PageID(UUID()),
            documentID: documentID,
            index: 0,
            label: "A-101",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 612, height: 792))
        )
        let session = try TakeoffSession(documentID: documentID, pages: [page])
        let environment = try await AppCoreEnvironment.make(session: session, documentID: documentID)
        #expect(environment.status.snapshot.activeScaleDisplay == "No scale")

        // 100 points stand for 10 metres: metresPerPoint 0.1, a nominal 1:283.
        _ = try await environment.commands.calibrate(
            page: page.id,
            first: PDFPoint(x: 0, y: 0),
            second: PDFPoint(x: 100, y: 0),
            knownLength: 10,
            knownLengthUnit: .metre
        )
        await environment.refresh()
        // 0.1 m per point × 72 / 0.0254 points per metre = 283.4645…, which reads 1:283 — the
        // Calibrate sheet's precision-by-size rule, shared with every `1:n` since L-38.
        #expect(environment.status.snapshot.activeScaleDisplay == "1:283 @ 1.00 m")
        #expect(environment.status.statusLine.contains("Scale: 1:283 @ 1.00 m"))

        // The regression's shape: repeated viewport-driven refreshes (scroll, cursor
        // moves) must never take the readout back to "No scale".
        for _ in 0..<8 {
            environment.refreshStatus()
            #expect(environment.status.snapshot.activeScaleDisplay == "1:283 @ 1.00 m")
        }

        // And one ⌘Z returns the readout to the honest empty state with the scale.
        await environment.commands.undo()
        #expect(environment.status.snapshot.activeScaleDisplay == "No scale")
    }

    @Test("Snap toggles map onto the engine's enabled-kind set")
    func togglesReachTheEngine() {
        let all = SnapSourceToggles(grid: true, vector: true, markup: true).snapKinds()
        #expect(all.contains(.endpoint))
        #expect(all.contains(.markupVertex))
        #expect(all.contains(.grid))

        let markupOnly = SnapSourceToggles(grid: false, vector: false, markup: true).snapKinds()
        #expect(markupOnly.contains(.markupVertex))
        #expect(!markupOnly.contains(.endpoint), "endpoint is PDF geometry, which is off")
        #expect(!markupOnly.contains(.grid))
        // These three never depend on a source switch: a zone boundary and a calibration
        // point are Zenit's own geometry, and a parallel guide is derived from the anchor.
        #expect(markupOnly.contains(.zoneBoundary))
        #expect(markupOnly.contains(.calibrationPoint))
        #expect(markupOnly.contains(.parallelGuide))
    }

    @Test("Warnings sort most serious first and only dismissible ones can be dismissed")
    @MainActor
    func warningTray() {
        let presenter = AppStatusPresenter(snapshot: Self.snapshot())
        let blocking = AppWarning(
            id: UUID(),
            severity: .danger,
            title: "Scale missing",
            message: "This page has no scale.",
            source: "Scale",
            isDismissible: false,
            timestamp: Date(timeIntervalSince1970: 0)
        )
        let note = AppWarning(
            id: UUID(),
            severity: .info,
            title: "OCR used",
            message: "Some results came from recognised text.",
            source: "Search",
            timestamp: Date(timeIntervalSince1970: 0)
        )
        presenter.setWarnings([note, blocking])
        #expect(presenter.warnings.first?.severity == .danger)
        #expect(presenter.highestSeverity == .danger)

        presenter.dismissWarning(id: blocking.id)
        #expect(presenter.warnings.count == 2, "a blocking warning is not dismissible")

        presenter.dismissAllWarnings()
        #expect(presenter.warnings.map(\.id) == [blocking.id])
    }

    @Test("An empty bar says so rather than showing a plausible scale")
    func emptyBar() {
        let line = AppStatusPresenter.line(AppStatusPresenter.emptySnapshot)
        #expect(line.contains("Page: 0 of 0"))
        #expect(line.contains("Scale: No scale"))
        #expect(line.contains("Coord: —"))
    }
}
