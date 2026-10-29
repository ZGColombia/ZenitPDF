import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
@testable import ZenitPDFAppKit

/// NL-PLAT-09: a row link in an exported workbook brings its markup forward; an unknown project is
/// a quiet note, never an alert.
@MainActor
@Suite("Deep links — NL-PLAT-09", .appTierSerialised)
struct DeepLinkTests {

    @Test("reveal links parse, and a malformed one is unknown")
    func parse() throws {
        let id = UUID()
        let prefix = ZenitURLNotes.revealLinkPrefix(project: "drawing:abc 123")
        let url = try #require(URL(string: prefix + id.uuidString))
        #expect(ZenitURLRoute(url) == .reveal(project: "drawing:abc 123", markup: id))
        #expect(ZenitURLRoute(try #require(URL(string: "zenitpdf://reveal?project=x&markup=not-a-uuid"))) == .unknown)
        #expect(ZenitURLRoute(try #require(URL(string: "zenitpdf://reveal?markup=\(id.uuidString)"))) == .unknown)
    }

    @Test("A link to an open project selects and zooms to its markup; a closed project's link leaves a note")
    func revealSelects() async throws {
        let harness = try await Fix2Harness.make("Deep link.pdf")
        defer { harness.tearDown() }
        let record = try await harness.addMarkup(tool: .length) { page in
            MeasurementGeometry(pageID: page, points: [PDFPoint(x: 10, y: 10), PDFPoint(x: 200, y: 10)])
        }
        let identity = await SpreadsheetRoundTrip.identity(of: harness.document)
        ZenitModalPresenter.reset()
        #expect(await ZenitURLNotes.reveal(project: identity, markup: record.id.rawValue, in: [harness.document]))
        #expect(harness.core.canvas.selectedMarkupIDs.contains(record.id.rawValue))

        #expect(await ZenitURLNotes.reveal(project: "project:someone-else", markup: record.id.rawValue, in: [harness.document]) == false)
        #expect(harness.core.document.warnings.contains { $0.id == ZenitURLNotes.revealNoteID })
        #expect(!ZenitModalPresenter.recorded.contains { $0.kind == .alert && $0.title.contains("link") })
    }
}
