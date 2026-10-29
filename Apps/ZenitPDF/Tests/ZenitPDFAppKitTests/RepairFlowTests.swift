import CryptoKit
import Foundation
import Testing
import ZPDFServiceClient
import ZPDFTestingSupport
@testable import ZenitPDFAppKit

/// A damaged drawing is repaired as a *copy*, through the same client the
/// assembled bundle routes into `RepairService.xpc`. The original file's bytes are
/// asserted untouched, not just promised.
@MainActor
@Suite(.appTierSerialised, .serialized) // the repaired-copies root override is one static; keep it per-test
struct RepairFlowTests {

    /// Points the repair flow at the worker executable for the length of one test.
    ///
    /// `DamagedDrawingRepair` talks to `RepairService.xpc` and nothing else. A `swift test`
    /// process is not an application bundle, so `NSXPCConnection(serviceName:)` finds no
    /// service and every repair fails with "couldn't communicate with a helper application" —
    /// which is what this test was doing. `zpdf-repair-worker` runs the same service handler
    /// in a child process, so the flow under test is the real one and the client is exercised
    /// across a real process boundary.
    ///
    /// Not the in-process executor. That would link qpdf into the test binary, which is the
    /// address space `RepairService.xpc` exists to keep it out of (S17-03) — and it is not a
    /// theoretical objection: with qpdf in-process, this one test corrupted unrelated SQLite
    /// work in two other suites running beside it (`SQLite error 10: disk I/O error`, and a
    /// project left with its crash marker armed), and those failures disappear when the
    /// repair runs in a child process instead.
    private static func installWorkerRepairClient() throws {
        let worker = try productsDirectory().appendingPathComponent("zpdf-repair-worker")
        try #require(FileManager.default.fileExists(atPath: worker.path),
                     "zpdf-repair-worker is not built next to the test bundle")
        DamagedDrawingRepair.clientOverride =
            ZPDFRepairServiceClient(backend: .subprocess(executableURL: worker))
    }

    /// The build products directory, found by walking up from this module's own image.
    ///
    /// Swift Testing does not promise an `.xctest` bundle in `Bundle.allBundles`, so the
    /// loader's answer for where this code lives is the reliable anchor. Same walk as
    /// `ZPDFServiceClientTests.ServiceTestSupport`.
    private static func productsDirectory() throws -> URL {
        var candidates: [URL] = []
        var info = Dl_info()
        if dladdr(#dsohandle, &info) != 0, let name = info.dli_fname {
            candidates.append(URL(fileURLWithPath: String(cString: name)).deletingLastPathComponent())
        }
        candidates.append(Bundle.main.bundleURL)
        if let executable = Bundle.main.executableURL {
            candidates.append(executable.deletingLastPathComponent())
        }
        for start in candidates {
            var directory = start.standardizedFileURL
            for _ in 0..<6 {
                let probe = directory.appendingPathComponent("zpdf-repair-worker")
                if FileManager.default.fileExists(atPath: probe.path) { return directory }
                directory.deleteLastPathComponent()
            }
        }
        Issue.record("could not locate the build products directory from \(candidates)")
        throw CocoaError(.fileNoSuchFile)
    }

    private func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @Test("A broken-xref drawing is rebuilt into an openable copy; the original is untouched")
    func repairRebuildsACopy() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenit-repair-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let repairedRoot = directory.appendingPathComponent("container", isDirectory: true)
        DamagedDrawingRepair.repairedCopiesRootOverride = repairedRoot
        try Self.installWorkerRepairClient()
        defer {
            DamagedDrawingRepair.repairedCopiesRootOverride = nil
            DamagedDrawingRepair.clientOverride = nil
        }

        let handle = try ZPDFFixtures.make(.brokenXref, in: directory)
        let originalHash = try sha256(of: handle.url)

        let repaired = try await ZenitPDFProjectDocument.repairCopy(of: handle.url)

        // The copy is inside the container root, not beside the drawing.
        #expect(repaired.path.hasPrefix(repairedRoot.path), "repaired copy must land in the container: \(repaired.path)")
        #expect(repaired != handle.url)
        // The copy actually opens through the shipping loader.
        let loaded = try await DocumentSessionLoader.load(pdfAt: repaired)
        #expect(!loaded.pages.isEmpty, "the repaired copy must be a readable drawing")
        await loaded.rasterSource.close()
        // The original is byte-for-byte what it was.
        #expect(try sha256(of: handle.url) == originalHash, "repair must never write into the original")
    }

    @Test("The repair offer is made for damaged PDFs only")
    func repairOfferPolicy() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenit-repair-offer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let handle = try ZPDFFixtures.make(.brokenXref, in: directory)
        let anyError = ZenitDocumentError.documentNotReady
        #expect(DamagedDrawingRepair.canOffer(for: handle.url, afterLoadFailure: anyError))

        // A project package is not a PDF to rebuild.
        let package = directory.appendingPathComponent("Tower.zpdfproj")
        #expect(!DamagedDrawingRepair.canOffer(for: package, afterLoadFailure: anyError))
        // An unsupported type keeps its own error.
        #expect(!DamagedDrawingRepair.canOffer(
            for: handle.url,
            afterLoadFailure: ZenitDocumentError.unsupportedFileType("x.png")
        ))
        // A file that no longer exists cannot be repaired.
        let gone = directory.appendingPathComponent("missing.pdf")
        #expect(!DamagedDrawingRepair.canOffer(for: gone, afterLoadFailure: anyError))
    }
}
