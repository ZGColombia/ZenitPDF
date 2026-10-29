import AppKit
import CoreText
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
@testable import ZenitPDFAppKit

/// Quality loop iteration 5 re-fix, appcore (V-040): the batch sheet's "Pages containing text"
/// asks every added drawing with a sheet in the set. The app used to hand the resolver only the
/// drawings whose text index was already open, and opened an added drawing's index without its
/// password, so a password-protected drawing's sheets were left out of the count and the preview
/// said nothing. Headless: the window is built, never shown.
@MainActor
@Suite("Iteration 5 re-fix appcore — batch search scope over the set", .appTierSerialised)
struct Iter5RAppCoreBatchScopeTests {

    private func save(_ document: ZenitPDFProjectDocument, to url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            document.save(to: url, ofType: ZenitAppInfo.projectTypeIdentifier, for: .saveAsOperation) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    /// A password-protected drawing whose page n says "FLOOR n SCREED", drawn through CoreText.
    private func writeLockedTextPDF(pages count: Int, password: String, to url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let options: [CFString: Any] = [kCGPDFContextUserPassword: password, kCGPDFContextOwnerPassword: password]
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, options as CFDictionary))
        let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
        for page in 0..<count {
            context.beginPDFPage(nil)
            let text = NSAttributedString(string: "FLOOR \(page + 1) SCREED", attributes: [.font: font])
            context.textPosition = CGPoint(x: 72, y: 700)
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
            context.endPDFPage()
        }
        context.closePDF()
    }

    /// Old output, every step: available, 0 pages — the locked drawing's index held no text, and a
    /// drawing without an index was dropped from the list without a word.
    @Test("V-040: a password-protected added drawing is counted; one with no index is named, never left out")
    func addedDrawingsAreNeverLeftOut() async throws {
        let harness = try await Fix2Harness.make("It5r Batch Host.pdf", calibrate: false)
        defer { harness.tearDown() }
        try await save(harness.document, to: harness.directory.appendingPathComponent("It5r Batch.zpdfproj"))
        let fixtures = FileManager.default.temporaryDirectory.appendingPathComponent("it5r-batch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtures) }
        let password = "zenit-it5r-batch"
        let lockedURL = fixtures.appendingPathComponent("It5r Locked Details.pdf")
        try writeLockedTextPDF(pages: 3, password: password, to: lockedURL)
        let previousPrompt = ZenitPDFProjectDocument.passwordPrompt
        ZenitPDFProjectDocument.passwordPrompt = { _ in password }
        defer { ZenitPDFProjectDocument.passwordPrompt = previousPrompt }

        #expect(await harness.document.addDrawingToSet(fileAt: lockedURL, at: 1))
        let set = try #require(harness.document.drawingSet)
        let added = try #require(set.members.last)
        #expect(added.password == password)
        let addedPages = Set(added.drawing.pages.map(\.id.rawValue))
        #expect(addedPages.count == 3)

        // Asked straight after the drop: the index still opening is waited for, and it was
        // opened with the drawing's password, so its three SCREED sheets are counted.
        let found = await harness.document.pageIDsContaining("SCREED")
        #expect(found.isAvailable, "\(found.unavailableReason ?? "")")
        #expect(found.pageIDs == addedPages)

        // A drawing of the set whose index is not open (its open failed): no count, and the
        // drawing is named — not a count of the set without its sheets.
        let removed = set.searchIndexes.removeValue(forKey: added.drawing.documentID)
        let index = try #require(removed)
        let missing = await harness.document.pageIDsContaining("SCREED")
        #expect(!missing.isAvailable)
        #expect(missing.pageIDs.isEmpty)
        #expect(missing.unavailableReason == "The text of “It5r Locked Details” could not be searched: its text index is not open. This scope cannot be previewed.")

        // With its sheets out of the set it is not asked: none of its pages could be stamped.
        await harness.core.commands.undo()
        #expect(await harness.core.session.pageOrderIDs.allSatisfy { !addedPages.contains($0.rawValue) })
        let outside = await harness.document.pageIDsContaining("SCREED")
        #expect(outside.isAvailable)
        #expect(outside.pageIDs.isEmpty)
        await index.shutDown()
    }
}
