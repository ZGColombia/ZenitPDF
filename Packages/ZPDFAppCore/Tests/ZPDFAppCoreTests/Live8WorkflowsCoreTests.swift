import Foundation
import Testing
@testable import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
import ZPDFVectorExtraction

/// Manual-test findings: the core halves of Name Sheets (L-54), the batch stamp's
/// sheet label (L-58) and Import Table from Drawing (L-64). Every position is written next to
/// the line it places; the expected values are the text printed in the cells.
struct Live8WorkflowsCoreTests {

    // MARK: - L-54: a boxed title-block cell's printed label is not the name

    /// A1 landscape, and the boxes of `TitleBlockReaderTests`: number 2200…2360 × 40…90,
    /// title 1900…2360 × 110…190.
    static let a1 = PDFRectValue(x: 0, y: 0, width: 2384, height: 1684)
    static let numberBox = PDFRectValue(x: 2200, y: 40, width: 160, height: 50)
    static let titleBox = PDFRectValue(x: 1900, y: 110, width: 460, height: 80)

    static func line(_ text: String, _ x: Double, _ y: Double, _ width: Double, _ height: Double = 20) -> RecognisedTextLine {
        RecognisedTextLine(text: text, boundsInPageSpace: PDFRectValue(x: x, y: y, width: width, height: height))
    }

    static func read(_ lines: [RecognisedTextLine]) throws -> SheetNameProposal {
        let template = TitleBlockTemplate(numberRect: numberBox, titleRect: titleBox, pageBox: a1)
        return try #require(TitleBlockReader().read(template: template, pageIndex: 0, pageBox: a1, lines: lines))
    }

    @Test("L-54: the number cell's label and the next cell's label are left out of the reading")
    func labelsAreStripped() throws {
        let proposal = try Self.read([
            // The number cell: its label printed small at the top (y 76…86), the number below.
            Self.line("DOKUMENTNUMMER", 2205, 76, 100, 10),
            Self.line("A-00-0-001", 2210, 50, 120),
            // The title, and the label of the cell under it that the generous box reached.
            Self.line("VII Takplan Demo", 1910, 160, 300),
            Self.line("RITNINGSKATEGORI", 1910, 115, 150, 10)
        ])
        // Old: "DOKUMENTNUMMER A-00-0-001" and "VII Takplan Demo RITNINGSKATEGORI".
        #expect(proposal.number == "A-00-0-001")
        #expect(proposal.title == "VII Takplan Demo")
        #expect(proposal.source == .template)
    }

    @Test("L-54: a label on the value's own line is cut off; a box that starts in the cell above skips its label")
    func labelOnTheSameLineAndCellAbove() throws {
        let proposal = try Self.read([
            Self.line("DOKUMENTNUMMER A-00-0-001", 2205, 50, 150),
            // The cell above the title (its label and value), then the title cell's own label.
            Self.line("SKALA 1:100", 1910, 170, 120, 12),
            Self.line("INNEHÅLL", 1910, 150, 80, 10),
            Self.line("Plan 2 tr", 1910, 120, 200)
        ])
        // Old: "DOKUMENTNUMMER A-00-0-001" and "SKALA 1:100 INNEHÅLL Plan 2 tr".
        #expect(proposal.number == "A-00-0-001")
        #expect(proposal.title == "Plan 2 tr")
    }

    @Test("L-54: a title that only begins with a label word is still read whole")
    func aTitleOfLabelWordsIsKept() throws {
        let proposal = try Self.read([
            Self.line("A-101", 2210, 50, 120),
            Self.line("PROJECT OVERVIEW", 1910, 160, 300)
        ])
        #expect(proposal.number == "A-101")
        #expect(proposal.title == "PROJECT OVERVIEW")
    }

    // MARK: - L-54 (re-fix): a standard Swedish title block

    /// The sheet ("Plan A") is A1 landscape with the Swedish standard title block
    /// in its bottom-right corner. These are the block's text lines as PDFKit's line selections
    /// gave them (x, y, width, height in page points, origin bottom left), labels 6.5 pt high at
    /// the top of each cell, values 13 pt high under them — the cell layout as measured, every
    /// value replaced by a fictional one.
    static let planAPage = PDFRectValue(x: 0, y: 0, width: 2383.94, height: 1683.78)
    static let planABlock: [RecognisedTextLine] = [
        line("DATUM ", 2047.2, 496.6, 20.4, 6.5), line("2026-01-15", 2047.2, 482.2, 59.7, 13.0),
        line("GODKÄND AV ", 2143.6, 496.6, 38.5, 6.5), line("A. Berg", 2143.6, 482.2, 65.5, 13.0),
        line("ÄNDRINGS PM", 2282.5, 496.6, 41.1, 6.5), line("BESTÄLLARE", 2047.2, 473.9, 37.6, 6.5),
        line("PROJEKTNAMN", 2047.2, 360.5, 44.1, 6.5), line("EXEMPELPROJEKT", 2124.5, 340.8, 122.0, 21.7),
        line("OMRÅDE", 2047.2, 332.2, 25.6, 6.5), line("KV 1:10 EXEMPELPARK", 2094.8, 312.5, 182.6, 21.7),
        line("PROJEKTNUMMER ", 2047.2, 303.8, 53.1, 6.5), line("100001 - 0001 ", 2047.2, 289.5, 75.2, 13.0),
        line("ADRESS", 2143.6, 303.8, 24.0, 6.5), line("Exempelgatan", 2143.6, 289.5, 67.2, 13.0),
        line("DIARIENUMMER ", 2047.2, 281.1, 45.7, 6.5), line("FASTIGHET", 2143.6, 281.1, 32.4, 6.5),
        line("- Exempel 1", 2047.2, 266.8, 163.8, 13.0),
        line("DISCIPLIN ", 2047.2, 258.5, 28.5, 6.5), line("FÖRETAG", 2143.6, 258.5, 27.8, 6.5),
        line("A Exempelarkitekter AB", 2047.2, 244.1, 215.7, 13.0),
        line("UPPDRAGSNUMMER ", 2047.2, 235.8, 59.0, 6.5), line("1000", 2047.2, 221.4, 25.9, 13.0),
        line("SKAPAD AV", 2143.6, 235.8, 32.2, 6.5), line("B. Lund", 2143.6, 221.5, 61.4, 13.0),
        line("TELEFON ", 2047.2, 213.1, 26.9, 6.5), line("00 - 000 00 00 ", 2047.2, 198.8, 75.2, 13.0),
        line("KONTAKTPERSON", 2143.6, 213.1, 51.8, 6.5), line("C. Holm", 2143.6, 198.8, 71.3, 13.0),
        line("BYGGNADSVERK ", 2047.2, 190.4, 48.9, 6.5), line("PLUSHÖJD", 2143.6, 190.4, 31.1, 6.5),
        line("- -", 2047.2, 176.1, 100.3, 13.0),
        line("VÅNINGSPLAN ", 2047.2, 167.8, 41.5, 6.5), line("17 ", 2047.2, 153.4, 13.0, 13.0),
        line("VÅNINGSDEL ", 2095.4, 167.8, 37.6, 6.5), line("01 ", 2095.4, 153.4, 13.0, 13.0),
        line("DELOMRÅDE", 2143.6, 167.8, 36.9, 6.5), line("HUS 1", 2143.6, 153.4, 34.4, 13.0),
        line("SYSTEM", 2047.2, 145.1, 24.0, 6.5), line("A-00-0 Takplan", 2047.2, 130.7, 78.4, 13.0),
        line("SPECIFIKATION", 2047.2, 122.4, 44.0, 6.5), line("Takplan Demo", 2047.2, 108.1, 73.9, 13.0),
        line("RITNINGSKATEGORI ", 2047.2, 99.7, 57.6, 6.5), line("Planer", 2047.2, 85.4, 33.7, 13.0),
        line("SKALA ", 2234.3, 99.7, 18.8, 6.5), line("1:50", 2234.3, 85.4, 22.7, 13.0),
        line("FORMAT", 2282.5, 99.7, 24.3, 6.5), line("A1", 2282.5, 85.4, 14.3, 13.0),
        line("DOKUMENTNUMMER ", 2047.2, 77.1, 59.6, 6.5), line("A-00-0-001", 2047.2, 57.3, 86.4, 19.5),
        line("ÄNDRING", 2282.5, 77.1, 26.9, 6.5)
    ]

    static func readPlanA(number: PDFRectValue, title: PDFRectValue?, lines: [RecognisedTextLine] = planABlock) throws -> SheetNameProposal {
        let template = TitleBlockTemplate(numberRect: number, titleRect: title, pageBox: planAPage)
        return try #require(TitleBlockReader().read(template: template, pageIndex: 0, pageBox: planAPage, lines: lines))
    }

    /// A number box drawn tight around "A-00-0-001" (57.3…76.8), inside its cell.
    static let planATightNumber = PDFRectValue(x: 2042, y: 54, width: 160, height: 22)

    @Test("L-54: a title box with the usual margin reads the title, not SPECIFIKATION above it or RITNINGSKATEGORI below")
    func planATitleCellLabelIsLeftOut() throws {
        // y 102…127: more than half of SPECIFIKATION (122.4…128.9) and of RITNINGSKATEGORI
        // (99.7…106.2) lies inside, the same margin the manual test's boxes had.
        let proposal = try Self.readPlanA(number: Self.planATightNumber, title: PDFRectValue(x: 2042, y: 102, width: 160, height: 25))
        // Before the re-fix: "SPECIFIKATION Takplan Demo".
        #expect(proposal.title == "Takplan Demo")
        #expect(proposal.number == "A-00-0-001")
    }

    @Test("L-54: a number box that starts in the cell above drops that cell's label and its value")
    func planANumberBoxReachingTheCellAbove() throws {
        // y 54…104: RITNINGSKATEGORI / "Planer" (the cell above), then DOKUMENTNUMMER / the number.
        let proposal = try Self.readPlanA(number: PDFRectValue(x: 2042, y: 54, width: 160, height: 50), title: nil)
        // Before the re-fix: "Planer A-00-0-001".
        #expect(proposal.number == "A-00-0-001")
    }

    @Test("L-54: a title box reaching two cells up still reads only the title cell's value")
    func planATitleBoxReachingTheSystemCell() throws {
        // y 102…150: SYSTEM / "A-00-0 Takplan" above, SPECIFIKATION / title, RITNINGSKATEGORI below.
        let proposal = try Self.readPlanA(number: Self.planATightNumber, title: PDFRectValue(x: 2042, y: 102, width: 160, height: 48))
        #expect(proposal.title == "Takplan Demo")
    }

    @Test("L-54: a box wide enough to reach the next column passes over the label beside the field's own")
    func planAWideNumberBox() throws {
        // x 2042…2320, y 54…88: DOKUMENTNUMMER and ÄNDRING share a row; the number is under them.
        let proposal = try Self.readPlanA(number: PDFRectValue(x: 2042, y: 54, width: 278, height: 34), title: nil)
        #expect(proposal.number == "A-00-0-001")
    }

    @Test("L-54: a title cell holding only its label reads as nothing, never as the label or the next cell")
    func planAEmptyTitleCell() throws {
        let withoutTitle = Self.planABlock.filter { $0.text != "Takplan Demo" }
        let proposal = try Self.readPlanA(number: Self.planATightNumber, title: PDFRectValue(x: 2042, y: 80, width: 160, height: 47), lines: withoutTitle)
        // Old: "SPECIFIKATION" (or "SPECIFIKATION Planer" once the label was known).
        #expect(proposal.title == nil)
        #expect(proposal.number == "A-00-0-001")
    }

    @Test("L-54: the value straight under the field's own label is read even when it begins with a label word")
    func valueUnderTheOwnLabelBeginningWithALabelWord() throws {
        let proposal = try Self.read([
            Self.line("A-101", 2210, 50, 120),
            Self.line("TITLE", 1910, 176, 60, 10),
            Self.line("SYSTEM SCHEMATIC", 1910, 150, 300),
            Self.line("SCALE 1:50", 1910, 115, 120, 12)
        ])
        #expect(proposal.title == "SYSTEM SCHEMATIC")
    }

    @Test("L-54: automatic mode finds the sheet's number and its SPECIFIKATION title")
    func planAAutomatic() {
        let proposal = TitleBlockReader().readAutomatically(pageIndex: 0, pageBox: Self.planAPage, lines: Self.planABlock)
        #expect(proposal.number == "A-00-0-001")
        // Before the re-fix: nil — no title label of this block was known.
        #expect(proposal.title == "Takplan Demo")
    }

    // MARK: - L-58: a batch stamp names the sheet by its number

    @MainActor
    @Test("L-58: the stamp's sheet field reads the sheet's number, the page label only when it has none")
    func stampNamesTheSheet() throws {
        let box = PDFRectValue(x: 0, y: 0, width: 2384, height: 1684)
        let page = ZPDFUIPresentation.PageDescriptor(
            id: UUID(), index: 0, label: "1", mediaBox: box, cropBox: box, rotation: .degrees0
        )
        let named = page.withSheetIdentity(number: "A-00-0-002", title: "Takplan")
        // Old: "1" for both — the page label, though the sheet is named A-00-0-002.
        #expect(StampBatchProducer.stampedSheetLabel(of: named) == "A-00-0-002")
        #expect(StampBatchProducer.stampedSheetLabel(of: page) == "1")

        let template = StampAndBatchApplyTests.template(id: UUID())
        let producer = StampBatchProducer(
            preset: StampAndBatchApplyTests.preset(stamp: template),
            template: template,
            now: Date(timeIntervalSinceReferenceDate: 800_000_000),
            author: "A. Berg"
        )
        let record = try #require(producer.record(
            forPage: named, position: 0, at: PDFPointValue(x: 2000, y: 1500),
            documentID: DocumentID(UUID()), identifier: UUID()
        ))
        #expect(record.stamp?.text(for: .pageLabel) == "A-00-0-002")
    }

    // MARK: - L-64: Import Table from Drawing

    static func text(_ value: String, x: Double, y: Double, width: Double = 50) -> RecognisedTextLine {
        RecognisedTextLine(text: value, boundsInPageSpace: PDFRectValue(x: x, y: y, width: width, height: 9))
    }

    static func vertical(_ x: Double) -> VectorLine {
        VectorLine(start: CGPoint(x: x, y: 500), end: CGPoint(x: x, y: 625))
    }

    static func horizontal(_ y: Double) -> VectorLine {
        VectorLine(start: CGPoint(x: 100, y: y), end: CGPoint(x: 500, y: y))
    }

    /// A ruled room schedule, 100…500 × 500…625: column rules at x 100, 180, 280, 380, 500 and
    /// row rules every 25 pt. The header row (600…625) is "Room | Area m2 | Floor | Finish";
    /// four rooms under it. The schedule's title is printed above the frame, at y 640.
    static func schedule() -> (lines: [RecognisedTextLine], rules: [VectorLine]) {
        let rules = [100.0, 180, 280, 380, 500].map(vertical) + [500.0, 525, 550, 575, 600, 625].map(horizontal)
        var lines = [Self.text("ROOM SCHEDULE", x: 110, y: 640, width: 120)]
        let rows: [(Double, [String])] = [
            (608, ["Room", "Area m2", "Floor", "Finish"]),
            (583, ["Kitchen", "24.5", "1", "Tiles"]),
            (558, ["Bath", "6", "1", "Tiles"]),
            (533, ["Bedroom", "14.25", "2", "Oak"]),
            (508, ["Hall", "9", "1", "Oak"])
        ]
        let columnX: [Double] = [110, 190, 290, 390]
        for (y, cells) in rows {
            for (index, cell) in cells.enumerated() {
                lines.append(Self.text(cell, x: columnX[index], y: y))
            }
        }
        return (lines, rules)
    }

    @Test("L-64: the first ruled row of text is the header, even with a unit's digit in a column name")
    func firstRuledRowIsTheHeader() throws {
        let fixture = Self.schedule()
        let proposal = try TableImportEngine().propose(
            region: PDFRectValue(x: 100, y: 500, width: 400, height: 125),
            recognisedLines: fixture.lines,
            ruleLines: fixture.rules
        ).get()
        // Old: no header ("Column 1"…"Column 4") and five rows, the first "Room / Area m2 / …".
        #expect(proposal.headerRow != nil)
        #expect(proposal.columns.map(\.title) == ["Room", "Area m2", "Floor", "Finish"])
        #expect(proposal.rows.count == 4)
        #expect(proposal.rows.map { $0.cells[0].text } == ["Kitchen", "Bath", "Bedroom", "Hall"])
        #expect(proposal.unreadCellCount == 0)
    }

    @Test("L-64: a box drawn too large ignores the margin outside the outer rules and the title above the frame")
    func spaceOutsideTheOuterRulesIsIgnored() throws {
        let fixture = Self.schedule()
        // 20 pt too far left, 5 pt too low, 10 pt too far right and 35 pt too high: the frame
        // lines are inside the box, and so is the title.
        let proposal = try TableImportEngine().propose(
            region: PDFRectValue(x: 80, y: 495, width: 430, height: 165),
            recognisedLines: fixture.lines,
            ruleLines: fixture.rules
        ).get()
        // Old: six columns, an all-unread "Column 1" left of the first rule, "ROOM SCHEDULE" as
        // a column header, and "5 cells could not be read" when every cell was read.
        #expect(proposal.columns.count == 4)
        #expect(proposal.columns.map(\.title) == ["Room", "Area m2", "Floor", "Finish"])
        #expect(proposal.rows.count == 4)
        #expect(proposal.unreadCellCount == 0)
        #expect(!proposal.rows.contains { $0.sourceText.contains("ROOM SCHEDULE") })
        #expect(proposal.headerRow?.sourceText.contains("ROOM SCHEDULE") == false)
    }

    @Test("L-64: a unit in a column name is not a value; a digit elsewhere still is")
    func unitTokens() {
        #expect(TableImportEngine.withoutUnitTokens("Area m2") == "Area ")
        #expect(TableImportEngine.withoutUnitTokens("Volume (m3)") == "Volume ()")
        #expect(TableImportEngine.withoutUnitTokens("Length mm") == "Length mm")
        #expect(TableImportEngine.withoutUnitTokens("Level 2") == "Level 2")
        #expect(TableImportEngine.withoutUnitTokens("B500B") == "B500B")
    }
}
