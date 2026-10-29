import Foundation
import ZPDFServiceClient
import UniformTypeIdentifiers

/// The repair flow: a drawing that fails to open is offered as "Repair a Copy…",
/// rebuilt by the sandboxed `RepairService` into the app container — the original file is
/// never written to, moved, or reopened for writing.
///
/// One shared client for the whole process, exactly like ``GeometryExtraction``: in the
/// assembled bundle it talks to `RepairService.xpc` (embedded and signed since S15, unused
/// until this flow existed).
///
/// ### Why there is no in-process fallback here
///
/// `ZPDFRepairServiceClient.automatic()` is the *no-fallback* constructor on purpose. The
/// in-process path runs qpdf inside the calling process, and its only conformance lives in
/// `ZPDFRepairServiceCore`, a target the application deliberately does not link (S17-03).
/// Linking it to make a test pass would put qpdf inside the app and quietly
/// undo the sandboxing claim that is the whole reason `RepairService.xpc` exists.
///
/// So the seam is ``clientOverride`` instead, and the suite that uses it points at the
/// `zpdf-repair-worker` **child process** — the same service handler, across a real process
/// boundary, with qpdf still outside the test binary. The shipping application never assigns
/// the override, and a source gate in `SearchAndOCRWiringTests` fails if it ever does.
@MainActor
enum DamagedDrawingRepair {

    /// The process-wide client. Talks to `RepairService.xpc`; nothing else.
    private static let embeddedServiceClient = ZPDFRepairServiceClient.automatic()

    /// Test-only injection point. `nil` in the shipping application, always.
    ///
    /// A `swift test` process is not an application bundle, so `NSXPCConnection(serviceName:)`
    /// cannot find `RepairService.xpc` and every repair fails with "couldn't communicate with a
    /// helper application" — which is what this flow's regression test was doing until this
    /// seam existed.
    static var clientOverride: ZPDFRepairServiceClient?

    static var client: ZPDFRepairServiceClient { clientOverride ?? embeddedServiceClient }

    /// Where repaired copies land. Overridable so tests keep out of the real container.
    static var repairedCopiesRootOverride: URL?

    /// `Application Support/Zenit PDF/Repaired` — inside the container, never beside the
    /// user's drawing. Outside the assembled bundle the root falls back to the temporary
    /// directory, for the same reason as the autosave root: a test process must never
    /// write into the user's real Application Support.
    static var repairedCopiesRoot: URL {
        if let repairedCopiesRootOverride { return repairedCopiesRootOverride }
        let base: URL
        if Bundle.main.bundleIdentifier == ZenitAppInfo.bundleIdentifier {
            base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
        } else {
            base = FileManager.default.temporaryDirectory
        }
        return base
            .appendingPathComponent(ZenitAppInfo.displayName, isDirectory: true)
            .appendingPathComponent("Repaired", isDirectory: true)
    }

    /// Whether a failed open is worth the repair offer: a plain PDF, still present on
    /// disk **and readable**. Project packages and unknown types keep the plain error —
    /// repair rebuilds PDF structure, nothing else — and a file this process cannot even
    /// read is a permissions problem, not damage: repairing it would
    /// fail exactly the way opening it did.
    static func canOffer(for url: URL, afterLoadFailure error: any Error) -> Bool {
        guard url.pathExtension.lowercased() == "pdf" else { return false }
        if case ZenitDocumentError.unsupportedFileType = error { return false }
        // LT-38: a drawing that stayed locked is not damaged, and "Repair a Copy…" of an
        // encrypted file both misdiagnoses the refusal and cannot succeed.
        if case ZenitDocumentError.passwordRequired = error { return false }
        if case ZenitDocumentError.wrongPassword = error { return false }
        return FileManager.default.fileExists(atPath: url.path)
            && FileManager.default.isReadableFile(atPath: url.path)
    }

    /// Output paths a repair in flight has claimed but not yet written.
    private static var reservedOutputs: Set<String> = []

    /// The first free "(repaired)" name, free on disk **and** unclaimed by a repair still
    /// running, claimed before the caller awaits anything.
    static func reserveOutput(for source: URL, in directory: URL) -> URL {
        let base = source.deletingPathExtension().lastPathComponent
        var output = directory.appendingPathComponent("\(base) (repaired).pdf")
        var counter = 2
        while FileManager.default.fileExists(atPath: output.path)
                || reservedOutputs.contains(output.standardizedFileURL.path) {
            output = directory.appendingPathComponent("\(base) (repaired \(counter)).pdf")
            counter += 1
        }
        reservedOutputs.insert(output.standardizedFileURL.path)
        return output
    }

    /// Releases a claim. For tests that reserve without repairing.
    static func releaseOutput(_ url: URL) {
        reservedOutputs.remove(url.standardizedFileURL.path)
    }

    /// Rebuilds a structurally correct copy of `source` and returns where it was written.
    ///
    /// The original's bytes are asserted untouched by the regression test, not just
    /// promised here: the service reads through an inherited read-only descriptor and
    /// writes only to the fresh output file.
    static func repairCopy(of source: URL) async throws -> URL {
        let directory = repairedCopiesRoot
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = reserveOutput(for: source, in: directory)
        // Held until the service has finished: two repairs of one file both found
        // "(repaired).pdf" free before either wrote it, and one overwrote the other (BH-912).
        defer { reservedOutputs.remove(output.standardizedFileURL.path) }
        do {
            _ = try await client.repair(input: source, output: output)
        } catch {
            throw ZenitDocumentError.repairFailed(
                source.lastPathComponent,
                detail: String(describing: error)
            )
        }
        guard FileManager.default.fileExists(atPath: output.path) else {
            throw ZenitDocumentError.repairFailed(
                source.lastPathComponent,
                detail: "the repair service reported success but wrote no file"
            )
        }
        return output
    }
}

extension ZenitPDFProjectDocument {

    /// What a load failure actually is, so the alert can say the right thing: a file the
    /// process cannot *read* — a bare `argv` launch with no sandbox extension, or plain POSIX
    /// permissions — is not damage, and offering to
    /// repair it both misdiagnoses the problem and guarantees a second failure.
    public enum LoadFailureDiagnosis: Equatable, Sendable {
        /// The file exists but this process has no permission to read it: offer to
        /// grant access through an open panel.
        case unreadable
        /// The file was read and failed to parse: offer "Repair a Copy…".
        case damaged
        /// Anything else keeps the plain error.
        case plain
    }

    /// Classifies the load failure of `url`.
    public static func diagnoseLoadFailure(for url: URL, error: any Error) -> LoadFailureDiagnosis {
        if url.pathExtension.lowercased() == "pdf",
           FileManager.default.fileExists(atPath: url.path),
           !FileManager.default.isReadableFile(atPath: url.path) {
            return .unreadable
        }
        return DamagedDrawingRepair.canOffer(for: url, afterLoadFailure: error) ? .damaged : .plain
    }

    /// Repairs a copy of `source` into the app container and returns its location.
    public static func repairCopy(of source: URL) async throws -> URL {
        try await DamagedDrawingRepair.repairCopy(of: source)
    }
}
