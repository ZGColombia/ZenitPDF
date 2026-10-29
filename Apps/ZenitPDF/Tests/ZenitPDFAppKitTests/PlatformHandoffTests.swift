import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFExport
@testable import ZenitPDFAppKit

/// NL-PLAT-08 and NL-PLAT-10 in the app: export through a profile, and Send Project's refusals.
@MainActor
@Suite("Hand-off: export profiles and Send Project", .appTierSerialised)
struct PlatformHandoffTests {

    @Test("A profile made from the ledger's columns exports the ledger with those columns, in its dialect")
    func profileExport() async throws {
        let harness = try await Fix2Harness.make("Profile.pdf")
        defer { harness.tearDown() }
        _ = try await harness.addMarkup(tool: .length, geometry: { page in
            MeasurementGeometry(pageID: page, points: [PDFPoint(x: 0, y: 10), PDFPoint(x: 125, y: 10)])
        }, subject: "Wall")
        await harness.settle()
        let projection = try await ProjectWindowController.projection(
            core: harness.core, documentName: "Profile", scaleDescription: nil, request: harness.core.ledger.request)
        var profile = ExportProfiles.profile(from: projection, name: "Office")
        profile.columns = profile.columns.filter { $0.key == "subject" || $0.key == "planLength" }
        profile.columns = profile.columns.map { var c = $0; if c.key == "planLength" { c.decimals = 3; c.header = "Längd" }; return c }
        profile.encoding = .utf8
        profile.lineEnding = .lf
        let url = harness.directory.appendingPathComponent("office.csv")
        #expect(await ExportProfiles.write(profile: profile, document: harness.document, to: url))
        let text = try String(contentsOf: url, encoding: .utf8)
        // 125 pt at 100 pt/m is 1.25 m; three places, decimal comma.
        #expect(text.contains("Wall;1,250\n"), "\(text)")
        #expect(text.hasPrefix(profile.columns.map { $0.header ?? "" }.joined(separator: ";")))
    }

    @Test("Send Project refuses a Quick PDF with a note, never a half-made archive")
    func sendRefusesQuickPDF() async throws {
        let harness = try await Fix2Harness.make("Quick.pdf")
        defer { harness.tearDown() }
        ZenitModalPresenter.reset()
        SendProject.send(document: harness.document, window: nil)
        #expect(harness.core.document.warnings.contains { $0.id == SendProject.noteID && $0.title == "Only a project can be sent" })
        #expect(!ZenitModalPresenter.didRequest(SendProject.savePanelIdentifier))
    }

    @Test("An overlay or a profile opened with nothing in front says what to do, and never opens a window")
    func dataFileNeedsADrawing() async throws {
        // Old code: typeForContents threw unsupportedFileType ("cannot open") for both.
        #expect(ZenitDocumentController.isDataFile(URL(fileURLWithPath: "/tmp/a.zpdfoverlay")))
        #expect(ZenitDocumentController.isDataFile(URL(fileURLWithPath: "/tmp/b.ZPDFPROFILE")))
        #expect(!ZenitDocumentController.isDataFile(URL(fileURLWithPath: "/tmp/c.pdf")))
        let controller = ZenitDocumentController()
        guard controller.documents.isEmpty, controller.currentDocument == nil else { return }
        var failure: NSError?
        controller.openDataFile(URL(fileURLWithPath: "/tmp/a.zpdfoverlay"), release: nil) { _, _, error in failure = error as NSError? }
        #expect(failure?.localizedDescription == "“a.zpdfoverlay” belongs to a drawing or project.")
    }
}
