import Foundation

/// How a page content stream moves the graphics-state stack: the depth it ends at and the
/// lowest depth it reaches, both relative to where it started.
///
/// # Why the layered export needs to know
///
/// The markup layer is appended after the drawing's own content and placed with one `cm`. That
/// placement is only correct in the page's *default* coordinate system, so the drawing is
/// bracketed as `q` ⟨drawing⟩ `Q` before the layer is painted. A drawing whose operators are
/// balanced makes one `q` and one `Q` enough. Plotter drivers are known to leave a `q` dangling
/// (or to write one `Q` too many), and then a single `Q` pops the drawing's inner state instead
/// of the bracket, and the layer is placed on the drawing's leftover CTM and clip — scaled or
/// offset, with no error. Counting the operators gives the exact number of `q`s the bracket
/// needs in front and the exact number of `Q`s it needs behind.
///
/// # What it reads
///
/// Just enough of the content-stream syntax (ISO 32000-1 §7.8.2) not to count a `q` that is not
/// an operator: literal strings with their nesting and escapes, hex strings, names, comments,
/// and inline image data between `ID` and `EI`, which is binary and may contain any byte.
struct PDFContentStateBalance: Equatable {
    /// Depth after the last operator; positive means `q`s were left open.
    var final: Int
    /// Lowest depth reached; negative means the stream popped state it never saved.
    var minimum: Int

    static let balanced = PDFContentStateBalance(final: 0, minimum: 0)

    /// How many `q` operators must precede the drawing so it can never pop below the bracket.
    var savesBefore: Int { 1 + max(0, -minimum) }

    /// How many `Q` operators after the drawing return the stack to the page's default state.
    var restoresAfter: Int { savesBefore + final }

    /// Counts the `q`/`Q` operators of one content stream, or of several streams given in page
    /// order (a page's `/Contents` array is one stream split at token boundaries).
    static func measure(_ content: [UInt8]) -> PDFContentStateBalance {
        var depth = 0
        var minimum = 0
        var index = 0
        let count = content.count
        while index < count {
            let byte = content[index]
            if PDFByte.isWhitespace(byte) {
                index += 1
                continue
            }
            switch byte {
            case UInt8(ascii: "%"):
                while index < count, content[index] != 0x0A, content[index] != 0x0D { index += 1 }
            case UInt8(ascii: "("):
                index = skipLiteralString(content, from: index)
            case UInt8(ascii: "<"):
                if index + 1 < count, content[index + 1] == UInt8(ascii: "<") {
                    index += 2
                } else {
                    index += 1
                    while index < count, content[index] != UInt8(ascii: ">") { index += 1 }
                    index += 1
                }
            case UInt8(ascii: ">"), UInt8(ascii: "["), UInt8(ascii: "]"),
                 UInt8(ascii: "{"), UInt8(ascii: "}"), UInt8(ascii: ")"):
                index += 1
            case UInt8(ascii: "/"):
                index += 1
                while index < count, PDFByte.isRegular(content[index]) { index += 1 }
            default:
                let start = index
                while index < count, PDFByte.isRegular(content[index]) { index += 1 }
                guard index > start else {
                    index += 1
                    continue
                }
                let length = index - start
                if length == 1, content[start] == UInt8(ascii: "q") {
                    depth += 1
                } else if length == 1, content[start] == UInt8(ascii: "Q") {
                    depth -= 1
                    minimum = min(minimum, depth)
                } else if length == 2, content[start] == UInt8(ascii: "I"),
                          content[start + 1] == UInt8(ascii: "D") {
                    index = skipInlineImageData(content, from: index)
                }
            }
        }
        return PDFContentStateBalance(final: depth, minimum: minimum)
    }

    /// Past the closing parenthesis of the literal string opening at `start`.
    private static func skipLiteralString(_ content: [UInt8], from start: Int) -> Int {
        var index = start + 1
        var depth = 1
        while index < content.count {
            let byte = content[index]
            index += 1
            if byte == UInt8(ascii: "\\") {
                index += 1
                continue
            }
            if byte == UInt8(ascii: "(") { depth += 1 }
            if byte == UInt8(ascii: ")") {
                depth -= 1
                if depth == 0 { return index }
            }
        }
        return index
    }

    /// Past the `EI` that ends the inline image data following an `ID` operator. The data is
    /// binary, so `EI` counts only when whitespace precedes it and whitespace, a delimiter or the
    /// end of the stream follows it.
    private static func skipInlineImageData(_ content: [UInt8], from start: Int) -> Int {
        var index = start + 1  // the single whitespace byte after `ID`
        while index + 1 < content.count {
            if content[index] == UInt8(ascii: "E"), content[index + 1] == UInt8(ascii: "I"),
               index > 0, PDFByte.isWhitespace(content[index - 1]) {
                let after = index + 2
                if after >= content.count || !PDFByte.isRegular(content[after]) {
                    return after
                }
            }
            index += 1
        }
        return content.count
    }
}
