import CoreGraphics
import Foundation

/// Hit and miss counts for a ``ThumbnailCache``.
public struct ThumbnailCacheStatistics: Sendable, Hashable, Codable {
    public var hits: Int
    public var misses: Int
    public var evictions: Int
    public var count: Int
    public var capacity: Int
    /// Bytes of decoded image currently retained.
    public var residentByteCount: Int
    /// The byte ceiling the cache evicts to stay under.
    public var byteCapacity: Int

    public init(
        hits: Int = 0,
        misses: Int = 0,
        evictions: Int = 0,
        count: Int = 0,
        capacity: Int = 0,
        residentByteCount: Int = 0,
        byteCapacity: Int = 0
    ) {
        self.hits = hits
        self.misses = misses
        self.evictions = evictions
        self.count = count
        self.capacity = capacity
        self.residentByteCount = residentByteCount
        self.byteCapacity = byteCapacity
    }
}

/// A bounded least-recently-used cache of rendered thumbnails.
///
/// Keyed by the document's SHA-256 rather than by its handle or URL, so the same drawing
/// opened twice, moved, or copied into a `.zpdfproj` package shares one cache entry, and
/// a *different* file at the same path never returns a stale image.
///
/// This is a value type. Recency is a monotonically increasing counter rather than a
/// timestamp, so behaviour is identical on every run without injecting a clock, and there
/// is no shared mutable state to make `Sendable` by hand.
public struct ThumbnailCache: Sendable {

    /// What makes one thumbnail different from another.
    public struct Key: Sendable, Hashable, Codable {
        public let documentSHA256: String
        public let pageIndex: Int
        public let box: PDFPageBox
        public let pixelWidth: Int
        public let pixelHeight: Int
        /// The annotation display state the image was drawn under: empty for the file's own
        /// state, otherwise a fingerprint of the annotations layer visibility has hidden.
        ///
        /// `PDFPage.draw(with:to:)` honours `PDFAnnotation.shouldDisplay`, which
        /// ``PDFKitDocumentProvider/applyAnnotationLayerVisibility(of:bindings:hiddenLayerIDs:)``
        /// flips. Without this component a thumbnail cached before a layer toggle kept showing
        /// the hidden annotations (or kept missing them after the layer came back), and one
        /// handle's view state leaked into another handle's thumbnails of the same file
        /// (BH-173, BH-180, BH-181).
        public let displayState: String

        public init(
            documentSHA256: String,
            pageIndex: Int,
            box: PDFPageBox,
            pixelWidth: Int,
            pixelHeight: Int,
            displayState: String = ""
        ) {
            self.documentSHA256 = documentSHA256
            self.pageIndex = pageIndex
            self.box = box
            self.pixelWidth = pixelWidth
            self.pixelHeight = pixelHeight
            self.displayState = displayState
        }

        private enum CodingKeys: String, CodingKey {
            case documentSHA256, pageIndex, box, pixelWidth, pixelHeight, displayState
        }

        /// Decodes keys written before ``displayState`` existed as the file's own state.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                documentSHA256: try container.decode(String.self, forKey: .documentSHA256),
                pageIndex: try container.decode(Int.self, forKey: .pageIndex),
                box: try container.decode(PDFPageBox.self, forKey: .box),
                pixelWidth: try container.decode(Int.self, forKey: .pixelWidth),
                pixelHeight: try container.decode(Int.self, forKey: .pixelHeight),
                displayState: try container.decodeIfPresent(String.self, forKey: .displayState) ?? ""
            )
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(documentSHA256, forKey: .documentSHA256)
            try container.encode(pageIndex, forKey: .pageIndex)
            try container.encode(box, forKey: .box)
            try container.encode(pixelWidth, forKey: .pixelWidth)
            try container.encode(pixelHeight, forKey: .pixelHeight)
            try container.encode(displayState, forKey: .displayState)
        }
    }

    private struct Entry {
        let image: CGImage
        let byteCount: Int
        var recency: UInt64
    }

    private var entries: [Key: Entry] = [:]
    private var clock: UInt64 = 0
    private var hits = 0
    private var misses = 0
    private var evictions = 0
    private var totalBytes = 0

    /// Maximum number of images held. Zero disables the cache entirely, which is a
    /// supported configuration: every lookup then misses and nothing is retained.
    public private(set) var capacity: Int

    /// Maximum bytes of decoded image held. A count cap alone is not a memory bound: 512
    /// entries of a 2048² page are about 8.6 GB, so the cache is bounded by bytes as well
    /// and evicts least-recently-used entries to stay under it (CR-83).
    public private(set) var byteCapacity: Int

    /// The default byte ceiling: 256 MB, roughly sixteen 2048² pages.
    public static let defaultByteCapacity = 256 * 1024 * 1024

    public init(capacity: Int = 256, byteCapacity: Int = ThumbnailCache.defaultByteCapacity) {
        self.capacity = max(0, capacity)
        self.byteCapacity = max(0, byteCapacity)
        entries.reserveCapacity(min(self.capacity, 1024))
    }

    public var count: Int { entries.count }

    /// Bytes of decoded image currently retained.
    public var residentByteCount: Int { totalBytes }

    public var statistics: ThumbnailCacheStatistics {
        ThumbnailCacheStatistics(
            hits: hits,
            misses: misses,
            evictions: evictions,
            count: entries.count,
            capacity: capacity,
            residentByteCount: totalBytes,
            byteCapacity: byteCapacity
        )
    }

    /// The decoded byte footprint of a `CGImage`: its row stride times its height.
    static func byteCount(of image: CGImage) -> Int {
        image.bytesPerRow * image.height
    }

    /// Looks a thumbnail up, recording a hit or a miss and refreshing recency on a hit.
    public mutating func value(for key: Key) -> CGImage? {
        guard var entry = entries[key] else {
            misses += 1
            return nil
        }
        hits += 1
        clock &+= 1
        entry.recency = clock
        entries[key] = entry
        return entry.image
    }

    /// Inserts an image, evicting least-recently-used entries until the cache is within both
    /// its count capacity and its byte budget.
    public mutating func insert(_ image: CGImage, for key: Key) {
        guard capacity > 0, byteCapacity > 0 else { return }
        clock &+= 1
        if let existing = entries.removeValue(forKey: key) {
            totalBytes -= existing.byteCount
        }
        let byteCount = Self.byteCount(of: image)
        // A single image larger than the whole budget is not cached: retaining it would
        // guarantee the cache is always over budget.
        guard byteCount <= byteCapacity else { return }
        entries[key] = Entry(image: image, byteCount: byteCount, recency: clock)
        totalBytes += byteCount
        evictToLimits()
    }

    /// Drops every entry whose key belongs to `documentSHA256`.
    ///
    /// Called when a document is closed, so the cache does not pin the pixels of a
    /// drawing set nobody has open.
    public mutating func removeAll(forDocumentSHA256 documentSHA256: String) {
        for (key, entry) in entries where key.documentSHA256 == documentSHA256 {
            totalBytes -= entry.byteCount
            entries.removeValue(forKey: key)
        }
    }

    public mutating func removeAll() {
        entries.removeAll(keepingCapacity: true)
        totalBytes = 0
    }

    /// Evicts least-recently-used entries until the cache is within both its count capacity
    /// and its byte budget.
    private mutating func evictToLimits() {
        // Bounded: each pass removes exactly one entry, and `entries.count` decreases.
        while entries.count > capacity || totalBytes > byteCapacity {
            guard let victim = entries.min(by: { $0.value.recency < $1.value.recency })?.key,
                  let removed = entries.removeValue(forKey: victim) else {
                return
            }
            totalBytes -= removed.byteCount
            evictions += 1
        }
    }
}
