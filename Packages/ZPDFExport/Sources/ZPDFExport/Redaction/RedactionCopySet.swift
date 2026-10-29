import Foundation
import ZPDFPDFKitBridge

/// Apply Redactions over several drawings: one redacted copy of each, written into one folder
/// the person chose, all or nothing (C-09).
///
/// # Why a folder
///
/// The app is sandboxed with `com.apple.security.files.user-selected.read-write` only. A save
/// panel grants the file it names and nothing beside it, so a second copy
/// written beside the chosen one — the first answer to C-09 — was refused with "Operation not
/// permitted" in the shipped app, after the first copy had already been written. An open panel
/// that chooses a folder grants everything inside it, so every copy of the set goes there, as
/// Split into Sheets and Process PDF Files already do.
///
/// # All or nothing
///
/// Every copy is built and proved in a private staging folder first
/// (``StagedFileReplacement/stagingDirectory(appropriateFor:)``) and moved into the folder only
/// when all of them succeeded. A drawing that cannot be redacted, or a move that fails, leaves
/// no copy of the set in the folder: the ones already moved are removed again, and the error
/// names the drawing (``RedactionRefusal/copyFailed(drawing:reason:)``). A copy never takes the
/// name of a file already in the folder, so removing one never removes anything else.
public enum RedactionCopySet {

    /// Where each copy is written: `<name> — <suffix>.pdf` in `folder`, numbered past a file
    /// already there or a name an earlier copy of this set took. A character that cannot stand in
    /// a file name (`/`, `:` and the like) becomes `-`, so a drawing's name can never reach
    /// outside the folder.
    public static func targets(named names: [String], suffix: String, in folder: URL) -> [URL] {
        var taken: Set<String> = []
        return names.map { name in
            // No leading dot either: the copy would be a hidden file.
            let safe = String(String(name.map { "/:\\?%*|\"<>".contains($0) ? "-" : $0 })
                .trimmingCharacters(in: .whitespacesAndNewlines).drop { $0 == "." })
            let base = (safe.isEmpty ? "Drawing" : safe) + " — " + suffix
            var candidate = folder.appendingPathComponent(base + ".pdf")
            var number = 2
            while taken.contains(candidate.lastPathComponent.lowercased())
                    || FileManager.default.fileExists(atPath: candidate.path) {
                candidate = folder.appendingPathComponent("\(base) \(number).pdf")
                number += 1
            }
            taken.insert(candidate.lastPathComponent.lowercased())
            return candidate
        }
    }

    /// Writes one copy per name into `folder` (``targets(named:suffix:in:)``), all or nothing.
    ///
    /// - Parameters:
    ///   - names: each drawing's name, in the order the copies are made.
    ///   - sources: the files the copies are made from; no copy may land on one of them.
    ///   - make: redacts drawing `index` into the staging file it is given and returns its outcome.
    /// - Returns: each copy's final location with its outcome, in `names` order.
    public static func write<Outcome: Sendable>(
        names: [String],
        suffix: String = "Redacted",
        into folder: URL,
        protecting sources: [URL],
        isolation: isolated (any Actor)? = #isolation,
        _ make: (_ index: Int, _ staging: URL) async throws -> Outcome
    ) async throws -> [(output: URL, outcome: Outcome)] {
        guard !names.isEmpty else { throw RedactionRefusal.noMarks }
        let targets = targets(named: names, suffix: suffix, in: folder)
        for target in targets {
            try StagedFileReplacement.refuseOverwriting(sources, with: target, refusal: RedactionRefusal.outputIsSource)
        }
        let manager = FileManager.default
        let staging = try StagedFileReplacement.stagingDirectory(appropriateFor: folder)
        defer { try? manager.removeItem(at: staging) }

        var outcomes: [Outcome] = []
        for index in names.indices {
            let staged = staging.appendingPathComponent("copy-\(index).pdf")
            do {
                outcomes.append(try await make(index, staged))
            } catch {
                throw RedactionRefusal.copyFailed(drawing: names[index], reason: reason(error))
            }
        }
        var moved: [URL] = []
        for index in names.indices {
            do {
                // Never over anything: a file that appeared at the name since it was chosen fails
                // the move, and the set is rolled back rather than written over it.
                try manager.moveItem(at: staging.appendingPathComponent("copy-\(index).pdf"), to: targets[index])
                moved.append(targets[index])
            } catch {
                for url in moved { try? manager.removeItem(at: url) }
                throw RedactionRefusal.copyFailed(drawing: names[index], reason: reason(error))
            }
        }
        return Array(zip(targets, outcomes)).map { (output: $0.0, outcome: $0.1) }
    }

    private static func reason(_ error: any Error) -> String {
        if let refusal = error as? RedactionRefusal { return refusal.description }
        return error.localizedDescription
    }
}
