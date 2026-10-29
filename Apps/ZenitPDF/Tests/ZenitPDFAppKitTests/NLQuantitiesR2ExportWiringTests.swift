import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFExport
import ZPDFUIPresentation
@testable import ZenitPDFAppKit

/// Round 2 of the quantities features in the export dialog: the summary matrix (NL-QTY-09), group
/// sheets (NL-QTY-13), logo, company block and page images (NL-QTY-11) are controls a person can
/// reach, and they reach the writers.
@Suite("Quantities round 2 — export wiring", .appTierSerialised)
@MainActor
struct NLQuantitiesR2ExportWiringTests {

    static let options: [(column: LedgerColumnID, title: String)] = [
        (.subject, "Subject"), (.pageLabel, "Page"), (.trade, "Trade")
    ]

    @Test("The matrix, group-sheet, logo and company controls become the writers' options")
    func accessoryControls() throws {
        let accessory = ExportAccessoryView(panel: NSSavePanel(), matrixOptions: Self.options)
        accessory.selectForTesting(.xlsx)
        #expect(accessory.summaryAxes == nil, "no matrix until one is chosen")
        accessory.matrixRowsPopUp.selectItem(at: 1)     // Subject
        accessory.matrixColumnsPopUp.selectItem(at: 1)  // Page
        #expect(accessory.summaryAxes?.rows == .subject)
        #expect(accessory.summaryAxes?.columns == .pageLabel)
        accessory.matrixColumnsPopUp.selectItem(at: 0)  // Subject both ways
        #expect(accessory.summaryAxes == nil, "the same grouping both ways is no matrix")
        accessory.matrixColumnsPopUp.selectItem(at: 1)

        #expect(!accessory.xlsxOptions.includeGroupSheets)
        accessory.groupSheetsCheckbox.state = .on
        #expect(accessory.xlsxOptions.includeGroupSheets)
        #expect(!accessory.groupSheetsCheckbox.isHidden)

        accessory.selectForTesting(.csv)
        #expect(accessory.summaryAxes == nil, "a CSV has no second sheet")
        #expect(accessory.groupSheetsCheckbox.isHidden)
        #expect(accessory.pageImagesCheckbox.isHidden)

        accessory.selectForTesting(.pdfReport)
        #expect(accessory.summaryAxes?.rows == .subject, "the report prints the matrix page")
        #expect(!accessory.pageImagesCheckbox.isHidden)
        accessory.pageImagesCheckbox.state = .on
        #expect(accessory.includesPageImages)
        accessory.companyField.stringValue = "Zenit Group S.A.S.\nBogotá"
        #expect(accessory.pdfOptions.companyBlock == "Zenit Group S.A.S.\nBogotá")

        // The logo, through an injected chooser — no panel on screen.
        let png = try Self.png()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("zenit-logo-\(UUID().uuidString).png")
        try png.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        accessory.chooseLogoFile = { deliver in deliver(url) }
        accessory.logoButton.performClick(nil)
        #expect(accessory.pdfOptions.logoImageData == png)
        #expect(accessory.logoButton.title == "Remove Logo")
        accessory.logoButton.performClick(nil)
        #expect(accessory.pdfOptions.logoImageData == nil)
        // A file that is not an image is refused.
        let text = FileManager.default.temporaryDirectory.appendingPathComponent("zenit-logo-\(UUID().uuidString).png")
        try Data("not an image".utf8).write(to: text)
        defer { try? FileManager.default.removeItem(at: text) }
        accessory.chooseLogoFile = { deliver in deliver(text) }
        accessory.logoButton.performClick(nil)
        #expect(accessory.pdfOptions.logoImageData == nil)
    }

    @Test("A template carries the matrix, group sheets, company block, page images and logo")
    func templateCarriesRoundTwo() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenit-r2-accessory-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LedgerReportTemplateStore(directory: directory)
        let png = try Self.png()
        let accessory = ExportAccessoryView(panel: NSSavePanel(), templateStore: store, matrixOptions: Self.options)
        accessory.selectForTesting(.pdfReport)
        accessory.matrixRowsPopUp.selectItem(at: 3)     // Trade
        accessory.matrixColumnsPopUp.selectItem(at: 1)  // Page
        accessory.groupSheetsCheckbox.state = .on
        accessory.pageImagesCheckbox.state = .on
        accessory.companyField.stringValue = "Zenit Group S.A.S."
        accessory.setLogo(png)
        try store.save(accessory.currentTemplate(named: "Client summary"))

        let again = ExportAccessoryView(panel: NSSavePanel(), templateStore: store, matrixOptions: Self.options)
        again.selectForTesting(.csv)
        again.templatePopUp.selectItem(at: 1)
        again.apply(try #require(again.selectedTemplate))
        #expect(again.format == .pdfReport)
        #expect(again.summaryAxes?.rows == .trade)
        #expect(again.summaryAxes?.columns == .pageLabel)
        #expect(again.groupSheetsCheckbox.state == .on)
        #expect(again.includesPageImages)
        #expect(again.pdfOptions.companyBlock == "Zenit Group S.A.S.")
        #expect(again.pdfOptions.logoImageData == png, "the logo comes back from the store by digest")
    }

    @Test("The summary matrix of a real session: two 12 m² slabs on A-101 make one 24 m² cell")
    func summaryMatrixFromTheSession() async throws {
        let (core, _, _, _) = try await NLQuantitiesExportTests().makeCore()
        let matrix = try await ProjectWindowController.summaryMatrix(
            core: core, documentName: "Takeoff", scaleDescription: nil,
            request: core.ledger.request, axes: (.subject, .pageLabel)
        )
        #expect(matrix.rowTitles == ["Slab"])
        #expect(matrix.columnTitles == ["A-101"])
        let area = try #require(matrix.blocks.first { $0.column.key == StandardLedgerColumn.planArea.rawValue })
        // 40 × 30 pt at 0.1 m/pt is 4 m × 3 m = 12 m²; two of them are 24 m².
        #expect(area.cells[0][0].number?.raw == 24)
        #expect(area.rowTotals[0].number?.raw == 24)
        #expect(area.columnTotals[0].number?.raw == 24)
        #expect(area.grandTotal.number?.raw == 24)
        // The export dialog offers the ledger's groupable columns, never a quantity.
        let offered = ProjectWindowController.matrixOptions(core: core).map(\.column)
        #expect(offered.contains(.subject) && offered.contains(.pageLabel))
        #expect(!offered.contains(.planArea))
    }

    static func png() throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: 20, height: 10, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.3, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 20, height: 10))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
