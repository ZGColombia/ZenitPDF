import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
import ZPDFUIShell
@testable import ZenitPDFAppKit

/// Shared plumbing for the round-2 measure tests: a one-page A1 PDF with optional extra page
/// entries (a `/VP` array) and content, opened through the shipping window controller. No window
/// is ordered front and every modal goes through `ZenitModalPresenter`.
@MainActor
enum NLMeasureR2Harness {

    struct Harness {
        let document: ZenitPDFProjectDocument
        let controller: ProjectWindowController
        let core: AppCoreEnvironment
        let shell: ProjectShellEnvironment
        let page: PageID
        let directory: URL
    }

    /// A one-page A1 portrait PDF (1684 × 2384 pt).
    static func writeFixture(named name: String, pageExtras: String = "", content: String = "2 w 0 0 0 RG 100 100 m 500 100 l S") throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenit-r2measure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        let stream = Data((content + "\n").utf8)
        var objects: [Data] = [
            Data("<< /Type /Catalog /Pages 2 0 R >>".utf8),
            Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8),
            Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 1684 2384]\(pageExtras.isEmpty ? "" : " " + pageExtras) /Contents 4 0 R >>".utf8)
        ]
        var body = Data("<< /Length \(stream.count) >>\nstream\n".utf8)
        body.append(stream)
        body.append(Data("\nendstream".utf8))
        objects.append(body)
        var pdf = Data("%PDF-1.7\n".utf8)
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(pdf.count)
            pdf.append(Data("\(index + 1) 0 obj\n".utf8))
            pdf.append(object)
            pdf.append(Data("\nendobj\n".utf8))
        }
        let xref = pdf.count
        pdf.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets { pdf.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        pdf.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        try pdf.write(to: url)
        return url
    }

    static func make(_ name: String, pageExtras: String = "", content: String = "2 w 0 0 0 RG 100 100 m 500 100 l S") async throws -> Harness {
        ZenitModalPresenter.reset()
        let url = try writeFixture(named: name, pageExtras: pageExtras, content: content)
        let document = try AppTestSupport.makeDocument(opening: url)
        let controller = ProjectWindowController(document: document)
        #expect(await AppTestSupport.wait { document.core != nil && document.shell != nil && document.drawing != nil })
        document.addWindowController(controller)
        let core = try #require(document.core)
        let shell = try #require(document.shell)
        let page = try #require(await core.session.firstPageID)
        #expect(await AppTestSupport.wait { core.document.currentPageID != nil })
        return Harness(document: document, controller: controller, core: core, shell: shell, page: page, directory: url.deletingLastPathComponent())
    }

    static func tearDown(_ harness: Harness) {
        if let sheet = ScaleSheetCoordinator.active(for: harness.document) { sheet.cancel() }
        harness.controller.window?.close()
        // A measured document is dirty; closing it dirty would raise the unsaved-takeoff review.
        harness.document.updateChangeCount(.changeCleared)
        harness.document.close()
        try? FileManager.default.removeItem(at: harness.directory)
        ZenitModalPresenter.reset()
    }
}
