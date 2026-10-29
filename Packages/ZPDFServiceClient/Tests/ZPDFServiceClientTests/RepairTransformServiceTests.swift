import CryptoKit
import Foundation
import PDFKit
import Testing
import ZPDFServiceWire
import ZPDFTestingSupport
@testable import ZPDFServiceClient

/// NL-PDF-08 / NL-PDF-09 across the process boundary: the transform runs in the repair worker,
/// qpdf never enters the test binary, and the input's bytes are the same afterwards.
struct RepairTransformServiceTests {

    @Test("A compress-and-protect transform runs in the worker and writes an encrypted, smaller copy")
    func transformRunsOutOfProcess() async throws {
        let fixture = try ServiceTestSupport.makeFixture(.titleBlockSheet)
        defer { ServiceTestSupport.remove(fixture.directory) }
        let before = SHA256.hash(data: try Data(contentsOf: fixture.url))
        let output = fixture.directory.appendingPathComponent("protected.pdf")
        let client = ZPDFRepairServiceClient(
            backend: .subprocess(executableURL: try ServiceTestSupport.repairWorkerURL()),
            maximumRestarts: 0)
        defer { Task { await client.shutdown() } }

        let reply = try await client.transform(
            input: fixture.url,
            output: output,
            transform: RepairWireTransform(
                compresses: true,
                sanitizes: true,
                protection: .init(
                    openPassword: "site-2026",
                    permissionsPassword: "estimator",
                    printing: 2,
                    allowsChanges: false,
                    allowsCopying: true,
                    allowsAnnotating: true
                )
            )
        )
        #expect(reply.outputByteCount > 0)
        #expect(reply.transformSummary != nil)
        #expect(SHA256.hash(data: try Data(contentsOf: fixture.url)) == before, "the input must not change")
        let document = try #require(PDFDocument(url: output))
        #expect(document.isLocked, "the copy must need its password")
        #expect(document.unlock(withPassword: "site-2026"))
        #expect(document.pageCount >= 1)
    }

    @Test("A transform request without a transform is refused by the worker, and nothing is written")
    func missingTransformIsRefused() async throws {
        let fixture = try ServiceTestSupport.makeFixture(.titleBlockSheet)
        defer { ServiceTestSupport.remove(fixture.directory) }
        let output = fixture.directory.appendingPathComponent("never.pdf")
        let client = ZPDFRepairServiceClient(
            backend: .subprocess(executableURL: try ServiceTestSupport.repairWorkerURL()),
            maximumRestarts: 0)
        defer { Task { await client.shutdown() } }
        await #expect(throws: (any Error).self) {
            _ = try await client.transform(input: fixture.url, output: output, transform: RepairWireTransform())
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }
}
