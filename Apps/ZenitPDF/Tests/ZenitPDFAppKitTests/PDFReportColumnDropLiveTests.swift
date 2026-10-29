import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFExport
import ZPDFUIPresentation
@testable import ZenitPDFAppKit

/// RT-11, retest of LT-18 (2026-08-31): the shipping report STILL printed every column —
/// 46 across 7 bands, 8 pages for a two-row ledger — although `dropsEmptyColumns` defaults
/// on and the drop is proven in ZPDFExport's own fixtures. This drives the APP's projection
/// (the exact one File ▸ Export… renders) into the drop rule and asserts the empty
/// measurement columns actually leave.
@MainActor
@Suite(.appTierSerialised)
struct PDFReportColumnDropLiveTests {

    @Test("The app's own projection of a one-length ledger drops the empty columns")
    func appProjectionDropsEmptyColumns() async throws {
        let url = try AppTestSupport.writeFixturePDF(named: "ReportDrop.pdf")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let document = try AppTestSupport.makeDocument(opening: url)
        #expect(await AppTestSupport.wait { document.core != nil })
        let core = try #require(document.core)
        _ = try await core.commands.calibrate(
            page: try #require(await core.session.firstPageID),
            first: PDFPoint(x: 0, y: 0),
            second: PDFPoint(x: 100, y: 0),
            knownLength: 5,
            knownLengthUnit: .metre
        )
        await core.refresh()
        core.measurement.activate(kind: .length)
        core.measurement.placePoint(PDFPointValue(x: 100, y: 100))
        core.measurement.placePoint(PDFPointValue(x: 300, y: 100))
        await core.measurement.settlePlacements()
        core.measurement.commitActiveMeasurement()
        #expect(await AppTestSupport.wait { core.ledger.rowCount > 0 })

        let projection = try await ProjectWindowController.projection(
            core: core,
            documentName: "ReportDrop",
            scaleDescription: nil,
            request: core.ledger.request
        )
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("report-drop-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        let result = try PDFReportRenderer().render(projection, to: out)
        let dropped = projection.table.columns.count - result.printedColumnCount
        // One length row fills a handful of columns; rise/run/slope/volume/wallArea and the
        // cost columns are all empty and MUST leave. Live they did not (46 → 46).
        #expect(dropped >= 10,
                "RT-11: only \(dropped) of \(projection.table.columns.count) columns dropped — the report still prints its empty columns")
        // Name the survivors when it fails, so the filler is identifiable at a glance.
        document.close()
    }
}
