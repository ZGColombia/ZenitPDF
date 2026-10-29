import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFPersistence
@testable import ZenitPDFAppKit

/// CR-153: the Quick PDF container autosave is written every second and, before this, never
/// read back. Reopening the drawing now offers the takeoff; stale autosaves are swept.
@MainActor
@Suite(.appTierSerialised)
struct QuickTakeoffRestoreTests {

    private func withContainerRoot<T>(_ body: (URL) async throws -> T) async rethrows -> T {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenit-restore-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        ZenitPDFProjectDocument.quickPDFAutosaveRootOverride = root
        defer {
            ZenitPDFProjectDocument.quickPDFAutosaveRootOverride = nil
            try? FileManager.default.removeItem(at: root)
        }
        return try await body(root)
    }

    /// Opens the fixture, calibrates it, autosaves, and closes as a crashed session would
    /// leave it: the autosave directory stays in the container.
    private func leaveAnAutosave(for url: URL) async throws -> URL {
        let document = try AppTestSupport.makeDocument(opening: url)
        #expect(await AppTestSupport.wait { document.core != nil })
        let core = try #require(document.core)
        _ = try await core.commands.calibrate(
            page: try #require(await core.session.firstPageID),
            first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
            knownLength: 5, knownLengthUnit: .metre
        )
        await core.refresh()
        document.updateChangeCount(.changeDone)
        _ = try await document.autosaveQuickPDFTakeoff()
        let directory = document.quickPDFAutosaveDirectory
        document.close()
        #expect(await AppTestSupport.wait { !document.hasOpenStorage })
        #expect(FileManager.default.fileExists(atPath: directory.path), "an edited takeoff keeps its autosave")
        return directory
    }

    @Test("Reopening a drawing offers its container autosave, and Restore continues the takeoff")
    func restoreContinuesTheTakeoff() async throws {
        try await withContainerRoot { _ in
            let url = try AppTestSupport.writeFixturePDF(named: "Restore A-1.pdf")
            let directory = try await leaveAnAutosave(for: url)

            QuickTakeoffRestorePrompt.decisionOverride = .restore
            defer { QuickTakeoffRestorePrompt.decisionOverride = nil }
            let reopened = try AppTestSupport.makeDocument(opening: url)
            #expect(await AppTestSupport.wait { reopened.core != nil })
            defer { reopened.close() }
            let core = try #require(reopened.core)
            // Before CR-153 the reopened drawing had no scale: nothing read the autosave.
            #expect(core.document.currentPageScale != nil, "CR-153: the calibrated scale comes back")
            #expect(reopened.restoredFromAutosave)
            #expect(reopened.isDocumentEdited, "restored work is unsaved work")
            #expect(reopened.quickPDFAutosaveDirectory.resolvingSymlinksInPath() == directory.resolvingSymlinksInPath(),
                    "the document continues in the same autosave rather than starting another")
        }
    }

    @Test("Discard opens the drawing clean and removes the autosave")
    func discardRemovesTheAutosave() async throws {
        try await withContainerRoot { _ in
            let url = try AppTestSupport.writeFixturePDF(named: "Restore B-2.pdf")
            let directory = try await leaveAnAutosave(for: url)

            QuickTakeoffRestorePrompt.decisionOverride = .discard
            defer { QuickTakeoffRestorePrompt.decisionOverride = nil }
            let reopened = try AppTestSupport.makeDocument(opening: url)
            #expect(await AppTestSupport.wait { reopened.core != nil })
            defer { reopened.close() }
            #expect(reopened.core?.document.currentPageScale == nil, "Discard opens clean")
            #expect(!reopened.restoredFromAutosave && !reopened.isDocumentEdited)
            #expect(!FileManager.default.fileExists(atPath: directory.path),
                    "CR-153: a discarded autosave does not accumulate")
        }
    }

    @Test("A different drawing is not offered another drawing's autosave")
    func otherDrawingsAreNotMatched() async throws {
        try await withContainerRoot { _ in
            let url = try AppTestSupport.writeFixturePDF(named: "Restore C-3.pdf")
            _ = try await leaveAnAutosave(for: url)
            // A different file body (two pages), so the digests differ.
            let otherURL = try AppTestSupport.writeFixturePDF(named: "Restore C-3 other.pdf", pageCount: 2)
            let candidate = ZenitPDFProjectDocument.restorableQuickAutosave(
                matchingDigest: try FileDigestProbe.sha256(of: otherURL)
            )
            #expect(candidate == nil, "matching is by the drawing's digest, not by the container")
        }
    }

    @Test("The launch sweep removes autosaves nobody came back for and keeps recent ones")
    func sweepRemovesOnlyStaleAutosaves() async throws {
        try await withContainerRoot { root in
            let manager = FileManager.default
            func makeAutosave(named name: String, modified: Date) throws -> URL {
                let directory = root.appendingPathComponent(name, isDirectory: true)
                let package = directory.appendingPathComponent("Autosave.zpdfproj", isDirectory: true)
                try manager.createDirectory(at: package, withIntermediateDirectories: true)
                let manifest = package.appendingPathComponent("manifest.json")
                try Data("{}".utf8).write(to: manifest)
                try manager.setAttributes([.modificationDate: modified], ofItemAtPath: manifest.path)
                return directory
            }
            let now = Date()
            let stale = try makeAutosave(named: UUID().uuidString, modified: now.addingTimeInterval(-40 * 24 * 3600))
            let recent = try makeAutosave(named: UUID().uuidString, modified: now.addingTimeInterval(-2 * 24 * 3600))
            // Before CR-153 nothing ever removed either.
            let removed = ZenitPDFProjectDocument.removeStaleQuickAutosaves(in: root, sparing: [], olderThan: 30 * 24 * 3600, now: now)
            #expect(removed.map(\.lastPathComponent) == [stale.lastPathComponent])
            #expect(!manager.fileExists(atPath: stale.path))
            #expect(manager.fileExists(atPath: recent.path), "a recent autosave is kept for its restore offer")
        }
    }
}

/// SHA-256 of a file, as the persistence layer computes it — for the negative match test.
enum FileDigestProbe {
    static func sha256(of url: URL) throws -> String {
        try ZPDFPersistence.FileDurability.sha256(ofFileAt: url)
    }
}
