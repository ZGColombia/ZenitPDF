import Foundation
import Testing
import ZPDFGeometryServiceCore
import ZPDFServiceClient
import ZPDFServiceWire
import ZPDFTestingSupport

/// BH-069: an unlocked, password-protected drawing gets Vector Snap.
@Suite("Geometry service — password (BH-069)", .serialized)
struct PasswordGeometryTests {

    private func encryptedFixture() throws -> (url: URL, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-bh069-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (try ZPDFFixtures.make(.encryptedUserPassword, in: directory).url, directory)
    }

    private let password = ZPDFFixtures.encryptedUserPassword

    /// Old behaviour: the password had nowhere to go, so an unlocked drawing always failed
    /// with `documentEncrypted` in every backend.
    @Test("BH-069: in process and across the worker boundary, the password unlocks and its absence is refused")
    func passwordUnlocksEverywhere() async throws {
        let fixture = try encryptedFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let inProcess = ZPDFGeometryServiceClient(backend: .inProcess)
        let worker = ZPDFGeometryServiceClient(
            backend: .subprocess(executableURL: try ServiceTestSupport.geometryWorkerURL()))
        defer { Task { await worker.shutdown() } }

        for client in [inProcess, worker] {
            let unlocked = try await client.extractPageGeometry(
                documentAt: fixture.url, pageIndex: 0, options: GeometryWireOptions(password: password))
            // The fixture's one stroke runs (100,100) -> (400,500).
            #expect(unlocked.availability.isAvailable)
            #expect(!unlocked.primitives.isEmpty)

            await #expect(throws: (any Error).self) {
                _ = try await client.extractPageGeometry(documentAt: fixture.url, pageIndex: 0)
            }
            await #expect(throws: (any Error).self) {
                _ = try await client.extractPageGeometry(
                    documentAt: fixture.url, pageIndex: 0, options: GeometryWireOptions(password: password + "x"))
            }
            // Unlocking once does not leave the drawing open for a later call without it.
            await #expect(throws: (any Error).self) {
                _ = try await client.extractPageGeometry(documentAt: fixture.url, pageIndex: 0)
            }
        }
        await worker.shutdown()
    }

    @Test("BH-069: the service core honours the password and refuses without it")
    func coreHonoursPassword() async throws {
        let fixture = try encryptedFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let core = GeometryServiceCore()
        let with = await core.extract(
            request: GeometryWireRequest(pageIndex: 0, options: GeometryWireOptions(password: password)),
            documentAt: fixture.url)
        guard case .success = with else { Issue.record("with password: \(with)"); return }
        let without = await core.extract(request: GeometryWireRequest(pageIndex: 0), documentAt: fixture.url)
        guard case .failure(let failure) = without else { Issue.record("extracted without a password"); return }
        #expect(failure.message.contains("ncrypt"), "\(failure.message)")
        #expect(!failure.message.contains(password))
    }

    @Test("BH-069: no textual rendering of the options shows the password")
    func passwordIsRedacted() throws {
        let options = GeometryWireOptions(includesHiddenOptionalContent: true, password: "s3cret-pw")
        let request = GeometryWireRequest(pageIndex: 0, options: options)
        for text in [String(describing: options), String(reflecting: options), "\(options)",
                     String(describing: request), String(reflecting: request)] {
            #expect(!text.contains("s3cret-pw"), "\(text)")
        }
        var dumped = ""
        dump(request, to: &dumped)
        #expect(!dumped.contains("s3cret-pw"))
        // It still crosses the wire, which is the point.
        let decoded = try JSONDecoder().decode(GeometryWireRequest.self, from: JSONEncoder().encode(request))
        #expect(decoded.options.password == "s3cret-pw")
    }
}
