import Foundation

/// What a bounded look at a PDF's first and last bytes tells us.
///
/// Everything here is decided from at most `headerProbeByteCount + trailerProbeByteCount`
/// bytes, so probing a 2 GB drawing set costs two reads. None of it involves a PDF
/// parser, which is the point: these are the checks that must not themselves be an
/// attack surface.
public struct PDFFileProbe: Sendable, Hashable {
    /// The version from the `%PDF-x.y` header, when there is one.
    public let headerVersion: PDFVersion?
    /// Whether the first object declares `/Linearized`.
    public let isLinearized: Bool
    /// Whether `%%EOF` appears in the trailing window.
    public let hasEndOfFileMarker: Bool
    public let byteCount: Int

    public init(
        headerVersion: PDFVersion?,
        isLinearized: Bool,
        hasEndOfFileMarker: Bool,
        byteCount: Int
    ) {
        self.headerVersion = headerVersion
        self.isLinearized = isLinearized
        self.hasEndOfFileMarker = hasEndOfFileMarker
        self.byteCount = byteCount
    }

    /// Probes bytes already in memory.
    public static func probe(data: Data, limits: DocumentLimits) -> PDFFileProbe {
        let head = data.prefix(limits.headerProbeByteCount)
        let tail = data.suffix(limits.trailerProbeByteCount)
        return probe(head: Data(head), tail: Data(tail), byteCount: data.count)
    }

    /// Probes a file with two bounded reads.
    public static func probe(fileAt url: URL, limits: DocumentLimits) throws -> PDFFileProbe {
        let byteCount = try FileDigestReader.fileByteCount(at: url)
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw PDFBridgeError.fileUnreadable(path: url.path, reason: error.localizedDescription)
        }
        defer { try? handle.close() }

        do {
            let head = try handle.read(upToCount: limits.headerProbeByteCount) ?? Data()
            let tailWindow = min(limits.trailerProbeByteCount, byteCount)
            var tail = Data()
            if tailWindow > 0 {
                try handle.seek(toOffset: UInt64(byteCount - tailWindow))
                tail = try handle.read(upToCount: tailWindow) ?? Data()
            }
            return probe(head: head, tail: tail, byteCount: byteCount)
        } catch {
            throw PDFBridgeError.fileUnreadable(path: url.path, reason: error.localizedDescription)
        }
    }

    static func probe(head: Data, tail: Data, byteCount: Int) -> PDFFileProbe {
        PDFFileProbe(
            headerVersion: version(inHeader: head),
            isLinearized: contains(head, ascii: "/Linearized"),
            hasEndOfFileMarker: contains(tail, ascii: "%%EOF"),
            byteCount: byteCount
        )
    }

    /// Parses `%PDF-1.7` from the first bytes.
    ///
    /// The specification allows junk before the header, and real files have it, so the
    /// marker is searched for in the probe window rather than required at offset 0.
    static func version(inHeader head: Data) -> PDFVersion? {
        let marker = Array("%PDF-".utf8)
        let bytes = [UInt8](head)
        guard let start = firstIndex(of: marker, in: bytes) else { return nil }
        var cursor = start + marker.count
        var major = 0
        var majorDigits = 0
        // Bounded by the probe window.
        while cursor < bytes.count, let digit = asciiDigit(bytes[cursor]), majorDigits < 2 {
            major = major * 10 + digit
            majorDigits += 1
            cursor += 1
        }
        guard majorDigits > 0, cursor < bytes.count, bytes[cursor] == UInt8(ascii: ".") else {
            return nil
        }
        cursor += 1
        var minor = 0
        var minorDigits = 0
        while cursor < bytes.count, let digit = asciiDigit(bytes[cursor]), minorDigits < 2 {
            minor = minor * 10 + digit
            minorDigits += 1
            cursor += 1
        }
        guard minorDigits > 0 else { return nil }
        return PDFVersion(major: major, minor: minor)
    }

    private static func asciiDigit(_ byte: UInt8) -> Int? {
        (byte >= 0x30 && byte <= 0x39) ? Int(byte - 0x30) : nil
    }

    private static func contains(_ data: Data, ascii: String) -> Bool {
        firstIndex(of: Array(ascii.utf8), in: [UInt8](data)) != nil
    }

    /// Naive substring search, which is correct and linear enough for a 4 KiB window.
    private static func firstIndex(of needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        let last = haystack.count - needle.count
        var start = 0
        while start <= last {
            var offset = 0
            while offset < needle.count, haystack[start + offset] == needle[offset] {
                offset += 1
            }
            if offset == needle.count { return start }
            start += 1
        }
        return nil
    }
}
