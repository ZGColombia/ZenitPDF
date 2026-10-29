import Foundation

/// The fixed-width decimal fields a PDF writer fills in: a classic cross-reference entry
/// (`oooooooooo ggggg n `, ISO 32000-1 §7.5.4, exactly 20 bytes) and a signature's `/ByteRange`,
/// which is written over a placeholder of the same length.
///
/// Written from the `Int` itself, never through `String(format: "%010d")`: `%d` reads 32 bits,
/// so an offset past 2 GiB came out wrapped or negative — 3 000 000 000 printed as
/// `-1294967296`, eleven characters where the entry has ten, moving every byte after it. The
/// test writer was fixed for this in BH-697; the four production writers were not (T-044).
enum PDFFixedWidthField {

    /// Digits in a cross-reference offset and in each `/ByteRange` number.
    static let offsetWidth = 10
    /// Digits in a cross-reference generation.
    static let generationWidth = 5

    /// `value` zero-padded to exactly `width` digits, or `nil` when it is negative or needs more
    /// digits than that — a field that does not fit is refused, never truncated or widened.
    static func digits(_ value: Int, width: Int) -> String? {
        guard value >= 0 else { return nil }
        let text = String(value)
        guard text.count <= width else { return nil }
        return String(repeating: "0", count: width - text.count) + text
    }

    /// One in-use classic cross-reference entry, `nil` when the offset does not fit or the
    /// generation is past the largest a PDF allows (65535).
    static func inUseEntry(offset: Int, generation: Int) -> String? {
        guard generation <= 65_535, let offset = digits(offset, width: offsetWidth),
              let generation = digits(generation, width: generationWidth) else { return nil }
        return "\(offset) \(generation) n \n"
    }

    /// A signature's `/ByteRange` array, `[0 open after tail]` with every number in ten digits,
    /// the length of ``PDFSignatureWriter/rangePlaceholder``; `nil` when a number does not fit.
    static func byteRange(open: Int, after: Int, total: Int) -> String? {
        let fields = [0, open, after, total - after].compactMap { digits($0, width: offsetWidth) }
        guard fields.count == 4 else { return nil }
        return "[" + fields.joined(separator: " ") + "]"
    }
}
