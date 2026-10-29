import Foundation
import ZPDFContracts

/// Which rectangle a coverage percentage is a percentage **of**.
///
/// Invariant: the coverage percentage names its denominator ("of the drawn extent", never "of
/// the paper"), or an A1 sheet with a small plan reads as 80 % forgotten. This enum is the
/// engine's half of that promise — it travels on ``CoverageResult/denominator`` so that no
/// caller can display a fraction without having been handed the name of what it was divided by.
///
/// The engine deliberately carries **no user-facing string** for these cases. Wording is a UI
/// concern and belongs in a localizable resource next to the label that shows it.
public enum CoverageExtentKind: String, Codable, Hashable, Sendable, CaseIterable {

    /// The page box: the whole sheet, margins and title block included.
    ///
    /// Honest, and usually the wrong denominator to *show*: a small plan on a large sheet reads
    /// as mostly forgotten. Use it when the vector extraction has produced no ink bounds.
    case pageBox

    /// The drawn extent: the bounding box of the page's ink, from the vector extraction.
    ///
    /// This is the denominator to show, because empty margin is not something an
    /// estimator forgot to measure.
    case inkBounds
}

/// The rectangle a coverage map divides by, and where that rectangle came from.
///
/// # The engine never guesses
///
/// There is no `.automatic` case and there is no fallback that derives ink bounds from the
/// measured polygons. Ink bounds are a property of the *page*, produced by the vector extraction,
/// and a page whose extraction has not run (or has run and found nothing) has none. Inventing one
/// — from the measured areas, say — would make the denominator a function of the answer, and the
/// percentage would then approach 100 % simply because the estimator stopped measuring.
///
/// So the caller passes what it actually has: ``inkBounds(_:)`` when the extraction gave it ink
/// bounds for this page, ``pageBox(_:)`` otherwise. Both are truthful; they are not
/// interchangeable, and ``CoverageResult/denominator`` says which one produced the number.
///
/// Everything here is canonical PDF page space (spec 9.1): points, origin at the lower left,
/// y increasing upwards. No zoom, no view transform, no scale.
public enum CoverageExtent: Codable, Hashable, Sendable {

    /// The page box, for a page with no ink bounds available.
    case pageBox(PDFRect)

    /// The drawn extent reported by the vector extraction for this page.
    case inkBounds(PDFRect)

    /// The rectangle itself, whichever case this is.
    public var rect: PDFRect {
        switch self {
        case let .pageBox(rect), let .inkBounds(rect): rect
        }
    }

    /// The name of this denominator, for ``CoverageResult/denominator``.
    public var kind: CoverageExtentKind {
        switch self {
        case .pageBox: .pageBox
        case .inkBounds: .inkBounds
        }
    }
}
