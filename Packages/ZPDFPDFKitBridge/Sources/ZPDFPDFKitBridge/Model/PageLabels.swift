import Foundation

/// The numbering styles of a `/PageLabels` range (PDF 32000-1, table 159).
public enum PageLabelStyle: String, Sendable, Hashable, Codable, CaseIterable {
    /// `1, 2, 3, …`
    case decimal = "D"
    /// `I, II, III, …`
    case uppercaseRoman = "R"
    /// `i, ii, iii, …`
    case lowercaseRoman = "r"
    /// `A, B, …, Z, AA, BB, …`
    case uppercaseLetters = "A"
    /// `a, b, …, z, aa, bb, …`
    case lowercaseLetters = "a"
}

/// One `/PageLabels` range: from `startPageIndex` until the next range begins.
public struct PageLabelRange: Sendable, Hashable, Codable {
    /// Zero-based index of the first page this range covers.
    public var startPageIndex: Int
    /// `/S`. `nil` means the range has a prefix and no number at all.
    public var style: PageLabelStyle?
    /// `/P`, prepended to every label in the range. `A-` for a `A-101` sheet set.
    public var prefix: String
    /// `/St`, the number given to the first page of the range. Defaults to 1, and the
    /// PDF specification requires it to be at least 1.
    public var firstNumber: Int

    public init(
        startPageIndex: Int,
        style: PageLabelStyle?,
        prefix: String = "",
        firstNumber: Int = 1
    ) {
        self.startPageIndex = max(0, startPageIndex)
        self.style = style
        self.prefix = prefix
        self.firstNumber = max(1, firstNumber)
    }

    private enum CodingKeys: String, CodingKey {
        case startPageIndex, style, prefix, firstNumber
    }

    /// Decodes through the memberwise initialiser, so a decoded range obeys the same clamps
    /// as a constructed one (BH-569). The keys and the encoding are exactly the synthesised
    /// ones, so every previously encoded range still decodes.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            startPageIndex: try container.decode(Int.self, forKey: .startPageIndex),
            style: try container.decodeIfPresent(PageLabelStyle.self, forKey: .style),
            prefix: try container.decodeIfPresent(String.self, forKey: .prefix) ?? "",
            firstNumber: try container.decodeIfPresent(Int.self, forKey: .firstNumber) ?? 1
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(startPageIndex, forKey: .startPageIndex)
        try container.encodeIfPresent(style, forKey: .style)
        try container.encode(prefix, forKey: .prefix)
        try container.encode(firstNumber, forKey: .firstNumber)
    }
}

/// The mapping from page index to page label for a whole document.
///
/// Two things are separate and stay separate: the *index*, which is where a page sits in
/// the page tree, and the *label*, which is what the drawing is called. Construction
/// sheet sets are labelled `A-101`, `S-201`, `M-3.02`, so the label is neither a number
/// nor derivable from the index.
///
/// When the document declares no `/PageLabels`, ``isExplicit`` is `false` and the table
/// falls back to the PDF-viewer convention of `String(index + 1)`. That fallback is
/// still a label: callers must not re-derive it themselves.
public struct PageLabelTable: Sendable, Hashable, Codable {
    public let pageCount: Int
    /// Ranges sorted by `startPageIndex`, deduplicated, with the first one starting at 0.
    public let ranges: [PageLabelRange]
    /// `true` when the document actually declared a `/PageLabels` number tree.
    public let isExplicit: Bool

    /// Builds a table, normalising the ranges: sorted, deduplicated on start index, and
    /// with an implicit decimal range prepended if the first declared range does not
    /// start at page 0.
    public init(pageCount: Int, ranges: [PageLabelRange], isExplicit: Bool) {
        let count = max(0, pageCount)
        self.pageCount = count

        var sorted = ranges
            .filter { $0.startPageIndex < count }
            .sorted { $0.startPageIndex < $1.startPageIndex }
        var deduplicated: [PageLabelRange] = []
        deduplicated.reserveCapacity(sorted.count)
        for range in sorted where deduplicated.last?.startPageIndex != range.startPageIndex {
            deduplicated.append(range)
        }
        sorted = deduplicated

        if sorted.first?.startPageIndex != 0 {
            sorted.insert(
                PageLabelRange(startPageIndex: 0, style: .decimal, prefix: "", firstNumber: 1),
                at: 0
            )
        }
        self.ranges = count == 0 ? [] : sorted
        self.isExplicit = isExplicit
    }

    private enum CodingKeys: String, CodingKey {
        case pageCount, ranges, isExplicit
    }

    /// Decodes through the normalising initialiser: sorted, deduplicated, first range at
    /// page 0. The synthesised decoder assigned the stored properties directly, so a cached
    /// or hand-edited table could break the invariant the binary search in
    /// ``range(forPageIndex:)`` relies on (BH-569). Same keys, same encoding: previously
    /// encoded tables decode to the same value.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            pageCount: try container.decode(Int.self, forKey: .pageCount),
            ranges: try container.decode([PageLabelRange].self, forKey: .ranges),
            isExplicit: try container.decode(Bool.self, forKey: .isExplicit)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pageCount, forKey: .pageCount)
        try container.encode(ranges, forKey: .ranges)
        try container.encode(isExplicit, forKey: .isExplicit)
    }

    /// The range covering `pageIndex`, or `nil` when the index is out of range.
    public func range(forPageIndex pageIndex: Int) -> PageLabelRange? {
        guard pageIndex >= 0, pageIndex < pageCount, !ranges.isEmpty else { return nil }
        // Ranges are sorted and small in every real document; a binary search keeps a
        // 20 000-range hostile file from turning label lookup into a quadratic scan.
        var low = 0
        var high = ranges.count - 1
        var found = 0
        while low <= high {
            let mid = (low + high) / 2
            if ranges[mid].startPageIndex <= pageIndex {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return ranges[found]
    }

    /// The label of a page, or `nil` when the index is out of range.
    public func label(forPageIndex pageIndex: Int) -> String? {
        guard let range = range(forPageIndex: pageIndex) else { return nil }
        guard let style = range.style else { return range.prefix }
        // `firstNumber` is a hostile file's `/St`, which CoreGraphics reads as a 64-bit
        // integer: `/St 9223372036854775807` on a two-page document made page 1's ordinal
        // `Int.max + 1` and trapped on open (BH-027, BH-178). Both operands are non-negative
        // here (the range lookup guarantees `startPageIndex <= pageIndex`, and both are
        // clamped at construction and decoding), so their exact sum always fits a `UInt`,
        // and an ordinal that large is written in decimal whatever the style.
        let offset = pageIndex.subtractingReportingOverflow(range.startPageIndex)
        let sum = range.firstNumber.addingReportingOverflow(offset.partialValue)
        if offset.overflow || sum.overflow || offset.partialValue < 0 {
            let exact = UInt(clamping: range.firstNumber) &+ UInt(clamping: offset.partialValue)
            return range.prefix + String(exact)
        }
        return range.prefix + PageLabelNumbering.string(sum.partialValue, style: style)
    }

    /// The first page whose label equals `label`, compared exactly.
    ///
    /// Labels are not required to be unique — a set can legitimately contain two pages
    /// labelled `A-101` after a revision insert — so this returns the first match and the
    /// caller is expected to disambiguate when it matters.
    public func pageIndex(forLabel label: String) -> Int? {
        for index in 0..<pageCount where self.label(forPageIndex: index) == label {
            return index
        }
        return nil
    }

    /// Every label, in page order.
    public func allLabels() -> [String] {
        (0..<pageCount).map { label(forPageIndex: $0) ?? "" }
    }
}

/// Turning an ordinal into a page-label string.
///
/// Split out from ``PageLabelTable`` because it is pure arithmetic on integers and is
/// tested as such: roman numerals, the PDF's unusual `A … Z, AA, BB` letter sequence,
/// and the clamping that keeps a hostile `/St 2147483647` from allocating.
public enum PageLabelNumbering {
    /// The largest ordinal that is rendered in full. Beyond this the decimal form is used
    /// for every style, because a roman numeral for 10^9 is an allocation attack.
    public static let maximumStyledOrdinal = 1_000_000

    /// The longest run of one letter a letter-style label is written with. Beyond it the
    /// label is decimal. Letter labels repeat one character `ordinal / 26 + 1` times, so the
    /// ordinal clamp alone admitted a 38 462-character label per page — about 770 MB of
    /// label strings for a hostile 20 000-page file opened once (BH-169).
    public static let maximumLetterRepeatCount = 64

    /// The largest ordinal written as a roman numeral. Above 3999 roman numerals repeat `M`,
    /// one per thousand; this keeps a label under about 115 characters (BH-169).
    public static let maximumRomanOrdinal = 100_000

    public static func string(_ ordinal: Int, style: PageLabelStyle) -> String {
        guard ordinal >= 1 else { return "" }
        guard ordinal <= maximumStyledOrdinal else { return String(ordinal) }
        switch style {
        case .decimal:
            return String(ordinal)
        case .uppercaseRoman, .lowercaseRoman:
            guard ordinal <= maximumRomanOrdinal else { return String(ordinal) }
            return roman(ordinal, uppercase: style == .uppercaseRoman)
        case .uppercaseLetters, .lowercaseLetters:
            guard (ordinal - 1) / 26 + 1 <= maximumLetterRepeatCount else { return String(ordinal) }
            return letters(ordinal, uppercase: style == .uppercaseLetters)
        }
    }

    /// `A … Z`, then `AA … ZZ`, then `AAA …` — the PDF specification's scheme, which is
    /// *not* spreadsheet-column numbering: 27 is `AA`, not `AB`.
    static func letters(_ ordinal: Int, uppercase: Bool) -> String {
        let alphabet = uppercase
            ? "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
            : "abcdefghijklmnopqrstuvwxyz"
        let zeroBased = ordinal - 1
        let letterIndex = zeroBased % 26
        let repeatCount = zeroBased / 26 + 1
        let scalars = Array(alphabet)
        let character = scalars[letterIndex]
        return String(repeating: character, count: repeatCount)
    }

    /// Additive-subtractive roman numerals. Values above 3999 are written with repeated
    /// `M`, which is what every PDF reader does and what the specification implies.
    static func roman(_ ordinal: Int, uppercase: Bool) -> String {
        let table: [(value: Int, symbol: String)] = [
            (1000, "M"), (900, "CM"), (500, "D"), (400, "CD"),
            (100, "C"), (90, "XC"), (50, "L"), (40, "XL"),
            (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")
        ]
        var remaining = ordinal
        var out = ""
        out.reserveCapacity(16)
        for entry in table {
            // Bounded: `remaining` strictly decreases by at least `entry.value` each turn.
            while remaining >= entry.value {
                out += entry.symbol
                remaining -= entry.value
            }
        }
        return uppercase ? out : out.lowercased()
    }
}
