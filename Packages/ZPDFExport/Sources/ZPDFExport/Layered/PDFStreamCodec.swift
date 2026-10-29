import Compression
import Foundation

/// `/FlateDecode`, both ways, plus the PNG predictor an object stream may be written through.
///
/// Only what the layered export needs. The exporter decodes exactly two kinds of stream — the
/// object streams that hide a source file's catalog and page dictionaries, and the markup content
/// Core Graphics wrote — and encodes exactly one, the markup content it appends. Every other
/// stream in the source is copied byte for byte with its filter untouched, which is the whole
/// point of ADR-0013: the drawing is not re-encoded.
enum PDFStreamCodec {

    /// Enough for any catalog or page dictionary; a decompression bomb cannot make the export
    /// allocate without bound.
    static let maximumDecodedBytes = 256 * 1024 * 1024

    /// Decodes a stream far enough to read the objects inside it.
    ///
    /// - Parameter limit: the most bytes the decoded stream may hold, after every step: a stream
    ///   that would pass it is refused while it is inflated, as ``inflate(_:limit:progress:)``
    ///   does, and again before a PNG predictor is undone, which can pad a short row out to its
    ///   full width. A reader that decodes several streams for one answer passes what is left of
    ///   its own budget (W-055).
    /// - Returns: `nil` when the filter chain is one this codec does not implement, or the result
    ///   would pass `limit`. A caller treats that as "this object stream is unreadable", not as an
    ///   empty one.
    static func decode(dictionary: [String: PDFObject], data: Data, limit: Int = maximumDecodedBytes) -> Data? {
        let filters: [String]
        switch dictionary["Filter"] {
        case let .name(value): filters = [value]
        case let .array(values): filters = values.compactMap(\.nameValue)
        case .none: filters = []
        default: return nil
        }
        guard filters.count <= 1, limit >= 0 else { return nil }
        guard let filter = filters.first else { return data.count <= limit ? data : nil }
        guard filter == "FlateDecode" || filter == "Fl" else { return nil }
        guard let inflated = inflate(data, limit: limit) else { return nil }

        let parameters: [String: PDFObject]?
        switch dictionary["DecodeParms"] ?? dictionary["DP"] {
        case let .dictionary(value): parameters = value
        case let .array(values): parameters = values.first?.dictionaryValue
        case .none: parameters = nil
        default: return nil
        }
        guard let parameters, let predictor = parameters["Predictor"]?.integerValue, predictor > 1
        else { return inflated }
        guard predictor >= 10 else { return nil }  // TIFF predictor 2 is not implemented.
        let columns = parameters["Columns"]?.integerValue ?? 1
        let colors = parameters["Colors"]?.integerValue ?? 1
        let bits = parameters["BitsPerComponent"]?.integerValue ?? 8
        return undoPNGPredictor(inflated, columns: columns, colors: colors, bitsPerComponent: bits, limit: limit)
    }

    /// Raw zlib: the two-byte header, the deflate payload, the Adler-32 trailer.
    ///
    /// `NSData.compressed(using: .zlib)` produces a bare deflate stream, which is *not* what
    /// `/FlateDecode` means — a reader that expects RFC 1950 and receives RFC 1951 reports a
    /// damaged file. The six bytes around it are the whole difference.
    static func flateEncode(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        guard let deflated = try? (data as NSData).compressed(using: .zlib) as Data else {
            return nil
        }
        var out = Data([0x78, 0x9C])
        out.append(deflated)
        var checksum = adler32(data).bigEndian
        withUnsafeBytes(of: &checksum) { out.append(contentsOf: $0) }
        return out
    }

    /// Inflates `data`, refusing — **while inflating**, not afterwards — once the output would
    /// pass `limit` bytes.
    ///
    /// The ceiling has to bind during decompression: a 1 MB object stream can inflate to
    /// gigabytes, and a check made after `NSData.decompressed(using:)` has returned is a check
    /// made after the allocation it was meant to prevent. The streaming filter hands the output
    /// over one buffer at a time, so the most this ever holds is `limit` plus one buffer.
    ///
    /// - Parameter progress: called with the running output size after each buffer; a test
    ///   hook for the peak, `nil` in production.
    static func inflate(
        _ data: Data,
        limit: Int = maximumDecodedBytes,
        progress: ((Int) -> Void)? = nil
    ) -> Data? {
        guard data.count > 2 else { return Data() }
        // Skip the RFC 1950 header when it is there; some producers emit bare deflate.
        let looksZlib = (data[data.startIndex] & 0x0F) == 8
            && (Int(data[data.startIndex]) << 8 | Int(data[data.startIndex + 1])) % 31 == 0
        let payload = Data(looksZlib ? data.dropFirst(2) : data[data.startIndex...])

        let chunk = 64 * 1024
        var out = Data()
        var finished = false
        do {
            let filter = try OutputFilter(.decompress, using: .zlib, bufferCapacity: chunk) {
                produced in
                guard let produced else {
                    finished = true
                    return
                }
                guard produced.count <= limit - out.count else { throw InflateLimitExceeded() }
                out.append(produced)
                progress?(out.count)
            }
            var cursor = payload.startIndex
            while cursor < payload.endIndex, !finished {
                let next = payload.index(cursor, offsetBy: chunk, limitedBy: payload.endIndex)
                    ?? payload.endIndex
                try filter.write(payload[cursor..<next])
                cursor = next
            }
            if !finished { try filter.finalize() }
        } catch {
            return nil
        }
        return out
    }

    private struct InflateLimitExceeded: Error {}

    static func adler32(_ data: Data) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        return b << 16 | a
    }

    // MARK: - PNG predictors

    /// Undoes a PNG predictor, or `nil` when the parameters are out of range, a row tag is
    /// unknown, or the result would hold more than `limit` bytes.
    ///
    /// Every row is one tag byte and up to `rowBytes` of data, and comes out a full `rowBytes`
    /// wide — a short last row is padded with zeros. So the size of the result is known from
    /// the input length before anything is allocated, and `limit` is checked then. Checked only
    /// against the fixed ceiling, a 2-byte stream declaring 2^20 − 1 columns of 32 16-bit
    /// colours came out as one 64 MB row whatever budget its caller had left (W-055).
    static func undoPNGPredictor(
        _ data: Data,
        columns: Int,
        colors: Int,
        bitsPerComponent: Int,
        limit: Int = maximumDecodedBytes
    ) -> Data? {
        guard columns > 0, colors > 0, bitsPerComponent > 0,
              columns < 1 << 20, colors <= 32, bitsPerComponent <= 16
        else { return nil }
        let sampleBits = colors * bitsPerComponent
        let rowBytes = (columns * sampleBits + 7) / 8
        let pixelBytes = max(1, sampleBits / 8)
        guard rowBytes > 0 else { return nil }
        // A trailing tag byte with no data after it ends the loop below without a row.
        let rows = data.count / (rowBytes + 1) + (data.count % (rowBytes + 1) >= 2 ? 1 : 0)
        let (outputBytes, overflow) = rows.multipliedReportingOverflow(by: rowBytes)
        guard !overflow, outputBytes <= limit else { return nil }
        guard rows > 0 else { return Data() }

        var out = Data()
        out.reserveCapacity(outputBytes)
        var previous = [UInt8](repeating: 0, count: rowBytes)
        var current = [UInt8](repeating: 0, count: rowBytes)
        var index = data.startIndex
        while index < data.endIndex {
            let tag = data[index]
            index += 1
            let available = min(rowBytes, data.distance(from: index, to: data.endIndex))
            guard available > 0 else { break }
            for offset in 0..<rowBytes {
                current[offset] = offset < available ? data[index + offset] : 0
            }
            index = data.index(index, offsetBy: available)

            switch tag {
            case 0:
                break
            case 1:
                for offset in pixelBytes..<rowBytes {
                    current[offset] = current[offset] &+ current[offset - pixelBytes]
                }
            case 2:
                for offset in 0..<rowBytes {
                    current[offset] = current[offset] &+ previous[offset]
                }
            case 3:
                for offset in 0..<rowBytes {
                    let left = offset >= pixelBytes ? Int(current[offset - pixelBytes]) : 0
                    current[offset] = current[offset] &+ UInt8((left + Int(previous[offset])) / 2)
                }
            case 4:
                for offset in 0..<rowBytes {
                    let left = offset >= pixelBytes ? Int(current[offset - pixelBytes]) : 0
                    let up = Int(previous[offset])
                    let upLeft = offset >= pixelBytes ? Int(previous[offset - pixelBytes]) : 0
                    let p = left + up - upLeft
                    let pa = abs(p - left), pb = abs(p - up), pc = abs(p - upLeft)
                    let predicted = (pa <= pb && pa <= pc) ? left : (pb <= pc ? up : upLeft)
                    current[offset] = current[offset] &+ UInt8(predicted)
                }
            default:
                return nil
            }
            out.append(contentsOf: current)
            previous = current
        }
        return out
    }
}
