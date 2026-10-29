import AppKit
import Foundation
import PDFKit
import Testing
@testable import ZenitPDFAppKit

/// NL-PDF-18: word-processing documents become PDFs with selectable text on this Mac; spreadsheets
/// and presentations are refused with the route that works; the print route writes an alias.
/// No panel is shown: every panel is answered by injection.
@MainActor
@Suite("New PDF from Documents (NL-PDF-18)", .appTierSerialised)
struct NLPDFR2CreatePDFTests {

    static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("zpdf-create-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("docx, doc, odt, rtf, html and txt fixtures become PDFs whose text a reader finds")
    func formatsConvert() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let body = NSAttributedString(string: "Transmittal 042 — Level 3 slab pour schedule\n", attributes: [.font: NSFont.systemFont(ofSize: 12)])
        let range = NSRange(location: 0, length: body.length)
        var sources: [URL] = []
        for (ext, type) in [("docx", NSAttributedString.DocumentType.officeOpenXML), ("doc", .docFormat), ("odt", .openDocument), ("rtf", .rtf)] {
            let url = folder.appendingPathComponent("letter.\(ext)")
            try body.data(from: range, documentAttributes: [.documentType: type]).write(to: url)
            sources.append(url)
        }
        let html = folder.appendingPathComponent("page.html")
        try Data("<html><body><h1>Transmittal 042</h1><img src=\"https://example.invalid/x.png\"><p>Level 3 slab pour schedule</p><script>alert(1)</script></body></html>".utf8).write(to: html)
        sources.append(html)
        let text = folder.appendingPathComponent("notes.txt")
        try Data("Transmittal 042\nLevel 3 slab pour schedule\n".utf8).write(to: text)
        sources.append(text)

        // Old behaviour: no way to make a PDF from any of these.
        for source in sources {
            let output = folder.appendingPathComponent(source.lastPathComponent + ".pdf")
            let pages = try CreatePDFFromDocuments.convert([source], to: output, refusingFilesOf: [])
            #expect(pages >= 1, "\(source.lastPathComponent)")
            let document = try #require(PDFDocument(url: output))
            let found = document.findString("slab pour", withOptions: .caseInsensitive)
            #expect(!found.isEmpty, "\(source.lastPathComponent): text not selectable")
        }
        // The web page's script and remote picture never reach the importer.
        let stripped = String(decoding: CreatePDFFromDocuments.localOnlyHTML(try Data(contentsOf: html)), as: UTF8.self)
        #expect(!stripped.contains("example.invalid") && !stripped.contains("alert(1)"))

        // Several documents: one PDF, each starting on a new page.
        let combined = folder.appendingPathComponent("combined.pdf")
        #expect(try CreatePDFFromDocuments.convert([sources[3], text], to: combined, refusingFilesOf: []) == 2)
    }

    @Test("A long document flows over pages; a spreadsheet and a presentation are refused with the route that works")
    func paginationAndRefusals() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let long = folder.appendingPathComponent("long.txt")
        try Data((1...400).map { "Line \($0) of the specification." }.joined(separator: "\n").utf8).write(to: long)
        let pages = try CreatePDFFromDocuments.convert([long], to: folder.appendingPathComponent("long.pdf"), refusingFilesOf: [])
        #expect(pages >= 5, "400 lines at 12 pt do not fit on fewer than five A4 or Letter pages; got \(pages)")
        let last = try #require(PDFDocument(url: folder.appendingPathComponent("long.pdf")))
        #expect(!last.findString("Line 400 of the specification").isEmpty, "the last line is on a page, not cut off")

        for name in ["budget.xlsx", "deck.pptx", "plan.numbers", "slides.key"] {
            let url = folder.appendingPathComponent(name)
            try Data("x".utf8).write(to: url)
            #expect(throws: CreatePDFFromDocuments.Refusal.needsAuthoringApp(name)) { try CreatePDFFromDocuments.attributedText(of: url) }
        }
        #expect(CreatePDFFromDocuments.Refusal.needsAuthoringApp("budget.xlsx").description.contains("Print ▸ Save as PDF"))
    }

    @Test("The menu command converts through injected panels and opens the result; the print route writes an alias to the app")
    func commandsThroughPanels() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("memo.rtf")
        let memo = NSAttributedString(string: "Site memo: crane lift Tuesday")
        try memo.data(from: NSRange(location: 0, length: memo.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]).write(to: source)
        let destination = folder.appendingPathComponent("memo.pdf")

        ZenitModalPresenter.reset()
        let previous = ZenitModalPresenter.handler
        defer { ZenitModalPresenter.handler = previous; CreatePDFFromDocuments.opener = nil }
        ZenitModalPresenter.handler = { request in
            switch request.identifier {
            case CreatePDFFromDocuments.openPanelIdentifier: return .urls([source])
            case CreatePDFFromDocuments.savePanelIdentifier: return .urls([destination])
            case CreatePDFFromDocuments.servicePanelIdentifier: return .urls([folder.appendingPathComponent("Zenit PDF")])
            default: return .dismissed
            }
        }
        var opened: URL?
        CreatePDFFromDocuments.opener = { opened = $0 }
        CreatePDFFromDocuments.run(window: nil)
        #expect(await AppTestSupport.wait { opened != nil })
        #expect(opened == destination)
        #expect(!(PDFDocument(url: destination)?.findString("crane lift").isEmpty ?? true))

        CreatePDFFromDocuments.setUpPrintService(window: nil)
        let alias = folder.appendingPathComponent("Zenit PDF")
        #expect(await AppTestSupport.wait { FileManager.default.fileExists(atPath: alias.path) })
        let resolved = try URL(resolvingAliasFileAt: alias)
        #expect(resolved.standardizedFileURL.path == Bundle.main.bundleURL.standardizedFileURL.path)
    }
}
