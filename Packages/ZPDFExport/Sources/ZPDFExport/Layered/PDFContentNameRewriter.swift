import Foundation

/// Renames the resource names inside a content stream.
///
/// # Why the markup ink needs renaming at all
///
/// The markups are painted by ``MarkupFlattener`` into a Core Graphics PDF context, and Core
/// Graphics names its resources `/Cs1`, `/Gs1`, `/Im1` — names a construction drawing produced by
/// any other tool is just as likely to have used. Merging the two resource dictionaries without
/// renaming would let the markup's alpha state silently become the drawing's, or the other way
/// round: the drawing changes, quietly, on one sheet in forty. So every markup resource enters
/// the page under a name prefixed for this export, and the operators that refer to it are
/// rewritten to match.
///
/// The rewrite is by **exact set membership**: a name is replaced only when it is a key of the
/// markup page's own resource dictionary. `/DeviceRGB`, `/Perceptual`, `/AAPL:Style` and every
/// other name that is not a resource key passes through untouched, because none of them is in
/// the map.
enum PDFContentNameRewriter {

    /// Rewrites `/Name` tokens using `map`, leaving strings and inline-image data alone.
    static func rewrite(_ content: Data, map: [String: String]) -> Data {
        guard !map.isEmpty else { return content }
        let bytes = [UInt8](content)
        var out = Data()
        out.reserveCapacity(bytes.count + bytes.count / 8)
        var index = 0

        while index < bytes.count {
            let byte = bytes[index]
            switch byte {
            case UInt8(ascii: "("):
                index = copyLiteralString(bytes, from: index, into: &out)
            case UInt8(ascii: "%"):
                while index < bytes.count, bytes[index] != 0x0A, bytes[index] != 0x0D {
                    out.append(bytes[index])
                    index += 1
                }
            case UInt8(ascii: "/"):
                var parser = PDFObjectParser(bytes: bytes, index: index)
                guard let name = parser.parseObject()?.nameValue else {
                    out.append(byte)
                    index += 1
                    continue
                }
                let replacement = map[name] ?? name
                out.append(UInt8(ascii: "/"))
                out.append(contentsOf: PDFObject.escapedName(replacement))
                index = parser.index
            default:
                // `BI ... ID <binary> EI`: the payload is not syntax and must not be scanned.
                if byte == UInt8(ascii: "B"), isInlineImageStart(bytes, at: index) {
                    index = copyInlineImage(bytes, from: index, into: &out)
                } else {
                    out.append(byte)
                    index += 1
                }
            }
        }
        return out
    }

    private static func isInlineImageStart(_ bytes: [UInt8], at index: Int) -> Bool {
        guard index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "I") else { return false }
        let after = index + 2
        guard after >= bytes.count || !PDFByte.isRegular(bytes[after]) else { return false }
        return index == 0 || !PDFByte.isRegular(bytes[index - 1])
    }

    private static func copyLiteralString(
        _ bytes: [UInt8],
        from start: Int,
        into out: inout Data
    ) -> Int {
        var index = start
        out.append(bytes[index])
        index += 1
        var depth = 1
        while index < bytes.count {
            let byte = bytes[index]
            out.append(byte)
            index += 1
            if byte == UInt8(ascii: "\\") {
                if index < bytes.count {
                    out.append(bytes[index])
                    index += 1
                }
                continue
            }
            if byte == UInt8(ascii: "(") { depth += 1 }
            if byte == UInt8(ascii: ")") {
                depth -= 1
                if depth == 0 { break }
            }
        }
        return index
    }

    /// Copies `BI … ID <bytes> EI` verbatim, payload included.
    ///
    /// An inline image's bytes are not syntax: they contain `(`, `/` and `%` as data, and a
    /// rewriter that scanned them would corrupt the image and could run off the end of the
    /// stream. The markup painter emits no inline images — `MarkupFlattener` asks the renderer
    /// for outlines precisely so that nothing arrives as a picture — so this path exists to be
    /// safe rather than to be used.
    private static func copyInlineImage(
        _ bytes: [UInt8],
        from start: Int,
        into out: inout Data
    ) -> Int {
        var index = start
        while index < bytes.count {
            if bytes[index] == UInt8(ascii: "I"), index + 1 < bytes.count,
               bytes[index + 1] == UInt8(ascii: "D") {
                out.append(contentsOf: [bytes[index], bytes[index + 1]])
                index += 2
                break
            }
            out.append(bytes[index])
            index += 1
        }
        while index < bytes.count {
            if bytes[index] == UInt8(ascii: "E"), index + 1 < bytes.count,
               bytes[index + 1] == UInt8(ascii: "I"),
               index > start, PDFByte.isWhitespace(bytes[index - 1]),
               index + 2 >= bytes.count || !PDFByte.isRegular(bytes[index + 2]) {
                out.append(contentsOf: [bytes[index], bytes[index + 1]])
                return index + 2
            }
            out.append(bytes[index])
            index += 1
        }
        return index
    }
}
