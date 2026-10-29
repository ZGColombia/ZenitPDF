import Foundation
import ZPDFVectorExtraction

/// Page geometry kept on disk between sessions (NL-AUTO-15), so a set-wide search on a reopened
/// drawing reads files instead of asking the extraction service to parse every page again.
///
/// The entries are `VectorExtractionCodec` files named after the drawing's SHA-256, the page and
/// the extractor version. A changed drawing has another SHA, and a new extractor another version,
/// so a stale entry is never read — it simply stops being asked for and ages out under the byte
/// budget, oldest first. A file that fails to decode is deleted and fetched again.
///
/// Where it lives: `Application Support/Zenit PDF/Geometry`, per user, beside the search indexes
/// — not inside the project package, whose manifest and crash-safe save exist for data a person
/// made. Geometry is derivable from the drawing; losing it costs one re-extraction, never work.
/// Outside the assembled bundle (tests, command-line runs) it is a per-process temporary
/// directory, the rule every store in this app follows.
struct PersistentExtractionStore: Sendable {

    let root: URL
    let documentDigest: String

    /// Total bytes the directory may hold before the oldest entries go.
    static let byteBudget = 512 * 1024 * 1024

    /// Overridable so tests keep out of the real container.
    @MainActor static var rootOverride: URL?

    @MainActor static var defaultRoot: URL {
        if let rootOverride { return rootOverride }
        if Bundle.main.bundleIdentifier == ZenitAppInfo.bundleIdentifier {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            return base
                .appendingPathComponent(ZenitAppInfo.displayName, isDirectory: true)
                .appendingPathComponent("Geometry", isDirectory: true)
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent(ZenitAppInfo.displayName, isDirectory: true)
            .appendingPathComponent("Geometry-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    }

    init(documentDigest: String, root: URL) {
        self.root = root
        self.documentDigest = documentDigest
    }

    func url(pageIndex: Int) -> URL {
        root.appendingPathComponent("\(documentDigest)-p\(pageIndex)-layeraware-v\(VectorExtractor.extractorVersion).zvx")
    }

    /// The stored extraction, or `nil`. A corrupt file is removed so it is fetched afresh.
    func load(pageIndex: Int) -> VectorPageExtraction? {
        let file = url(pageIndex: pageIndex)
        guard let data = try? Data(contentsOf: file) else { return nil }
        guard let extraction = try? VectorExtractionCodec.decode(data) else {
            try? FileManager.default.removeItem(at: file)
            return nil
        }
        // Touch it, so the budget keeps what is used.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return extraction
    }

    func save(_ extraction: VectorPageExtraction, pageIndex: Int) {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try VectorExtractionCodec.encode(extraction).write(to: url(pageIndex: pageIndex), options: .atomic)
            enforceBudget()
        } catch {
            // A cache that cannot be written is a cache that is empty next time, nothing more.
        }
    }

    /// Deletes the oldest entries until the directory fits the budget.
    func enforceBudget(byteBudget: Int = PersistentExtractionStore.byteBudget) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return }
        var entries = files.filter { $0.pathExtension == "zvx" }.compactMap { file -> (URL, Int, Date)? in
            guard let values = try? file.resourceValues(forKeys: Set(keys)) else { return nil }
            return (file, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.1 }
        entries.sort { $0.2 < $1.2 }
        for (file, size, _) in entries where total > byteBudget {
            try? FileManager.default.removeItem(at: file)
            total -= size
        }
    }
}
