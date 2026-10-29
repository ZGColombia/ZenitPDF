import Foundation
import ZPDFSpreadsheet

/// "Send Project…" (NL-PLAT-10): the project as one `.zip` a colleague can open, with nothing in
/// it that would make their copy think it crashed.
///
/// The archive is made from `versions/latest` — the package exactly as the last completed save
/// wrote it — never from the live directory, whose database is being written
/// while the project is open. It leaves out `recovery/` (the crash marker, the journal, the
/// autosave database) and `versions/`, so the copy opens as a clean project with no recovery prompt.
/// Entries are stored, not compressed: the drawings are already compressed PDFs, and a stored
/// archive is one any unzip reads.
extension ProjectPackage {

    public enum SendArchiveError: Error, Equatable, Sendable, CustomStringConvertible {
        case notSavedYet
        case tooLarge(path: String)
        case unreadable(path: String)
        /// A member whose name cannot travel safely in a zip (a backslash, a NUL, a `.` or
        /// `..` step), refused rather than written as a path another tool would misplace.
        case unsafeName(path: String)

        public var description: String {
            switch self {
            case .notSavedYet: return "The project has not been saved yet, so there is no finished copy to send. Save it first."
            case let .tooLarge(path): return "“\(path)” is larger than 4 GB, which a plain zip archive cannot hold."
            case let .unreadable(path): return "“\(path)” could not be read."
            case let .unsafeName(path): return "“\(path)” has a name that cannot be stored safely in a zip archive."
            }
        }
    }

    /// Members never sent: `recovery/` and `versions/` describe this machine's session, not the
    /// project; `thumbnails/` and `QuickLook/` describe the save *before* the last one.
    ///
    /// S-118. The app writes the Quick Look picture, the preview sheet, the totals summary and
    /// the Finder thumbnail after the save returns, and the save's step 8 had already cloned the
    /// live package into `versions/latest`; so `latest` always carried the previous save's
    /// pictures and totals beside this save's database, and a colleague's Finder or Space-bar
    /// preview of a sent project showed numbers the project inside did not hold. Left out, the
    /// preview falls back to the drawing until the recipient's first save writes fresh ones.
    public static let sendArchiveExclusions: [String] = [
        ProjectPackageLayout.recovery, ProjectPackageLayout.versions,
        ProjectPackageLayout.thumbnails, ProjectPackageLayout.finderQuickLook
    ]

    /// Writes the last saved state of the project to `destination` as a zip whose single top-level
    /// folder is `<name>.zpdfproj`. Returns the package-relative paths written, in archive order.
    @discardableResult
    public func writeSendArchive(to destination: URL, packageName: String) async throws -> [String] {
        await drainActiveSave()
        let source = url.member(ProjectPackageLayout.versions).appendingPathComponent("latest", isDirectory: true)
        guard FileManager.default.fileExists(atPath: source.appendingPathComponent(ProjectPackageLayout.manifest).path) else {
            throw SendArchiveError.notSavedYet
        }
        // The package's standard directories travel empty where their contents stay behind, so
        // the copy has the shape `open` expects (it writes its own crash marker into recovery/).
        return try Self.zip(directory: source, as: packageName, excluding: Self.sendArchiveExclusions,
                            emptyDirectories: ProjectPackageLayout.directories, to: destination)
    }

    /// Stored-entry zip of `directory`, every path under `rootName/`, skipping top-level members
    /// named in `excluding`. Deterministic order (sorted paths); symbolic links are not followed.
    ///
    /// Written through ``ZipStoredStreamWriter`` (R-212): the records and the CRC-32 are the
    /// spreadsheet package's, the one stored-zip format in the code base. This file used to
    /// hand-build the same local headers, central directory and end record, with a third copy
    /// of CRC-32 beside the two the code base already had.
    static func zip(directory: URL, as rootName: String, excluding: [String], emptyDirectories: [String] = [],
                    to destination: URL) throws -> [String] {
        var files: [(relative: String, url: URL?)] = emptyDirectories.sorted().map { ($0, nil) }
        let base = directory.standardizedFileURL.path
        if let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
            for case let item as URL in enumerator {
                let values = try item.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                var relative = String(item.standardizedFileURL.path.dropFirst(base.count))
                while relative.hasPrefix("/") { relative.removeFirst() }
                let top = relative.split(separator: "/").first.map(String.init) ?? relative
                if excluding.contains(top) { continue }
                files.append((relative, item))
            }
        }
        files.sort { ($0.url == nil ? 0 : 1, $0.relative) < ($1.url == nil ? 0 : 1, $1.relative) }

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: destination) else { throw SendArchiveError.unreadable(path: destination.lastPathComponent) }
        defer { try? handle.close() }
        var writer = ZipStoredStreamWriter(writingTo: handle)
        func translated(_ error: ZipStoredWriter.WriteError, _ path: String) -> SendArchiveError {
            switch error {
            case .tooLarge: return .tooLarge(path: path)
            case .duplicateEntry, .unsafeName: return .unsafeName(path: path)
            }
        }
        for file in files {
            let name = "\(rootName)/\(file.relative)"
            do {
                if let source = file.url {
                    guard let data = try? Data(contentsOf: source, options: .mappedIfSafe) else {
                        throw SendArchiveError.unreadable(path: file.relative)
                    }
                    try writer.addFile(name, data: data)
                } else {
                    try writer.addDirectory(name)   // a directory entry: "name/", no bytes
                }
            } catch let error as ZipStoredWriter.WriteError {
                throw translated(error, file.relative)
            }
        }
        do {
            try writer.finish()
        } catch let error as ZipStoredWriter.WriteError {
            throw translated(error, rootName)
        }
        return files.filter { $0.url != nil }.map(\.relative)
    }
}
