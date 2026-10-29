import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A second, on-disk tier under ``ThumbnailCache``, so a drawing opened again shows its page
/// thumbnails without rasterising every page through PDFKit a second time (IM-073).
///
/// # What keeps it honest
///
/// - **Keyed by the drawing's SHA-256.** Each drawing's thumbnails live in a directory named by
///   its digest, so a changed file — one byte is enough — can never be answered with a stale
///   picture: it has a different digest and therefore a different directory.
/// - **Only the file's own display state is stored.** A thumbnail drawn while layer visibility
///   hides annotations is view state; it stays in memory (``ThumbnailCache/Key/displayState``)
///   and is never written here.
/// - **Bounded.** The directory is trimmed to ``byteCapacity``, oldest first.
/// - **Local only.** The directory is chosen by the caller — the container's `Caches` — and
///   nothing here touches the network or the project package, so a save never clones it.
/// - **A file read back is input again.** A PNG whose decoded size differs from the key it is
///   stored under is discarded and deleted rather than shown.
public struct ThumbnailDiskCache: Sendable {

    /// The root directory; one subdirectory per drawing digest.
    public let directory: URL
    /// The byte ceiling the directory is trimmed to.
    public let byteCapacity: Int

    /// The default ceiling: 256 MB.
    public static let defaultByteCapacity = 256 * 1024 * 1024

    public init(directory: URL, byteCapacity: Int = ThumbnailDiskCache.defaultByteCapacity) {
        self.directory = directory
        self.byteCapacity = max(0, byteCapacity)
    }

    /// Where a key's image lives, or `nil` for a key this tier does not store.
    func fileURL(for key: ThumbnailCache.Key) -> URL? {
        guard key.displayState.isEmpty,
              key.documentSHA256.utf8.count == 64,
              key.documentSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              key.pageIndex >= 0, key.pixelWidth > 0, key.pixelHeight > 0
        else { return nil }
        return directory
            .appendingPathComponent(key.documentSHA256, isDirectory: true)
            .appendingPathComponent(
                "\(key.pageIndex)-\(key.box.rawValue)-\(key.pixelWidth)x\(key.pixelHeight).png",
                isDirectory: false
            )
    }

    /// The stored image for `key`, or `nil`.
    func load(_ key: ThumbnailCache.Key) -> CGImage? {
        guard let url = fileURL(for: key),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == key.pixelWidth, image.height == key.pixelHeight
        else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        // Touch it, so trimming removes the least recently *used* images first.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return image
    }

    /// Writes `image` for `key`, atomically. Failures are silent: the disk tier is an
    /// optimisation, and a full disk must not fail a thumbnail request.
    func store(_ image: CGImage, for key: ThumbnailCache.Key) {
        guard let url = fileURL(for: key) else { return }
        let manager = FileManager.default
        do {
            try manager.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
        } catch { return }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil
        ) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return }
        try? (output as Data).write(to: url, options: .atomic)
    }

    /// Deletes the oldest images until the directory is within ``byteCapacity``.
    ///
    /// - Returns: how many files were removed.
    @discardableResult
    func trim() -> Int {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = manager.enumerator(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return 0 }
        var files: [(url: URL, size: Int, date: Date)] = []
        var total = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            let size = values.fileSize ?? 0
            files.append((url, size, values.contentModificationDate ?? .distantPast))
            total += size
        }
        guard total > byteCapacity else { return 0 }
        var removed = 0
        for file in files.sorted(by: { $0.date < $1.date }) where total > byteCapacity {
            if (try? manager.removeItem(at: file.url)) != nil {
                total -= file.size
                removed += 1
            }
        }
        return removed
    }
}
