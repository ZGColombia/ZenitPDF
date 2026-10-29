import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
import ZPDFAppCore
import ZPDFContracts
import ZPDFPersistence
@testable import ZenitPDFAppKit

/// Bug hunt 2, document state: revert, names, search keys, photos, recognition runs and the
/// Quick PDF history key.
@MainActor
@Suite(.appTierSerialised)
struct Fix2DocumentStateTests {

    private func save(_ document: ZenitPDFProjectDocument, to url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            document.save(to: url, ofType: ZenitAppInfo.projectTypeIdentifier, for: .saveAsOperation) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    @Test("BH-355: Revert to Saved on an open takeoff is refused in words, not a silent clean")
    func revertIsRefused() async throws {
        let harness = try await Fix2Harness.make("BH355.pdf")
        defer { harness.tearDown() }
        let url = try #require(harness.document.drawing?.url)
        // Old: read(from:) recorded a URL, nothing reloaded, and AppKit marked the edits clean.
        #expect(throws: ZenitDocumentError.revertUnavailable) {
            try harness.document.revert(toContentsOf: url, ofType: UTType.pdf.identifier)
        }
        let item = NSMenuItem(title: "Revert", action: #selector(NSDocument.revertToSaved(_:)), keyEquivalent: "")
        #expect(!harness.document.validateUserInterfaceItem(item))
    }

    @Test("BH-356: after Save As the stamp fields name the document by its new name")
    func stampNamesFollowTheFile() async throws {
        let harness = try await Fix2Harness.make("plan.pdf")
        defer { harness.tearDown() }
        #expect(harness.core.documentDisplayName.hasPrefix("plan"))
        try await save(harness.document, to: harness.directory.appendingPathComponent("Block C.zpdfproj"))
        // Old: still "plan" — assigned once at load.
        #expect(harness.core.documentDisplayName == "Block C")
        #expect(harness.core.projectDisplayName == "Block C")
    }

    @Test("BH-358: two takeoffs over one drawing never share a search index")
    func searchIndexKeysAreSeparate() {
        let digest = "abc123"
        let a = UUID(), b = UUID()
        #expect(ZenitPDFProjectDocument.searchIndexKey(digest: digest, projectID: nil, documentIdentity: a, keysInUse: []) == digest)
        // Old: both documents opened <sha>.sqlite and deleted each other's markup rows.
        let second = ZenitPDFProjectDocument.searchIndexKey(digest: digest, projectID: nil, documentIdentity: b, keysInUse: [digest])
        #expect(second != digest)
        let projectA = ZenitPDFProjectDocument.searchIndexKey(digest: digest, projectID: "P1", documentIdentity: a, keysInUse: [])
        let projectB = ZenitPDFProjectDocument.searchIndexKey(digest: digest, projectID: "P2", documentIdentity: b, keysInUse: [])
        #expect(projectA != projectB)
    }

    @Test("BH-359: a photo sidecar that will not open says so")
    func unreadablePhotoManifestIsReported() async throws {
        let harness = try await Fix2Harness.make("BH359.pdf")
        let package = harness.directory.appendingPathComponent("Photos.zpdfproj")
        try await save(harness.document, to: package)
        harness.document.close()
        let photos = SaveAsCarryOver.photosDirectory(in: package)
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: photos.appendingPathComponent(PhotoStore.manifestFileName))
        let reopened = ZenitPDFProjectDocument()
        try reopened.read(from: package, ofType: ZenitAppInfo.projectTypeIdentifier)
        reopened.startLoadingIfNeeded()
        defer {
            reopened.close()
            try? FileManager.default.removeItem(at: harness.directory)
        }
        #expect(await AppTestSupport.wait { reopened.core != nil })
        // Old: `try?` — no photo UI, no rows, and no word about why.
        #expect(reopened.photoStoreFailure != nil)
        #expect(reopened.core?.status.warnings.contains { $0.id == ZenitPDFProjectDocument.photoStoreWarningID } == true)
    }

    @Test("BH-361: a replaced recognition run does not orphan the running one")
    func replacedOCRRunKeepsItsHandle() async throws {
        let harness = try await Fix2Harness.make("BH361.pdf", pageCount: 6, calibrate: false)
        defer { harness.tearDown() }
        #expect(await AppTestSupport.wait { harness.document.searchIndex != nil })
        var finishes = 0
        let languages = Array(ZenitPDFProjectDocument.supportedRecognitionLanguages().prefix(1))
        let pageIDs = try #require(harness.document.drawing).pages.map(\.id.rawValue)
        harness.document.runTextRecognition(
            pageIDs: pageIDs, languageIDs: languages, skipsPagesWithText: false,
            onPage: { _, _ in }, onFinish: { _ in finishes += 1 }
        )
        harness.document.runTextRecognition(
            pageIDs: pageIDs, languageIDs: languages, skipsPagesWithText: false,
            onPage: { _, _ in }, onFinish: { _ in finishes += 1 }
        )
        #expect(await AppTestSupport.wait { finishes >= 1 }, "the cancelled run never finished")
        if finishes == 1 {
            // Old: the cancelled run's finish set `ocrRunTask = nil` — the live run was orphaned.
            #expect(harness.document.isRecognizingText, "the running recognition lost its handle")
        }
        harness.document.cancelTextRecognition()
        #expect(await AppTestSupport.wait(upTo: 60) { finishes == 2 })
        #expect(!harness.document.isRecognizingText)
    }

    @Test("BH-362: a Quick PDF's history key survives a restore")
    func quickHistoryKeyIsStable() {
        let first = ZenitPDFProjectDocument.quickHistoryProjectID(digest: "deadbeef", fallback: UUID())
        let second = ZenitPDFProjectDocument.quickHistoryProjectID(digest: "deadbeef", fallback: UUID())
        // Old: a fresh DocumentID per open — the restored session read an empty trail.
        #expect(first == second)
    }
}
