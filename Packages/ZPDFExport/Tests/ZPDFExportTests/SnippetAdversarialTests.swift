import CoreGraphics
import Foundation
import Testing
import ZPDFContracts
import ZPDFQuantityLedger
import ZPDFRenderer
@testable import ZPDFExport

/// Adversarial checks on the snippet exporter (ADR-0006), written independently of the
/// implementation.
///
/// 1. The same spec rendered at three simulated window sizes — different drawable
///    dimensions, backing scales and zooms on a live renderer between the exports — must
///    produce byte-identical PNGs. ADR-0006 §1 promises a specification, not a screen grab.
/// 2. A markup with a slope applied (ADR-0004) has BOTH a plan area and a true area in the
///    ledger. The caption quotes one number; it must say which one it is, because an
///    unlabelled area under a slope is exactly the silent wrongness ADR-0004 exists to stop.
@Suite(.sharedHeap)
struct SnippetAdversarialTests {

    // MARK: - 1. Window-size invariance, three sizes, byte diff

    @Test("Three simulated window sizes, one spec, byte-identical PNGs")
    func windowSizeInvariance() async throws {
        let markups = SnippetExportTests.markups()
        let ids = [markups[0].id, markups[1].id]
        let spec = SnippetExportTests.spec(region: .markups(ids, padding: 15))
        let projection = try SnippetExportTests.projection()
        let exporter = SnippetExporter()
        let page = SnippetExportTests.page()

        // Three window sizes a real session moves between: a small laptop window at 1x,
        // a mid-size window on a Retina display, and a full 5K window at 2x with a deep zoom.
        let windows: [(zoom: Double, backingScale: Double)] = [
            (0.5, 1.0),   // 800-class window, non-Retina
            (1.0, 2.0),   // 1600-class window, Retina
            (6.0, 2.0)    // 5K-class window, zoomed to 600 %
        ]

        var exports: [SnippetImage] = []
        let canvas = CoreGraphicsMarkupRenderer()
        defer { canvas.dispose() }
        for window in windows {
            // The app "resizes the window": the live canvas renders at that size first,
            // so any leaked view state would have fresh, different values each time.
            let viewport = RenderViewport.fittingWholePage(
                page, zoom: window.zoom, backingScale: window.backingScale
            )
            canvas.update(
                page: page, markups: markups, selection: .empty,
                snapFeedback: nil, viewport: viewport
            )
            _ = try canvas.renderOffscreen()

            exports.append(try await exporter.render(
                spec: spec,
                page: page,
                markups: markups,
                projection: projection,
                pageSource: SnippetExportTests.PatternPageSource()
            ))
        }

        let reference = try exports[0].pngData()
        #expect(!reference.isEmpty)
        for (index, export) in exports.enumerated().dropFirst() {
            #expect(export.pixelWidth == exports[0].pixelWidth)
            #expect(export.pixelHeight == exports[0].pixelHeight)
            #expect(
                try export.pngData() == reference,
                "window size \(windows[index]) changed the exported bytes"
            )
        }
    }

    // MARK: - 2. Slope caption: plan vs true area must be labelled

    private static let slopeMarkupID = MarkupID(ExportFixture.uuid(9101))

    /// A ledger whose one markup has a slope applied: plan area 25.000 m², true area
    /// 27.951 m² (ADR-0004: true = plan / cos(slope)). Both columns are in the column set.
    private static func slopeProjection() throws -> ExportProjection {
        func standardColumn(
            _ standard: StandardLedgerColumn,
            title: String
        ) -> LedgerColumnDefinition {
            LedgerColumnDefinition(
                id: LedgerIdentifiers.columnID(for: standard),
                key: standard.rawValue,
                title: title,
                kind: standard.kind,
                standard: standard,
                isEditable: standard.isUserEditable
            )
        }
        var label = standardColumn(.label, title: "label")
        label.order = 0
        var planArea = LedgerColumnDefinition(
            id: LedgerIdentifiers.columnID(for: .planArea),
            key: StandardLedgerColumn.planArea.rawValue,
            title: "Plan Area",
            kind: .number,
            standard: .planArea,
            dimension: .area,
            displayUnit: .area(.squareMetre),
            precision: .decimalPlaces(3),
            isEditable: false
        )
        planArea.order = 1
        var trueArea = LedgerColumnDefinition(
            id: LedgerIdentifiers.columnID(for: .trueArea),
            key: StandardLedgerColumn.trueArea.rawValue,
            title: "True Area",
            kind: .number,
            standard: .trueArea,
            dimension: .area,
            displayUnit: .area(.squareMetre),
            precision: .decimalPlaces(3),
            isEditable: false
        )
        trueArea.order = 2
        let columns = try LedgerColumnSet(columns: [label, planArea, trueArea])

        let markup = MarkupRecord(
            id: slopeMarkupID,
            documentID: DocumentID(ExportFixture.uuid(-1)),
            pageID: PageID(ExportFixture.uuid(-2)),
            kind: .measurement,
            tool: .area,
            subject: "Roof",
            label: "R1",
            measurement: MeasurementResult(values: [
                // ADR-0016: the Plan Area column reads the net area; the engine writes both fields.
                .planArea: .area(Decimal(string: "25.000")!),
                .netArea: .area(Decimal(string: "25.000")!),
                .trueArea: .area(Decimal(string: "27.951")!)
            ]),
            createdAt: ExportFixture.epoch,
            modifiedAt: ExportFixture.epoch
        )
        let store = try LedgerStore(markups: [markup], columns: columns)
        let view = store.makeView(LedgerViewSpec())
        let report = LedgerReportBuilder(
            timestamps: FixedTimestampProvider(ExportFixture.epoch)
        ).makeReport(view, title: "Slope")
        return try ExportProjector().project(report)
    }

    @Test("A slope markup's caption says whether the quoted area is plan or true")
    func slopeCaptionIsLabelled() throws {
        let projection = try Self.slopeProjection()
        let table = projection.table
        let planIndex = try #require(table.columns.firstIndex { $0.key == "planArea" })
        let trueIndex = try #require(table.columns.firstIndex { $0.key == "trueArea" })
        let row = try #require(table.allRows().first {
            $0.markupID == Self.slopeMarkupID.rawValue.uuidString
        })
        // Non-vacuity: this row really is a slope row — both areas, different digits.
        let plan = try #require(row.cells[planIndex].number)
        let sloped = try #require(row.cells[trueIndex].number)
        #expect(plan.text != sloped.text)

        let caption = SnippetCaptionBuilder.build(
            detail: .compact,
            markupIDs: [Self.slopeMarkupID],
            projection: projection,
            source: SnippetExportTests.spec(region: .markups([Self.slopeMarkupID], padding: 0)).source
        )
        let line = try #require(caption.lines.first)

        // The quoted digits must come from the projection...
        let quotesPlan = line.contains(plan.text)
        let quotesTrue = line.contains(sloped.text)
        #expect(quotesPlan || quotesTrue, "caption quotes neither ledger value: \(line)")

        // ...and must say WHICH area they are. An unlabelled "27.951 m²" under a slope is
        // indistinguishable from a plan area and therefore silently wrong (ADR-0004).
        if quotesPlan {
            #expect(
                line.localizedCaseInsensitiveContains("plan"),
                "caption quotes the plan area without labelling it: \(line)"
            )
        }
        if quotesTrue {
            #expect(
                line.localizedCaseInsensitiveContains("true"),
                "caption quotes the true area without labelling it: \(line)"
            )
        }
    }

    @Test("A markup without slope keeps the unlabelled caption format")
    func unSlopedCaptionUnchanged() throws {
        let projection = try SnippetExportTests.projection()
        let markups = SnippetExportTests.markups()
        let caption = SnippetCaptionBuilder.build(
            detail: .compact,
            markupIDs: [markups[0].id],
            projection: projection,
            source: SnippetExportTests.spec(region: .markups([markups[0].id], padding: 0)).source
        )
        let line = try #require(caption.lines.first)
        #expect(!line.localizedCaseInsensitiveContains("plan area"),
                "a slope label leaked onto a markup with no true area: \(line)")
    }

    // MARK: - 3. The caption quotes a quantity, never an identifier that is a number

    /// The defect the application found the day snippet export was first wired to a menu item.
    ///
    /// The caption used to quote *"the first numeric column that holds a number"*. On the golden
    /// export fixture that is the plan area and the rule looked right. In the shipping ledger it
    /// is **`pageIndex`** — a number by declaration, column 5, with every measurement column at
    /// 14 or later — so the first snippet a person could actually take captioned a twenty-metre
    /// wall as `Length A · Length: 0 1`: the page index, followed by the dimensionless SI unit
    /// symbol. A caption that states a wrong quantity is worse than no caption at all, which is
    /// the whole reason ADR-0006 §2 makes the caption non-optional.
    ///
    /// The fixture below is the shipping column order in miniature: an identifier column that is
    /// numeric, before the quantity.
    @Test("A numeric identifier column before the quantity does not become the caption's value")
    func captionSkipsNumericIdentifierColumns() throws {
        let columns = [
            column(key: StandardLedgerColumn.pageIndex.rawValue, title: "Page #", unit: ""),
            column(key: StandardLedgerColumn.planLength.rawValue, title: "Length", unit: "m")
        ]
        let row = ExportRow(
            markupID: SnippetAdversarialTests.markupID.rawValue.uuidString,
            storeIndex: 0,
            groupPath: [],
            cells: [
                .number(number(raw: 0, text: "0", unit: "1")),
                .number(number(raw: 20, text: "20.00", unit: "m"))
            ]
        )
        let chosen = try #require(SnippetCaptionBuilder.quantityIndex(row: row, columns: columns))
        #expect(chosen == 1, "the caption picked \(columns[chosen].key), not the measured length")
    }

    /// And the last-resort branch still answers: a project whose only number is a custom
    /// column — no standard quantity anywhere — must say something rather than "(no value)".
    @Test("With no standard quantity the caption falls back to the first real number")
    func captionFallsBackToAnyNumber() throws {
        let columns = [
            column(key: StandardLedgerColumn.subject.rawValue, title: "Subject", unit: "", numeric: false),
            column(key: "custom.bays", title: "Bays", unit: "")
        ]
        let row = ExportRow(
            markupID: SnippetAdversarialTests.markupID.rawValue.uuidString,
            storeIndex: 0,
            groupPath: [],
            cells: [.text("Concrete"), .number(number(raw: 7, text: "7", unit: ""))]
        )
        #expect(SnippetCaptionBuilder.quantityIndex(row: row, columns: columns) == 1)
    }

    static let markupID = MarkupID(UUID(uuidString: "0DEC0DE0-0000-4000-8000-000000000001") ?? UUID())

    private func column(
        key: String,
        title: String,
        unit: String,
        numeric: Bool = true
    ) -> ExportColumn {
        ExportColumn(
            key: key,
            title: title,
            kind: numeric ? .number : .text,
            unitSymbol: unit,
            decimalPlaces: numeric ? 2 : nil,
            numberFormatCode: nil,
            aggregationSemantics: nil,
            formulaCanonicalText: nil
        )
    }

    private func number(raw: Decimal, text: String, unit: String) -> ExportNumber {
        ExportNumber(
            raw: raw,
            convertedRaw: raw,
            display: raw,
            text: text,
            invariantRawText: raw.description,
            unitSymbol: unit,
            dimension: nil
        )
    }
}
