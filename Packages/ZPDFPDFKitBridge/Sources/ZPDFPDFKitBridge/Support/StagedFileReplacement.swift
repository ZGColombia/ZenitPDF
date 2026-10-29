import Foundation

/// The one way a finished copy reaches the user's folder: written in a private staging folder on
/// the destination's volume, then swapped into place — and never over the file it was made from
/// (R-103, R-114).
///
/// Redaction and form fill each carried their own copy of these steps. Two of the three left the
/// hidden staging file behind when the final move failed, and none of them refused a destination
/// that was the source itself, so a Save panel pointed at the drawing and confirmed with Replace
/// swapped the original for its redacted picture copy. Every other writer in the product already
/// refused that case.
///
/// The staging file used to be a hidden sibling of the destination (`.zpdf-redact-…` beside it).
/// In the sandboxed app a save panel grants the chosen file and nothing beside it, so that
/// sibling was refused with "Operation not permitted" at every place a person could choose
/// (C-09). It is now staged in the system's item-replacement folder for the
/// destination (`FileManager.url(for: .itemReplacementDirectory, …)`), which the sandbox lets the
/// app write and which lies on the destination's volume, so the final step is a rename.
public enum StagedFileReplacement {

    /// Whether two file URLs name the same item on disk, however they are spelled: by the
    /// standardised, symlink-resolved path, and — when both exist — by the file system's own
    /// identifier, so a symlink, a `/private` prefix or a hard link cannot smuggle a write onto the
    /// original.
    public static func sameItem(_ a: URL, _ b: URL) -> Bool {
        let first = a.standardizedFileURL.resolvingSymlinksInPath()
        let second = b.standardizedFileURL.resolvingSymlinksInPath()
        if first.path == second.path { return true }
        if let idA = try? first.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier,
           let idB = try? second.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier {
            return idA.isEqual(idB)
        }
        return false
    }

    /// Throws `refusal` when `destination` is any of `sources`.
    public static func refuseOverwriting(
        _ sources: [URL], with destination: URL, refusal: @autoclosure () -> any Error
    ) throws {
        if sources.contains(where: { sameItem($0, destination) }) { throw refusal() }
    }

    /// A new, empty private folder to stage a file bound for `destination` in, on the
    /// destination's volume where the system provides one: the item-replacement folder for it,
    /// else a fresh folder in the process's temporary directory. Never in the destination's own
    /// folder, which a sandboxed save panel does not grant (C-09). The caller removes it.
    public static func stagingDirectory(appropriateFor destination: URL) throws -> URL {
        let manager = FileManager.default
        if let directory = try? manager.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true
        ) {
            return directory
        }
        let directory = manager.temporaryDirectory.appendingPathComponent("zpdf-staging-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Writes a copy to `destination` through a staging file in a private folder
    /// (``stagingDirectory(appropriateFor:)``), then moves or swaps it into place.
    ///
    /// - Parameters:
    ///   - sources: files the copy is made from; a destination that is one of them throws
    ///     `refusal` before anything is written.
    ///   - stagingPrefix: the staging file's name prefix, such as `.zpdf-redact-`.
    ///   - write: writes the finished copy to the URL it is given.
    ///
    /// Nothing but `destination` itself is written in the destination's folder. When `write` or
    /// the final move fails, the staging folder is removed and the error rethrown; the
    /// destination is either untouched or wholly replaced.
    public static func write(
        to destination: URL,
        protecting sources: [URL],
        refusal: @autoclosure () -> any Error,
        stagingPrefix: String,
        _ write: (URL) throws -> Void
    ) throws {
        try refuseOverwriting(sources, with: destination, refusal: refusal())
        let manager = FileManager.default
        let folder = try stagingDirectory(appropriateFor: destination)
        defer { try? manager.removeItem(at: folder) }
        let staging = folder.appendingPathComponent(
            "\(stagingPrefix)\(UUID().uuidString).\(destination.pathExtension.isEmpty ? "tmp" : destination.pathExtension)"
        )
        try write(staging)
        try place(staging, at: destination)
    }

    /// Moves a finished staged file to `destination`: swapped in with `replaceItemAt` when
    /// something is there (the destination is never removed first, so a failure leaves it as it
    /// was), moved when nothing is. The one placement step every staged writer ends with — the
    /// PDFKit write path, the repair service's hand-off and the structure-preserving Marked
    /// export among them (V-051, V-056).
    public static func place(_ staged: URL, at destination: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: staged)
        } else {
            try manager.moveItem(at: staged, to: destination)
        }
    }
}
