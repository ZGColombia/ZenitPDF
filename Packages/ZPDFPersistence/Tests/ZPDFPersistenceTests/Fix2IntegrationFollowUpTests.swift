import Foundation
import GRDB
import Testing
import ZPDFPersistence

/// Integration follow-ups: changes other packages need from this package.
struct Fix2IntegrationFollowUpTests {

    private func artwork(_ letter: Character, name: String) -> StampArtworkRecord {
        StampArtworkRecord(
            digest: String(repeating: letter, count: 64),
            kind: "vector",
            data: Data("%PDF-1.4 \(name)".utf8),
            sourceName: "\(name).pdf",
            sourcePageIndex: 0,
            geometryJson: #"{"kind":"vector","strokes":[],"regions":[],"compilerVersion":1}"#,
            compilerVersion: 1
        )
    }

    @Test("BH-071: copyStampArtwork carries every artwork row to another package, once")
    func copyStampArtworkCarriesRows() async throws {
        let sourceSpace = try TestSupport.makeWorkspace("Fix2ArtworkCopySource")
        let destinationSpace = try TestSupport.makeWorkspace("Fix2ArtworkCopyDestination")
        defer {
            try? FileManager.default.removeItem(at: sourceSpace.root)
            try? FileManager.default.removeItem(at: destinationSpace.root)
        }
        let source = try await TestSupport.createPackage(sourceSpace)
        let destination = try await TestSupport.createPackage(destinationSpace)
        let seal = artwork("a", name: "seal")
        let logo = artwork("b", name: "logo")
        try await source.write { db in
            try seal.insert(db)
            try logo.insert(db)
        }
        // The destination already holds one of them, as a Save As over a package would.
        try await destination.write { db in try seal.insert(db) }

        let inserted = try await source.copyStampArtwork(to: destination)
        #expect(inserted == 1)
        let digests = try await destination.read { db in
            try String.fetchAll(db, sql: "SELECT digest FROM stamp_artwork ORDER BY digest")
        }
        #expect(digests == [seal.digest, logo.digest])
        let copied = try await destination.read { db in try StampArtworkRecord.fetchOne(db, key: logo.digest) }
        #expect(copied == logo)
        // A second copy is a no-op.
        #expect(try await source.copyStampArtwork(to: destination) == 0)

        try await source.close()
        try await destination.close()
    }
}
