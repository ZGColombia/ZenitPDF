import CoreGraphics
import Foundation
import Testing
import ZPDFTestingSupport
@testable import ZPDFVectorExtraction

/// BH-069: Vector Snap on a password-protected drawing the person
/// has unlocked. Old behaviour: `extract(documentAt:pageIndex:)` had no password parameter, so a
/// user-password drawing always threw `.documentEncrypted` and the canvas had no Vector Snap.
struct PasswordUnlockTests {

    @Test("BH-069: a locked drawing extracts with its user password, and only with it")
    func lockedDrawingNeedsItsPassword() async throws {
        let directory = try ExtractionTestSupport.makeTemporaryDirectory()
        defer { ExtractionTestSupport.remove(directory) }
        let handle = try ZPDFFixtures.make(.encryptedUserPassword, in: directory)
        guard let probe = CGPDFDocument(handle.url as CFURL), probe.isEncrypted, !probe.isUnlocked else {
            Issue.record("the fixture must be locked for this test to mean anything")
            return
        }

        let cache = VectorExtractionCache()
        let extractor = VectorExtractor(cache: cache)

        // No password, and a wrong one: refused with the typed error.
        await #expect(throws: VectorExtractionError.self) {
            _ = try await extractor.extract(documentAt: handle.url, pageIndex: 0)
        }
        do {
            _ = try await extractor.extract(documentAt: handle.url, pageIndex: 0, password: "not-the-password")
            Issue.record("a wrong password must not unlock the drawing")
        } catch let error as VectorExtractionError {
            guard case .documentEncrypted = error else {
                Issue.record("expected documentEncrypted, got \(error)")
                return
            }
        }

        // The right user password: the page is read.
        let unlocked = try await extractor.extract(
            documentAt: handle.url, pageIndex: 0, password: ZPDFFixtures.encryptedUserPassword
        )
        // The fixture's one stroke runs (100,100) -> (400,500): sqrt(300^2 + 400^2) = 500 pt.
        #expect(unlocked.availability.isAvailable)
        #expect(abs(ExtractionTestSupport.totalSegmentLength(of: unlocked) - 500) < 1e-6)

        // Nothing about the unlocked drawing is cached or memoised: a following call without
        // the password is refused again, not served the geometry.
        #expect(await cache.count == 0)
        await #expect(throws: VectorExtractionError.self) {
            _ = try await extractor.extract(documentAt: handle.url, pageIndex: 0)
        }

        // Each page receives the password when extracting the drawing in order.
        try #require(probe.unlockWithPassword(ZPDFFixtures.encryptedUserPassword))
        var all: [VectorPageExtraction] = []
        for index in 0..<min(probe.numberOfPages, 4) {
            all.append(try await extractor.extract(
                documentAt: handle.url, pageIndex: index, password: ZPDFFixtures.encryptedUserPassword
            ))
        }
        #expect(!all.isEmpty)
    }

    @Test("BH-069: a password on an unencrypted drawing is ignored and the result is unchanged")
    func passwordOnPlainDrawingIsIgnored() async throws {
        let directory = try ExtractionTestSupport.makeTemporaryDirectory()
        defer { ExtractionTestSupport.remove(directory) }
        let handle = try ZPDFFixtures.make(.rectangle, in: directory)
        let plain = try await VectorExtractor().extract(documentAt: handle.url, pageIndex: 0)
        let withPassword = try await VectorExtractor().extract(documentAt: handle.url, pageIndex: 0, password: "anything")
        #expect(VectorExtractionCodec.encode(plain) == VectorExtractionCodec.encode(withPassword))
    }
}
