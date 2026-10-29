import CoreGraphics
import Foundation
import Testing
import ZPDFPDFKitBridge
import ZPDFTestingSupport

/// Iteration 5, in the bridge: V-054 (Clean Up Scanned Sheets opens a
/// password-protected drawing with its password, and names the real reason when it cannot) and
/// V-056 (one staging rule and one same-file rule for every write). No `@testable`: the release
/// gate builds this package's tests; the entry points used here are `public` or `package`.
@Suite("Iteration 5 — PDF export (bridge)", .serialized)
struct Iter5ExportPDFBridgeTests {

    /// A one-sheet 400 × 300 pt drawing with a ruled line, locked with `password`.
    static func lockedDrawing(at url: URL, password: String) throws {
        var box = CGRect(x: 0, y: 0, width: 400, height: 300)
        let options: [CFString: Any] = [kCGPDFContextUserPassword: password, kCGPDFContextOwnerPassword: password]
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, options as CFDictionary))
        context.beginPDFPage(nil)
        context.setLineWidth(2)
        context.stroke(CGRect(x: 20, y: 20, width: 360, height: 260))
        context.endPDFPage()
        context.closePDF()
    }

    // MARK: - V-054

    @Test("V-054: a locked drawing is cleaned with its password; without it the refusal says it is locked")
    func lockedDrawingIsUnlockedOrNamed() throws {
        let directory = try Corpus.scratchDirectory("iter5-scan-locked")
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("Locked.pdf"), output = directory.appendingPathComponent("Clean.pdf")
        try Self.lockedDrawing(at: input, password: "zenit-it5")
        let document = try #require(CGPDFDocument(input as CFURL))
        #expect(document.isEncrypted && !document.isUnlocked, "the fixture is locked")
        let options = ScanCleanup.Options(straightens: false, enhancement: .none, dpi: 72)

        // Old: Refusal.unreadablePage(0) — "sheet 1 of the drawing could not be read" — because a
        // locked drawing lists its page and hands none out.
        #expect(throws: ScanCleanup.Refusal.locked) {
            try ScanCleanup.cleanDocument(at: input, to: output, options: options)
        }
        #expect(throws: ScanCleanup.Refusal.locked) {
            try ScanCleanup.cleanDocument(at: input, password: "wrong", to: output, options: options)
        }
        #expect(ScanCleanup.Refusal.locked.description.contains("password-protected"))
        #expect(!FileManager.default.fileExists(atPath: output.path), "nothing is written for a refused drawing")

        let reports = try ScanCleanup.cleanDocument(at: input, password: "zenit-it5", to: output, options: options)
        #expect(reports.map(\.pageIndex) == [0])
        #expect(reports.first?.renderedDPI == 72)
        let cleaned = try #require(CGPDFDocument(output as CFURL))
        #expect(cleaned.numberOfPages == 1)
        #expect(cleaned.page(at: 1)?.getBoxRect(.mediaBox).size == CGSize(width: 400, height: 300))
    }

    // MARK: - V-056

    @Test("V-056: the PDFKit write stages in StagedFileReplacement's private folder, never beside the destination, and removes it")
    func atomicWriteSharesTheStagingRule() throws {
        let directory = try Corpus.scratchDirectory("iter5-atomic")
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("export.pdf")
        try Data("OLD".utf8).write(to: destination)
        var staged: URL?
        try PDFKitDocumentProvider.atomicallyWrite(to: destination) { temporary in
            staged = temporary
            #expect(temporary.deletingLastPathComponent().resolvingSymlinksInPath().path
                    != directory.resolvingSymlinksInPath().path, "staged beside the destination")
            #expect(temporary.lastPathComponent.hasPrefix("zpdf-write-"))
            try Data("NEW".utf8).write(to: temporary)
            return true
        }
        #expect(try Data(contentsOf: destination) == Data("NEW".utf8))
        let folder = try #require(staged).deletingLastPathComponent()
        #expect(!FileManager.default.fileExists(atPath: folder.path), "the staging folder outlived the write")
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["export.pdf"])

        // A placement that fails is still reported as the bridge's write failure.
        let missing = directory.appendingPathComponent("gone", isDirectory: true).appendingPathComponent("x.pdf")
        do {
            try PDFKitDocumentProvider.atomicallyWrite(to: missing) { temporary in
                try Data("NEW".utf8).write(to: temporary)
                return true
            }
            Issue.record("a write into a missing folder succeeded")
        } catch let PDFBridgeError.writeFailed(path, reason) {
            #expect(path == missing.path)
            #expect(reason.hasPrefix("atomic replace failed"), "\(reason)")
        }
    }

    @Test("V-056: StagedFileReplacement.place swaps an existing file and moves onto a free name")
    func placeSwapsOrMoves() throws {
        let directory = try Corpus.scratchDirectory("iter5-place")
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("out.pdf")
        for (round, bytes) in ["FIRST", "SECOND"].enumerated() {
            let folder = try StagedFileReplacement.stagingDirectory(appropriateFor: destination)
            defer { try? FileManager.default.removeItem(at: folder) }
            let staged = folder.appendingPathComponent("staged-\(round).pdf")
            try Data(bytes.utf8).write(to: staged)
            try StagedFileReplacement.place(staged, at: destination)
            #expect(try Data(contentsOf: destination) == Data(bytes.utf8))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["out.pdf"])
    }
}
