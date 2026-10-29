import Foundation

/// The writing counterpart of ``ZipArchiveReader``: a zip whose entries are *stored*, not
/// compressed, in memory, in the order given. Enough for the small data containers Zenit writes
/// (a pack of tool sets, templates and profiles, NL-PLAT-23); any unzip reads it, and
/// ``ZipArchiveReader`` reads it back byte for byte. No ZIP64: an entry or archive past 4 GB is
/// refused.
///
/// The records themselves are written by ``ZipStoredRecords``, which ``ZipStoredStreamWriter``
/// shares: one stored-zip format in the code base (R-212 — Send Project used to hand-build the
/// same headers, and carry its own CRC-32, in the persistence package).
public struct ZipStoredWriter: Sendable {

    public enum WriteError: Error, Equatable, Sendable, CustomStringConvertible {
        case tooLarge(entry: String)
        case duplicateEntry(String)
        case unsafeName(String)

        public var description: String {
            switch self {
            case let .tooLarge(entry): return "“\(entry)” is larger than a plain zip archive can hold."
            case let .duplicateEntry(name): return "“\(name)” is in the archive twice."
            case let .unsafeName(name): return "“\(name)” is not a safe name inside an archive."
            }
        }
    }

    private var entries: [(name: String, data: Data)] = []
    private var names: Set<String> = []

    public init() {}

    /// Whether `name` is a relative path with no parent step, no absolute root and no backslash.
    public static func isSafeEntryName(_ name: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("\\"), !name.contains("\0") else { return false }
        return !name.split(separator: "/", omittingEmptySubsequences: false).contains { $0 == ".." || $0 == "." || $0.isEmpty }
    }

    public mutating func add(_ name: String, data: Data) throws {
        guard Self.isSafeEntryName(name) else { throw WriteError.unsafeName(name) }
        guard !names.contains(name) else { throw WriteError.duplicateEntry(name) }
        guard data.count < Int(UInt32.max) else { throw WriteError.tooLarge(entry: name) }
        entries.append((name, data))
        names.insert(name)
    }

    /// The archive bytes. Every timestamp is the DOS epoch (1980-01-01 00:00), so the same entries
    /// always make the same bytes.
    public func archive() throws -> Data {
        var out = Data()
        var central = Data()
        for entry in entries {
            guard out.count < Int(UInt32.max) else { throw WriteError.tooLarge(entry: entry.name) }
            let offset = UInt32(out.count)
            let crc = ZipCRC32.checksum(entry.data)
            out.append(ZipStoredRecords.localHeader(name: entry.name, byteCount: entry.data.count, crc: crc))
            out.append(entry.data)
            central.append(ZipStoredRecords.centralRecord(
                name: entry.name, byteCount: entry.data.count, crc: crc, offset: offset
            ))
        }
        guard out.count < Int(UInt32.max) else { throw WriteError.tooLarge(entry: entries.last?.name ?? "") }
        let directoryOffset = UInt32(out.count)
        out.append(central)
        out.append(ZipStoredRecords.endRecord(
            entryCount: entries.count, directoryByteCount: central.count, directoryOffset: directoryOffset
        ))
        return out
    }
}

/// A stored zip written straight to a file, one entry at a time, so an archive of a project with a
/// 400 MB drawing set never holds more than one member in memory (Send Project, NL-PLAT-10).
///
/// Same records as ``ZipStoredWriter``; ``ZipArchiveReader`` and any unzip read it. Entries are
/// written in the order added; ``finish()`` writes the central directory. No ZIP64: an entry, the
/// archive, or more than 65 534 entries is refused before anything past the limit is written.
public struct ZipStoredStreamWriter {

    private let handle: FileHandle
    private var central = Data()
    private var offset: UInt64 = 0
    private var names: Set<String> = []
    private var finished = false

    /// Writes into `handle` from its current position, which must be the start of the file.
    public init(writingTo handle: FileHandle) {
        self.handle = handle
    }

    /// A directory entry, `name/` with no bytes. `name` is given without the trailing slash.
    public mutating func addDirectory(_ name: String) throws {
        guard ZipStoredWriter.isSafeEntryName(name) else { throw ZipStoredWriter.WriteError.unsafeName(name) }
        try write(name + "/", data: Data())
    }

    /// A file entry.
    public mutating func addFile(_ name: String, data: Data) throws {
        guard ZipStoredWriter.isSafeEntryName(name) else { throw ZipStoredWriter.WriteError.unsafeName(name) }
        try write(name, data: data)
    }

    /// Writes the central directory and the end record. Nothing may be added afterwards.
    public mutating func finish() throws {
        guard !finished else { return }
        guard names.count < 0xFFFF, offset < 0xFFFF_FFFF,
              offset + UInt64(central.count) < 0xFFFF_FFFF else {
            throw ZipStoredWriter.WriteError.tooLarge(entry: "the archive")
        }
        try handle.write(contentsOf: central)
        try handle.write(contentsOf: ZipStoredRecords.endRecord(
            entryCount: names.count, directoryByteCount: central.count, directoryOffset: UInt32(offset)
        ))
        finished = true
    }

    private mutating func write(_ name: String, data: Data) throws {
        precondition(!finished, "an entry was added after finish()")
        guard !names.contains(name) else { throw ZipStoredWriter.WriteError.duplicateEntry(name) }
        guard data.count < Int(UInt32.max), offset < 0xFFFF_FFFF, names.count < 0xFFFE else {
            throw ZipStoredWriter.WriteError.tooLarge(entry: name)
        }
        let crc = ZipCRC32.checksum(data)
        let local = ZipStoredRecords.localHeader(name: name, byteCount: data.count, crc: crc)
        try handle.write(contentsOf: local)
        try handle.write(contentsOf: data)
        central.append(ZipStoredRecords.centralRecord(
            name: name, byteCount: data.count, crc: crc, offset: UInt32(offset)
        ))
        offset += UInt64(local.count + data.count)
        names.insert(name)
    }
}

/// The three records of a stored zip, shared by ``ZipStoredWriter`` and ``ZipStoredStreamWriter``.
/// Version 2.0, UTF-8 names (general-purpose bit 11), method 0 (stored), and the DOS epoch
/// (1980-01-01 00:00) for every timestamp, so the same entries always make the same bytes.
///
/// The central record says the archive was **made on Unix** (`version made by` 0x0314), with
/// ordinary permissions in the external attributes (L-67). It said MS-DOS (0x0014), and the
/// `unzip` that ships with macOS — which does not read bit 11 — then took every name for an
/// OEM code page and translated it: "templates/Väster Testmall.zpdftemplate" listed as
/// "V+?ster Testmall" and could not be extracted at all ("Illegal byte sequence"). Names from a
/// Unix host are left as their bytes, which are UTF-8. A tool that reads bit 11 is unaffected.
enum ZipStoredRecords {
    private static let dosTime = 0
    private static let dosDate = (0 << 9) | (1 << 5) | 1
    /// `version made by`: host 3 (Unix) in the high byte, specification 2.0 in the low byte.
    static let versionMadeBy = (3 << 8) | 20
    /// A file's external attributes on a Unix host: a regular file, rw-r--r--, in the high half.
    static let fileAttributes: UInt32 = 0o100644 << 16
    /// A directory's: drwxr-xr-x in the high half, and the MS-DOS directory bit for readers that
    /// look only at the low byte.
    static let directoryAttributes: UInt32 = (0o040755 << 16) | 0x10

    static func localHeader(name: String, byteCount: Int, crc: UInt32) -> Data {
        let nameBytes = Data(name.utf8)
        var out = Data()
        le32(0x0403_4b50, into: &out); le16(20, into: &out); le16(0x0800, into: &out); le16(0, into: &out)
        le16(dosTime, into: &out); le16(dosDate, into: &out); le32(crc, into: &out)
        le32(UInt32(byteCount), into: &out); le32(UInt32(byteCount), into: &out)
        le16(nameBytes.count, into: &out); le16(0, into: &out)
        out.append(nameBytes)
        return out
    }

    static func centralRecord(name: String, byteCount: Int, crc: UInt32, offset: UInt32) -> Data {
        let nameBytes = Data(name.utf8)
        var out = Data()
        le32(0x0201_4b50, into: &out); le16(versionMadeBy, into: &out); le16(20, into: &out)
        le16(0x0800, into: &out); le16(0, into: &out); le16(dosTime, into: &out); le16(dosDate, into: &out)
        le32(crc, into: &out); le32(UInt32(byteCount), into: &out); le32(UInt32(byteCount), into: &out)
        le16(nameBytes.count, into: &out); le16(0, into: &out); le16(0, into: &out)
        le16(0, into: &out); le16(0, into: &out)
        le32(name.hasSuffix("/") ? directoryAttributes : fileAttributes, into: &out); le32(offset, into: &out)
        out.append(nameBytes)
        return out
    }

    static func endRecord(entryCount: Int, directoryByteCount: Int, directoryOffset: UInt32) -> Data {
        var out = Data()
        le32(0x0605_4b50, into: &out); le16(0, into: &out); le16(0, into: &out)
        le16(entryCount, into: &out); le16(entryCount, into: &out)
        le32(UInt32(directoryByteCount), into: &out); le32(directoryOffset, into: &out); le16(0, into: &out)
        return out
    }

    private static func le16(_ v: Int, into data: inout Data) {
        data.append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)])
    }

    private static func le32(_ v: UInt32, into data: inout Data) {
        data.append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)])
    }
}
