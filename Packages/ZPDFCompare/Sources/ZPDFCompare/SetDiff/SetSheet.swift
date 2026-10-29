import CoreGraphics
import Foundation

/// One sheet of one drawing set, as the set-level matcher sees it.
///
/// This is deliberately the smallest description that can support a matching decision:
/// where the sheet sits, what it is called, and how big it is. No document handle, no
/// file URL, no rendered content. The set-level pass runs *before* any page is
/// rasterised or scanned, and a matcher that could touch a document would be a matcher
/// that could be slow, could fail, and could not be reasoned about in a test.
///
/// The caller builds these from the page count and the labels it already has —
/// `PageLabelTable` in `ZPDFPDFKitBridge` produces the labels — and hands the engine
/// nothing else.
public struct SetSheet: Sendable, Hashable, Codable {

    /// Zero-based position of the sheet in its own document's page tree.
    ///
    /// Every index in a ``SheetMatching`` — in ``SheetMatching/pairs``, in
    /// ``SheetMatching/addedInNew``, in ``SheetMatching/removedFromOld`` — is one of
    /// these values, never an ordinal into the array that was passed in. The two
    /// coincide for a whole document read front to back and diverge the moment a caller
    /// matches a subset, so they are kept apart on purpose.
    ///
    /// Indices must be unique within a set; ``SheetMatcher/match(old:new:)`` refuses a
    /// set that repeats one rather than quietly dropping a sheet.
    public var index: Int

    /// What the drawing is called: `A-101`, `S-201`, `M-3.02`.
    ///
    /// A label is not a number and is not derivable from ``index``. It arrives verbatim,
    /// including whatever spacing and case the producer used, and every normalisation
    /// this engine performs is a documented rule in ``SheetLabel`` rather than a quiet
    /// clean-up at the boundary.
    public var label: String

    /// The sheet's page box, in PDF points (72 per inch).
    ///
    /// Used by one rule only — the positional fallback in ``SheetMatcher``, which will
    /// not pair two sheets of different paper sizes however well their positions line
    /// up. A caller holding a presentation-tier `PDFSizeValue` builds the `CGSize` from its
    /// width and height; this package speaks CoreGraphics because that is the geometry vocabulary the rest
    /// of `ZPDFCompare` already uses, and because an engine type must not reach up into
    /// a UI package for a width and a height.
    public var sizeInPoints: CGSize

    /// `false` when ``label`` was synthesised rather than read from the document — the
    /// `String(index + 1)` a page provider falls back to when the PDF has no `/PageLabels`
    /// (`labelIsExplicit` in `ZPDFPDFKitBridge`). A synthesised label is an ordinal, not a
    /// name, so the matcher never treats it as label evidence (BH-124).
    public var labelIsExplicit: Bool

    public init(index: Int, label: String, sizeInPoints: CGSize, labelIsExplicit: Bool = true) {
        self.index = index
        self.label = label
        self.sizeInPoints = sizeInPoints
        self.labelIsExplicit = labelIsExplicit
    }

    /// Convenience for callers that have two scalars rather than a size value.
    public init(
        index: Int,
        label: String,
        widthInPoints: Double,
        heightInPoints: Double,
        labelIsExplicit: Bool = true
    ) {
        self.init(
            index: index,
            label: label,
            sizeInPoints: CGSize(width: widthInPoints, height: heightInPoints),
            labelIsExplicit: labelIsExplicit
        )
    }

    private enum CodingKeys: String, CodingKey {
        case index, label, sizeInPoints, labelIsExplicit
    }

    /// Archives written before `labelIsExplicit` existed decode as explicit, which is what
    /// the matcher assumed of them at the time.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        index = try container.decode(Int.self, forKey: .index)
        label = try container.decode(String.self, forKey: .label)
        sizeInPoints = try container.decode(CGSize.self, forKey: .sizeInPoints)
        labelIsExplicit = try container.decodeIfPresent(Bool.self, forKey: .labelIsExplicit) ?? true
    }

    /// Whether ``label`` can serve as evidence at all: read from the document, and not
    /// empty after canonicalisation (an empty `/PageLabels` prefix on both sides is not a
    /// name either).
    public var labelIsEvidence: Bool {
        labelIsExplicit && !SheetLabel.canonical(label).isEmpty
    }
}

/// Which of the two sets a value belongs to.
public enum SetSide: String, Sendable, Hashable, Codable, CaseIterable {
    case old
    case new
}

/// The two label normalisations the matcher is allowed to perform, and nothing else.
///
/// Both are pure functions of a string, both are public, and both are unit-tested on
/// their own. That is the point: the difference between "these two sheets are the same
/// drawing" and "these two sheets happen to look alike" is decided here, so the rule has
/// to be readable and checkable without running a match.
///
/// Normalisation is deliberately shallow. Diacritics are not folded and punctuation is
/// not removed, because over-normalising turns two genuinely different drawings into one
/// pairing, and a wrong pairing reports changes against the wrong sheet — the failure
/// this whole feature is written to avoid.
public enum SheetLabel {

    /// Trim, collapse internal whitespace to single spaces, and case-fold.
    ///
    /// `"  A-101  "` and `"a-101"` produce the same key. `"A  -  105"` and `"A - 105"`
    /// produce the same key. `"A-101"` and `"A-1013"` do not.
    ///
    /// Case folding is `lowercased()`, which is locale-independent, so a sheet set does
    /// not match differently on a Turkish system than on a Swedish one.
    public static func canonical(_ label: String) -> String {
        label
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
    }

    /// ``canonical(_:)`` with **at most one** trailing revision suffix removed.
    ///
    /// Two suffix forms are recognised, and only these two:
    ///
    /// - `" rev X"` — a space, `rev`, a space, then a single letter.
    ///   `"A-102 rev C"` → `"a-102"`.
    /// - `"-X"` — a hyphen, then a single letter.
    ///   `"A-101-B"` → `"a-101"`. `A-101-B` is revision B of `A-101`, so when the old set
    ///   has no sheet actually called `A-101-B`, the two pair as the same drawing.
    ///
    /// `X` must be a **single letter**. This is what stops the rule eating real label
    /// text: `"A-1013"` keeps its `3` and stems to `"a-1013"`, so it never pairs with
    /// `"A-101"` on a label basis. `"A-101-BB"` keeps both letters for the same reason —
    /// two characters is not one.
    ///
    /// Stripping is applied once, not repeatedly: `"a-101-b-c"` stems to `"a-101-b"`. A
    /// label that is *only* a suffix (`"-B"`) is left alone, because an empty stem would
    /// match every other empty stem in the set.
    public static func stem(_ label: String) -> String {
        let canonical = canonical(label)
        return strippingRevisionSuffix(canonical) ?? canonical
    }

    private static func strippingRevisionSuffix(_ canonical: String) -> String? {
        // The last character has to be the revision letter itself. Anything else — a
        // digit, punctuation, nothing at all — ends the rule here.
        guard let last = canonical.last, last.isLetter else { return nil }
        let head = canonical.dropLast()

        if head.hasSuffix(" rev ") {
            let stem = String(head.dropLast(5))
            return stem.isEmpty ? nil : stem
        }
        if head.hasSuffix("-") {
            let stem = String(head.dropLast())
            return stem.isEmpty ? nil : stem
        }
        return nil
    }
}
