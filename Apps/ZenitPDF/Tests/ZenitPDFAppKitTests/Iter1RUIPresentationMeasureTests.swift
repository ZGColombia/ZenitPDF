import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
import ZPDFAppCore
import ZPDFContracts
import ZPDFPersistence
import ZPDFQuantityLedger
import ZPDFUIPresentation
@testable import ZenitPDFAppKit

/// Iteration-1 re-fix, area ui-presentation-measure: the two app-tier halves the checker found
/// open. R-136 — a stored formula column the engine now refuses is kept and reported, never
/// erased by the next save. R-137 — a Length and a Polylength drawn with the keyboard alone.
@MainActor
@Suite(.appTierSerialised)
struct Iter1RUIPresentationMeasureTests {

    // MARK: - R-136

    /// A formula column an earlier build accepted: `CONVERT(Area, ft2, m2)` read the Area's base
    /// magnitude (m²) as if it were ft². R-136 made the engine refuse it at compile time.
    private static let legacyColumn = LedgerColumnDefinition(
        id: ColumnID(UUID(uuidString: "0C0C0136-0000-4000-8000-000000000136")!),
        key: "custom-area-ft2",
        title: "Area ft2",
        kind: .formula,
        formula: FormulaExpression(source: "CONVERT(Area, ft2, m2)"),
        isEditable: false
    )

    private func save(
        _ document: ZenitPDFProjectDocument, to url: URL, _ operation: NSDocument.SaveOperationType
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            document.save(to: url, ofType: ZenitAppInfo.projectTypeIdentifier, for: operation) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private func drawLength(_ core: AppCoreEnvironment, y: Double, rows: Int) async {
        core.measurement.activate(kind: .length)
        core.measurement.appendRawPoints([PDFPointValue(x: 80, y: y), PDFPointValue(x: 180, y: y)])
        core.measurement.commitActiveMeasurement()
        #expect(await AppTestSupport.wait { core.ledger.rowCount == rows }, "the length row never landed")
    }

    private func storedColumns(at url: URL) async throws -> [LedgerColumnDefinition] {
        let package = try await ProjectPackage.open(at: url, resolving: .recover)
        let stored = try await TakeoffArchive.read(from: package)?.customColumns ?? []
        try await package.close()
        return stored
    }

    /// Old output (by the code path the checker traced): the reopen installed the column with
    /// `try?`, the refusal was swallowed, no warning was posted, and the next save — built from the
    /// installed columns only, deleting the `custom_column` rows it no longer had — left
    /// `customColumns == []`. The formula was gone from the project for good.
    @Test("R-136: a refused stored formula column survives reopen and save, and the tray says why")
    func refusedFormulaColumnIsKept() async throws {
        let url = try AppTestSupport.writeFixturePDF(named: "HeldColumn.pdf")
        let directory = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }

        // The premise: this build refuses the definition.
        #expect(throws: (any Error).self) {
            try LedgerColumnSet(columns: try LedgerColumnSet.standard().columns + [Self.legacyColumn])
        }

        // A project saved by the earlier build: a takeoff, plus the formula column in its file.
        let document = try AppTestSupport.makeDocument(opening: url)
        #expect(await AppTestSupport.wait { document.core != nil })
        let core = try #require(document.core)
        _ = try await core.commands.calibrate(
            page: try #require(await core.session.firstPageID),
            first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
            knownLength: 1, knownLengthUnit: .metre
        )
        await drawLength(core, y: 80, rows: 1)
        // The definition goes into the file exactly as the earlier build wrote it: one
        // `custom_column` row carrying its JSON. This build can only put it there by holding it,
        // so the seed is a restore onto the live session, which holds and saves it unchanged.
        #expect(await core.session.restoreCustomColumns([Self.legacyColumn]).isEmpty)
        await core.refresh()
        let destination = directory.appendingPathComponent("HeldColumn.zpdfproj")
        try await save(document, to: destination, .saveAsOperation)
        #expect(await core.session.takeoffState().customColumns == [Self.legacyColumn])
        document.close()
        await ZenitPDFProjectDocument.drainStorageShutdowns()

        // Reopen through the shipping load path. `fileURL` and `fileType` are what
        // NSDocumentController's `init(contentsOf:ofType:)` sets around `read(from:ofType:)`;
        // without them ⌘S takes the Save As branch and replaces the package it has open.
        let reopened = ZenitPDFProjectDocument()
        try reopened.read(from: destination, ofType: ZenitAppInfo.projectTypeIdentifier)
        reopened.fileURL = destination
        reopened.fileType = ZenitAppInfo.projectTypeIdentifier
        reopened.startLoadingIfNeeded()
        #expect(await AppTestSupport.wait { reopened.core != nil && !reopened.isLoading })
        let restored = try #require(reopened.core)
        #expect(reopened.loadFailure == nil, "a refused column never refuses the file")
        #expect(await AppTestSupport.wait { restored.ledger.rowCount == 1 })

        // Kept, with the engine's reason …
        let held = await restored.session.heldCustomColumns
        #expect(held.map(\.definition) == [Self.legacyColumn])
        #expect(held.first?.reason.contains("m2") == true, "\(held.first?.reason ?? "")")
        #expect(!restored.ledger.visibleColumns.contains { $0.title == "Area ft2" }, "not shown as if it worked")
        // … and said out loud, naming the column.
        let warning = try #require(restored.document.warnings.first { $0.title.contains("“Area ft2”") })
        #expect(warning.severity == .warning)
        #expect(warning.message.contains("kept in the project unchanged"))
        #expect(warning.message.contains("m2"))

        // An edit, then ⌘S: the takeoff rows are rewritten, and the definition goes back unchanged.
        await drawLength(restored, y: 120, rows: 2)
        await restored.refresh()
        try await save(reopened, to: destination, .saveOperation)
        reopened.close()
        await ZenitPDFProjectDocument.drainStorageShutdowns()
        #expect(try await storedColumns(at: destination) == [Self.legacyColumn])
    }

    /// The retry in `restoreCustomColumns`: a formula stored ahead of the column it reads is
    /// installed once that column is. Old output: the formula was tried first, refused for naming a
    /// column not yet installed, and dropped by the `try?` — installed == ["Rate"] only.
    @Test("R-136: a formula stored ahead of the column it reads is installed, not held")
    func formulaAheadOfItsColumnInstalls() async throws {
        let session = try TakeoffSession(documentID: DocumentID(UUID()))
        let rate = LedgerColumnDefinition(id: ColumnID(UUID()), key: "Rate", title: "Rate", kind: .number)
        let cost = LedgerColumnDefinition(
            id: ColumnID(UUID()), key: "Cost", title: "Cost", kind: .formula,
            formula: FormulaExpression(source: "[Rate] * 2"), isEditable: false
        )
        let installed = await session.restoreCustomColumns([cost, rate])
        #expect(Set(installed.map(\.key)) == ["Rate", "Cost"])
        #expect(await session.heldCustomColumns.isEmpty)
        #expect(await session.takeColumnRefusals().isEmpty)

        // A definition refused for itself is held once, and its refusal is said once.
        let broken = Self.legacyColumn
        #expect(await session.restoreCustomColumns([broken, broken]).isEmpty)
        #expect(await session.heldCustomColumns.map(\.definition) == [broken])
        #expect(await session.takeColumnRefusals().count == 1)
        #expect(await session.takeColumnRefusals().isEmpty)
        #expect(await session.takeoffState().customColumns.map(\.key) == ["Rate", "Cost", "custom-area-ft2"])
    }

    // MARK: - R-137

    private static func key(_ keyCode: UInt16, _ characters: String, _ modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: keyCode
        ))
    }

    /// One key through the canvas's own `keyDown`, as AppKit delivers it to the focused canvas.
    private static func press(_ pageView: CanvasPageView, _ keyCode: UInt16, _ characters: String,
                              _ modifiers: NSEvent.ModifierFlags = [], times: Int = 1) throws {
        for _ in 0..<times { pageView.keyDown(with: try key(keyCode, characters, modifiers)) }
    }

    private static let right: (UInt16, String) = (124, "\u{F703}")
    private static let down: (UInt16, String) = (125, "\u{F701}")
    private static let returnKey: (UInt16, String) = (36, "\r")

    private func measured(_ tool: MeasurementTool, _ harness: Fix2Harness) async -> ZPDFContracts.MarkupRecord? {
        for _ in 0..<200 {
            if let record = await harness.records().first(where: { $0.tool == tool }) { return record }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return nil
    }

    /// The ledger's plan-length total in metres. The cursor starts mid-screen at a fractional page
    /// coordinate, so 100 pt is 1 m to within the last bits of a Double, not to the digit.
    private func metres(_ harness: Fix2Harness) -> Double? {
        harness.core.ledger.grandTotals.total("planLength").map { NSDecimalNumber(decimal: $0.value).doubleValue }
    }

    private func near(_ a: PDFPoint?, _ b: PDFPointValue) -> Bool {
        guard let a else { return false }
        return abs(a.x - b.x) < 1e-9 && abs(a.y - b.y) < 1e-9
    }

    /// The keyboard-only measurement acceptance, against the shipping window and canvas: the tool from the
    /// Measure menu (⌘L), the cursor moved with the arrow keys, each point placed with Return, and
    /// the Length committed by its second point — not one mouse event. The sheet is calibrated
    /// 100 pt = 1 m with snapping off, so ten Shift-arrows (10 pt each) are 1 m.
    ///
    /// Old output: with a tool armed the canvas's `nudge` returned `false` at once, the arrow fell
    /// through, and Return finished nothing — no point could be placed without the pointer.
    @Test("R-137: arrow keys and Return draw a 1 m Length with no mouse event")
    func keyboardOnlyLength() async throws {
        let harness = try await Fix2Harness.make("Iter1R Keyboard Length.pdf")
        defer { harness.tearDown() }
        let pageView = harness.canvas.pageViewForTesting
        let machine = harness.canvas.measurementInputForTesting
        harness.shell.perform(.measureLength)
        #expect(await AppTestSupport.wait { harness.core.measurement.activeKind == .length })
        #expect(!machine.state.returnPlacesPoint, "until an arrow is pressed, Return means finish")

        try Self.press(pageView, Self.right.0, Self.right.1)
        #expect(machine.state.returnPlacesPoint)
        #expect(await AppTestSupport.wait {
            harness.core.status.snapshot.activeToolNote?.contains("Return places a point") == true
        }, "the status bar says what Return does now: \(harness.core.status.snapshot.activeToolNote ?? "nil")")
        #expect(pageView.live.drawing.keyboardCursor == machine.cursor, "the canvas draws the keyboard cursor")
        let first = machine.cursor
        try Self.press(pageView, Self.returnKey.0, Self.returnKey.1)
        await harness.core.measurement.settlePlacements()
        #expect(harness.core.measurement.placedPoints.count == 1)
        #expect(harness.core.measurement.placedPoints.first.map { abs($0.x - first.x) < 1e-9 && abs($0.y - first.y) < 1e-9 } == true)

        try Self.press(pageView, Self.right.0, Self.right.1, .shift, times: 10)
        let second = PDFPointValue(x: first.x + 100, y: first.y)
        #expect(abs(machine.cursor.x - second.x) < 1e-9 && abs(machine.cursor.y - second.y) < 1e-9, "\(machine.cursor)")
        try Self.press(pageView, Self.returnKey.0, Self.returnKey.1)

        let record = try #require(await measured(.length, harness), "the Length never committed")
        let points = record.geometry?.points ?? []
        #expect(points.count == 2)
        #expect(near(points.first, first) && near(points.last, second), "\(points)")
        await harness.settle()
        #expect(metres(harness).map { abs($0 - 1) < 1e-9 } == true, "\(String(describing: metres(harness)))")
    }

    /// ⌘Return finishes a variable-vertex shape while the keyboard cursor leads, and the pointer
    /// takes Return back the moment it moves.
    @Test("R-137: a Polylength placed by keyboard finishes with ⌘Return; a pointer move hands Return back")
    func keyboardPolylengthFinishes() async throws {
        let harness = try await Fix2Harness.make("Iter1R Keyboard Polylength.pdf")
        defer { harness.tearDown() }
        let pageView = harness.canvas.pageViewForTesting
        let machine = harness.canvas.measurementInputForTesting
        harness.shell.perform(.measurePolylength)
        #expect(await AppTestSupport.wait { harness.core.measurement.activeKind == .polylength })

        try Self.press(pageView, Self.right.0, Self.right.1)
        let first = machine.cursor
        try Self.press(pageView, Self.returnKey.0, Self.returnKey.1)
        try Self.press(pageView, Self.right.0, Self.right.1, .shift, times: 5)
        try Self.press(pageView, Self.returnKey.0, Self.returnKey.1)
        try Self.press(pageView, Self.down.0, Self.down.1, .shift, times: 5)   // screen down = page −y
        try Self.press(pageView, Self.returnKey.0, Self.returnKey.1)
        await harness.core.measurement.settlePlacements()
        #expect(harness.core.measurement.placedPoints.count == 3, "Return placed, it did not finish")
        try Self.press(pageView, Self.returnKey.0, Self.returnKey.1, .command)

        let record = try #require(await measured(.polylength, harness), "⌘Return did not finish")
        let points = record.geometry?.points ?? []
        #expect(points.count == 3)
        #expect(near(points.last, PDFPointValue(x: first.x + 50, y: first.y - 50)), "\(points)")
        await harness.settle()
        #expect(metres(harness).map { abs($0 - 1) < 1e-9 } == true, "\(String(describing: metres(harness)))")

        harness.canvas.handlePointerMove(PDFPointValue(x: 300, y: 300))
        #expect(!machine.state.returnPlacesPoint, "the pointer leads again")
        harness.canvas.refreshLiveFeedback()
        #expect(pageView.live.drawing.keyboardCursor == nil, "and the keyboard cursor is no longer drawn")
    }
}
