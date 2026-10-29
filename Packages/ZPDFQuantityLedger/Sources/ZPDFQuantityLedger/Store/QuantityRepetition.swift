import Foundation
import ZPDFContracts

/// How the store scales a row's measured quantities by the row's repeat count.
///
/// A takeoff drawn once and marked "repeat × 6" — six identical balconies, one traced — must
/// count six times in every quantity a person or an export reads, and it must do so on the
/// *one evaluation path* (``LedgerStore/value(at:column:)``): the cell, the subtotal, the grand
/// total and the exported field all multiply or none of them do. Multiplying anywhere later —
/// in a presenter, in an exporter — is exactly the divergence QUALITY_BAR A25 forbids.
///
/// The store does not know which column carries the count; the application designates one at
/// build time (``LedgerStore/init(markups:columns:names:measurements:quantityMultiplierColumn:)``).
/// With no designated column every value passes through untouched.
enum QuantityRepetition {

    /// A row never repeats fewer than one time — a multiplier below this reads as corrupt.
    static let minimumCount = 1

    /// A row never repeats more than this — the application's `RepetitionColumn.maximumCount`,
    /// far beyond any building and far inside `Int`, so the conversion from `Decimal` is exact.
    static let maximumCount = 10_000

    /// The repeat count stored on a record, or `1` when there is none worth honouring.
    ///
    /// A stored `0` or negative is corrupt data: honouring it would zero or negate a real,
    /// measured quantity, so the safe reading is "once". Fractions floor — 2.9 repetitions are
    /// two complete ones. Mirrors the application-side reader exactly; the two must never
    /// disagree about what a stored cell means.
    static func repeatCount(record: MarkupRecord, multiplierColumn: ColumnID?) -> Int {
        guard let multiplierColumn,
              case .number(let quantity)? = record.customValues[multiplierColumn],
              quantity.dimension == .ratio || quantity.dimension == .count
        else { return minimumCount }
        // BH-618: the range is checked in `Decimal`, before any conversion. `intValue` of a
        // value beyond `Int` is unspecified — a saturated 9.2e18 multiplier on one machine,
        // a clamped "once" on another. Out of range is corrupt, and corrupt reads as once,
        // exactly as the application-side reader (`RepetitionColumn.effectiveCount`) says.
        let value = quantity.value
        guard value.isFinite, !value.isNaN,
              value >= Decimal(minimumCount), value < Decimal(maximumCount + 1)
        else { return minimumCount }
        var source = value
        var floored = Decimal()
        NSDecimalRound(&floored, &source, 0, .down)
        return (floored as NSDecimalNumber).intValue
    }

    /// One field's value under a repeat count. Extensive quantities scale; intensive ones and
    /// per-instance inputs pass through. Integer × `Decimal` is exact, so six repetitions equal
    /// the sum of six copies to the last digit.
    static func multiplied(
        _ quantity: DecimalQuantity,
        field: MeasurementField,
        count: Int
    ) -> DecimalQuantity {
        guard count > minimumCount, field.repeatsWithMarkup else { return quantity }
        return DecimalQuantity(value: quantity.value * Decimal(count), dimension: quantity.dimension)
    }
}

extension MeasurementField {
    /// Whether repeating the markup repeats this quantity.
    ///
    /// Extensive quantities — the ones a takeoff *sums* — scale with the number of instances:
    /// six identical rooms have six times the floor area and six times the skirting. Intensive
    /// values and per-instance inputs do not: six identical roofs share one slope, six columns
    /// share one radius, and six slabs share one depth. Getting this wrong is not cosmetic —
    /// a formula `netArea × depth` must see area × 6 and depth × 1, or the volume comes out
    /// × 36.
    var repeatsWithMarkup: Bool {
        switch self {
        case .count,
             .planLength, .trueLength, .perimeter, .truePerimeter,
             .circumference, .arcLength,
             .planArea, .trueArea, .netArea, .cutoutArea,
             .planWallArea, .wallArea, .netWallArea,
             .volume:
            true
        case .rise, .run, .slopeRatio, .slopePercent, .slopeAngle,
             .depth, .height, .radius, .diameter, .angle:
            false
        }
    }
}
