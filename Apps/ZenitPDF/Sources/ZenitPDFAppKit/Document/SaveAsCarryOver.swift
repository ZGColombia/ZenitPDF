import Foundation
import ZPDFPersistence
import ZPDFAppCore
import ZPDFPDFKitBridge

/// What a Save As must carry from the open project package into the new one, beyond the
/// takeoff archive.
///
/// `ProjectPackage.create` clones only the original PDF into a fresh, empty package, and the
/// takeoff archive writes markups, stamps and presets — nothing else. So a Save As from
/// Project Mode left the site photographs and every imported stamp picture behind, and the
/// document then switched to the new package: the Inspector's photo rows went empty and every
/// artwork stamp drew with no artwork, while the person believed they had a complete copy
/// (BH-071).
enum SaveAsCarryOver {

    /// Copies every `stamp_artwork` row. Content-addressed, so `INSERT OR IGNORE` is exact:
    /// a row the new package already holds is the same bytes.
    @discardableResult
    static func copyArtwork(from source: ProjectPackage, to destination: ProjectPackage) async throws -> Int {
        // Through the persistence package's own API, so the app carries no database
        // dependency of its own (BH-071).
        try await source.copyStampArtwork(to: destination)
    }

    /// Copies the photo sidecar directory, file for file. Existing files at the destination
    /// are kept (content-addressed blobs), missing ones are copied.
    @discardableResult
    static func copyPhotos(fromPackage source: URL, toPackage destination: URL) throws -> Int {
        let from = photosDirectory(in: source)
        let to = photosDirectory(in: destination)
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: from.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return 0
        }
        try manager.createDirectory(at: to, withIntermediateDirectories: true)
        var copied = 0
        guard let enumerator = manager.enumerator(at: from, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return 0
        }
        let base = from.standardizedFileURL.path
        for case let item as URL in enumerator {
            let path = item.standardizedFileURL.path
            guard path.hasPrefix(base) else { continue }
            let relative = String(path.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !relative.isEmpty else { continue }
            let target = to.appendingPathComponent(relative)
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true {
                try manager.createDirectory(at: target, withIntermediateDirectories: true)
            } else if !manager.fileExists(atPath: target.path) {
                try manager.copyItem(at: item, to: target)
                copied += 1
            }
        }
        return copied
    }

    static func photosDirectory(in package: URL) -> URL {
        package
            .member(ProjectPackageLayout.attachments)
            .appendingPathComponent(PhotoStore.sidecarDirectoryName, isDirectory: true)
    }

    /// Whether two file URLs name the same item on disk, however they are spelled.
    ///
    /// Compared by file identity first — a symlinked folder, `/tmp` against `/private/tmp`,
    /// or an alias all resolve to one inode — and by the standardised, symlink-resolved path
    /// when the item does not exist yet. A raw `==` sent a Save As onto the open package down
    /// the "new package" branch, which deleted the live package and then tried to clone its
    /// PDF out of it (BH-070).
    ///
    /// One rule decides "the same file" everywhere (S-012): this is
    /// `StagedFileReplacement.sameItem`, the comparison every derived-copy writer uses.
    static func sameItem(_ a: URL, _ b: URL?) -> Bool {
        guard let b else { return false }
        return StagedFileReplacement.sameItem(a, b)
    }

    /// Whether `item` lives inside `directory` (after resolving symlinks).
    static func isInside(_ item: URL, _ directory: URL) -> Bool {
        let child = item.standardizedFileURL.resolvingSymlinksInPath().path
        let parent = directory.standardizedFileURL.resolvingSymlinksInPath().path
        return child.hasPrefix(parent.hasSuffix("/") ? parent : parent + "/")
    }
}
