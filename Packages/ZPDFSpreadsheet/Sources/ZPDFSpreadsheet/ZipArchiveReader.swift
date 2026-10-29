import Compression
import Foundation

/// Limits applied to an untrusted zip before a single entry is inflated.
public struct ZipLimits: Sendable, Equatable {
    /// Entries in the central directory.
    public var maximumEntryCount: Int
    /// Uncompressed bytes of one entry.
    public var maximumEntryBytes: Int
    /// Uncompressed bytes of every entry together.
    public var maximumTotalBytes: Int
    /// Uncompressed ÷ compressed, per entry. Real spreadsheets compress XML about 10–30×; a zip
    /// bomb compresses thousands of times.
    public var maximumCompressionRatio: Int

    public init(maximumEntryCount: Int = 10_000, maximumEntryBytes: Int = 256 * 1024 * 1024,
                maximumTotalBytes: Int = 512 * 1024 * 1024, maximumCompressionRatio: Int = 200) {
        self.maximumEntryCount = maximumEntryCount
        self.maximumEntryBytes = maximumEntryBytes
        self.maximumTotalBytes = maximumTotalBytes
        self.maximumCompressionRatio = maximumCompressionRatio
    }

    public static let standard = ZipLimits()
}

/// Why a zip was refused. Each case says what was found and what the limit is.
public enum ZipError: Error, Equatable, Sendable, CustomStringConvertible {
    case notAZip
    case truncated
    case unsupportedZip64
    case encrypted(entry: String)
    case unsupportedMethod(entry: String, method: Int)
    case tooManyEntries(count: Int, limit: Int)
    case entryTooLarge(entry: String, bytes: Int, limit: Int)
    case totalTooLarge(bytes: Int, limit: Int)
    case suspiciousRatio(entry: String, ratio: Int, limit: Int)
    case inflateFailed(entry: String)
    case sizeMismatch(entry: String, declared: Int, actual: Int)
    case checksumMismatch(entry: String)
    case missingEntry(String)

    public var description: String {
        switch self {
        case .notAZip: return "the file is not a zip archive"
        case .truncated: return "the archive is truncated"
        case .unsupportedZip64: return "the archive uses ZIP64, which is larger than a spreadsheet this build reads"
        case let .encrypted(entry): return "“\(entry)” is encrypted"
        case let .unsupportedMethod(entry, method): return "“\(entry)” uses compression method \(method)"
        case let .tooManyEntries(count, limit): return "the archive has \(count) entries; the limit is \(limit)"
        case let .entryTooLarge(entry, bytes, limit): return "“\(entry)” expands to \(bytes) bytes; the limit is \(limit)"
        case let .totalTooLarge(bytes, limit): return "the archive expands to \(bytes) bytes; the limit is \(limit)"
        case let .suspiciousRatio(entry, ratio, limit): return "“\(entry)” expands \(ratio)×; the limit is \(limit)× (a zip bomb looks like this)"
        case let .inflateFailed(entry): return "“\(entry)” could not be decompressed"
        case let .sizeMismatch(entry, declared, actual): return "“\(entry)” declares \(declared) bytes but holds \(actual)"
        case let .checksumMismatch(entry): return "“\(entry)” fails its checksum"
        case let .missingEntry(name): return "the archive has no “\(name)”"
        }
    }
}

/// A read-only view of a zip archive held in memory. The central directory is parsed and every
/// limit checked in `init`; entries are inflated only on request, one at a time.
public struct ZipArchiveReader: Sendable {

    public struct Entry: Sendable, Equatable {
        public let name: String
        let method: Int
        let crc32: UInt32
        public let compressedSize: Int
        public let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    public let entries: [Entry]
    private let data: Data
    private let limits: ZipLimits

    public init(data: Data, limits: ZipLimits = .standard) throws {
        self.data = data
        self.limits = limits
        guard data.count >= 22, data.readUInt32(at: 0) == 0x0403_4b50 else { throw ZipError.notAZip }
        // The end-of-central-directory record: within the last 64 KiB + 22 bytes (its comment is
        // at most 65 535 bytes). Searched backwards.
        let searchStart = max(0, data.count - 22 - 65_535)
        var eocd: Int?
        var index = data.count - 22
        while index >= searchStart {
            if data.readUInt32(at: index) == 0x0605_4b50 { eocd = index; break }
            index -= 1
        }
        guard let eocd else { throw ZipError.truncated }
        let totalEntries = Int(data.readUInt16(at: eocd + 10))
        let directorySize = Int(data.readUInt32(at: eocd + 12))
        let directoryOffset = Int(data.readUInt32(at: eocd + 16))
        if totalEntries == 0xFFFF || directorySize == 0xFFFF_FFFF || directoryOffset == 0xFFFF_FFFF {
            throw ZipError.unsupportedZip64
        }
        guard totalEntries <= limits.maximumEntryCount else {
            throw ZipError.tooManyEntries(count: totalEntries, limit: limits.maximumEntryCount)
        }
        guard directoryOffset + directorySize <= data.count else { throw ZipError.truncated }

        var parsed: [Entry] = []
        parsed.reserveCapacity(totalEntries)
        var cursor = directoryOffset
        var total = 0
        for _ in 0..<totalEntries {
            guard cursor + 46 <= data.count, data.readUInt32(at: cursor) == 0x0201_4b50 else { throw ZipError.truncated }
            let flags = data.readUInt16(at: cursor + 8)
            let method = Int(data.readUInt16(at: cursor + 10))
            let crc = data.readUInt32(at: cursor + 16)
            let compressed = Int(data.readUInt32(at: cursor + 20))
            let uncompressed = Int(data.readUInt32(at: cursor + 24))
            let nameLength = Int(data.readUInt16(at: cursor + 28))
            let extraLength = Int(data.readUInt16(at: cursor + 30))
            let commentLength = Int(data.readUInt16(at: cursor + 32))
            let localOffset = Int(data.readUInt32(at: cursor + 42))
            guard cursor + 46 + nameLength <= data.count else { throw ZipError.truncated }
            let name = String(decoding: data.subdata(in: (cursor + 46)..<(cursor + 46 + nameLength)), as: UTF8.self)
            if compressed == 0xFFFF_FFFF || uncompressed == 0xFFFF_FFFF || localOffset == 0xFFFF_FFFF {
                throw ZipError.unsupportedZip64
            }
            if flags & 0x1 != 0 { throw ZipError.encrypted(entry: name) }
            guard method == 0 || method == 8 else { throw ZipError.unsupportedMethod(entry: name, method: method) }
            guard uncompressed <= limits.maximumEntryBytes else {
                throw ZipError.entryTooLarge(entry: name, bytes: uncompressed, limit: limits.maximumEntryBytes)
            }
            if compressed > 0 {
                let ratio = uncompressed / compressed
                guard ratio <= limits.maximumCompressionRatio else {
                    throw ZipError.suspiciousRatio(entry: name, ratio: ratio, limit: limits.maximumCompressionRatio)
                }
            } else if uncompressed > 0 {
                throw ZipError.suspiciousRatio(entry: name, ratio: Int.max, limit: limits.maximumCompressionRatio)
            }
            total += uncompressed
            guard total <= limits.maximumTotalBytes else {
                throw ZipError.totalTooLarge(bytes: total, limit: limits.maximumTotalBytes)
            }
            parsed.append(Entry(name: name, method: method, crc32: crc, compressedSize: compressed,
                                uncompressedSize: uncompressed, localHeaderOffset: localOffset))
            cursor += 46 + nameLength + extraLength + commentLength
        }
        entries = parsed
    }

    public func entry(named name: String) -> Entry? { entries.first { $0.name == name } }

    /// The uncompressed bytes of one entry, checked against its declared size and CRC-32.
    public func contents(of name: String) throws -> Data {
        guard let entry = entry(named: name) else { throw ZipError.missingEntry(name) }
        let local = entry.localHeaderOffset
        guard local + 30 <= data.count, data.readUInt32(at: local) == 0x0403_4b50 else { throw ZipError.truncated }
        let start = local + 30 + Int(data.readUInt16(at: local + 26)) + Int(data.readUInt16(at: local + 28))
        guard start + entry.compressedSize <= data.count else { throw ZipError.truncated }
        let compressed = data.subdata(in: start..<(start + entry.compressedSize))
        let output: Data
        switch entry.method {
        case 0: output = compressed
        default: output = try Self.inflate(compressed, expected: entry.uncompressedSize, name: entry.name)
        }
        guard output.count == entry.uncompressedSize else {
            throw ZipError.sizeMismatch(entry: entry.name, declared: entry.uncompressedSize, actual: output.count)
        }
        guard ZipCRC32.checksum(output) == entry.crc32 else { throw ZipError.checksumMismatch(entry: entry.name) }
        return output
    }

    /// Raw DEFLATE (zip method 8) with Apple's `Compression` (`COMPRESSION_ZLIB` is raw DEFLATE).
    /// Stops as soon as the output would pass `expected`, so a header that lies about the size
    /// cannot make this allocate more than the limit already accepted.
    static func inflate(_ input: Data, expected: Int, name: String) throws -> Data {
        if expected == 0 { return Data() }
        var output = Data(count: expected)
        let produced: Int = input.withUnsafeBytes { (source: UnsafeRawBufferPointer) -> Int in
            output.withUnsafeMutableBytes { (destination: UnsafeMutableRawBufferPointer) -> Int in
                var stream = compression_stream(
                    dst_ptr: destination.bindMemory(to: UInt8.self).baseAddress!, dst_size: 0,
                    src_ptr: source.bindMemory(to: UInt8.self).baseAddress ?? UnsafePointer(bitPattern: 1)!, src_size: 0,
                    state: nil)
                guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { return -1 }
                defer { compression_stream_destroy(&stream) }
                stream.src_ptr = source.bindMemory(to: UInt8.self).baseAddress ?? stream.src_ptr
                stream.src_size = source.count
                stream.dst_ptr = destination.bindMemory(to: UInt8.self).baseAddress!
                stream.dst_size = expected
                // One `compression_stream_process` call is not one inflate. The decoder hands
                // back its output in pieces — 393,216 bytes on the first call here — and answers
                // OK with the input consumed and the rest still inside it. The reader used to
                // stop after that one call, so every entry larger than that (a ledger sheet of a
                // few thousand rows) failed as "declares N bytes but holds 393216". Drive it
                // until it ends, fills the buffer, or stops making progress.
                func drive() -> compression_status {
                    while true {
                        let before = (stream.src_size, stream.dst_size)
                        let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                        guard status == COMPRESSION_STATUS_OK, stream.dst_size > 0,
                              (stream.src_size, stream.dst_size) != before
                        else { return status }
                    }
                }
                let status = drive()
                let written = expected - stream.dst_size
                switch status {
                case COMPRESSION_STATUS_END: return written
                case COMPRESSION_STATUS_OK:
                    // Short of the declared size with no progress left: the size check reports it.
                    guard stream.dst_size == 0 else { return written }
                    // Full at the declared size before the stream said it ended. One more byte
                    // means the entry holds more than it declares; none means it was exact.
                    var spare: UInt8 = 0
                    return withUnsafeMutablePointer(to: &spare) { pointer -> Int in
                        stream.dst_ptr = pointer
                        stream.dst_size = 1
                        switch drive() {
                        case COMPRESSION_STATUS_ERROR: return -1
                        default: return stream.dst_size == 0 ? -2 : written
                        }
                    }
                default: return -1
                }
            }
        }
        if produced == -2 { throw ZipError.sizeMismatch(entry: name, declared: expected, actual: expected + 1) }
        guard produced >= 0 else { throw ZipError.inflateFailed(entry: name) }
        output.count = produced
        return output
    }
}

/// CRC-32 (IEEE 802.3, reflected, polynomial `0xEDB88320`), as every zip entry carries it. Public
/// so the stored-zip writers and their callers share one implementation (R-212) — and so does
/// the persistence layer's geometry blob trailer (U-103), which used to keep a private copy.
public enum ZipCRC32 {
    static let table: [UInt32] = (0..<256).map { value -> UInt32 in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        return crc
    }

    public static func checksum(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { checksum($0) }
    }

    /// The same checksum over raw bytes, for a caller holding an array or a slice of one.
    public static func checksum(_ bytes: UnsafeRawBufferPointer) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}

extension Data {
    func readUInt16(at offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= count else { return 0 }
        let base = startIndex + offset
        return UInt16(self[base]) | UInt16(self[base + 1]) << 8
    }

    func readUInt32(at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { return 0 }
        let base = startIndex + offset
        return UInt32(self[base]) | UInt32(self[base + 1]) << 8 | UInt32(self[base + 2]) << 16 | UInt32(self[base + 3]) << 24
    }
}
