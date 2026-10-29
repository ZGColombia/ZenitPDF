import Foundation
import Testing
@testable import ZPDFAppCore
import ZPDFContracts
import ZPDFQuantityLedger
import ZPDFUIPresentation

/// NL-QTY-07 (assemblies, ADR-0024), end to end through the shipping presenter and bus.
///
/// Hand-derived: a 100 pt line at 0.1 m/pt is a 10 m wall. The timber stud wall at height
/// 2.4 m and spacing 0.6 m gives wall area 10 × 2.4 = 24 m², studs FLOOR(10 / 0.6) + 1 =
/// FLOOR(16.67) + 1 = 17, plates 10 × 2 = 20 m and plasterboard 10 × 2.4 × 2 = 48 m².
@Suite("Quantities — assemblies")
@MainActor
struct NLQuantitiesAssemblyTests {

    struct Wall {
        let environment: AppCoreEnvironment
        let session: TakeoffSession
        let wall: MarkupID
        let page: PageID
        let documentID: DocumentID
    }

    func makeWall(length points: Double = 100) async throws -> Wall {
        let documentID = DocumentID(UUID())
        let page = ZPDFContracts.PageDescriptor(
            id: PageID(UUID()), documentID: documentID, index: 0, label: "A-101",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 612, height: 792))
        )
        let session = try TakeoffSession(documentID: documentID, pages: [page])
        let environment = try await AppCoreEnvironment.make(session: session, documentID: documentID)
        try await environment.commands.calibrate(
            page: page.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
            knownLength: 10, knownLengthUnit: .metre
        )
        let id = MarkupID(UUID())
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        try await environment.commands.perform(.addMarkup(ZPDFContracts.MarkupRecord(
            id: id, documentID: documentID, pageID: page.id, kind: .measurement, tool: .length,
            subject: "Wall W1", author: "test",
            geometry: MeasurementGeometry(pageID: page.id, points: [PDFPoint(x: 0, y: 0), PDFPoint(x: points, y: 0)]),
            createdAt: stamp, modifiedAt: stamp
        )))
        await environment.ledger.refresh()
        return Wall(environment: environment, session: session, wall: id, page: page.id, documentID: documentID)
    }

    func applier(_ wall: Wall) throws -> any LedgerAssemblyApplying {
        try #require(wall.environment.ledger as? any LedgerAssemblyApplying)
    }

    /// Every derived row's primary quantity, by line name.
    func derived(_ wall: Wall) -> [String: Decimal] {
        var values: [String: Decimal] = [:]
        let ledger = wall.environment.ledger
        for index in 0..<ledger.rowCount {
            guard let row = ledger.row(at: index), row.markupID != wall.wall.rawValue else { continue }
            let subject = row.displayValue(.subject)
            if let quantity = LedgerDefaultColumns.primaryQuantity(for: row) { values[subject] = quantity.value }
        }
        return values
    }

    @Test("The timber wall at 2.4 m / 0.6 m derives four rows with ƒ, follows a vertex edit, and dies with its wall in one undo")
    func timberWallAcceptance() async throws {
        let wall = try await makeWall()
        let assembly = try applier(wall)
        let timber = try #require(assembly.availableAssemblies.first { $0.name == "Timber stud wall" })
        #expect(timber.inputs.first { $0.name == "Spacing" }?.isFreeParameter == true)

        let receipt = await assembly.applyAssembly(
            timber.id,
            parameters: ["Height": .init(value: Decimal(string: "2.4")!, dimension: .length),
                         "Spacing": .init(value: Decimal(string: "0.6")!, dimension: .length)],
            to: [wall.wall.rawValue]
        )
        #expect(!receipt.didFail, "\(receipt.failureDescription ?? "")")
        let ledger = wall.environment.ledger
        #expect(ledger.rowCount == 5, "the wall and its four derived rows")
        var rows = derived(wall)
        #expect(rows["Wall area"] == 24)
        #expect(rows["Studs"] == 17)
        #expect(rows["Plates"] == 20)
        #expect(rows["Plasterboard both sides"] == 48)
        // ƒ in the Type cell, the formula in the comment — words and a glyph, not colour.
        for index in 0..<ledger.rowCount {
            let row = try #require(ledger.row(at: index))
            guard row.markupID != wall.wall.rawValue else { continue }
            #expect(row.displayValue(.icon).hasPrefix("ƒ"))
            #expect(row.displayValue(.comment).contains("Timber stud wall"))
        }
        let studs = try #require((0..<ledger.rowCount).compactMap { ledger.row(at: $0) }.first { $0.displayValue(.subject) == "Studs" })
        #expect(studs.displayValue(.comment).contains("FLOOR(Length / Spacing) + 1"))

        // Move the far vertex to 12 m: 28.8 m², FLOOR(20) + 1 = 21 studs, 24 m of plate, 57.6 m².
        try await wall.environment.commands.perform(.editVertices(
            id: wall.wall,
            geometry: MeasurementGeometry(pageID: wall.page, points: [PDFPoint(x: 0, y: 0), PDFPoint(x: 120, y: 0)])
        ))
        await ledger.refresh()
        rows = derived(wall)
        #expect(rows["Wall area"] == Decimal(string: "28.8")!)
        #expect(rows["Studs"] == 21)
        #expect(rows["Plates"] == 24)
        #expect(rows["Plasterboard both sides"] == Decimal(string: "57.6")!)

        // A derived row is never edited as itself.
        let edit = try #require(ledger as? any LedgerBulkEditPresenting)
        let refused = await edit.applyBulkEdit(LedgerBulkEditRequest(markupIDs: [studs.markupID], values: [.label: .text("x")]))
        #expect(refused.failureDescription?.contains("derived") == true, "\(refused.failureDescription ?? "")")

        // Deleting the wall removes all five rows; one ⌘Z brings all five back.
        try await wall.environment.commands.perform(.removeMarkup(wall.wall))
        await ledger.refresh()
        #expect(ledger.rowCount == 0)
        await wall.environment.commands.undo()
        await ledger.refresh()
        #expect(ledger.rowCount == 5)
    }

    @Test("An export marks the derived rows as derived and names the formula")
    func exportMarksDerivedRows() async throws {
        let wall = try await makeWall()
        _ = try await applier(wall).applyAssembly(
            LedgerAssemblyLibrary.standard[0].id,
            parameters: ["Height": .init(value: Decimal(string: "2.4")!, dimension: .length),
                         "Spacing": .init(value: Decimal(string: "0.6")!, dimension: .length)],
            to: [wall.wall.rawValue]
        )
        let (report, _) = try await wall.session.exportReportWithDiagnostics(title: "T")
        let rows = report.allRows()
        #expect(rows.filter { $0.provenance == .derived }.count == 4)
        #expect(rows.filter { $0.provenance == .measured }.count == 1)
        let comment = try #require(await wall.session.ledgerColumns.column(standard: .comment))
        let texts = rows.filter { $0.provenance == .derived }.compactMap { row -> String? in
            guard case .value(.text(let text))? = row.cells.first(where: { $0.column == comment.id })?.value else { return nil }
            return text
        }
        #expect(texts.contains { $0.contains("Length * Height") })
        // The plan-length total counts the wall and the 20 m of plates, both extents: 10 + 20 = 30.
        let planLength = try #require(await wall.session.ledgerColumns.column(standard: .planLength))
        #expect(report.grandTotals.first { $0.column == planLength.id && $0.function == .sum }?.value == .quantity(.length(30)))
    }

    @Test("A missing parameter says which on the derived row instead of showing a blank")
    func missingParameterIsSaid() async throws {
        let wall = try await makeWall()
        _ = try await applier(wall).applyAssembly(
            LedgerAssemblyLibrary.standard[0].id,
            parameters: ["Height": .init(value: Decimal(string: "2.4")!, dimension: .length)],
            to: [wall.wall.rawValue]
        )
        let ledger = wall.environment.ledger
        let studs = try #require((0..<ledger.rowCount).compactMap { ledger.row(at: $0) }.first { $0.displayValue(.subject) == "Studs" })
        #expect(studs.displayValue(.comment).contains("Spacing"), "\(studs.displayValue(.comment))")
        // The lines that do not need Spacing still derive.
        #expect(derived(wall)["Plates"] == 20)
    }

    @Test("Removing the assembly takes its rows away as one undoable step")
    func removeAssembly() async throws {
        let wall = try await makeWall()
        let assembly = try applier(wall)
        _ = await assembly.applyAssembly(
            LedgerAssemblyLibrary.concreteSlab.id, parameters: [:], to: [wall.wall.rawValue]
        )
        // A slab recipe on a line: Area is missing, so its lines say so, but the rows exist.
        #expect(wall.environment.ledger.rowCount == 4)
        let removed = await assembly.applyAssembly(nil, parameters: [:], to: [wall.wall.rawValue])
        #expect(!removed.didFail)
        #expect(wall.environment.ledger.rowCount == 1)
        await wall.environment.commands.undo()
        await wall.environment.ledger.refresh()
        #expect(wall.environment.ledger.rowCount == 4)
    }
}
