import Foundation
import Testing
@testable import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation

/// Bug hunt 2, the measurement palette and Draw-mode arming (BH-002, BH-003, BH-012, BH-084,
/// BH-085, BH-086, BH-112, BH-113, BH-114, BH-414, BH-449).
///
/// Every test names the old output it replaces.
@MainActor
@Suite("Bug hunt 2: arming and the measurement palette")
struct BugHunt2ArmingTests {

    private func makeEnvironment() async throws -> (AppCoreEnvironment, TakeoffSession, ZPDFContracts.PageDescriptor) {
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
        return (environment, session, page)
    }

    private func makePresenter() throws -> (AppMeasurementToolPresenter, PageID) {
        let documentID = DocumentID(UUID())
        let pageID = PageID(UUID())
        let page = ZPDFContracts.PageDescriptor(
            id: pageID,
            documentID: documentID,
            index: 0,
            label: "1",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 595, height: 842))
        )
        let session = try TakeoffSession(documentID: documentID, pages: [page])
        return (AppMeasurementToolPresenter(session: session, documentID: documentID, pageID: pageID), pageID)
    }

    private static func preset(
        _ kind: MeasurementKind,
        name: String,
        defaults: ToolPresetMeasurementDefaults = .none,
        labelPattern: String = "",
        status: ZPDFUIPresentation.MarkupStatus = .none,
        custom: [String: String] = [:],
        unit: ZPDFUIPresentation.LengthUnit = .metre
    ) -> ToolPresetSummary {
        ToolPresetSummary(
            id: UUID(),
            name: name,
            category: "Test",
            panel: .myTools,
            markupKind: .measurement,
            measurementKind: kind,
            colorRGBA: ColorRGBA(red: 0.2, green: 0.6, blue: 0.9),
            defaultSubject: name,
            measurementDefaults: defaults,
            labelPattern: labelPattern,
            defaultStatus: status,
            displayLengthUnit: unit,
            customDefaults: custom
        )
    }

    // MARK: BH-002

    @Test("A sloped preset fills the slope field, so the tool can commit")
    func slopedPresetFillsTheField() async throws {
        let (environment, _, _) = try await makeEnvironment()
        let roof = Self.preset(
            .trueSlopedArea,
            name: "Roof 6:12",
            defaults: ToolPresetMeasurementDefaults(slopePercent: 50, slopeAzimuthDegrees: 90)
        )
        environment.toolLibrary.setPresets([roof])
        environment.toolLibrary.activatePreset(id: roof.id)

        // Old output: parameterText "" and parameterValue nil — the slope was in the block but
        // `isMissingRequiredParameter` stayed true, so Finish never enabled.
        #expect(environment.measurement.parameterText == "50")
        #expect(environment.measurement.parameterValue == 50)
        #expect(!environment.measurement.isMissingRequiredParameter)
        environment.measurement.appendRawPoints([
            PDFPointValue(x: 0, y: 0), PDFPointValue(x: 100, y: 0), PDFPointValue(x: 100, y: 100)
        ])
        // The field's value is folded in without losing the preset's fall line.
        let slope = environment.measurement.parametersInEffect.slope
        #expect(slope.mode == .uniformPlane)
        #expect(try slope.magnitude?.percentValue() == 50)
        #expect(slope.azimuth?.degrees == 90)
    }

    // MARK: BH-003

    @Test("The toolbar mirroring an arm keeps the preset's second height")
    func toolbarMirrorKeepsTheParameterBlock() async throws {
        let (environment, _, _) = try await makeEnvironment()
        // The app's mirror: lighting the toolbar chip calls back into activate(kind:).
        environment.onLibraryArmedTool = { [weak environment] mode in
            if case .measure(let kind) = mode { environment?.measurement.activate(kind: kind) }
        }
        let gable = Self.preset(
            .wallArea,
            name: "Gable",
            defaults: ToolPresetMeasurementDefaults(
                wallHeight: DecimalQuantity(value: 3, dimension: .length),
                wallHeightAtEnd: DecimalQuantity(value: 5, dimension: .length)
            )
        )
        environment.toolLibrary.setPresets([gable])
        environment.toolLibrary.activatePreset(id: gable.id)

        // Old output: heightAtEnd nil — the echo reset `presetBaseParameters` to `.default`.
        let parameters = environment.measurement.parametersInEffect
        #expect(parameters.heightAtEnd == .length(5))
        #expect(parameters.height == .length(3))
    }

    // MARK: BH-084

    @Test("A preset depth in feet shows six places and keeps the exact metres")
    func imperialPresetDepthIsReadableAndExact() async throws {
        let (environment, _, _) = try await makeEnvironment()
        let slab = Self.preset(
            .volume,
            name: "Slab",
            defaults: ToolPresetMeasurementDefaults(depth: DecimalQuantity(value: Decimal(string: "0.2")!, dimension: .length)),
            unit: .foot
        )
        environment.toolLibrary.setPresets([slab])
        environment.toolLibrary.activatePreset(id: slab.id)

        // Old output: "0.65616797900262467191601049868766404" (0.2 / 0.3048 to 38 digits).
        // Hand-derived: 0.2 / 0.3048 = 0.656167979…, rounded to six places = 0.656168.
        #expect(environment.measurement.parameterText == "0.656168")
        // The engine keeps the preset's exact 0.2 m while the field is untouched.
        #expect(environment.measurement.parametersInEffect.depth == .length(Decimal(string: "0.2")!))
        // Typing makes the typed number the value: 1 ft = 0.3048 m exactly.
        environment.measurement.setParameterText("1")
        #expect(environment.measurement.parametersInEffect.depth == .length(Decimal(string: "0.3048")!))
    }

    // MARK: BH-085

    @Test("Draw mode honours a preset's label, status and custom column value")
    func drawModeHonoursRowDefaults() async throws {
        let (environment, session, page) = try await makeEnvironment()
        let column = LedgerColumnDefinition(
            id: ColumnID(UUID()),
            key: "custom.costCode",
            title: "Cost code",
            kind: .text,
            standard: nil,
            dimension: nil,
            isEditable: true,
            isVisible: true,
            order: 100
        )
        try await session.addCustomColumns([column])
        await environment.refresh()

        let length = Self.preset(
            .length,
            name: "Kerb",
            labelPattern: "Kerb run",
            status: .open,
            custom: ["custom.costCode": "1234"]
        )
        environment.toolLibrary.setPresets([length])
        environment.toolLibrary.activatePreset(id: length.id)
        var committed: [MarkupRecord] = []
        environment.measurement.onCommit = { committed.append($0) }
        environment.measurement.setPage(page.id)
        environment.measurement.appendRawPoints([PDFPointValue(x: 0, y: 0), PDFPointValue(x: 100, y: 0)])
        environment.measurement.commitActiveMeasurement()

        // Old output: label "Length A", status .none, customValues [:].
        let record = try #require(committed.first)
        #expect(record.label == "Kerb run")
        #expect(record.status == .open)
        #expect(record.customValues[column.id] == .text("1234"))

        // Disarming clears all three, so a plain Length afterwards inherits nothing.
        environment.toolLibrary.clearActivePreset()
        #expect(environment.measurement.defaultLabel.isEmpty)
        #expect(environment.measurement.defaultStatus == .none)
        #expect(environment.measurement.defaultCustomValues.isEmpty)
    }

    // MARK: BH-086

    @Test("Arming a measurement preset finishes a count in progress")
    func armingFinishesTheCount() async throws {
        let (environment, _, _) = try await makeEnvironment()
        var committed: [MarkupRecord] = []
        environment.measurement.onCommit = { committed.append($0) }
        environment.measurement.activate(kind: .count)
        environment.measurement.appendRawPoints((0..<10).map { PDFPointValue(x: Double($0) * 10, y: 10) })

        let length = Self.preset(.length, name: "Kerb")
        environment.toolLibrary.setPresets([length])
        environment.toolLibrary.activatePreset(id: length.id)

        // Old output: committed empty — activate(kind:) discarded the ten marks.
        #expect(committed.count == 1)
        #expect(committed.first?.geometry?.countPoints.count == 10)
        #expect(environment.measurement.activeKind == .length)
    }

    // MARK: BH-112

    @Test("A page turn counts a mark whose snap is still resolving")
    func pageTurnAbsorbsInFlightMarks() throws {
        let (presenter, pageID) = try makePresenter()
        var committed: [MarkupRecord] = []
        presenter.onCommit = { committed.append($0) }
        presenter.activate(kind: .count)
        presenter.appendRawPoints([PDFPointValue(x: 10, y: 10), PDFPointValue(x: 20, y: 20)])
        // Queued behind the snap resolve: nothing has landed when the page turns.
        presenter.placePoint(PDFPointValue(x: 30, y: 30))
        presenter.setPage(PageID(UUID()))

        // Old output: two count points — the queued mark died at the epoch guard.
        #expect(committed.count == 1)
        #expect(committed.first?.geometry?.countPoints.count == 3)
        #expect(committed.first?.pageID == pageID)
    }

    // MARK: BH-012, BH-113, BH-414

    @Test("Auto-label parsing is bounded, strict and reads split pieces")
    func autoLabelParsing() {
        // BH-012 old output: a trap — `ordinal * 26` overflowed Int at the 14th letter.
        #expect(AppMeasurementToolPresenter.autoLabelOrdinal(of: "Length NORTHELEVATIONWALLS", kind: .length) == nil)
        // Hand-derived bijective base 26: A = 1, Z = 26, AA = 27, ZZZZ = 475 254.
        #expect(AppMeasurementToolPresenter.autoLabelOrdinal(of: "Length A", kind: .length) == 1)
        #expect(AppMeasurementToolPresenter.autoLabelOrdinal(of: "Length AA", kind: .length) == 27)
        #expect(AppMeasurementToolPresenter.autoLabelOrdinal(of: "Length ZZZZ", kind: .length) == 475_254)
        // BH-113 old output: 83 943 839 for "GARAGE", seeding the allocator.
        #expect(AppMeasurementToolPresenter.autoLabelOrdinal(of: "Area GARAGE", kind: .area) == nil)
        // BH-414 old output: nil — split pieces seeded nothing.
        #expect(AppMeasurementToolPresenter.autoLabelOrdinal(of: "Length C (1 of 2)", kind: .length) == 3)
    }

    @Test("A capitalised user label does not poison the allocator, and letters are never duplicated")
    func allocatorIgnoresTypedCapitalsAndSkipsTakenLabels() async throws {
        let (environment, session, page) = try await makeEnvironment()
        func area(_ label: String) -> MarkupRecord {
            MarkupRecord(
                id: MarkupID(UUID()),
                documentID: DocumentID(environment.snapshot.documentID),
                pageID: page.id,
                kind: .measurement,
                tool: .area,
                subject: "Area",
                label: label,
                author: "test",
                geometry: MeasurementGeometry(pageID: page.id, polygons: [PolygonGeometry(outer: PolygonRing(points: [
                    PDFPoint(x: 0, y: 0), PDFPoint(x: 10, y: 0), PDFPoint(x: 10, y: 10)
                ], isClosed: true))]),
                createdAt: Date(timeIntervalSince1970: 0),
                modifiedAt: Date(timeIntervalSince1970: 0)
            )
        }
        // "Area GAR" parses (3 letters, ordinal 4 958) but is far beyond the page's population.
        try await session.apply(.addMarkup(area("Area GAR")))
        try await session.apply(.addMarkup(area("Area A")))
        await environment.refresh()
        var committed: [MarkupRecord] = []
        environment.measurement.onCommit = { committed.append($0) }
        environment.measurement.setPage(page.id)
        environment.measurement.activate(kind: .area)
        environment.measurement.appendRawPoints([
            PDFPointValue(x: 0, y: 0), PDFPointValue(x: 50, y: 0), PDFPointValue(x: 50, y: 50)
        ])
        environment.measurement.commitActiveMeasurement()
        // Old output: "Area GAS". "Area A" is taken, so the allocator steps to "Area B".
        #expect(committed.first?.label == "Area B")
    }

    // MARK: BH-114, BH-449

    @Test("The parameter field refuses prefixes, junk and negative depths")
    func parameterParsing() {
        // BH-449 old output: 1 and 0.15 — `Decimal(string:)` parsed the prefix.
        #expect(AppMeasurementToolPresenter.parseParameter("1 500") == 1500)
        #expect(AppMeasurementToolPresenter.parseParameter("1 500,5") == Decimal(string: "1500.5"))
        #expect(AppMeasurementToolPresenter.parseParameter("0.15.2") == nil)
        #expect(AppMeasurementToolPresenter.parseParameter("12abc") == nil)
        // X-020: the field reads by the one typed-number grammar, which strips grouping wherever
        // it stands (CR-184), so "1 50" is 150 here exactly as it is in a ledger cell. Before
        // X-020 this field alone refused it with a stricter grouping rule of its own.
        #expect(AppMeasurementToolPresenter.parseParameter("1 50") == 150)
        #expect(AppMeasurementToolPresenter.parseParameter("1 50") == TypedDecimalGrammar.decimal("1 50"))
        #expect(AppMeasurementToolPresenter.parseParameter("0,15") == Decimal(string: "0.15"))
        #expect(AppMeasurementToolPresenter.parseParameter("-0.2") == Decimal(string: "-0.2"))
        // BH-114 old output: -0.2 accepted as a depth, committing a negative volume.
        #expect(AppMeasurementToolPresenter.parseParameter("-0,2", for: .depth) == nil)
        #expect(AppMeasurementToolPresenter.parseParameter("-2", for: .wallHeight) == nil)
        #expect(AppMeasurementToolPresenter.parseParameter("-0.5", for: .totalRiseDrop) == Decimal(string: "-0.5"))
    }

    @Test("A negative depth leaves Volume waiting for a value")
    func negativeDepthCannotCommit() throws {
        let (presenter, _) = try makePresenter()
        presenter.activate(kind: .volume)
        presenter.setParameterText("-0,2")
        // Old output: parameterValue -0.2, so canCommit could turn true.
        #expect(presenter.parameterValue == nil)
        #expect(presenter.isMissingRequiredParameter)
    }
}
