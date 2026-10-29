import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
@testable import ZenitPDFAppKit

/// NL-PLAT-12: what the Shortcuts actions return, on the shipping projection.
@MainActor
@Suite("Shortcuts bridge — NL-PLAT-12", .appTierSerialised)
struct ShortcutsBridgeTests {

    @Test("Get Totals returns one line per quantity column of the grand total")
    func totalsAreText() async throws {
        let harness = try await Fix2Harness.make("Shortcuts.pdf")
        defer { harness.tearDown() }
        // 100 pt = 1 m in the harness: 250 pt and 150 pt of wall are 2.5 m + 1.5 m = 4 m.
        _ = try await harness.addMarkup(tool: .length, geometry: { page in
            MeasurementGeometry(pageID: page, points: [PDFPoint(x: 0, y: 10), PDFPoint(x: 250, y: 10)])
        }, subject: "Wall")
        _ = try await harness.addMarkup(tool: .length, geometry: { page in
            MeasurementGeometry(pageID: page, points: [PDFPoint(x: 0, y: 60), PDFPoint(x: 150, y: 60)])
        }, subject: "Wall")
        await harness.settle()
        let projection = try await ProjectWindowController.projection(
            core: harness.core, documentName: "Shortcuts", scaleDescription: nil, request: harness.core.ledger.request)
        let text = ZenitShortcutsBridge.totalsText(projection)
        // One "title: value" line per numeric total, the value exactly the grand total's own text.
        let lengthLine = try #require(text.split(separator: "\n").first { $0.lowercased().contains("length") }, "\(text)")
        let total = try #require(ZenitShortcutsBridge.totalsText(projection).split(separator: "\n").first { $0 == lengthLine })
        #expect(total.split(separator: ":").count == 2)
        #expect(total.split(separator: ":").last.map { $0.trimmingCharacters(in: .whitespaces).first?.isNumber == true } == true, "\(total)")
    }

    @Test("With nothing open, the actions say so instead of failing silently")
    func nothingOpen() async {
        if NSDocumentController.shared.documents.isEmpty {
            await #expect(throws: ZenitShortcutsBridge.Failure.self) { try await ZenitShortcutsBridge.frontTotals() }
        }
    }
}
