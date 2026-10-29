import Foundation
import Testing
@testable import ZPDFPDFKitBridge

/// CR-77: the one write path is atomic.
///
/// `atomicallyWrite` fills a sibling temporary and places it with `replaceItemAt`; it never
/// removes the destination first. The old code deleted the destination before writing, so a
/// write that then failed destroyed the previous export and wrote nothing in its place.
@Suite("Atomic write")
struct AtomicWriteTests {

    private func scratch(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-atomic-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("A failed write leaves the previous export untouched")
    func failedWritePreservesPreviousExport() throws {
        let directory = try scratch("fail")
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("export.pdf")
        let previous = Data("PREVIOUS EXPORT".utf8)
        try previous.write(to: destination)

        // The write step fails (PDFKit refused). Old output: the destination had been removed
        // before the write, so the previous export was gone and nothing replaced it.
        #expect(throws: (any Error).self) {
            try PDFKitDocumentProvider.atomicallyWrite(to: destination) { _ in false }
        }
        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(try Data(contentsOf: destination) == previous)
    }

    @Test("A write whose placement throws leaves the previous export untouched")
    func throwingWritePreservesPreviousExport() throws {
        let directory = try scratch("throw")
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("export.pdf")
        let previous = Data("KEEP ME".utf8)
        try previous.write(to: destination)

        struct WriteBlewUp: Error {}
        #expect(throws: WriteBlewUp.self) {
            try PDFKitDocumentProvider.atomicallyWrite(to: destination) { _ in throw WriteBlewUp() }
        }
        #expect(try Data(contentsOf: destination) == previous)
    }

    @Test("A successful write replaces the destination with the new bytes")
    func successfulWriteReplaces() throws {
        let directory = try scratch("ok")
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("export.pdf")
        try Data("OLD".utf8).write(to: destination)

        try PDFKitDocumentProvider.atomicallyWrite(to: destination) { temporaryURL in
            // Proof the write goes to a sibling temporary, not the destination, until it is placed.
            #expect(temporaryURL != destination)
            #expect(try Data(contentsOf: destination) == Data("OLD".utf8))
            try Data("NEW".utf8).write(to: temporaryURL)
            return true
        }
        #expect(try Data(contentsOf: destination) == Data("NEW".utf8))
    }

    @Test("A successful write creates a destination that did not exist yet")
    func successfulWriteCreates() throws {
        let directory = try scratch("create")
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("new.pdf")
        #expect(!FileManager.default.fileExists(atPath: destination.path))

        try PDFKitDocumentProvider.atomicallyWrite(to: destination) { temporaryURL in
            try Data("FRESH".utf8).write(to: temporaryURL)
            return true
        }
        #expect(try Data(contentsOf: destination) == Data("FRESH".utf8))
    }
}
