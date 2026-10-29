import AppKit
import Foundation
import Testing
import ZPDFDesignSystem
import ZPDFUIPresentation
@testable import ZPDFUILedger

/// design-d6 (2026-09-23 main-window mockup): the ledger table draws in the chrome's tokens —
/// its own header band and cells, its own row views with a hairline and a rounded selection,
/// and a raised band under group headings. No window is ever created: the controller's view
/// is loaded and laid out off screen.
@MainActor
@Suite(.ledgerTierSerialised)
struct DesignD6TableAppearanceTests {

    private func controller(grouped: Bool) -> LedgerTableController {
        let source = LedgerArrayRowSource(rows: LedgerFixtures.rows, columns: LedgerFixtures.columns)
        let controller = LedgerTableController(
            rowSource: source,
            mode: grouped ? .grouped : .flat,
            groupingColumns: grouped ? [.subject] : []
        )
        controller.loadViewIfNeeded()
        controller.rebuildPlan()
        return controller
    }

    @Test("Every table's header band is the ledger's own header view, every column its own header cell")
    func headersUseTheLedgerAppearance() {
        let flat = controller(grouped: false)
        for table in [flat.mainTableViewForTesting, flat.pinnedTableViewForTesting, flat.outlineViewForTesting] {
            #expect(table.headerView is LedgerTableHeaderView)
        }
        let columns = flat.mainTableViewForTesting.tableColumns + flat.pinnedTableViewForTesting.tableColumns
        #expect(!columns.isEmpty)
        for column in columns {
            #expect(column.headerCell is LedgerTableHeaderCell, "column \(column.identifier.rawValue)")
            #expect(!column.headerCell.stringValue.isEmpty, "the title still reaches the custom cell")
        }
    }

    @Test("The header cell keeps the column's alignment and draws in the section-header type")
    func headerCellAlignmentAndFont() {
        let flat = controller(grouped: false)
        for column in flat.mainTableViewForTesting.tableColumns {
            guard let ledgerColumn = flat.column(LedgerColumnID(column.identifier.rawValue)) else { continue }
            #expect(column.headerCell.alignment == LedgerCellView.nsAlignment(ledgerColumn.alignment))
            #expect(column.headerCell.font == ZPDFTypography.nsFont(.sectionHeader))
        }
    }

    @Test("Flat rows get the ledger row view; data rows are not group headings")
    func flatRowViews() {
        let flat = controller(grouped: false)
        let table = flat.mainTableViewForTesting
        let rowView = flat.tableView(table, rowViewForRow: 0)
        let ledgerRow = rowView as? LedgerTableRowView
        #expect(ledgerRow != nil)
        #expect(ledgerRow?.isGroupHeading == false)
    }

    @Test("Grouped outline: group items get a heading row view, data rows do not")
    func groupedRowViews() throws {
        let grouped = controller(grouped: true)
        let outline = grouped.outlineViewForTesting
        #expect(outline.numberOfRows > 0)
        var sawHeading = false
        var sawData = false
        for row in 0..<outline.numberOfRows {
            guard let item = outline.item(atRow: row) as? LedgerOutlineItem else { continue }
            let rowView = try #require(grouped.outlineView(outline, rowViewForItem: item) as? LedgerTableRowView)
            #expect(rowView.isGroupHeading == item.isGroup)
            if item.isGroup { sawHeading = true } else { sawData = true }
        }
        #expect(sawHeading, "the fixture groups by subject, so there is at least one heading")
        _ = sawData
    }

    @Test("A selected row keeps primary text: the selection is a translucent fill, not the saturated bar")
    func selectedRowInteriorStyleIsNormal() {
        let rowView = LedgerTableRowView()
        rowView.isSelected = true
        rowView.isEmphasized = true
        #expect(rowView.interiorBackgroundStyle == .normal)
        #expect(!rowView.isOpaque)
    }

    @Test("Row, header cell and header view draw off screen without a window, in both appearances")
    func drawsOffScreenInBothAppearances() throws {
        for name in [NSAppearance.Name.darkAqua, .aqua] {
            let appearance = try #require(NSAppearance(named: name))
            let rowView = LedgerTableRowView(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
            rowView.appearance = appearance
            rowView.isGroupHeading = true
            rowView.isSelected = true
            let bitmap = try #require(rowView.bitmapImageRepForCachingDisplay(in: rowView.bounds))
            rowView.cacheDisplay(in: rowView.bounds, to: bitmap)
            #expect(bitmap.pixelsWide > 0)

            let header = LedgerTableHeaderView(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
            header.appearance = appearance
            let headerBitmap = try #require(header.bitmapImageRepForCachingDisplay(in: header.bounds))
            header.cacheDisplay(in: header.bounds, to: headerBitmap)
            #expect(headerBitmap.pixelsWide > 0)
        }
    }

    @Test("A focused selection paints the selected-fill token, not the opaque accent")
    func selectionPaintsSelectedFill() throws {
        let appearance = try #require(NSAppearance(named: .darkAqua))
        let rowView = LedgerTableRowView(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        rowView.appearance = appearance
        rowView.isSelected = true
        rowView.isEmphasized = true
        let bitmap = try #require(rowView.bitmapImageRepForCachingDisplay(in: rowView.bounds))
        rowView.cacheDisplay(in: rowView.bounds, to: bitmap)
        let centre = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?
            .usingColorSpace(.sRGB))
        var expected: NSColor = .clear
        appearance.performAsCurrentDrawingAppearance {
            expected = ZPDFColor.nsColor(.selectedFill).usingColorSpace(.sRGB) ?? .clear
        }
        #expect(abs(centre.redComponent - expected.redComponent) < 0.03)
        #expect(abs(centre.greenComponent - expected.greenComponent) < 0.03)
        #expect(abs(centre.blueComponent - expected.blueComponent) < 0.03)
    }

    @Test("The appearance file paints only through design-system tokens")
    func noRawColourLiterals() throws {
        let source = try String(contentsOf: Self.sourceURL("Table/LedgerTableAppearance.swift"), encoding: .utf8)
        for forbidden in ["NSColor(red", "NSColor(calibratedRed", "NSColor(srgbRed", "NSColor(white",
                          "Color(red", "#colorLiteral", "NSColor.systemBlue", "NSColor.white", "NSColor.black",
                          "withAlphaComponent"] {
            #expect(!source.contains(forbidden), "raw colour \(forbidden) in LedgerTableAppearance.swift")
        }
    }

    private static func sourceURL(_ relative: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ZPDFUILedger")
            .appendingPathComponent(relative)
    }
}
