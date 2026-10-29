import AppKit
import CoreGraphics
import Foundation
import PDFKit
import Testing
import ZPDFAppCore
import ZPDFPDFKitBridge
import ZPDFServiceClient
@testable import ZenitPDFAppKit

/// NL-PDF-17 in the app: the sheet's native controls produce the values, the filled copy is
/// written, and "burn in" leaves no widgets and draws the same page. The repair worker runs as a
/// child process, never the embedded service.
@MainActor
@Suite("Fill Form Fields (NL-PDF-17)", .appTierSerialised)
struct NLPDFR2FormFillTests {

    static func productsDirectory() throws -> URL {
        var info = Dl_info()
        guard dladdr(#dsohandle, &info) != 0, let path = info.dli_fname else { throw CocoaError(.fileNoSuchFile) }
        var url = URL(fileURLWithPath: String(cString: path))
        while url.pathComponents.count > 1, url.pathExtension != "xctest" { url.deleteLastPathComponent() }
        return url.deletingLastPathComponent()
    }

    static func rfiForm(at url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 400, height: 300)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil); context.stroke(CGRect(x: 10, y: 10, width: 380, height: 280)); context.endPDFPage(); context.closePDF()
        let document = try #require(PDFDocument(url: url))
        let page = try #require(document.page(at: 0))
        let text = PDFAnnotation(bounds: CGRect(x: 40, y: 230, width: 200, height: 22), forType: .widget, withProperties: nil)
        text.widgetFieldType = .text; text.fieldName = "Project"
        page.addAnnotation(text)
        let check = PDFAnnotation(bounds: CGRect(x: 40, y: 190, width: 16, height: 16), forType: .widget, withProperties: nil)
        check.widgetFieldType = .button; check.widgetControlType = .checkBoxControl; check.fieldName = "Urgent"
        page.addAnnotation(check)
        let choice = PDFAnnotation(bounds: CGRect(x: 40, y: 110, width: 120, height: 22), forType: .widget, withProperties: nil)
        choice.widgetFieldType = .choice; choice.fieldName = "Status"; choice.choices = ["Open", "Closed"]; choice.isListChoice = false
        page.addAnnotation(choice)
        #expect(document.write(to: url))
    }

    @Test("Controls → values → a filled copy; burned in, the copy has no widgets and looks the same as the filled one")
    func fillAndFlatten() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zpdf-formapp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("RFI.pdf")
        try Self.rfiForm(at: source)
        let before = try Data(contentsOf: source)

        // Old behaviour: forms were a hazard warning; nothing filled them.
        let controller = FormFillController(fields: try PDFFormFields.fields(ofFileAt: source))
        _ = controller.view
        (controller.controls["Project"] as? NSTextField)?.stringValue = "Level 3 slab"
        (controller.controls["Urgent"] as? NSButton)?.state = .on
        (controller.controls["Status"] as? NSPopUpButton)?.selectItem(withTitle: "Closed")
        let values = controller.values
        #expect(values["Project"] == .text("Level 3 slab"))
        #expect(values["Urgent"] == .checked(true))
        #expect(values["Status"] == .option("Closed"))

        let filled = folder.appendingPathComponent("RFI — Filled.pdf")
        #expect(try await FormFill.write(source: source, password: nil, values: values, flatten: false, to: filled) == 3)
        #expect(try PDFFormFields.fields(ofFileAt: filled).first { $0.name == "Project" }?.value == "Level 3 slab")
        #expect(try Data(contentsOf: source) == before)

        let worker = try Self.productsDirectory().appendingPathComponent("zpdf-repair-worker")
        try #require(FileManager.default.fileExists(atPath: worker.path), "zpdf-repair-worker is built next to the tests")
        DamagedDrawingRepair.clientOverride = ZPDFRepairServiceClient(backend: .subprocess(executableURL: worker), maximumRestarts: 0)
        defer { DamagedDrawingRepair.clientOverride = nil }
        let burned = folder.appendingPathComponent("RFI — Burned.pdf")
        _ = try await FormFill.write(source: source, password: nil, values: values, flatten: true, to: burned)
        let flat = try #require(PDFDocument(url: burned))
        #expect(flat.page(at: 0)?.annotations.contains { $0.type == "Widget" } == false, "no widgets are left")
        #expect(flat.page(at: 0)?.string?.contains("Level 3 slab") == true, "the value is on the page")
    }
}

extension NLPDFR2FormFillTests {

    @Test("R-103: a filled copy — plain or burned in — whose destination is the drawing itself is refused, and the drawing is untouched")
    func refusesToOverwriteTheDrawing() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zpdf-formapp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("RFI.pdf")
        try Self.rfiForm(at: source)
        let before = try Data(contentsOf: source)
        for flatten in [false, true] {
            // Old: the drawing was replaced by the filled (or burned-in) copy, and the result note
            // still said "The drawing itself was not changed."
            await #expect(throws: PDFFormFields.Refusal.destinationIsSource) {
                try await FormFill.write(source: source, password: nil, values: ["Project": .text("X")], flatten: flatten, to: source)
            }
        }
        #expect(try Data(contentsOf: source) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["RFI.pdf"])
    }
}
