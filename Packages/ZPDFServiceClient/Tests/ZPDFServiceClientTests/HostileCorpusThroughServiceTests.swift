import Foundation
import Testing
import ZPDFServiceWire
import ZPDFTestingSupport
@testable import ZPDFServiceClient

/// The hostile corpus through the out-of-process path: every
/// hostile fixture produces an extraction or a typed error — and whatever it does
/// to the worker, the host process is still here to assert about it.
struct HostileCorpusThroughServiceTests {

    static let hostileKinds: [FixtureKind] = [
        .truncatedFile, .brokenXref, .cyclicPageTree, .missingObject,
        .deeplyNestedForms, .decompressionBomb, .encryptedUserPassword,
        .embeddedFileWithLaunchAction, .javaScriptAction, .brokenLayerReference
    ]

    @Test("Every hostile fixture through the geometry worker: typed outcome, host survives, worker still answers")
    func hostileCorpusThroughGeometryWorker() async throws {
        let client = ZPDFGeometryServiceClient(
            backend: .subprocess(executableURL: try ServiceTestSupport.geometryWorkerURL()),
            maximumRestarts: 1)

        for kind in Self.hostileKinds {
            let fixture = try ServiceTestSupport.makeFixture(kind)
            defer { ServiceTestSupport.remove(fixture.directory) }
            do {
                let extraction = try await client.extractPageGeometry(
                    documentAt: fixture.url, pageIndex: 0)
                // Fine: recovered or partial. The contract is typed outcome, not failure.
                _ = extraction
            } catch let error as ZPDFServiceError {
                // Also fine: typed. What is not fine is anything else escaping.
                _ = error
            }
        }

        // The worker (possibly restarted along the way) still does real work.
        let sane = try ServiceTestSupport.makeFixture(.rectangle)
        defer { ServiceTestSupport.remove(sane.directory) }
        let extraction = try await client.extractPageGeometry(documentAt: sane.url, pageIndex: 0)
        #expect(!extraction.primitives.isEmpty, "worker must still extract after the hostile corpus")
        await client.shutdown()
    }

    @Test("Hostile fixtures that qpdf can reason about, through the repair worker")
    func hostileCorpusThroughRepairWorker() async throws {
        let client = ZPDFRepairServiceClient(
            backend: .subprocess(executableURL: try ServiceTestSupport.repairWorkerURL()),
            maximumRestarts: 1)

        for kind in Self.hostileKinds {
            let fixture = try ServiceTestSupport.makeFixture(kind)
            defer { ServiceTestSupport.remove(fixture.directory) }
            do {
                _ = try await client.inspect(fixture.url)
            } catch let error as ZPDFServiceError {
                _ = error
            }
        }

        // Still standing, and still useful: repair a broken-xref file end to end.
        let broken = try ServiceTestSupport.makeFixture(.brokenXref)
        defer { ServiceTestSupport.remove(broken.directory) }
        let repaired = broken.directory.appendingPathComponent("repaired.pdf")
        let reply = try await client.repair(input: broken.url, output: repaired)
        #expect(reply.outputByteCount > 0)
        #expect(FileManager.default.fileExists(atPath: repaired.path))

        let verdict = try await client.inspect(repaired)
        #expect(verdict.isDamaged == false, "a repaired copy must inspect clean")
        await client.shutdown()
    }

    @Test("Decrypt with the user password through the repair worker; wrong password is a typed remote failure")
    func decryptThroughRepairWorker() async throws {
        let client = ZPDFRepairServiceClient(
            backend: .subprocess(executableURL: try ServiceTestSupport.repairWorkerURL()),
            maximumRestarts: 1)

        let fixture = try ServiceTestSupport.makeFixture(.encryptedUserPassword)
        defer { ServiceTestSupport.remove(fixture.directory) }

        // Wrong password: typed remote failure, not a crash.
        let wrongOut = fixture.directory.appendingPathComponent("wrong.pdf")
        do {
            _ = try await client.decrypt(input: fixture.url, output: wrongOut, password: "not-the-password")
            Issue.record("a wrong password cannot decrypt")
        } catch let error as ZPDFServiceError {
            guard case .remoteFailure(let domain, _, _) = error else {
                Issue.record("expected .remoteFailure, got \(error)")
                return
            }
            #expect(domain == "ZPDFQPDF")
        }

        // Right password: a decrypted copy that opens without one.
        let decrypted = fixture.directory.appendingPathComponent("decrypted.pdf")
        let reply = try await client.decrypt(
            input: fixture.url, output: decrypted,
            password: ZPDFFixtures.encryptedUserPassword)
        #expect(reply.outputByteCount > 0)
        let verdict = try await client.inspect(decrypted)
        #expect(verdict.isEncrypted == false)
        await client.shutdown()
    }
}
