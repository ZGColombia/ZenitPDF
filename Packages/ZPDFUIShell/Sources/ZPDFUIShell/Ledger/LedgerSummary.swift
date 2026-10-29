import Foundation
import ZPDFDesignSystem
import ZPDFUIPresentation

/// A presenter that can say how many of its rows — after the filter — are of each
/// measurement kind.
///
/// The ledger bar's summary chips show one count per quantity kind ("Areas 2", "Lengths 7").
/// The totals beside those counts come from ``LedgerPresenting/grandTotals`` — the one
/// aggregation path the ledger has — but a total does not say how many rows made it, and
/// reading every row to count them is exactly what the index-addressed ledger forbids
/// (ADR-0003 §3.4). A presenter that already holds the projection answers this in O(kinds);
/// one that does not simply leaves the count off the chip rather than guessing it.
@MainActor
public protocol LedgerKindRowCounting: AnyObject {
    /// Rows that pass the active filter, per measurement kind. Kinds with no rows may be
    /// absent. Rows with no measurement kind (text, callouts) are not counted here.
    var rowCountsByMeasurementKind: [MeasurementKind: Int] { get }
}

#if DEBUG || ZPDF_MOCKS
/// The mock holds every row in memory, so it can count honestly — which is what lets the
/// previews and the shell tests show the chip counts the app shows. Debug and test builds only,
/// like the mock itself (R-142).
extension MockLedgerPresenter: LedgerKindRowCounting {
    public var rowCountsByMeasurementKind: [MeasurementKind: Int] {
        var counts: [MeasurementKind: Int] = [:]
        for index in 0..<rowCount {
            guard let kind = row(at: index)?.measurementKind else { continue }
            counts[kind, default: 0] += 1
        }
        return counts
    }
}
#endif

/// What the ledger bar's summary chips say: one chip per quantity kind, in the mockup's
/// order — Areas, Lengths, Counts, Markups.
///
/// Every total is read from the presenter's grand totals, never summed here: the
/// aggregation layer has one path (fix round 3 retired the second), and a header that did
/// its own arithmetic would be a third that could disagree with the table under it.
public struct LedgerSummary: Equatable, Sendable {

    /// The quantity kinds the bar summarises, in display order.
    public enum Kind: String, CaseIterable, Identifiable, Sendable {
        case areas
        case lengths
        case counts
        case markups

        public var id: String { rawValue }

        /// The chip's title.
        public var title: String {
            switch self {
            case .areas: return NSLocalizedString("Areas", comment: "Ledger summary chip: area measurements")
            case .lengths: return NSLocalizedString("Lengths", comment: "Ledger summary chip: length measurements")
            case .counts: return NSLocalizedString("Counts", comment: "Ledger summary chip: counted marks")
            case .markups: return NSLocalizedString("Markups", comment: "Ledger summary chip: every row in the ledger")
            }
        }

        /// The grand-totals column whose total the chip shows, or `nil` for the Markups chip,
        /// whose number is the row count itself.
        public var totalColumn: LedgerColumnID? {
            switch self {
            case .areas: return .planArea
            case .lengths: return .planLength
            case .counts: return .count
            case .markups: return nil
            }
        }

        /// The measurement kinds whose rows the chip's count covers when the presenter's totals
        /// carry no per-column row counts: the kinds whose headline value is the chip's total
        /// column (Arc Length's headline is Plan Length too — S-043). Cutouts are left out — they
        /// subtract from an area, they are not an area of their own. A presenter that counts
        /// (``LedgerTotals/valueCounts``) is preferred: kinds cannot see the Perimeter row that
        /// also fills Plan Area, or the open Wall Area run that fills Plan Length.
        public var measurementKinds: Set<MeasurementKind> {
            switch self {
            case .areas: return [.area, .rectangleArea, .ellipseArea]
            case .lengths: return [.length, .dimension, .polylength, .arcLength]
            case .counts: return [.count]
            case .markups: return []
            }
        }
    }

    /// One chip.
    public struct Chip: Equatable, Identifiable, Sendable {
        /// Which quantity kind this chip summarises.
        public let kind: Kind
        /// How many rows of this kind pass the filter, or `nil` when the presenter cannot say.
        /// For the Markups chip, the number of markups that carry no quantity (L-50); always set.
        public let rowCount: Int?
        /// The formatted grand total for the kind, or `nil` when there is none — nothing of
        /// the kind measured, or rows whose units disagree (the table shows "mixed" there).
        public let total: String?
        /// The total as VoiceOver should say it — the unit's full name ("2,480 square feet"),
        /// not its symbol — or `nil` to read ``total`` as written.
        public var spokenTotal: String? = nil

        public var id: Kind { kind }

        /// The chip's headline figure: the total where there is one, the count otherwise.
        /// Counts and Markups show a number of things, so their total *is* their headline.
        public var headline: String {
            if let total, !total.isEmpty { return total }
            if let rowCount { return rowCount.formatted() }
            return LedgerSummary.missingValue
        }

        /// The small secondary count badge — how many measurements make the total — on the
        /// Areas and Lengths chips only. Counts and Markups show a number of things as their
        /// headline already; a second number beside it ("3" count groups next to "12" marks)
        /// would be two counts to tell apart.
        public var badge: String? {
            guard kind == .areas || kind == .lengths, let rowCount, total != nil else { return nil }
            return rowCount.formatted()
        }

        /// What the chip's count box shows: the row count beside an Areas or Lengths total,
        /// or — for a chip whose figure is itself a number of things (Counts, Markups, or a
        /// kind with nothing measured) — that figure. `nil` when there is no count to show.
        public var displayCount: String? {
            if let badge { return badge }
            if displayTotal != nil { return nil }
            return headline
        }

        /// What the chip's second line shows: an Areas or Lengths total with its unit, or
        /// `nil` when the chip's figure is a count and sits in the count box instead.
        public var displayTotal: String? {
            guard kind == .areas || kind == .lengths, let total, !total.isEmpty else { return nil }
            return total
        }

        /// One sentence for VoiceOver — "Areas, 2 items, total 2,480 SF" — the design
        /// system's summary-chip wording, so every chip in the app reads the same way.
        public var accessibilityLabel: String {
            ZPDFSummaryChip.accessibilityLabel(
                title: kind.title,
                count: displayCount,
                total: displayTotal.map { spokenTotal ?? $0 }
            )
        }
    }

    /// Shown where a figure is unknown or empty.
    public static let missingValue = "\u{2014}"

    /// The chips, in display order.
    public let chips: [Chip]

    /// Builds the summary from what the presenter publishes.
    ///
    /// A chip's count is the number of rows in its total — ``LedgerTotals/valueCounts`` for
    /// the chip's column, which is also the number of rows its click (a "has a value" filter
    /// on that column) shows (S-043). Only a presenter whose totals carry no counts falls back
    /// to adding up `kindCounts`.
    ///
    /// - Parameters:
    ///   - totals: the presenter's grand totals (filtered rows only).
    ///   - rowCount: rows that pass the filter — the Markups chip's figure only for a presenter
    ///     that cannot count its markups (the previews' mock before L-50, a test double).
    ///   - kindCounts: per-kind row counts, or `nil` when the presenter cannot say.
    ///   - markupCount: markups in the document that carry no quantity, ledger row or not
    ///     (``LedgerMarkupCounting``) — what the Markups chip's name says it counts (L-50).
    ///   - format: renders a total with its unit — the pane passes the table's own totals
    ///     formatter (`LedgerNumberFormatting.display`) with the display units and locale in
    ///     force. `nil` uses the presenter's display string as it stands.
    ///   - speak: the same total with the unit's full name, for VoiceOver.
    public init(
        totals: LedgerTotals,
        rowCount: Int,
        kindCounts: [MeasurementKind: Int]?,
        markupCount: Int? = nil,
        format: ((DecimalQuantity) -> String)? = nil,
        speak: ((DecimalQuantity) -> String)? = nil
    ) {
        chips = Kind.allCases.map { kind in
            let count: Int?
            if kind == .markups {
                // L-50: four text boxes read "Markups 0" — the ledger's rows leave out every
                // markup without a quantity or a subject.
                count = markupCount ?? rowCount
            } else if let column = kind.totalColumn, let filled = totals.valueCounts[column] {
                count = filled
            } else if let kindCounts {
                count = kind.measurementKinds.reduce(0) { $0 + (kindCounts[$1] ?? 0) }
            } else {
                count = nil
            }
            var total: String?
            var spoken: String?
            if let column = kind.totalColumn,
               !totals.incompatibleColumns.contains(column),
               let quantity = totals.total(column) {
                let text = format?(quantity) ?? totals.displayValue(column)
                total = text.isEmpty ? nil : text
                spoken = speak?(quantity)
            }
            // A kind with no rows has no total to show, whatever the column says.
            if count == 0 { total = nil; spoken = nil }
            return Chip(kind: kind, rowCount: count, total: total, spokenTotal: total == nil ? nil : spoken)
        }
    }

    /// The chip for one kind.
    public func chip(_ kind: Kind) -> Chip? { chips.first { $0.kind == kind } }
}
