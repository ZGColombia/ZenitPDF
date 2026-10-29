import Foundation
import ZPDFUIPresentation

/// The counted phrases the measurement screens build their sentences from, each with its
/// singular (T-062).
///
/// Every one of these used to be a flat `%d` inside a longer format, so the singular — the
/// common case for the Current page target, a Count with one mark, a region measuring one
/// thing — read "1 pages", "1 markups", "Apply 1 Proposed Scales". A sentence that counts
/// several things is now built from separately pluralised phrases; the plural rules live in
/// `Plurals.stringsdict` (see ``LocalizedPlural``), with the English one/other choice made here
/// when the catalogue carries no rule.
enum MeasurementPlurals {

    /// "1 page" / "4 pages".
    static func pages(_ count: Int) -> String {
        LocalizedPlural.string(
            "%lld pages",
            count: count,
            one: NSLocalizedString("%lld page", comment: "Count of pages, singular"),
            other: NSLocalizedString("%lld pages", comment: "Count of pages, plural")
        )
    }

    /// "1 markup" / "30 markups".
    static func markups(_ count: Int) -> String {
        LocalizedPlural.string(
            "%lld markups",
            count: count,
            one: NSLocalizedString("%lld markup", comment: "Count of markups, singular"),
            other: NSLocalizedString("%lld markups", comment: "Count of markups, plural")
        )
    }

    /// "1 measurement" / "12 measurements".
    static func measurements(_ count: Int) -> String {
        LocalizedPlural.string(
            "%lld measurements",
            count: count,
            one: NSLocalizedString("%lld measurement", comment: "Count of measurements, singular"),
            other: NSLocalizedString("%lld measurements", comment: "Count of measurements, plural")
        )
    }

    /// "1 sheet" / "40 sheets".
    static func sheets(_ count: Int) -> String {
        LocalizedPlural.string(
            "%lld sheets",
            count: count,
            one: NSLocalizedString("%lld sheet", comment: "Count of drawing sheets, singular"),
            other: NSLocalizedString("%lld sheets", comment: "Count of drawing sheets, plural")
        )
    }

    /// "1 point" / "3 points".
    static func points(_ count: Int) -> String {
        LocalizedPlural.string(
            "%lld points",
            count: count,
            one: NSLocalizedString("%lld point", comment: "Count of placed measurement points, singular"),
            other: NSLocalizedString("%lld points", comment: "Count of placed measurement points, plural")
        )
    }

    /// "1 Scale Region" / "2 Scale Regions".
    static func scaleRegions(_ count: Int) -> String {
        LocalizedPlural.string(
            "%lld Scale Regions",
            count: count,
            one: NSLocalizedString("%lld Scale Region", comment: "Count of Scale Regions, singular"),
            other: NSLocalizedString("%lld Scale Regions", comment: "Count of Scale Regions, plural")
        )
    }
}
