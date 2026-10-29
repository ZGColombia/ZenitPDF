import Foundation

/// Minimal `FlateDecode` support.
///
/// `NSData.compressed(using: .zlib)` produces a *raw* DEFLATE stream, while PDF's
/// `/FlateDecode` filter expects an RFC 1950 zlib stream: a two-byte header, the
/// DEFLATE data, and a big-endian Adler-32 of the *uncompressed* bytes. This wraps
/// one into the other so the corpus needs no third-party compression dependency.
enum PDFFlate {

    /// Compresses `input` into an RFC 1950 zlib stream suitable for `/FlateDecode`.
    static func zlibStream(_ input: Data, kind: FixtureKind) throws -> Data {
        let deflated: Data
        do {
            deflated = try (input as NSData).compressed(using: .zlib) as Data
        } catch {
            throw FixtureError.compressionFailed(kind: kind)
        }
        var out = Data(capacity: deflated.count + 6)
        // 0x78 0x9C: deflate, 32 KiB window, default compression level.
        out.append(contentsOf: [0x78, 0x9C])
        out.append(deflated)
        let checksum = adler32(input)
        out.append(UInt8(truncatingIfNeeded: checksum >> 24))
        out.append(UInt8(truncatingIfNeeded: checksum >> 16))
        out.append(UInt8(truncatingIfNeeded: checksum >> 8))
        out.append(UInt8(truncatingIfNeeded: checksum))
        return out
    }

    /// Adler-32 per RFC 1950. The modulus is applied once per block rather than once
    /// per byte, which keeps the loop cheap and cannot overflow `UInt32`: 5552 is the
    /// largest block for which `b` provably stays below 2³².
    static func adler32(_ data: Data) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        let modulus: UInt32 = 65_521
        let blockSize = 5_552

        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var index = 0
            let count = buffer.count
            while index < count {
                let end = Swift.min(index + blockSize, count)
                var i = index
                while i < end {
                    a &+= UInt32(buffer[i])
                    b &+= a
                    i += 1
                }
                a %= modulus
                b %= modulus
                index = end
            }
        }
        return (b << 16) | a
    }
}
