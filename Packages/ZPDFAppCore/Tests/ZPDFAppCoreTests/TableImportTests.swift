import Foundation
import Testing
@testable import ZPDFAppCore
import ZPDFContracts
import ZPDFQuantityLedger
import ZPDFUIPresentation
import ZPDFVectorExtraction

/// Feature 31: a table printed on the drawing becomes `.read` ledger rows (ADR-0012),
/// distinguishable from measurements forever after.
@Suite("Table import")
struct TableImportTests {

    // MARK: - Fixtures

    /// Injected identifiers — nothing in the engine mints its own. Fresh UUIDs are enough
    /// here: the tests assert structure and provenance, never specific id values.
    private struct FreshIdentifiers: IdentifierGenerating {
        func nextIdentifier() -> UUID { UUID() }
    }

    private struct FixedClock: TimestampProviding {
        func now() -> Date { Date(timeIntervalSinceReferenceDate: 800_000_000) }
    }

    /// The user-chosen rectangle every fixture table sits in.
    private static let region = PDFRectValue(x: 100, y: 500, width: 300, height: 100)

    private static func line(_ text: String, x: Double, y: Double, width: Double = 60) -> RecognisedTextLine {
        RecognisedTextLine(
            text: text,
            boundsInPageSpace: PDFRectValue(x: x, y: y, width: width, height: 9)
        )
    }

    private static func vertical(_ x: Double, from y0: Double = 500, to y1: Double = 600) -> VectorLine {
        VectorLine(start: CGPoint(x: x, y: y0), end: CGPoint(x: x, y: y1))
    }

    private static func horizontal(_ y: Double, from x0: Double = 100, to x1: Double = 400) -> VectorLine {
        VectorLine(start: CGPoint(x: x0, y: y), end: CGPoint(x: x1, y: y))
    }

    /// A drawn schedule: frame, two interior column rules, three interior row rules,
    /// a header row and three data rows — with one cell the OCR never read.
    private static func ruledFixture() -> (lines: [RecognisedTextLine], rules: [VectorLine]) {
        let rules: [VectorLine] = [
            vertical(100), vertical(200), vertical(300), vertical(400),
            horizontal(600), horizontal(575), horizontal(550), horizontal(525), horizontal(500)
        ]
        let lines: [RecognisedTextLine] = [
            line("Material", x: 110, y: 578),
            line("Volume", x: 210, y: 578),
            line("Unit", x: 310, y: 578),
            line("Betong C30/37", x: 110, y: 560),
            line("12,5", x: 210, y: 560, width: 25),
            line("m3", x: 310, y: 560, width: 15),
            line("Armering B500B", x: 110, y: 535),
            line("890", x: 210, y: 535, width: 22),
            line("kg", x: 310, y: 535, width: 14),
            line("Formwork", x: 110, y: 510),
            // The middle cell of the last row was never read: it must stay empty.
            line("m2", x: 310, y: 510, width: 15)
        ]
        return (lines, rules)
    }

    private static func page(documentID: DocumentID, pageID: PageID) -> ZPDFContracts.PageDescriptor {
        ZPDFContracts.PageDescriptor(
            id: pageID,
            documentID: documentID,
            index: 0,
            label: "1",
            boxes: PageBoxes(
                media: PDFRect(x: 0, y: 0, width: 595, height: 842),
                crop: PDFRect(x: 0, y: 0, width: 595, height: 842)
            )
        )
    }

    private static func propose(
        _ fixture: (lines: [RecognisedTextLine], rules: [VectorLine])
    ) throws -> TableImportProposal {
        let engine = TableImportEngine()
        return try engine.propose(
            region: region, recognisedLines: fixture.lines, ruleLines: fixture.rules
        ).get()
    }

    // MARK: - Detection

    @Test("A ruled schedule yields its columns from the rule lines, intact")
    func ruledScheduleDetects() throws {
        let proposal = try Self.propose(Self.ruledFixture())
        #expect(proposal.columnSource == .ruleLines)
        #expect(proposal.columns.count == 3)
        #expect(proposal.columns.map(\.title) == ["Material", "Volume", "Unit"])
        #expect(proposal.headerRow != nil)
        #expect(proposal.rows.count == 3)
        #expect(proposal.rows[0].cells.map(\.text) == ["Betong C30/37", "12,5", "m3"])
        #expect(proposal.rows[1].cells.map(\.text) == ["Armering B500B", "890", "kg"])
        #expect(proposal.unplacedTexts.isEmpty)
    }

    @Test("A cell the OCR could not read stays empty and stays flagged, never invented")
    func unreadCellStaysEmpty() throws {
        let proposal = try Self.propose(Self.ruledFixture())
        let lastRow = try #require(proposal.rows.last)
        #expect(lastRow.cells[0].text == "Formwork")
        #expect(lastRow.cells[1].text.isEmpty)
        #expect(lastRow.cells[1].isUnread)
        #expect(lastRow.cells[2].text == "m2")
        #expect(proposal.unreadCellCount == 1)
    }

    @Test("A gridless schedule falls back to text alignment and says so")
    func alignmentFallback() throws {
        let lines: [RecognisedTextLine] = [
            Self.line("Betong C30/37", x: 110, y: 560),
            Self.line("12,5", x: 260, y: 560, width: 25),
            Self.line("Armering B500B", x: 110, y: 535),
            Self.line("890", x: 260, y: 535, width: 22),
            Self.line("Formwork", x: 110, y: 510),
            Self.line("55", x: 260, y: 510, width: 18)
        ]
        let engine = TableImportEngine()
        let proposal = try engine.propose(
            region: Self.region, recognisedLines: lines, ruleLines: []
        ).get()
        #expect(proposal.columnSource == .textAlignment)
        #expect(proposal.columns.count == 2)
        #expect(proposal.headerRow == nil)
        #expect(proposal.rows.count == 3)
        #expect(proposal.rows[0].cells.map(\.text) == ["Betong C30/37", "12,5"])
        // No header on the sheet: the columns get positional names, not invented ones.
        #expect(proposal.columns.map(\.title) == ["Column 1", "Column 2"])
    }

    // MARK: - Honest refusals

    @Test("A region with no detectable column structure is refused, never a one-column guess")
    func noStructureIsRefused() throws {
        // One alignment cluster: every line starts at the same x. That is a list, not a table.
        let lines: [RecognisedTextLine] = [
            Self.line("Betong C30/37", x: 110, y: 560),
            Self.line("Armering B500B", x: 110, y: 535),
            Self.line("Formwork", x: 110, y: 510)
        ]
        let engine = TableImportEngine()
        let result = engine.propose(region: Self.region, recognisedLines: lines, ruleLines: [])
        switch result {
        case .success(let proposal):
            Issue.record("expected a refusal, got a \(proposal.columns.count)-column proposal")
        case .failure(let refusal):
            #expect(refusal == .noColumnStructure(interiorRuleCount: 0, alignmentClusterCount: 1))
        }
    }

    @Test("An empty region is refused as empty")
    func emptyRegionIsRefused() {
        let engine = TableImportEngine()
        let result = engine.propose(
            region: Self.region,
            recognisedLines: [Self.line("Elsewhere", x: 900, y: 900)],
            ruleLines: []
        )
        #expect(result == .failure(.emptyRegion))
    }

    @Test("Text that arrived without page positions is refused by name, not guessed into a grid")
    func positionlessTextIsRefused() {
        let engine = TableImportEngine()
        let result = engine.propose(
            region: Self.region,
            recognisedLines: [
                RecognisedTextLine(text: "Betong C30/37 12,5 m3"),
                RecognisedTextLine(text: "Armering B500B 890 kg")
            ],
            ruleLines: []
        )
        #expect(result == .failure(.textWithoutPositions(lineCount: 2)))
    }

    // MARK: - Acceptance: .read records under ADR-0012

    @Test("An accepted proposal becomes .read records that carry the recognised text verbatim")
    func acceptanceBuildsReadRecords() throws {
        let proposal = try Self.propose(Self.ruledFixture())
        let documentID = DocumentID(UUID())
        let pageID = PageID(UUID())
        let acceptance = TableImportAcceptance.records(
            from: proposal,
            documentID: documentID,
            pageID: pageID,
            identifiers: FreshIdentifiers(),
            timestamps: FixedClock()
        )

        #expect(acceptance.records.count == 3)
        #expect(acceptance.columnBindings.map(\.title) == ["Material", "Volume", "Unit"])

        for (index, record) in acceptance.records.enumerated() {
            #expect(record.provenance == .read)
            let derivation = try #require(record.derivation)
            #expect(derivation.formulaText == proposal.rows[index].sourceText)
            #expect(derivation.sourceMarkupID == nil)
            #expect(derivation.originIdentifier.contains(pageID.rawValue.uuidString))
            #expect(derivation.originIdentifier.contains("row \(index + 1)"))
            // Nothing here was measured, so nothing here may look measured.
            #expect(record.measurement == nil)
            #expect(record.geometry == nil)
            #expect(record.tool == nil)
            #expect(record.quantityProvenanceViolation() == nil)
        }

        let first = acceptance.records[0]
        #expect(first.subject == "Betong C30/37")
        #expect(first.derivation?.inputs == [
            "Material": "Betong C30/37", "Volume": "12,5", "Unit": "m3"
        ])

        // The unread cell is absent everywhere: no input, no custom value, no invention.
        let last = acceptance.records[2]
        #expect(last.derivation?.inputs == ["Material": "Formwork", "Unit": "m2"])
        let volumeBinding = try #require(acceptance.columnBindings.first { $0.title == "Volume" })
        #expect(last.customValues[volumeBinding.columnID] == nil)
        #expect(last.customValues.count == 2)
    }

    @Test("Rows land through the existing .addMarkup command with provenance intact")
    func rowsLandThroughAddMarkup() async throws {
        let proposal = try Self.propose(Self.ruledFixture())
        let documentID = DocumentID(UUID())
        let pageID = PageID(UUID())
        let session = try TakeoffSession(
            documentID: documentID,
            pages: [Self.page(documentID: documentID, pageID: pageID)]
        )
        let acceptance = TableImportAcceptance.records(
            from: proposal,
            documentID: documentID,
            pageID: pageID,
            identifiers: FreshIdentifiers(),
            timestamps: FixedClock()
        )

        for command in acceptance.commands {
            guard case .addMarkup = command else {
                Issue.record("table import may only use the existing .addMarkup command")
                return
            }
        }
        let outcome = try await session.applyBatch(acceptance.commands)
        #expect(outcome.changedMarkupIDs.count == 3)

        for record in acceptance.records {
            let stored = try #require(await session.markup(record.id))
            #expect(stored.provenance == .read)
            #expect(stored.derivation == record.derivation)
            #expect(stored.measurement == nil)
        }
        // Classified by subject, so every imported row is a ledger row.
        let ledgerIDs = Set(await session.ledgerMarkups.map(\.id))
        for record in acceptance.records {
            #expect(ledgerIDs.contains(record.id))
        }
    }

    // MARK: - Must never: an imported row mistaken for a measurement

    @Test("A .read row round-trips through the session and stays distinguishable in the export report")
    func exportDistinguishesReadFromMeasured() async throws {
        let documentID = DocumentID(UUID())
        let pageID = PageID(UUID())
        let session = try TakeoffSession(
            documentID: documentID,
            pages: [Self.page(documentID: documentID, pageID: pageID)]
        )

        // One genuinely classified measured row (no geometry, so nothing recomputes)…
        let measured = MarkupRecord(
            id: MarkupID(UUID()),
            documentID: documentID,
            pageID: pageID,
            kind: .note,
            subject: "Slab edge note",
            createdAt: Date(timeIntervalSinceReferenceDate: 0),
            modifiedAt: Date(timeIntervalSinceReferenceDate: 0)
        )
        _ = try await session.apply(.addMarkup(measured))

        // …and the imported table beside it.
        let proposal = try Self.propose(Self.ruledFixture())
        let acceptance = TableImportAcceptance.records(
            from: proposal,
            documentID: documentID,
            pageID: pageID,
            identifiers: FreshIdentifiers(),
            timestamps: FixedClock()
        )
        _ = try await session.applyBatch(acceptance.commands)

        let report = try await session.exportReportWithDiagnostics(
            title: "Test export", timestamps: FixedClock()
        ).report
        let rows = report.allRows()
        #expect(rows.count == 4)

        // Per exported row, the stored record's claim is recoverable and correct.
        var claims: [MarkupID: QuantityProvenance] = [:]
        for row in rows {
            let record = try #require(await session.markup(row.markupID))
            claims[row.markupID] = record.provenance
        }
        #expect(claims[measured.id] == .measured)
        for imported in acceptance.records {
            #expect(claims[imported.id] == .read)
        }
        // The two claims never collapse into one.
        #expect(Set(claims.values) == Set([.measured, .read]))
    }

    @Test("A .read row survives a JSON round-trip with provenance and derivation intact")
    func readRowSurvivesArchiveRoundTrip() throws {
        let proposal = try Self.propose(Self.ruledFixture())
        let acceptance = TableImportAcceptance.records(
            from: proposal,
            documentID: DocumentID(UUID()),
            pageID: PageID(UUID()),
            identifiers: FreshIdentifiers(),
            timestamps: FixedClock()
        )
        let record = try #require(acceptance.records.first)
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(MarkupRecord.self, from: data)
        #expect(decoded == record)
        #expect(decoded.provenance == .read)
        #expect(decoded.derivation?.formulaText == proposal.rows[0].sourceText)
    }

    // MARK: - The proposal measures nothing

    @Test("Store-level: the ledger store keeps the whole record, so provenance survives into any view")
    func ledgerStoreKeepsProvenance() throws {
        let proposal = try Self.propose(Self.ruledFixture())
        let acceptance = TableImportAcceptance.records(
            from: proposal,
            documentID: DocumentID(UUID()),
            pageID: PageID(UUID()),
            identifiers: FreshIdentifiers(),
            timestamps: FixedClock()
        )
        let columns = try TakeoffSession.baseColumnSet(displayPolicy: DisplayUnitSelection.metric.domainPolicy)
        let store = try LedgerStore(markups: acceptance.records, columns: columns)
        for index in 0..<store.rowCount {
            #expect(store.record(at: index).provenance == .read)
        }
    }
}
