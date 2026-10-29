import AppKit
import Foundation
import ImageIO
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFExport
@testable import ZenitPDFAppKit

/// NL-PDF-21: Share Snippet… puts the selection's picture on a shelf; dragging it out writes a PNG
/// through a file promise where it is dropped, and Share hands the PNG to the sharing picker.
/// Nothing is shown: the shelf and the picker are injected.
@MainActor
@Suite("Snippet shelf: drag out and share (NL-PDF-21)", .appTierSerialised)
struct NLPDFR2SnippetShelfTests {

    @Test("The shelf's file promise writes the snippet PNG where the drag lands; Share gets the same PNG; Copy writes the pasteboard seam")
    func dragOutAndShare() async throws {
        let url = try AppTestSupport.writeFixturePDF(named: "Shelf.pdf")
        let document = try AppTestSupport.makeDocument(opening: url)
        defer { Task { await document.drawing?.rasterSource.close(); document.close() } }
        #expect(await AppTestSupport.wait { document.core != nil && document.drawing != nil })
        let core = try #require(document.core)
        let drawing = try #require(document.drawing)
        let page = try #require(drawing.pages.first)
        _ = try await core.commands.calibrate(page: page.id, first: PDFPoint(x: 72, y: 72), second: PDFPoint(x: 372, y: 72),
                                              knownLength: 30, knownLengthUnit: .metre)
        let id = MarkupID(UUID())
        _ = try await core.commands.perform(.addMarkup(MarkupRecord(
            id: id, documentID: drawing.documentID, pageID: page.id, kind: .measurement, tool: .length, label: "Wall",
            geometry: MeasurementGeometry(pageID: page.id, points: [PDFPoint(x: 100, y: 300), PDFPoint(x: 400, y: 300)]),
            createdAt: Date(), modifiedAt: Date()
        )))
        await core.commands.settle()
        await core.refresh()

        let controller = ProjectWindowController(document: document)
        let pasteboard = RecordingSnippetPasteboard()
        controller.snippetPasteboard = pasteboard
        // Old behaviour: no drag source and no sharing picker existed for a snippet.
        let shelf = try await controller.snippetShelf(for: document, of: .selection([id.rawValue]))
        _ = shelf.view
        #expect(shelf.fileName.hasSuffix(".png"))

        // The drop: the Finder asks the promise for its name, then to write at the drop location.
        let promise = try #require(shelf.dragView.promise)
        let provider = NSFilePromiseProvider(fileType: "public.png", delegate: promise)
        #expect(promise.filePromiseProvider(provider, fileNameForType: "public.png") == shelf.fileName)
        let dropFolder = FileManager.default.temporaryDirectory.appendingPathComponent("zpdf-drop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dropFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dropFolder) }
        let target = dropFolder.appendingPathComponent(shelf.fileName)
        var written: Error?? = .none
        promise.filePromiseProvider(provider, writePromiseTo: target) { written = .some($0) }
        #expect(written != nil && written! == nil)
        let dropped = try Data(contentsOf: target)
        #expect(dropped == shelf.png)
        let decoded = try #require(CGImageSourceCreateWithData(dropped as CFData, nil))
        #expect(CGImageSourceGetType(decoded) as String? == "public.png")
        #expect(shelf.dragView.draggingItem() != nil, "the picture is a drag source")

        var shared: [URL] = []
        SnippetShelf.sharingPresenter = { urls, _ in shared = urls }
        defer { SnippetShelf.sharingPresenter = nil }
        shelf.share()
        let sharedURL = try #require(shared.first)
        #expect(try Data(contentsOf: sharedURL) == shelf.png)
        try? FileManager.default.removeItem(at: sharedURL.deletingLastPathComponent())

        shelf.copyPicture()
        #expect(pasteboard.payloads.last?.png == shelf.png)

        // The menu path presents the shelf through the injectable presenter.
        var presented: SnippetShelfController?
        SnippetShelf.presenter = { controller, _ in presented = controller }
        defer { SnippetShelf.presenter = nil }
        core.canvas.select(markupIDs: [id.rawValue], additive: false)
        controller.shareSnippet(for: document)
        #expect(await AppTestSupport.wait { presented != nil })
    }
}
