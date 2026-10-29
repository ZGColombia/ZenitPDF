import Foundation
import Testing
@testable import ZPDFAppCore
import ZPDFContracts
import ZPDFSnapEngine
import ZPDFUIPresentation

/// Bug hunt 2, the presenters and the preset doors (BH-013, 100, 102, 106, 115, 116, 117, 412,
/// 413, 447, 450, 452, 453, 458; IM-055, IM-056).
@MainActor
@Suite("Bug hunt 2: presenters and preset doors")
struct BugHunt2PresenterTests {

    private func makeEnvironment() async throws -> (AppCoreEnvironment, TakeoffSession, ZPDFContracts.PageDescriptor, DocumentID) {
        let documentID = DocumentID(UUID())
        let page = ZPDFContracts.PageDescriptor(
            id: PageID(UUID()), documentID: documentID, index: 0, label: "A-101",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 1_000, height: 1_000))
        )
        let session = try TakeoffSession(documentID: documentID, pages: [page])
        let environment = try await AppCoreEnvironment.make(session: session, documentID: documentID)
        return (environment, session, page, documentID)
    }

    private let phase = LedgerColumnDefinition(id: ColumnID(UUID()), key: "custom.phase", title: "Phase", kind: .text)
    private let factor = LedgerColumnDefinition(id: ColumnID(UUID()), key: "custom.factor", title: "Factor", kind: .number, dimension: .ratio)

    private func addColumns(_ environment: AppCoreEnvironment, _ session: TakeoffSession) async throws {
        try await session.addCustomColumns([phase, factor])
        await environment.refresh()
    }

    private func stampPreset(custom: [String: String] = [:], subject: String = "Review") -> ToolPresetSummary {
        ToolPresetSummary(
            id: UUID(), name: "Reviewed", category: "Review", panel: .myTools, markupKind: .stamp,
            colorRGBA: ColorRGBA(red: 0.8, green: 0.1, blue: 0.1), defaultSubject: subject,
            customDefaults: custom,
            stamp: StampTemplate(
                id: UUID(), revision: 1, widthPoints: 160, heightPoints: 60, artwork: nil,
                fields: [StampFieldDefinition(kind: .date, prompt: "", dateFormat: "yyyy-MM-dd",
                                              normalizedFrame: PDFRectValue(x: 0, y: 0, width: 1, height: 1))]
            )
        )
    }

    private let custom = ["custom.phase": "2", "custom.factor": "two", "custom.missing": "1"]

    // MARK: BH-013, BH-116, BH-452

    @Test("A single Place click on a stamp preset draws a resolved stamp and reports what it skipped")
    func placeClickResolvesTheStamp() async throws {
        let (environment, session, page, _) = try await makeEnvironment()
        try await addColumns(environment, session)
        let preset = stampPreset(custom: custom)

        let receipt = await environment.placePreset(preset, at: PDFPointValue(x: 100, y: 100), pageID: page.id.rawValue)
        let placed = try #require(await session.orderedMarkups.first)
        // Old output: stamp nil — the shipping click drew nothing.
        #expect(placed.stamp?.templateID == preset.stamp?.id)
        #expect(placed.stamp?.fields.isEmpty == false)
        #expect(placed.customValues[phase.id] == .text("2"))
        // Old output: [] — the number and unknown columns were dropped in silence.
        #expect(receipt.skippedCustomColumns == ["custom.factor", "custom.missing"])

        // The stamp-only door is the same door now (BH-452).
        let second = await environment.placeStamp(preset, at: PDFPointValue(x: 300, y: 300), pageID: page.id.rawValue)
        let secondID = try #require(second.markupID)
        let stamped = try #require(await session.markup(MarkupID(secondID)))
        #expect(stamped.customValues[phase.id] == .text("2"))
    }

    // MARK: BH-117

    @Test("Batch-placed stamps carry the preset's custom column values")
    func batchStampsCarryCustomValues() async throws {
        let (environment, session, page, documentID) = try await makeEnvironment()
        try await addColumns(environment, session)
        let producer = try #require(environment.stampBatchProducer(for: stampPreset(custom: custom)))
        let record = try #require(producer.record(
            forPage: ZPDFUIPresentation.PageDescriptor(domain: page),
            position: 0,
            at: PDFPointValue(x: 10, y: 10),
            documentID: documentID,
            identifier: UUID()
        ))
        // Old output: [:] on every batch-placed stamp.
        #expect(record.customValues[phase.id] == .text("2"))
    }

    // MARK: BH-115, BH-116, BH-458

    @Test("Apply keeps subjects a name-only preset has none for, and reports what did not fit")
    func applyGuardsSubjectAndReportsCustomSkips() async throws {
        let (environment, session, page, documentID) = try await makeEnvironment()
        try await addColumns(environment, session)
        let target = ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: documentID, pageID: page.id, kind: .rectangle,
            subject: "Doors", author: "t",
            geometry: MeasurementGeometry(pageID: page.id, points: [PDFPoint(x: 0, y: 0), PDFPoint(x: 10, y: 10)]),
            createdAt: Date(timeIntervalSince1970: 0), modifiedAt: Date(timeIntervalSince1970: 0)
        )
        try await environment.commands.perform(.addMarkup(target))
        var brush = stampPreset(custom: ["custom.factor": "two"], subject: "")
        brush.colorRGBA = ColorRGBA(red: 0, green: 1, blue: 0)
        let receipt = await environment.applyPreset(brush, to: [target.id.rawValue])
        // Old output: subject "" — twelve editSubject commands erasing the grouping.
        #expect(await session.markup(target.id)?.subject == "Doors")
        // Old output: an empty skip report for the refused number cell.
        #expect(!receipt.skipReport.isEmpty)

        // BH-458: a cutout does not take a cutout or perimeter policy.
        let policies = ToolPresetSummary(
            id: UUID(), name: "Ignore holes", category: "", panel: .myTools, markupKind: .measurement,
            measurementKind: .area, colorRGBA: ColorRGBA(red: 0, green: 0, blue: 0), defaultSubject: "",
            measurementDefaults: ToolPresetMeasurementDefaults(cutoutPolicy: .ignore)
        )
        let plan = ToolPresetApplicability.plan(preset: policies, targetKind: .polygon, targetTool: .polygonCutout)
        #expect(!plan.applicable.contains(.cutoutPolicy))
        #expect(plan.skipped.contains { $0.property == .cutoutPolicy })
        let onArea = ToolPresetApplicability.plan(preset: policies, targetKind: .measurement, targetTool: .area)
        #expect(onArea.applicable.contains(.cutoutPolicy))
    }

    // MARK: BH-412

    @Test("A mode flip on another panel leaves the armed tool's note alone")
    func modeNoteFollowsTheArmedPanel() async throws {
        let (environment, _, _, _) = try await makeEnvironment()
        let preset = ToolPresetSummary(
            id: UUID(), name: "Kerb", category: "", panel: .myTools, markupKind: .measurement,
            measurementKind: .length, colorRGBA: ColorRGBA(red: 0, green: 0, blue: 0), defaultSubject: "Kerb"
        )
        environment.toolLibrary.setPresets([preset])
        environment.toolLibrary.activatePreset(id: preset.id)
        let armedNote = environment.status.snapshot.activeToolNote
        environment.toolLibrary.setMode(.apply, for: .projectTools)
        // Old output: Apply's "click a markup to apply…" while Length was still drawing.
        #expect(environment.status.snapshot.activeToolNote == armedNote)
        environment.toolLibrary.setMode(.apply, for: .myTools)
        #expect(environment.status.snapshot.activeToolNote == ToolSetMode.apply.shortHelp)
    }

    // MARK: BH-413, BH-453

    @Test("A refused snap setting is put back and said; non-vector kinds do not hang on Vector Snap")
    func snapSettingsRefusalAndDerivation() async throws {
        let (environment, session, _, _) = try await makeEnvironment()
        var settings = await session.currentSnapSettings
        settings.enabledKinds.remove(.grid)
        settings.gridSpacingPoints = 0
        try await session.setSnapSettings(settings)
        environment.status.adoptSnapToggles(SnapSourceToggles(grid: false, vector: true, markup: true))

        environment.status.setGridSnapEnabled(true)
        let deadline = ContinuousClock.now + .seconds(5)
        while !environment.document.warnings.contains(where: { $0.id == AppCoreEnvironment.snapSettingsWarningID }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        // Old output: the toggle stayed on with nothing said; the engine kept the old kinds.
        #expect(environment.document.warnings.contains { $0.id == AppCoreEnvironment.snapSettingsWarningID })
        #expect(environment.status.toggles.grid == false)
        #expect(await !session.currentSnapSettings.enabledKinds.contains(.grid))

        let noVector = SnapSourceToggles(grid: true, vector: false, markup: true).snapKinds(base: [])
        #expect(noVector == Set(SnapKind.allCases.filter { !$0.requiresVectorContent }))
    }

    // MARK: BH-447

    @Test("A bulk edit whose selection has partly gone is refused, not half-applied")
    func partlyStaleSelectionIsRefused() async throws {
        let (environment, session, page, documentID) = try await makeEnvironment()
        let kept = ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: documentID, pageID: page.id, kind: .rectangle,
            subject: "Old", author: "t",
            geometry: MeasurementGeometry(pageID: page.id, points: [PDFPoint(x: 0, y: 0), PDFPoint(x: 10, y: 10)]),
            createdAt: Date(timeIntervalSince1970: 0), modifiedAt: Date(timeIntervalSince1970: 0)
        )
        try await environment.commands.perform(.addMarkup(kept))
        let receipt = await environment.applyBulkEdit(LedgerBulkEditRequest(
            markupIDs: [kept.id.rawValue, UUID()],
            values: [.subject: .text("New")]
        ))
        // Old output: success, one changed, the missing row never mentioned.
        #expect(receipt.didFail)
        #expect(await session.markup(kept.id)?.subject == "Old")
    }

    // MARK: BH-100, BH-106, BH-450

    @Test("Cancelling an operation cancels the work, not a wrapper around it")
    func handleCancelsTheWork() async {
        let handle = OperationHandle(title: "Work")
        let work = Task<Int, Error> {
            try await Task.sleep(for: .seconds(30))
            return 1
        }
        handle.attach(cancelling: work)
        handle.cancel()
        // Old behaviour: the wrapper was cancelled and the work slept its 30 s and returned 1.
        let result = await work.result
        #expect((try? result.get()) == nil)
        #expect(handle.progress == .cancelled)
    }

    // MARK: BH-102, IM-055, IM-056

    @Test("Sorting is immediate, a display-only sort is refused out loud, and a good rebuild clears any error")
    func ledgerSortBehaviour() async throws {
        let (environment, _, _, _) = try await makeEnvironment()
        let ledger = environment.ledger
        ledger.debounce = .seconds(30)

        // IM-055: a header click used to wait out the typing debounce first.
        let clock = ContinuousClock()
        let started = clock.now
        ledger.sort(by: LedgerColumnID("subject"), ascending: false)
        while ledger.isLoading, clock.now - started < .seconds(5) {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(!ledger.isLoading)
        #expect(clock.now - started < .seconds(5), "sorted without the 30 s debounce")
        #expect(ledger.sortDescriptors.first?.column == LedgerColumnID("subject"))

        // BH-102: old output — a descriptor on Value, which the spec builder then dropped.
        ledger.sort(by: LedgerDefaultColumns.valueColumnID, ascending: true)
        #expect(ledger.sortDescriptors.first?.column == LedgerColumnID("subject"))
        #expect(ledger.unappliedSortColumn == LedgerDefaultColumns.valueColumnID)
        #expect(ledger.unappliedSortMessage != nil)

        // IM-056: a successful rebuild leaves no stale-result banner.
        await ledger.refresh()
        #expect(ledger.lastRebuildError == nil)
    }
}
