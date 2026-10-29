import Foundation

/// Decodes the standard stream filters far enough to read a content stream, a CMap or the
/// samples of an image (ISO 32000-1 §7.4).
///
/// ``PDFStreamCodec`` stays as small as the layered export needs; redaction must read whatever
/// a drawing's producer chose, so the chain here also covers ASCIIHex, ASCII85, LZW, RunLength
/// and the TIFF predictor. `DCTDecode` is left to the image code (it needs ImageIO) and
/// `CCITTFaxDecode`, `JBIG2Decode`, `JPXDecode` and `Crypt` are refusals: a sheet that needs
/// them where a box falls goes to the raster path.
enum RedactionStreamFilters {

    struct Decoded {
        var data: Data
        /// A filter the chain stopped at because the caller must handle it (DCT for images).
        var remainingFilter: String?
    }

    static func filterNames(_ dictionary: [String: PDFObject]) -> [String] {
        switch dictionary["Filter"] ?? dictionary["F"] {
        case let .name(value)?: [value]
        case let .array(values)?: values.compactMap(\.nameValue)
        default: []
        }
    }

    static func parameters(_ dictionary: [String: PDFObject], count: Int) -> [[String: PDFObject]?] {
        switch dictionary["DecodeParms"] ?? dictionary["DP"] {
        case let .dictionary(value)?: return [value] + Array(repeating: nil, count: max(0, count - 1))
        case let .array(values)?: return (0..<count).map { $0 < values.count ? values[$0].dictionaryValue : nil }
        default: return Array(repeating: nil, count: count)
        }
    }

    /// Decodes every filter; DCT is allowed only as the last one and only when `allowDCT`.
    ///
    /// Every expanding filter stops as soon as its output would pass `limit` — not after it has
    /// finished: RunLength emits up to 128 bytes per two input bytes, so a limit-sized Flate
    /// stream behind it allocated about 16 GB before the size was checked (R-107).
    static func decode(
        dictionary: [String: PDFObject], data: Data, allowDCT: Bool = false, limit: Int = PDFStreamCodec.maximumDecodedBytes
    ) throws -> Decoded {
        let names = filterNames(dictionary).map { RedactionInlineImageKeys.filterExpansions[$0] ?? $0 }
        let parms = parameters(dictionary, count: names.count)
        var current = data
        for (position, name) in names.enumerated() {
            let parameters = parms[position]
            switch name {
            case "FlateDecode":
                guard let inflated = PDFStreamCodec.inflate(current, limit: limit) else { throw RedactionUnsupported("a Flate stream is damaged") }
                current = try predict(inflated, parameters, limit: limit)
            case "LZWDecode":
                let early = parameters?["EarlyChange"]?.integerValue ?? 1
                current = try predict(try lzw(current, earlyChange: early != 0, limit: limit), parameters, limit: limit)
            case "ASCIIHexDecode":
                current = asciiHex(current)
            case "ASCII85Decode":
                current = try ascii85(current, limit: limit)
            case "RunLengthDecode":
                current = try runLength(current, limit: limit)
            case "DCTDecode" where allowDCT && position == names.count - 1:
                return Decoded(data: current, remainingFilter: "DCTDecode")
            default:
                throw RedactionUnsupported("a stream uses the \(name) filter, which the vector rewriter does not decode")
            }
            guard current.count <= limit else { throw RedactionUnsupported("a stream decodes past the size limit") }
        }
        return Decoded(data: current, remainingFilter: nil)
    }

    /// A stream decoded completely, or a refusal.
    static func decodeFully(_ object: PDFObject?) throws -> Data {
        guard case let .stream(dictionary, data)? = object else { throw RedactionUnsupported("a content stream is missing") }
        let decoded = try decode(dictionary: dictionary, data: data)
        return decoded.data
    }

    private static func predict(_ data: Data, _ parameters: [String: PDFObject]?, limit: Int) throws -> Data {
        guard let parameters, let predictor = parameters["Predictor"]?.integerValue, predictor > 1 else { return data }
        let columns = parameters["Columns"]?.integerValue ?? 1
        let colors = parameters["Colors"]?.integerValue ?? 1
        let bits = parameters["BitsPerComponent"]?.integerValue ?? 8
        if predictor >= 10 {
            guard let undone = PDFStreamCodec.undoPNGPredictor(data, columns: columns, colors: colors, bitsPerComponent: bits, limit: limit) else {
                throw RedactionUnsupported("a stream's PNG predictor cannot be undone")
            }
            return undone
        }
        guard predictor == 2, bits == 8 else { throw RedactionUnsupported("a stream uses TIFF predictor \(predictor) at \(bits) bits") }
        // The PNG branch's bounds (PDFStreamCodec.undoPNGPredictor): Columns × Colors below is
        // then at most 2^25, so it cannot overflow however large the dictionary's values are (S-062).
        guard columns > 0, colors > 0, columns < 1 << 20, colors <= 32 else {
            throw RedactionUnsupported("a stream's TIFF predictor has \(columns) columns of \(colors) colours, which is out of range")
        }
        var bytes = [UInt8](data)
        let row = columns * colors
        var start = 0
        while start + row <= bytes.count {
            for index in (start + colors)..<(start + row) { bytes[index] = bytes[index] &+ bytes[index - colors] }
            start += row
        }
        return Data(bytes)
    }

    static func asciiHex(_ data: Data) -> Data {
        var out = Data()
        var high: UInt8?
        for byte in data {
            if byte == UInt8(ascii: ">") { break }
            guard let value = PDFObjectParser.hexValue(byte) else { continue }
            if let pending = high { out.append(pending << 4 | value); high = nil } else { high = value }
        }
        if let pending = high { out.append(pending << 4) }
        return out
    }

    static func asciiHexEncode(_ data: Data) -> Data {
        var out = Data()
        out.reserveCapacity(data.count * 2 + data.count / 32 + 1)
        let digits = Array("0123456789ABCDEF".utf8)
        for (index, byte) in data.enumerated() {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0F)])
            if index % 32 == 31 { out.append(0x0A) }
        }
        out.append(UInt8(ascii: ">"))
        return out
    }

    static func ascii85(_ data: Data, limit: Int = PDFStreamCodec.maximumDecodedBytes) throws -> Data {
        var out = Data()
        var group: [UInt32] = []
        var bytes = [UInt8](data)
        if bytes.starts(with: Array("<~".utf8)) { bytes.removeFirst(2) }
        for byte in bytes {
            if byte == UInt8(ascii: "~") { break }
            if PDFByte.isWhitespace(byte) { continue }
            if byte == UInt8(ascii: "z"), group.isEmpty {
                guard out.count <= limit - 4 else { throw RedactionUnsupported("an ASCII85 stream decodes past the size limit") }
                out.append(contentsOf: [0, 0, 0, 0])
                continue
            }
            guard byte >= 33, byte <= 117 else { throw RedactionUnsupported("an ASCII85 stream is damaged") }
            group.append(UInt32(byte - 33))
            if group.count == 5 {
                let value = group.reduce(UInt64(0)) { $0 * 85 + UInt64($1) }
                guard value <= UInt64(UInt32.max) else { throw RedactionUnsupported("an ASCII85 stream is damaged") }
                withUnsafeBytes(of: UInt32(value).bigEndian) { out.append(contentsOf: $0) }
                group.removeAll()
            }
        }
        if !group.isEmpty {
            let count = group.count
            while group.count < 5 { group.append(84) }
            let value = group.reduce(UInt64(0)) { $0 * 85 + UInt64($1) }
            var word = UInt32(truncatingIfNeeded: value).bigEndian
            withUnsafeBytes(of: &word) { out.append(contentsOf: $0.prefix(count - 1)) }
        }
        return out
    }

    static func runLength(_ data: Data, limit: Int = PDFStreamCodec.maximumDecodedBytes) throws -> Data {
        var out = Data()
        let bytes = [UInt8](data)
        var index = 0
        while index < bytes.count {
            let length = Int(bytes[index])
            index += 1
            if length == 128 { break }
            if length < 128 {
                let end = min(bytes.count, index + length + 1)
                guard end - index <= limit - out.count else { throw RedactionUnsupported("a RunLength stream decodes past the size limit") }
                out.append(contentsOf: bytes[index..<end])
                index = end
            } else if index < bytes.count {
                guard 257 - length <= limit - out.count else { throw RedactionUnsupported("a RunLength stream decodes past the size limit") }
                out.append(contentsOf: repeatElement(bytes[index], count: 257 - length))
                index += 1
            }
        }
        return out
    }

    static func lzw(_ data: Data, earlyChange: Bool, limit: Int = PDFStreamCodec.maximumDecodedBytes) throws -> Data {
        let bytes = [UInt8](data)
        var table: [[UInt8]] = (0..<256).map { [UInt8($0)] } + [[], []]
        var out: [UInt8] = []
        var codeLength = 9
        var bitBuffer: UInt32 = 0
        var bitCount = 0
        var previous: [UInt8]?
        var index = 0
        while true {
            while bitCount < codeLength {
                guard index < bytes.count else { return Data(out) }
                bitBuffer = (bitBuffer << 8) | UInt32(bytes[index])
                index += 1
                bitCount += 8
            }
            let code = Int((bitBuffer >> UInt32(bitCount - codeLength)) & ((1 << UInt32(codeLength)) - 1))
            bitCount -= codeLength
            if code == 256 {
                table.removeSubrange(258...)
                codeLength = 9
                previous = nil
                continue
            }
            if code == 257 { break }
            let entry: [UInt8]
            if code < table.count {
                entry = table[code]
            } else if let previous, code == table.count {
                entry = previous + [previous[0]]
            } else {
                throw RedactionUnsupported("an LZW stream is damaged")
            }
            out.append(contentsOf: entry)
            if out.count > limit { throw RedactionUnsupported("an LZW stream decodes past the size limit") }
            if let previous { table.append(previous + [entry[0]]) }
            previous = entry
            let threshold = table.count + (earlyChange ? 1 : 0)
            if threshold >= 1 << codeLength, codeLength < 12 { codeLength += 1 }
        }
        return Data(out)
    }
}
