import CoreGraphics
import Foundation
import Testing
@testable import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
import ZPDFVectorExtraction

/// Bug hunt 2, table import (BH-119, BH-120, BH-459, BH-460, BH-461, BH-462).
@Suite("Bug hunt 2: table import")
struct BugHunt2TableImportTests {

    private struct FreshIdentifiers: IdentifierGenerating {
        func nextIdentifier() -> UUID { UUID() }
    }

    private struct FixedClock: TimestampProviding {
        func now() -> Date { Date(timeIntervalSinceReferenceDate: 800_000_000) }
    }

    private static let region = PDFRectValue(x: 100, y: 500, width: 300, height: 100)

    private static func line(_ text: String, x: Double, y: Double, width: Double) -> RecognisedTextLine {
        RecognisedTextLine(text: text, boundsInPageSpace: PDFRectValue(x: x, y: y, width: width, height: 9))
    }

    // MARK: BH-119

    @Test("A right-aligned quantity column keeps its wide value")
    func rightAlignedColumn() throws {
        // Right edge R = 390. '1234,56' is 36 pt wide; '8' and '5' are 8 pt wide.
        let lines = [
            Self.line("Betong C30/37", x: 110, y: 575, width: 80),
            Self.line("Armering", x: 110, y: 555, width: 60),
            Self.line("Formwork", x: 110, y: 535, width: 60),
            Self.line("1234,56", x: 354, y: 575, width: 36),
            Self.line("8", x: 382, y: 555, width: 8),
            Self.line("5", x: 382, y: 535, width: 8)
        ]
        let proposal = try TableImportEngine().propose(region: Self.region, recognisedLines: lines, ruleLines: []).get()
        #expect(proposal.columnSource == .textAlignment)
        let first = try #require(proposal.rows.first)
        // Old output: "Betong C30/37 1234,56" in the description cell, the quantity unread.
        #expect(first.cells.map(\.text) == ["Betong C30/37", "1234,56"])
    }

    @Test("Left-aligned OCR jitter does not push a narrow line into the previous column")
    func leftAlignedJitter() throws {
        let lines = [
            Self.line("Door D-1", x: 110, y: 575, width: 70),
            Self.line("Door D-2", x: 110, y: 555, width: 70),
            Self.line("Door D-3", x: 110, y: 535, width: 70),
            // Leading edges 260, 262, 266: mean 262.67. The 5 pt '5' at 260 has its centre at 262.5.
            Self.line("5", x: 260, y: 575, width: 5),
            Self.line("12", x: 262, y: 555, width: 10),
            Self.line("40", x: 266, y: 535, width: 10)
        ]
        let proposal = try TableImportEngine().propose(region: Self.region, recognisedLines: lines, ruleLines: []).get()
        // Old output: "Door D-1 5" and an unread quantity.
        #expect(proposal.rows.first?.cells.map(\.text) == ["Door D-1", "5"])
    }

    // MARK: BH-120

    @Test("A grid drawn as one rectangle per cell is found as a grid")
    func perCellRectangles() throws {
        // Four rows of 25 pt, three columns of 100 pt, each cell its own four edges.
        var rules: [VectorLine] = []
        for row in 0..<4 {
            for column in 0..<3 {
                let x0 = 100.0 + Double(column) * 100, y0 = 500.0 + Double(row) * 25
                let c = [CGPoint(x: x0, y: y0), CGPoint(x: x0 + 100, y: y0), CGPoint(x: x0 + 100, y: y0 + 25), CGPoint(x: x0, y: y0 + 25)]
                for index in 0..<4 { rules.append(VectorLine(start: c[index], end: c[(index + 1) % 4])) }
            }
        }
        let lines = (0..<4).flatMap { row -> [RecognisedTextLine] in
            let y = 508.0 + Double(row) * 25
            return [
                Self.line("Item \(row)", x: 110, y: y, width: 40),
                Self.line("\(row + 1)", x: 210, y: y, width: 10),
                Self.line("st", x: 310, y: y, width: 10)
            ]
        }
        let proposal = try TableImportEngine().propose(region: Self.region, recognisedLines: lines, ruleLines: rules).get()
        // Old output: .textAlignment — every 25 pt edge was under 0.6 × 100 pt and discarded.
        #expect(proposal.columnSource == .ruleLines)
        #expect(proposal.columns.count == 3)
    }

    // MARK: BH-461

    @Test("A refusal names the alignment clusters it actually found")
    func refusalCountsClusters() {
        let region = PDFRectValue(x: 200, y: 500, width: 200, height: 100)
        // Two clusters, both left of the region, carried in by lines that cross into it.
        let lines = [
            Self.line("aaaaaaaaaaaaaaaaaaaa", x: 100, y: 575, width: 150),
            Self.line("bbbbbbbbbbbbbbbbbbbb", x: 100, y: 555, width: 150),
            Self.line("cccccccccccccccccccc", x: 150, y: 535, width: 150),
            Self.line("dddddddddddddddddddd", x: 150, y: 515, width: 150)
        ]
        let result = TableImportEngine().propose(region: region, recognisedLines: lines, ruleLines: [])
        guard case .failure(.noColumnStructure(_, let clusters)) = result else {
            Issue.record("expected a refusal, got \(result)")
            return
        }
        // Old output: 0.
        #expect(clusters == 2)
    }

    // MARK: BH-462

    @Test("A line whose centre sits just outside the selection still lands in a row")
    func edgeLineIsBanded() throws {
        let rules = [
            VectorLine(start: CGPoint(x: 200, y: 500), end: CGPoint(x: 200, y: 600)),
            VectorLine(start: CGPoint(x: 100, y: 550), end: CGPoint(x: 400, y: 550))
        ]
        let lines = [
            Self.line("Top", x: 110, y: 570, width: 40),
            Self.line("1", x: 210, y: 570, width: 10),
            // Centre at y = 498: overlaps the region, centre below it.
            Self.line("Bottom", x: 110, y: 493.5, width: 40),
            Self.line("2", x: 210, y: 493.5, width: 10)
        ]
        let proposal = try TableImportEngine().propose(region: Self.region, recognisedLines: lines, ruleLines: rules).get()
        // Old output: one row — "Bottom 2" vanished from rows, source text and unplaced text.
        #expect(proposal.rows.contains { $0.sourceText.contains("Bottom") })
    }

    // MARK: BH-459, BH-460

    @Test("Acceptance skips a ragged row's missing cell and keeps both values of a repeated header")
    func acceptanceRaggedAndDuplicateHeaders() {
        let columns = [
            TableImportColumn(index: 0, minX: 100, maxX: 200, headerText: "Qty"),
            TableImportColumn(index: 1, minX: 200, maxX: 300, headerText: "Qty"),
            TableImportColumn(index: 2, minX: 300, maxX: 400, headerText: "Unit")
        ]
        let full = TableImportRow(
            cells: [TableImportCell(text: "3", boundsInPageSpace: nil), TableImportCell(text: "4", boundsInPageSpace: nil),
                    TableImportCell(text: "st", boundsInPageSpace: nil)],
            sourceText: "3 4 st", boundsInPageSpace: nil
        )
        let ragged = TableImportRow(
            cells: [TableImportCell(text: "5", boundsInPageSpace: nil)],
            sourceText: "5", boundsInPageSpace: nil
        )
        let proposal = TableImportProposal(
            region: Self.region, columns: columns, headerRow: nil, rows: [full, ragged],
            columnSource: .ruleLines, unplacedTexts: []
        )
        // Old behaviour: an index-out-of-range trap on the ragged row.
        let acceptance = TableImportAcceptance.records(
            from: proposal, documentID: DocumentID(UUID()), pageID: PageID(UUID()),
            identifiers: FreshIdentifiers(), timestamps: FixedClock()
        )
        #expect(acceptance.records.count == 2)
        // Old output: ["Qty": "4", "Unit": "st"] — the first Qty value lost from the audit.
        #expect(acceptance.records[0].derivation?.inputs == ["Qty": "3", "Qty (column 2)": "4", "Unit": "st"])
        #expect(acceptance.records[1].derivation?.inputs == ["Qty": "5"])
    }
}
