import AppKit
import Foundation
import PDFKit
import Testing
@testable import ZenitPDFAppKit

/// NL-PDF-11 remainder: the system's "Import from iPhone or iPad" delivers a scan or a photo to
/// the window, which keeps it in the container and opens it. No device, no camera: the
/// delivery is a private pasteboard handed to the requestor, as AppKit hands it.
@MainActor
@Suite("Import from iPhone or iPad (NL-PDF-11)", .appTierSerialised)
struct NLPDFR2DeviceImportTests {

    @Test("The File menu carries the system item; the window accepts PDFs and photos; a scan opens as a PDF, a photo as an image")
    func importsFromADevice() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zpdf-device-\(UUID().uuidString)", isDirectory: true)
        DamagedDrawingRepair.repairedCopiesRootOverride = root.appendingPathComponent("Repaired")
        var opened: [URL] = []
        DeviceImport.opener = { opened.append($0) }
        defer {
            DamagedDrawingRepair.repairedCopiesRootOverride = nil
            DeviceImport.opener = nil
            try? FileManager.default.removeItem(at: root)
        }
        // Old behaviour: no such item; nothing could receive a scan from a phone.
        #expect(DeviceImport.menuItem().identifier == NSMenuItem.importFromDeviceIdentifier)

        let url = try AppTestSupport.writeFixturePDF(named: "Host.pdf")
        let document = try AppTestSupport.makeDocument(opening: url)
        defer { document.close(); try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let controller = ProjectWindowController(document: document)
        #expect(controller.validRequestor(forSendType: nil, returnType: .pdf) as AnyObject? === controller)
        #expect(controller.validRequestor(forSendType: nil, returnType: .png) as AnyObject? === controller)
        #expect(controller.validRequestor(forSendType: .string, returnType: .pdf) as AnyObject? !== controller, "it asks, it does not send")

        let scan = NSPasteboard(name: NSPasteboard.Name("zpdf-test-\(UUID().uuidString)"))
        defer { scan.releaseGlobally() }
        scan.clearContents()
        scan.setData(try Data(contentsOf: url), forType: .pdf)
        #expect(controller.readSelection(from: scan))
        let first = try #require(opened.first)
        #expect(first.pathExtension == "pdf" && first.lastPathComponent.hasPrefix("Scan "))
        #expect(PDFDocument(url: first)?.pageCount == 1)
        #expect(first.path.hasPrefix(root.path), "kept in the application's own folder")

        let photo = NSPasteboard(name: NSPasteboard.Name("zpdf-test-\(UUID().uuidString)"))
        defer { photo.releaseGlobally() }
        photo.clearContents()
        let image = NSImage(size: NSSize(width: 40, height: 30))
        image.lockFocus(); NSColor.black.setFill(); NSRect(x: 5, y: 5, width: 30, height: 20).fill(); image.unlockFocus()
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        photo.setData(png, forType: .png)
        #expect(controller.readSelection(from: photo))
        #expect(opened.last?.pathExtension == "png")
        let empty = NSPasteboard(name: NSPasteboard.Name("zpdf-test-\(UUID().uuidString)"))
        defer { empty.releaseGlobally() }
        empty.clearContents()
        #expect(!controller.readSelection(from: empty))
    }
}
