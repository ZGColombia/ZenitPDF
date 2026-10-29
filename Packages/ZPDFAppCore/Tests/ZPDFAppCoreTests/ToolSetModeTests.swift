import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFPersistence
import ZPDFUIPresentation

/// The three tool-set modes, driven through the shipping presenters and the shipping command
/// bus. Nothing here stands a double in for the session, the bus or the
/// audit trail: the claims being made are precisely about those three.
///
/// Every rule of the modes is one test:
///
/// | Rule | Test |
/// |---|---|
/// | Draw arms the preset with every stored property | ``drawModeArmsEveryStoredParameter()`` |
/// | Apply never changes geometry | ``applyNeverTouchesGeometry()`` |
/// | Applying a maths property recomputes through the engine | ``applyRecomputesThroughTheEngine()`` |
/// | Twelve areas, one undo | ``applyOverTwelveAreasIsOneUndo()`` |
/// | One audit entry per affected markup | ``applyWritesOneAuditEntryPerMarkup()`` |
/// | An incompatible preset says what it skipped | ``incompatiblePresetReportsWhatItSkipped()`` |
/// | Place drops an ordinary markup | ``placeDropsAnOrdinaryMarkup()`` |
/// | The mode is remembered with the set | ``setModeIsRememberedAcrossLaunches()`` |
/// | Capture from a markup keeps the maths | ``captureFromSelectionKeepsTheMeasurementParameters()`` |
@Suite("Tool set modes")
struct ToolSetModeTests {

    // MARK: Fixture

    private struct Fixture {
        let environment: AppCoreEnvironment
        let documentID: DocumentID
        let page: ZPDFContracts.PageDescriptor
        let ids: [MarkupID]
    }

    /// A calibrated page at 0.1 m/pt carrying `count` identical 100 × 80 pt areas — 80 m² each,
    /// so a wrong number is visible by eye rather than by arithmetic.
    ///
    /// A Volume fixture is created with a 100 mm depth rather than with none, because the engine
    /// refuses to create a volume that has no thickness at all
    /// (`MeasurementError.missingParameter`). That refusal is correct, and it makes the
    /// recompute test sharper than the empty case would have been: 8 m³ has to become 16 m³, so
    /// a "recompute" that quietly kept the old number cannot pass by being absent.
    @MainActor
    private func makeFixture(
        count: Int = 3,
        tool: MeasurementTool = .area
    ) async throws -> Fixture {
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
        try await environment.commands.calibrate(
            page: page.id,
            first: PDFPoint(x: 0, y: 0),
            second: PDFPoint(x: 100, y: 0),
            knownLength: 10,
            knownLengthUnit: .metre
        )
        var ids: [MarkupID] = []
        for index in 0..<count {
            let id = MarkupID(UUID())
            try await environment.commands.perform(
                .addMarkup(Self.area(
                    id: id, documentID: documentID, pageID: page.id,
                    subject: "Area \(index)", tool: tool,
                    parameters: tool == .volume ? Self.startingDepth : nil
                ))
            )
            ids.append(id)
        }
        await environment.ledger.refresh()
        return Fixture(environment: environment, documentID: documentID, page: page, ids: ids)
    }

    private static func area(
        id: MarkupID,
        documentID: DocumentID,
        pageID: PageID,
        subject: String,
        tool: MeasurementTool = .area,
        parameters: MeasurementParameters? = nil,
        locked: Bool = false
    ) -> ZPDFContracts.MarkupRecord {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        return ZPDFContracts.MarkupRecord(
            id: id,
            documentID: documentID,
            pageID: pageID,
            kind: .measurement,
            tool: tool,
            subject: subject,
            author: "test",
            status: .open,
            locked: locked,
            geometry: MeasurementGeometry(
                pageID: pageID,
                polygons: [PolygonGeometry(outer: PolygonRing(points: [
                    PDFPoint(x: 0, y: 0),
                    PDFPoint(x: 100, y: 0),
                    PDFPoint(x: 100, y: 80),
                    PDFPoint(x: 0, y: 80)
                ], isClosed: true))]
            ),
            parameters: parameters,
            createdAt: stamp,
            modifiedAt: stamp
        )
    }

    /// The depth a Volume fixture starts with: 100 mm, half of what the preset applies.
    static let startingDepth = MeasurementParameters(depth: .length(Decimal(string: "0.1") ?? 0))

    /// "Slab 200 mm": a Volume preset carrying a depth and a depth reference.
    private static func slabPreset(
        panel: ToolLibraryPanel = .myTools,
        subject: String = "Slab"
    ) -> ToolPresetSummary {
        ToolPresetSummary(
            id: UUID(),
            name: "Slab 200 mm",
            category: "Concrete",
            panel: panel,
            markupKind: .measurement,
            measurementKind: .volume,
            colorRGBA: ColorRGBA(red: 0.9, green: 0.7, blue: 0.2, alpha: 1),
            defaultSubject: subject,
            measurementDefaults: ToolPresetMeasurementDefaults(
                depth: .metres(Decimal(string: "0.2") ?? 0),
                volumeDepthReference: .verticalDepth
            )
        )
    }

    private static func makeDatabase() async throws -> (ProjectDatabaseActor, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenit-toolmode-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try await ProjectDatabaseActor.open(
            at: directory.appendingPathComponent("project.sqlite")
        )
        return (database, directory)
    }

    // MARK: Draw

    @Test("Draw arms the tool with every parameter the preset stores, not only the one in the field")
    @MainActor
    func drawModeArmsEveryStoredParameter() async throws {
        let fixture = try await makeFixture(count: 0)
        let environment = fixture.environment
        var preset = Self.slabPreset()
        preset.measurementDefaults.cutoutPolicy = .ignore
        preset.measurementDefaults.perimeterPolicy = .outerPlusCutoutEdges
        environment.toolLibrary.setPresets([preset])

        environment.toolLibrary.activatePreset(id: preset.id)

        #expect(environment.toolLibrary.armedSetMode == .draw, "Draw is the default mode")
        #expect(environment.measurement.activeKind == .volume)
        // The depth reaches the options bar, which is what the estimator can see...
        #expect(environment.measurement.parameterText == "0.2")
        // ...and the three parameters that have no field reach the engine block anyway. Before
        // `setPresetParameters` existed these were dropped between the preset and the tool.
        let armed = environment.measurement.parametersInEffect
        #expect(armed.depth == .length(Decimal(string: "0.2") ?? 0))
        #expect(armed.volumeDepthReference == .verticalDepth)
        #expect(armed.cutoutPolicy == .ignore)
        #expect(armed.perimeterPolicy == .outerPlusCutoutEdges)
    }

    // MARK: Apply

    @Test("Apply changes properties and never geometry")
    @MainActor
    func applyNeverTouchesGeometry() async throws {
        let fixture = try await makeFixture(count: 2)
        let environment = fixture.environment
        let before = try #require(await environment.session.markup(fixture.ids[0]))

        let preset = Self.slabPreset(subject: "Foundation")
        let receipt = await environment.applyPreset(preset, to: Set(fixture.ids.map(\.rawValue)))

        #expect(receipt.failureMessage == nil)
        #expect(receipt.changedMarkupIDs.count == 2)
        let after = try #require(await environment.session.markup(fixture.ids[0]))
        #expect(after.geometry == before.geometry, "Apply mode must not move a single vertex")
        #expect(after.subject == "Foundation")
        #expect(after.style.color == RGBAColor(shown: preset.colorRGBA))
    }

    @Test("Applying a property that feeds the maths recomputes through the engine")
    @MainActor
    func applyRecomputesThroughTheEngine() async throws {
        // 80 m² of outline extruded by 100 mm: 8 m³ before the preset touches it.
        let fixture = try await makeFixture(count: 1, tool: .volume)
        let environment = fixture.environment
        let id = fixture.ids[0]
        let before = try #require(await environment.session.markup(id))
        #expect(before.measurement?.values[.volume]?.value == 8)

        let receipt = await environment.applyPreset(Self.slabPreset(), to: [id.rawValue])
        #expect(receipt.recomputedMarkupIDs == [id.rawValue])

        let after = try #require(await environment.session.markup(id))
        #expect(after.parameters?.depth == .length(Decimal(string: "0.2") ?? 0))
        // 100 × 80 pt at 0.1 m/pt is 80 m²; 80 m² × 0.2 m is 16 m³. The number came out of the
        // calculator, not out of this test — nothing in the apply path writes a measurement.
        let volume = try #require(after.measurement?.values[.volume])
        #expect(volume.value == 16)
        // The formula version comes from the calculator that produced the value, so a number
        // written in from the side rather than computed would not carry one. The *audit* half of
        // the provenance promise is `applyWritesOneAuditEntryPerMarkup`, which needs a database.
        #expect(after.measurement?.formulaVersion != nil)
        #expect(after.modifiedAt > before.modifiedAt)
    }

    @Test("Slab 200 mm over twelve areas is twelve changes and one undo")
    @MainActor
    func applyOverTwelveAreasIsOneUndo() async throws {
        let fixture = try await makeFixture(count: 12, tool: .volume)
        let environment = fixture.environment
        let manager = environment.commands.undoManager

        let receipt = await environment.applyPreset(
            Self.slabPreset(), to: Set(fixture.ids.map(\.rawValue))
        )
        #expect(receipt.changedMarkupIDs.count == 12)
        #expect(receipt.undoActionName == AppCoreEnvironment.applyPresetUndoActionName)
        #expect(manager.undoActionName == AppCoreEnvironment.applyPresetUndoActionName)

        // One ⌘Z, and all twelve are back — not one of twelve.
        await environment.commands.undo()
        for id in fixture.ids {
            let record = try #require(await environment.session.markup(id))
            #expect(
                record.parameters?.depth == .length(Decimal(string: "0.1") ?? 0),
                "\(id) kept the preset's depth after one undo"
            )
            #expect(record.subject.hasPrefix("Area"))
        }
        #expect(!manager.canUndo || manager.undoActionName != AppCoreEnvironment.applyPresetUndoActionName)
    }

    @Test("The trail records one entry per affected markup, under one undo group")
    @MainActor
    func applyWritesOneAuditEntryPerMarkup() async throws {
        let fixture = try await makeFixture(count: 3, tool: .volume)
        let (database, directory) = try await Self.makeDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }
        let environment = fixture.environment
        environment.history.attach(
            database: database, projectID: fixture.documentID.rawValue.uuidString
        )
        await environment.history.settle()
        let baseline = environment.history.events.count

        let receipt = await environment.applyPreset(
            Self.slabPreset(), to: Set(fixture.ids.map(\.rawValue))
        )
        await environment.history.settle()
        #expect(receipt.auditEntryCount == 3)

        let appended = Array(environment.history.events.dropFirst(baseline))
        #expect(appended.count == 3, "one provenance-carrying entry per markup, got \(appended.count)")
        #expect(Set(appended.compactMap(\.markupID)) == Set(fixture.ids.map(\.rawValue)))
        #expect(Set(appended.compactMap(\.undoGroup)).count == 1, "one group for the whole action")
    }

    @Test("An incompatible preset applies the overlap and names what it skipped")
    @MainActor
    func incompatiblePresetReportsWhatItSkipped() async throws {
        // A plain Area cannot take a depth or a volume depth reference; it can take the colour
        // and the subject perfectly well.
        let fixture = try await makeFixture(count: 1, tool: .area)
        let environment = fixture.environment
        let id = fixture.ids[0]

        let receipt = await environment.applyPreset(Self.slabPreset(subject: "Foundation"), to: [id.rawValue])

        #expect(receipt.failureMessage == nil, "an incompatible preset is not a refusal")
        #expect(receipt.changedMarkupIDs == [id.rawValue])
        let skipped = Set(receipt.skipped.map(\.property))
        #expect(skipped == [.depth, .volumeDepthReference], "got \(skipped)")
        #expect(receipt.summaryMessage.contains("Depth"), "the message names the property")

        let after = try #require(await environment.session.markup(id))
        #expect(after.subject == "Foundation", "the overlap really was applied")
        #expect(after.parameters?.depth == nil, "the skip is a skip in the record, not only in the message")
    }

    @Test("Apply is refused, out loud, when a selected markup is locked")
    @MainActor
    func applyRefusesALockedSelection() async throws {
        let fixture = try await makeFixture(count: 0)
        let environment = fixture.environment
        let id = MarkupID(UUID())
        try await environment.commands.perform(.addMarkup(Self.area(
            id: id,
            documentID: fixture.documentID,
            pageID: fixture.page.id,
            subject: "Locked",
            tool: .volume,
            parameters: Self.startingDepth,
            locked: true
        )))

        let receipt = await environment.applyPreset(Self.slabPreset(), to: [id.rawValue])
        #expect(receipt.failureMessage != nil)
        #expect(!receipt.didChangeAnything)
    }

    // MARK: Place

    @Test("Place drops an ordinary markup: undoable, in the document, with the preset's identity")
    @MainActor
    func placeDropsAnOrdinaryMarkup() async throws {
        let fixture = try await makeFixture(count: 0)
        let environment = fixture.environment
        var preset = Self.slabPreset(subject: "Doors")
        preset = ToolPresetSummary(
            id: preset.id,
            name: "Door Count",
            category: "Openings",
            panel: .myTools,
            markupKind: .count,
            measurementKind: .count,
            colorRGBA: preset.colorRGBA,
            defaultSubject: "Doors",
            labelPattern: "D-1",
            defaultStatus: .open
        )

        let receipt = await environment.placePreset(
            preset, at: PDFPointValue(x: 120, y: 240), pageID: fixture.page.id.rawValue
        )
        let markupID = try #require(receipt.markupID)
        let record = try #require(await environment.session.markup(MarkupID(markupID)))
        #expect(record.kind == .count)
        #expect(record.tool == .count)
        #expect(record.subject == "Doors")
        #expect(record.label == "D-1")
        #expect(record.status == .open)
        // The mark is in `countPoints`, as the Count tool writes it (V-031). Old output: the mark
        // in `points` and `countPoints` empty, so Continue dropped it and Number Marks skipped it.
        #expect(record.geometry?.countPoints.map(\.position) == [PDFPoint(x: 120, y: 240)])
        #expect(record.geometry?.points.isEmpty == true)
        #expect(record.measurement?[.count]?.value == 1)

        // Ordinary means undoable through the same stack as anything else.
        await environment.commands.undo()
        #expect(await environment.session.markup(MarkupID(markupID)) == nil)
    }

    @Test("Place refuses a preset that has no shape of its own, and says so")
    @MainActor
    func placeRefusesADrawnTool() async throws {
        let fixture = try await makeFixture(count: 0)
        let receipt = await fixture.environment.placePreset(
            Self.slabPreset(), at: PDFPointValue(x: 10, y: 10), pageID: fixture.page.id.rawValue
        )
        #expect(receipt.markupID == nil)
        #expect(receipt.failureMessage?.contains("drawn") == true)
    }

    // MARK: The mode itself

    @Test("A set's mode is remembered with the set, and survives a relaunch")
    @MainActor
    func setModeIsRememberedAcrossLaunches() async throws {
        let defaults = ZPDFInMemoryDefaults()
        let store = ToolSetModeStore(defaults: defaults)
        #expect(store.read().isEmpty)

        let presenter = AppToolLibraryPresenter()
        presenter.onSetModesChanged = { store.write($0) }
        presenter.setMode(.apply, for: .myTools)
        presenter.setMode(.place, for: .projectTools)

        #expect(presenter.mode(of: .myTools) == .apply)
        #expect(presenter.mode(of: .projectTools) == .place)
        #expect(presenter.mode(of: .favorites) == .draw, "a set nobody changed is in Draw")

        // A second launch reads the same two decisions back.
        let reopened = AppToolLibraryPresenter()
        reopened.adoptSetModes(ToolSetModeStore(defaults: defaults).read())
        #expect(reopened.mode(of: .myTools) == .apply)
        #expect(reopened.mode(of: .projectTools) == .place)
    }

    @Test("The armed mode follows the preset's own set, not whichever panel is on screen")
    @MainActor
    func armedModeFollowsThePresetsSet() async throws {
        let presenter = AppToolLibraryPresenter()
        let projectPreset = Self.slabPreset(panel: .projectTools)
        presenter.setPresets([projectPreset])
        presenter.setMode(.place, for: .projectTools)
        presenter.activatePreset(id: projectPreset.id)

        presenter.selectPanel(.myTools)
        #expect(presenter.activePanel == .myTools)
        #expect(presenter.armedSetMode == .place, "browsing another set must not disarm the stamp")

        presenter.clearActivePreset()
        #expect(presenter.armedSetMode == .draw, "nothing armed means nothing to apply or place")
    }

    @Test("Apply and Place arm neither drawing family")
    @MainActor
    func applyAndPlaceDisarmTheDrawingTools() async throws {
        let fixture = try await makeFixture(count: 0)
        let environment = fixture.environment
        let preset = Self.slabPreset()
        environment.toolLibrary.setPresets([preset])

        environment.toolLibrary.activatePreset(id: preset.id)
        #expect(environment.measurement.activeKind == .volume, "Draw arms the tool")

        environment.toolLibrary.setMode(.apply, for: .myTools)
        #expect(environment.measurement.activeKind == nil, "a brush must not also draw")
        #expect(environment.markup.activeKind == nil)

        environment.toolLibrary.setMode(.place, for: .myTools)
        #expect(environment.measurement.activeKind == nil)

        environment.toolLibrary.setMode(.draw, for: .myTools)
        #expect(environment.measurement.activeKind == .volume, "and back again")
    }

    // MARK: Capture

    @Test("Making a tool out of a markup keeps its measurement parameters")
    @MainActor
    func captureFromSelectionKeepsTheMeasurementParameters() async throws {
        let fixture = try await makeFixture(count: 0)
        let environment = fixture.environment
        let id = MarkupID(UUID())
        try await environment.commands.perform(.addMarkup(Self.area(
            id: id,
            documentID: fixture.documentID,
            pageID: fixture.page.id,
            subject: "Screed",
            tool: .volume,
            parameters: MeasurementParameters(
                depth: .length(Decimal(string: "0.075") ?? 0),
                slope: .uniformPlane(.percent(50), azimuth: SlopeAzimuth(degrees: 90)),
                volumeDepthReference: .perpendicularThickness,
                cutoutPolicy: .ignore
            )
        )))
        await environment.refresh()

        // The Tool Library only ever sees a `MarkupSummary`, so this is the value the capture
        // path actually has to work from.
        let summary = try #require(environment.snapshot.markups.first { $0.id == id.rawValue })
        let captured = try #require(summary.measurementDefaults)
        #expect(captured.depth == .metres(Decimal(string: "0.075") ?? 0))
        #expect(captured.slopePercent == 50)
        #expect(captured.slopeAzimuthDegrees == 90)
        #expect(captured.volumeDepthReference == .perpendicularThickness)
        #expect(captured.cutoutPolicy == .ignore)
    }
}
