import AppKit
import Darwin
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFPDFKitBridge
import ZPDFPersistence
import ZPDFUIPresentation
import ZPDFVectorExtraction
@testable import ZenitPDFAppKit

/// Bug hunt 2, document: user unit, snap-index honesty, Save As, imported columns and
/// the words a failed save or export uses.
@MainActor
@Suite(.appTierSerialised)
struct Fix2DocumentTests {

    /// A one-page PDF whose page declares `/UserUnit`.
    private static func writeUserUnitPDF(_ userUnit: Double) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-userunit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("LargeFormat.pdf")
        let content = Data("2 w 0 0 0 RG\n72 72 m 372 72 l 372 272 l 72 272 l h S\n".utf8)
        var stream = Data("<< /Length \(content.count) >>\nstream\n".utf8)
        stream.append(content)
        stream.append(Data("\nendstream".utf8))
        let objects: [Data] = [
            Data("<< /Type /Catalog /Pages 2 0 R >>".utf8),
            Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8),
            Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /UserUnit \(userUnit) /Contents 4 0 R >>".utf8),
            stream
        ]
        var bytes = Data("%PDF-1.7\n".utf8)
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(bytes.count)
            bytes.append(Data("\(index + 1) 0 obj\n".utf8))
            bytes.append(object)
            bytes.append(Data("\nendobj\n".utf8))
        }
        let xref = bytes.count
        bytes.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets { bytes.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        bytes.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        try bytes.write(to: url)
        return url
    }

    private func save(_ document: ZenitPDFProjectDocument, to url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            document.save(to: url, ofType: ZenitAppInfo.projectTypeIdentifier, for: .saveAsOperation) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    // MARK: - BH-068

    @Test("BH-068: the page's /UserUnit reaches the contract page the engine measures on")
    func userUnitReachesTheContractPage() async throws {
        let url = try Self.writeUserUnitPDF(2)
        let harness = try await Fix2Harness.make("unused", calibrate: false, fixture: url)
        defer { harness.tearDown() }
        let page = try #require(harness.document.drawing?.pages.first)
        // Old: 1.0 — the seam never read it, so every preset-scale length was half size.
        #expect(page.userUnit == 2)
        #expect(PageUserUnits.sanitised(-3) == 1)
        #expect(PageUserUnits.sanitised(.nan) == 1)
    }

    // MARK: - BH-353 / BH-069

    @Test("BH-353: a failed extraction is reported as a failure, and the markup index still exists")
    func failedExtractionIsNotNoVectorContent() async throws {
        let harness = try await Fix2Harness.make("BH353.pdf", calibrate: false)
        defer { harness.tearDown() }
        let page = try #require(harness.document.drawing?.pages.first)
        let missing = harness.directory.appendingPathComponent("gone-\(UUID().uuidString).pdf")
        let result = await DocumentSessionLoader.buildSnapIndex(
            for: page, documentURL: missing, session: harness.core.session
        )
        // Old: `try?` collapsed the error to nil, which the status bar reads as "no vector content".
        #expect(result.failureReason != nil)
        #expect(result.availability != nil, "the markup-and-boundary index must still be built")
        let encrypted = DocumentSessionLoader.extractionFailureReason(
            VectorExtractionError.documentEncrypted(fileName: "Plan.pdf")
        )
        #expect(encrypted.localizedCaseInsensitiveContains("password"))
    }

    // MARK: - BH-070 / BH-071 Save As

    @Test("BH-070: Save As onto the open package through a symlinked folder saves in place")
    func saveAsThroughASymlinkIsInPlace() async throws {
        let harness = try await Fix2Harness.make("BH070.pdf")
        defer { harness.tearDown() }
        let real = harness.directory.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let package = real.appendingPathComponent("Job.zpdfproj")
        try await save(harness.document, to: package)
        #expect(harness.document.mode == .project)
        let link = harness.directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let respelled = link.appendingPathComponent("Job.zpdfproj")
        // Old: raw `url == fileURL` was false, the live package was deleted and the clone of
        // its PDF out of the deleted package threw — the only copy of the project gone.
        try await save(harness.document, to: respelled)
        #expect(FileManager.default.fileExists(atPath: package.appendingPathComponent("documents/original.pdf").path))
        #expect(FileManager.default.fileExists(atPath: package.appendingPathComponent("project.sqlite").path))
        #expect(SaveAsCarryOver.sameItem(respelled, package))
    }

    @Test("BH-071: Save As from Project Mode carries the photographs and the imported stamp artwork")
    func saveAsCarriesPhotosAndArtwork() async throws {
        let harness = try await Fix2Harness.make("BH071.pdf")
        defer { harness.tearDown() }
        let first = harness.directory.appendingPathComponent("First.zpdfproj")
        try await save(harness.document, to: first)
        let oldPackage = try #require(harness.document.projectPackage)
        // A photograph in the sidecar, and a compiled artwork row in the database.
        let photos = SaveAsCarryOver.photosDirectory(in: first)
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        try Data("jpeg".utf8).write(to: photos.appendingPathComponent("blob-1.jpg"))
        let artwork = try await StampArtworkImporter().importArtwork(
            from: .pdfPage(url: try #require(harness.document.drawing?.url), pageIndex: 0)
        )
        try await ProjectArtworkStore.store(artwork, in: oldPackage)

        let second = harness.directory.appendingPathComponent("Second.zpdfproj")
        try await save(harness.document, to: second)
        let newPackage = try #require(harness.document.projectPackage)
        #expect(newPackage.url.standardizedFileURL.path == second.standardizedFileURL.path)
        // Old: a fresh empty package — no photo files, no artwork rows.
        #expect(FileManager.default.fileExists(
            atPath: SaveAsCarryOver.photosDirectory(in: second).appendingPathComponent("blob-1.jpg").path
        ))
        #expect(try await ProjectArtworkStore.geometry(forDigest: artwork.digest, in: newPackage) != nil)
    }

    // MARK: - BH-075 imported ledger columns survive a reopen

    @Test("BH-075: imported ledger columns are written with the takeoff and restored on open")
    func importedColumnsSurviveReopen() async throws {
        let harness = try await Fix2Harness.make("BH075.pdf")
        let column = LedgerColumnDefinition(
            id: ColumnID(UUID()), key: "zenit.import.test", title: "Remarks", kind: .text
        )
        try await harness.core.session.addCustomColumns([column])
        harness.document.noteImportedLedgerColumns([column])
        let package = harness.directory.appendingPathComponent("Columns.zpdfproj")
        try await save(harness.document, to: package)
        harness.document.close()
        // Old: nothing wrote the definitions, so the reopened ledger had no column for the cells.
        // Their home is the takeoff database now; the interim attachments file is retired.
        #expect(ImportedLedgerColumnStore.read(fromPackage: package).isEmpty)

        let reopened = ZenitPDFProjectDocument()
        try reopened.read(from: package, ofType: ZenitAppInfo.projectTypeIdentifier)
        reopened.startLoadingIfNeeded()
        defer {
            reopened.close()
            try? FileManager.default.removeItem(at: harness.directory)
        }
        #expect(await AppTestSupport.wait { reopened.core != nil })
        #expect(reopened.importedLedgerColumns == [column], "the reopened session never got the column back")
        let reopenedPackage = try #require(reopened.projectPackage)
        let stored = try #require(try await TakeoffArchive.read(from: reopenedPackage))
        #expect(stored.customColumns.map(\.key) == [column.key], "the archive carries the definition")
    }

    // MARK: - BH-354 / IM-176 / BH-374 the words

    @Test("BH-354 / IM-176: a save failure names what failed, and keeps the engine's detail")
    func saveFailureWordsFollowTheCause() {
        let noSpace = ZenitDocumentError.saveFailure(
            .posixFailure(operation: "write", path: "/x", errnoValue: ENOSPC), projectName: "Tower"
        )
        #expect(noSpace == .projectSaveNoSpace("Tower"))
        #expect(noSpace.errorDescription?.contains("free space") == true)
        let changed = ZenitDocumentError.saveFailure(.originalPDFModified(expected: "a", found: "b"), projectName: "Tower")
        #expect(changed == .projectSaveDrawingChanged("Tower"))
        let location = ZenitDocumentError.saveFailure(.writeOnReadOnlyPackage, projectName: "Tower")
        // Old: every case was `projectSaveFailed` and the detail was dropped on the floor.
        #expect(location.failureReason?.isEmpty == false)
        #expect(changed.recoverySuggestion?.contains("folder you can write to") == false)
    }

    @Test("BH-374: an export that changed its source says so, not 'still opening'")
    func exportIntegrityBreachIsNamed() async throws {
        let harness = try await Fix2Harness.make("BH374.pdf", calibrate: false)
        defer { harness.tearDown() }
        let error = ProjectWindowController.annotatedExportIntegrityError(for: harness.document)
        #expect(error == .exportChangedSource("BH374.pdf"))
        #expect(error.errorDescription != ZenitDocumentError.documentNotReady.errorDescription)
    }
}
