import Foundation
import GRDB
import Testing
import ZPDFPersistence
import ZPDFTestingSupport

/// Anchor for `Bundle(for:)`, which is how a test finds the directory SwiftPM linked it
/// into and therefore where the `zpdf-save-harness` executable sits.
final class TestBundleAnchor {}

enum TestSupport {

    // MARK: Directories

    static func makeTemporaryDirectory(_ label: String = "ZPDFPersistence") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(ProcessInfo.processInfo.globallyUniqueString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A real PDF from the synthetic corpus. Never a hand-rolled fixture.
    static func makeSourcePDF(in directory: URL, kind: FixtureKind = .titleBlockSheet) throws -> URL {
        try ZPDFFixtures.make(kind, in: directory).url
    }

    /// A deterministic environment: pinned clock, sequential identifiers.
    static func environment(idPrefix: String = "T") -> PersistenceEnvironment {
        PersistenceEnvironment(
            clock: SteppingClock(start: Date(timeIntervalSince1970: 1_800_000_000)),
            identifiers: SequentialIdentifierGenerator(prefix: idPrefix),
            appVersion: "1.0.0-test",
            minimumReaderVersion: "1.0.0"
        )
    }

    // MARK: Packages

    struct Workspace {
        let root: URL
        let sourcePDF: URL
        let packageURL: URL
    }

    static func makeWorkspace(_ label: String = "ZPDFPersistence") throws -> Workspace {
        let root = try makeTemporaryDirectory(label)
        let sourcePDF = try makeSourcePDF(in: root.appendingPathComponent("source", isDirectory: true))
        return Workspace(
            root: root,
            sourcePDF: sourcePDF,
            packageURL: root.appendingPathComponent("Takeoff.zpdfproj", isDirectory: true)
        )
    }

    static func createPackage(
        _ workspace: Workspace,
        environment: PersistenceEnvironment? = nil
    ) async throws -> ProjectPackage {
        try await ProjectPackage.create(
            at: workspace.packageURL,
            displayName: "Takeoff",
            originalPDF: workspace.sourcePDF,
            pageCount: 1,
            environment: environment ?? Self.environment()
        )
    }

    // MARK: Seeding

    static let seedTimestamp = "2026-08-23T10:00:00.000Z"

    static func sampleGeometry(pointCount: Int = 24) throws -> Data {
        try GeometryBlob(
            kind: .polyline,
            points: (0..<pointCount).map { GeometryPoint(x: Double($0) * 3.5, y: Double($0) * 1.25) }
        ).encode()
    }

    /// Inserts one page and returns its identifier.
    @discardableResult
    static func insertPage(
        into package: ProjectPackage,
        pageIndex: Int = 0,
        identifier: String? = nil
    ) async throws -> String {
        let documentId = try await package.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM document LIMIT 1")
        }
        guard let documentId else {
            Issue.record("the package has no document row")
            return ""
        }
        let pageId = identifier ?? "page-\(pageIndex)"
        try await package.write { db in
            try PageRecord(
                id: pageId, documentId: documentId, pageIndex: pageIndex,
                mediaX: 0, mediaY: 0, mediaWidth: 1684, mediaHeight: 2384,
                cropX: 0, cropY: 0, cropWidth: 1684, cropHeight: 2384,
                rotation: 0
            ).insert(db)
        }
        return pageId
    }

    static func documentIdentifier(of package: ProjectPackage) async throws -> String {
        try await package.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM document LIMIT 1") ?? ""
        }
    }

    static func projectIdentifier(of package: ProjectPackage) async throws -> String {
        try await package.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM project LIMIT 1") ?? ""
        }
    }

    static func recoveryEntries(in packageURL: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(
            atPath: packageURL.member(ProjectPackageLayout.recovery).path
        ))?.sorted() ?? []
    }

    static func markupCount(inPackageAt url: URL) throws -> Int {
        // Read-write, because a WAL-mode database cannot be opened read-only without
        // the process being allowed to create its -shm. Nothing here writes.
        let queue = try DatabaseQueue(path: url.member(ProjectPackageLayout.database).path)
        defer { try? queue.close() }
        return try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM markup") ?? 0
        }
    }

    // MARK: Subprocess

    /// The `zpdf-save-harness` binary SwiftPM just built, next to the test bundle.
    static func harnessExecutableURL() throws -> URL {
        let bundleURL = Bundle(for: TestBundleAnchor.self).bundleURL
        let candidates = [
            bundleURL.deletingLastPathComponent().appendingPathComponent("zpdf-save-harness"),
            bundleURL.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("zpdf-save-harness")
        ]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        throw ZPDFPersistenceError.packageNotFound(
            path: "zpdf-save-harness near \(bundleURL.deletingLastPathComponent().path)"
        )
    }

    struct ProcessResult {
        let exitStatus: Int32
        /// The signal that killed the process, or `nil` for a normal exit.
        let terminatingSignal: Int32?
        let standardOutput: String
        let standardError: String

        var wasKilled: Bool { terminatingSignal == SIGKILL }
    }

    /// Runs the harness and waits for it, reporting how it died.
    static func runHarness(_ arguments: [String]) throws -> ProcessResult {
        let process = Process()
        process.executableURL = try harnessExecutableURL()
        process.arguments = arguments
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ProcessResult(
            exitStatus: process.terminationStatus,
            terminatingSignal: process.terminationReason == .uncaughtSignal
                ? process.terminationStatus
                : nil,
            standardOutput: String(decoding: outputData, as: UTF8.self),
            standardError: String(decoding: errorData, as: UTF8.self)
        )
    }

    // MARK: Statistics

    /// The p95 of a sample, by the nearest-rank method. No interpolation, so the value
    /// reported is a measurement that actually happened.
    static func percentile(_ samples: [Double], _ fraction: Double) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sorted = samples.sorted()
        let rank = Int((fraction * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank - 1, 0), sorted.count - 1)]
    }
}
