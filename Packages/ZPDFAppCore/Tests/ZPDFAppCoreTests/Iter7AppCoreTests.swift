import Foundation
import Testing
@testable import ZPDFAppCore
import ZPDFContracts
import ZPDFPersistence
import ZPDFUIPresentation

/// A toolbar pick replaces the armed preset (X-018,
/// the core half — the shell's seam is `Iter7PresetToolSwitchTests`), the audit action of every
/// markup in a batch (X-019) and one number grammar for the parameter field (X-020). Every
/// expected value is derived by hand next to its input, and every regression test names the old
/// output.
@Suite("Iteration 7 — application core")
@MainActor
struct Iter7AppCoreTests {

    static func environment() async throws -> (AppCoreEnvironment, TakeoffSession, ZPDFContracts.PageDescriptor) {
        let documentID = DocumentID(UUID())
        let page = ZPDFContracts.PageDescriptor(
            id: PageID(UUID()), documentID: documentID, index: 0, label: "A-101",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 1_000, height: 1_000))
        )
        let session = try TakeoffSession(documentID: documentID, pages: [page])
        let environment = try await AppCoreEnvironment.make(session: session, documentID: documentID)
        return (environment, session, page)
    }

    static func preset(
        _ name: String,
        markup: ZPDFUIPresentation.MarkupKind,
        measure: MeasurementKind? = nil,
        label: String = "",
        custom: [String: String] = [:],
        symbol: String? = nil
    ) -> ToolPresetSummary {
        ToolPresetSummary(
            id: UUID(), name: name, category: "Test", panel: .myTools,
            markupKind: markup, measurementKind: measure,
            colorRGBA: ColorRGBA(red: 0.8, green: 0.2, blue: 0.1), defaultSubject: name,
            labelPattern: label, defaultStatus: .open, customDefaults: custom, countSymbolName: symbol
        )
    }

    // MARK: X-018

    /// The core half of a toolbar pick: the shell disarms the preset (`clearActivePreset()`)
    /// before it arms the picked tool. The count placed under the preset is finished under it;
    /// the Length drawn next carries nothing of it.
    @Test("X-018: disarming finishes the preset's count under it, and the next tool commits plain")
    func disarmingPutsThePresetDown() async throws {
        let (environment, session, page) = try await Self.environment()
        let costCode = LedgerColumnDefinition(id: ColumnID(UUID()), key: "custom.costCode", title: "Cost code", kind: .text)
        try await session.addCustomColumns([costCode])
        await environment.refresh()
        let doors = Self.preset(
            "Doors", markup: .count, measure: .count, label: "D", custom: ["custom.costCode": "1234"], symbol: "square"
        )
        environment.toolLibrary.setPresets([doors])
        environment.toolLibrary.activatePreset(id: doors.id)
        var committed: [ZPDFContracts.MarkupRecord] = []
        environment.measurement.onCommit = { committed.append($0) }
        environment.measurement.setPage(page.id)
        environment.measurement.appendRawPoints([PDFPointValue(x: 10, y: 10), PDFPointValue(x: 40, y: 10)])

        // What `ProjectShellEnvironment.presetGivesWay(to:)` does on a choice of Length, then the
        // choice itself. The whole path through the toolbar is `C2rPresetPickEndToEndTests`.
        environment.toolLibrary.clearActivePreset()
        environment.measurement.activate(kind: .length)
        environment.measurement.appendRawPoints([PDFPointValue(x: 0, y: 100), PDFPointValue(x: 100, y: 100)])
        environment.measurement.commitActiveMeasurement()

        #expect(committed.count == 2)
        let count = try #require(committed.first { $0.tool == .count })
        #expect(count.subject == "Doors" && count.label == "D" && count.status == .open)
        #expect(count.customValues[costCode.id] == .text("1234"))
        #expect(count.symbol != nil, "the two marks were placed with the preset's glyph")
        let length = try #require(committed.first { $0.tool == .length })
        // The finding's old output for the next tool: subject "Doors", status Open, the cost
        // code, label "D".
        #expect(length.subject == "Length")
        #expect(length.status == .none)
        #expect(length.customValues.isEmpty)
        #expect(length.label == "Length A")
        #expect(length.symbol == nil)
        #expect(environment.toolLibrary.activePresetID == nil)
    }

    /// Old output: no record — `markup.deactivate()` discarded the draft, so a note typed under a
    /// Text preset vanished when a toolbar pick disarmed the preset ahead of the canvas's commit.
    @Test("X-018: a note typed under a Text preset is committed with the preset's row, not discarded")
    func typedTextSurvivesTheDisarm() async throws {
        let (environment, _, page) = try await Self.environment()
        let rfi = Self.preset("RFI", markup: .text, label: "Q-1")
        environment.toolLibrary.setPresets([rfi])
        environment.toolLibrary.activatePreset(id: rfi.id)
        #expect(environment.markup.activeKind == .text)
        var committed: [ZPDFContracts.MarkupRecord] = []
        environment.markup.onCommit = { committed.append($0) }
        environment.markup.setPage(page.id)
        environment.markup.placePoint(PDFPointValue(x: 100, y: 100))
        environment.markup.setDraftText("Check beam depth")

        environment.toolLibrary.clearActivePreset()

        let note = try #require(committed.first)
        #expect(note.caption == "Check beam depth")
        #expect(note.subject == "RFI" && note.label == "Q-1" && note.status == .open)
        #expect(environment.markup.activeKind == nil)
        #expect(environment.markup.defaultSubject.isEmpty, "the preset's defaults are down after the commit")

        // Empty text still discards the box, and a half-drawn shape is still thrown away.
        committed = []
        environment.toolLibrary.activatePreset(id: rfi.id)
        environment.markup.placePoint(PDFPointValue(x: 100, y: 100))
        environment.markup.setDraftText("   ")
        environment.toolLibrary.clearActivePreset()
        let cloud = Self.preset("Revisions", markup: .cloud)
        environment.toolLibrary.setPresets([rfi, cloud])
        environment.toolLibrary.activatePreset(id: cloud.id)
        environment.markup.placePoint(PDFPointValue(x: 0, y: 0))
        environment.markup.placePoint(PDFPointValue(x: 50, y: 0))
        environment.markup.placePoint(PDFPointValue(x: 50, y: 50))
        environment.toolLibrary.clearActivePreset()
        #expect(committed.isEmpty)
    }

    /// The core lights a tool on every arm with a preset: its `drawingTool` in Draw, Select when
    /// it arms none, and Select in Apply and Place. The shell's mirror names the preset in that
    /// selection, so a toolbar choice of any tool afterwards — the lit one included — is a change
    /// that disarms the preset and re-arms the presenters. Pinned against what the core really
    /// raises, for every shipped preset and one of each markup family, in all three modes.
    ///
    /// Old output: `[]` for a preset that draws nothing in Draw and for every preset in Apply or
    /// Place — the chip lit before the arm stayed lit over presenters the arm had put down.
    @Test("X-018: every arm lights the preset's tool in Draw, Select when it draws nothing or in Apply/Place")
    func theEchoIsTheDrawingTool() async throws {
        let (environment, _, _) = try await Self.environment()
        let presets = DefaultToolSet.shipped + [
            Self.preset("Revisions", markup: .cloud),
            Self.preset("RFI", markup: .text),
            Self.preset("Query", markup: .callout),
            Self.preset("Sketch", markup: .freehand),
            Self.preset("Approved", markup: .stamp),
            Self.preset("Kerb", markup: .measurement, measure: .length),
        ]
        environment.toolLibrary.setPresets(presets)
        var echoed: [ZenitToolMode] = []
        environment.onLibraryArmedTool = { echoed.append($0) }
        for preset in presets {
            for mode in [ToolSetMode.draw, .apply, .place] {
                environment.toolLibrary.setMode(mode, for: preset.panel)
                echoed = []
                environment.toolLibrary.activatePreset(id: preset.id)
                let expected: ZenitToolMode = mode == .draw ? (preset.drawingTool ?? .select) : .select
                #expect(echoed == [expected], "\(preset.name), \(mode)")
                if mode == .draw, case .measure(let kind) = expected {
                    #expect(environment.measurement.activeKind == kind, "\(preset.name)")
                } else {
                    #expect(environment.measurement.activeKind == nil, "\(preset.name), \(mode)")
                }
                // Disarming lights nothing: the person's choice that disarmed is armed next.
                echoed = []
                environment.toolLibrary.clearActivePreset()
                #expect(echoed.isEmpty, "\(preset.name), \(mode)")
            }
            environment.toolLibrary.setMode(.draw, for: preset.panel)
        }
        #expect(presets.contains { $0.drawingTool == nil }, "a preset that draws nothing is covered")

        // A set switched under the armed preset is lit again for the new mode.
        let kerb = try #require(presets.last)
        environment.toolLibrary.activatePreset(id: kerb.id)
        echoed = []
        environment.toolLibrary.setMode(.apply, for: kerb.panel)
        environment.toolLibrary.setMode(.draw, for: kerb.panel)
        #expect(echoed == [.select, .measure(.length)])
    }

    // MARK: X-019

    static func slab(x: Double, width: Double = 100) -> ZPDFContracts.MarkupRecord {
        let page = SharedReviewSyncTests.pageID
        return ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: SharedReviewSyncTests.documentID, pageID: page,
            kind: .measurement, tool: .area, subject: "Slab", author: "A. Berg",
            geometry: MeasurementGeometry(pageID: page, polygons: [PolygonGeometry(outer: PolygonRing(points: [
                PDFPoint(x: x, y: 0), PDFPoint(x: x + width, y: 0), PDFPoint(x: x + width, y: 50), PDFPoint(x: x, y: 50)
            ], isClosed: true))]),
            createdAt: Date(timeIntervalSince1970: 1_790_000_000), modifiedAt: Date(timeIntervalSince1970: 1_790_000_000)
        )
    }

    /// Delete, Cut and Shared Review removals all go through `performBatch`, even for one markup.
    @Test("X-019: a Delete through the batch path is Deleted in History and removed in a review round")
    func batchDeleteIsADeletion() async throws {
        let (a, db, dir) = try await SharedReviewSyncTests.machine()
        defer { try? FileManager.default.removeItem(at: dir) }
        let keep = Self.slab(x: 0)
        let gone = Self.slab(x: 300)
        try await a.commands.performBatch([.addMarkup(keep), .addMarkup(gone)], actionName: "Paste")
        await a.history.settle()
        a.review.closeRound(named: "")
        await a.review.settle()
        let round = try #require(a.review.rounds.first)

        try await a.commands.performBatch([.removeMarkup(gone.id)], actionName: "Delete")
        await a.history.settle()

        let rows = a.history.events.filter { $0.markupID == gone.id.rawValue }
        // Old output: ["markup_created", "markup_modified"] — the delete read "Edited".
        #expect(rows.map(\.action) == ["markup_created", "markup_deleted"])
        #expect(rows.last?.actionDisplayName == "Deleted")
        let diff = a.review.changes(since: round)
        // Old output: removed [], changed [gone].
        #expect(diff.removed == [gone.id.rawValue])
        #expect(diff.changed.isEmpty && diff.added.isEmpty)
        // Hand-derived: 100 pt × 50 pt at 0.01 m/pt = 1 m × 0.5 m = 0.5 m² leaves the Slab subject.
        let delta = try #require(diff.quantityDeltas.first { $0.subject == "Slab" && $0.field == "Plan Area" })
        #expect(delta.delta == Decimal(string: "-0.5"))
        try? await db.close()
    }

    @Test("X-019: a Split writes the parent Deleted and each part Measured, in one step")
    func splitIsOneDeletionAndOneCreationPerPart() async throws {
        let (a, db, dir) = try await SharedReviewSyncTests.machine()
        defer { try? FileManager.default.removeItem(at: dir) }
        let parent = Self.slab(x: 0)
        try await a.commands.perform(.addMarkup(parent))
        await a.history.settle()
        a.review.closeRound(named: "")
        await a.review.settle()
        let round = try #require(a.review.rounds.first)

        let commands = try await a.session.splitCommands(
            markup: parent.id, along: [PDFPoint(x: 50, y: -10), PDFPoint(x: 50, y: 60)]
        )
        try await a.commands.performBatch(commands, actionName: "Split Area")
        await a.history.settle()

        let parts: [UUID] = commands.compactMap {
            if case .addMarkup(let record) = $0 { return record.id.rawValue }
            return nil
        }
        #expect(parts.count == 2)
        let step = a.history.events.filter { $0.undoGroup != nil && $0.undoGroup == a.history.events.last?.undoGroup }
        // Old output: three "markup_modified" rows.
        #expect(step.filter { $0.action == "markup_deleted" }.compactMap(\.markupID) == [parent.id.rawValue])
        #expect(Set(step.filter { $0.action == "markup_created" }.compactMap(\.markupID)) == Set(parts))
        #expect(step.count == 3)
        let diff = a.review.changes(since: round)
        // Old output: added [], removed [], changed all three.
        #expect(diff.added == Set(parts))
        #expect(diff.removed == [parent.id.rawValue])
        #expect(diff.changed.isEmpty)
        try? await db.close()
    }

    @Test("X-019: a Merge writes the kept area Edited and the absorbed one Deleted")
    func mergeIsAnEditAndADeletion() async throws {
        let (a, db, dir) = try await SharedReviewSyncTests.machine()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = Self.slab(x: 0)
        let second = Self.slab(x: 50)   // overlaps x 50…100, so the union is one shape
        try await a.commands.performBatch([.addMarkup(first), .addMarkup(second)], actionName: "Paste")
        await a.history.settle()

        let plan = try await a.session.mergePlan(markups: [first.id, second.id])
        try await a.commands.performBatch(plan.commands, actionName: "Merge Areas")
        await a.history.settle()

        let group = try #require(a.history.events.last?.undoGroup)
        let step = a.history.events.filter { $0.undoGroup == group }
        let byMarkup = Dictionary(uniqueKeysWithValues: step.compactMap { row in row.markupID.map { ($0, row.action) } })
        // Old output: both "markup_modified".
        #expect(byMarkup == [first.id.rawValue: "markup_modified", second.id.rawValue: "markup_deleted"])
        try? await db.close()
    }

    // MARK: X-020

    /// Old output: nil for "−0,25" (U+2212, how the sv formatter writes a negative), for the bidi
    /// mark and for the Arabic-Indic digits — each a number in a ledger cell.
    @Test("X-020: the parameter field reads a number exactly as a ledger cell does")
    func parameterFieldUsesTheSharedGrammar() throws {
        let minus = "\u{2212}0,25"
        #expect(AppMeasurementToolPresenter.parseParameter(minus, for: .totalRiseDrop) == Decimal(string: "-0.25"))
        #expect(AppMeasurementToolPresenter.parseParameter(minus, for: .depth) == nil, "a negative depth is still refused")
        #expect(AppMeasurementToolPresenter.parseParameter("\u{200E}0,15") == Decimal(string: "0.15"))
        #expect(AppMeasurementToolPresenter.parseParameter("\u{0660}\u{066B}\u{0661}\u{0665}") == Decimal(string: "0.15"))
        #expect(AppMeasurementToolPresenter.parseParameter("1\u{202F}500,5") == Decimal(string: "1500.5"))

        // Everything else is the ledger's answer, except that zero leaves the tool waiting.
        let inputs = ["0.15", "0,15", "-2", "+3", "1 500", ".5", "5.", "1,5.0", "1,2,3", "1e3", "abc", "", "  "]
        for text in inputs {
            #expect(AppMeasurementToolPresenter.parseParameter(text) == TypedDecimalGrammar.decimal(text), "\(text)")
        }
        #expect(TypedDecimalGrammar.decimal("0") == 0)
        #expect(AppMeasurementToolPresenter.parseParameter("0") == nil)
        #expect(AppMeasurementToolPresenter.parseParameter("0,00") == nil)
    }

    /// Old output: Rise/Drop stayed "missing a value" with "−0,25" in the field, and the Inspector's
    /// Depth row called "−0,2" unreadable instead of not positive.
    @Test("X-020: the Rise/Drop field takes a formatted negative; the Inspector names a negative depth")
    func formattedNegativeInTheFieldAndTheInspector() async throws {
        let (environment, _, page) = try await Self.environment()
        environment.measurement.setPage(page.id)
        environment.measurement.activate(kind: .riseDrop)
        environment.measurement.setParameterText("\u{2212}0,25")
        #expect(environment.measurement.parameterValue == Decimal(string: "-0.25"))
        #expect(!environment.measurement.isMissingRequiredParameter)

        let volume = ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: DocumentID(environment.snapshot.documentID), pageID: page.id,
            kind: .measurement, tool: .volume, subject: "Slab", author: "A. Berg",
            geometry: MeasurementGeometry(pageID: page.id, polygons: [PolygonGeometry(outer: PolygonRing(points: [
                PDFPoint(x: 0, y: 0), PDFPoint(x: 10, y: 0), PDFPoint(x: 10, y: 10)
            ], isClosed: true))]),
            parameters: .default,
            createdAt: Date(timeIntervalSince1970: 0), modifiedAt: Date(timeIntervalSince1970: 0)
        )
        #expect(throws: ParameterEditing.Refusal.notPositive) {
            _ = try ParameterEditing.commands(setting: .depth, to: "\u{2212}0,2", on: [volume], lengthUnit: .metre)
        }
        let commands = try ParameterEditing.commands(setting: .depth, to: "1\u{202F}500", on: [volume], lengthUnit: .millimetre)
        // Hand-derived: "1 500" (narrow no-break space) is 1500; 1500 mm is exactly 1.5 m.
        guard case .editParameters(_, let parameters)? = commands.first else {
            Issue.record("no depth edit")
            return
        }
        #expect(parameters.depth == .length(Decimal(string: "1.5")!))
    }
}
