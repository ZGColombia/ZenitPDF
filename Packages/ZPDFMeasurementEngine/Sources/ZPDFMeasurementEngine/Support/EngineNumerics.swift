import Foundation
import ZPDFContracts

/// The engine's half of the numeric policy in spec 11.4.
///
/// Geometry stays in `Double` for the whole calculation and crosses into `Decimal` exactly once
/// per produced value, at a defined significance. Nothing here rounds for display.
enum EngineNumerics {

    /// `Double` -> `Decimal` at the policy significance, with the non-finite case typed.
    static func decimal(_ value: Double) throws(MeasurementEngineError) -> Decimal {
        do {
            return try NumericPolicy.decimal(from: value)
        } catch let error as NumericError {
            throw MeasurementEngineError.numeric(error)
        } catch {
            throw MeasurementEngineError.numeric(.notRepresentableAsDecimal(value))
        }
    }

    /// Re-normalises a `Decimal` produced by `Decimal` arithmetic back to the policy
    /// significance.
    ///
    /// Needed wherever a geometry value is multiplied by a *derived* scale factor: a factor
    /// born from `Decimal` division (`5 m / 283.465 pt`, say) carries the full 38-digit
    /// mantissa, so its product does too — and two such products cannot be added exactly
    /// within `Decimal`, which makes the aggregation core's exact-or-refuse addition
    /// (QUALITY_BAR A1) refuse a plain two-area total on any real calibrated drawing. The
    /// digits beyond the policy significance are noise, not information: the value's true
    /// precision is bounded by its `Double` geometry stage. So the product is taken back
    /// through the same policy crossing every other produced value uses.
    static func normalised(_ value: Decimal) throws(MeasurementEngineError) -> Decimal {
        try decimal(NumericPolicy.double(from: value))
    }

    /// The **one** multiplication of two produced `Decimal` values: the product, re-normalised
    /// to the policy significance.
    ///
    /// The rule "a product of policy-normalised decimals must be normalised again or the
    /// ledger refuses to add it" was found twice (area × slope factor, then volume and wall
    /// area — code review CR-23) and used to be applied by hand at each site. Routing every
    /// multiplication through here means the next calculator that multiplies cannot forget
    /// the step (IM-072).
    static func product(_ left: Decimal, _ right: Decimal) throws(MeasurementEngineError) -> Decimal {
        try normalised(left * right)
    }

    /// ``product(_:_:)`` for dimensioned quantities: the dimension is derived by
    /// ``DecimalQuantity/multiplied(by:)`` (metres squared times metres is metres cubed or it is
    /// a typed error), and the value is re-normalised.
    static func product(
        _ left: DecimalQuantity,
        _ right: DecimalQuantity
    ) throws(MeasurementEngineError) -> DecimalQuantity {
        let raw: DecimalQuantity
        do {
            raw = try left.multiplied(by: right)
        } catch let error as DimensionError {
            throw MeasurementEngineError.dimension(error)
        } catch let error as NumericError {
            throw MeasurementEngineError.numeric(error)
        } catch {
            throw MeasurementEngineError.dimension(
                .incompatibleDimensions(left: left.dimension, right: right.dimension)
            )
        }
        return DecimalQuantity(value: try normalised(raw.value), dimension: raw.dimension)
    }

    /// Compensated sum, per spec 11.4: pairwise below the policy threshold, Kahan–Babuska–Neumaier
    /// from it. Delegated so there is exactly one summation policy in the product.
    ///
    /// The terms are put into a canonical order first, which is what makes QUALITY_BAR **P7**
    /// hold *exactly* rather than nearly. Both `pairwiseSum` and `kahanSum` are functions of the
    /// term *sequence*, not of the term multiset: rotating a polygon's vertex list rotates the
    /// per-segment length array, changes the pairing, and moves the last bit of the total. That
    /// bit survives into the stored `Decimal` — a 5-gon at 1 ft/pt measured 15.9845047319568 m
    /// from one starting vertex and 15.9845047319567 m from another — and P7 requires exact
    /// equality under rotation and reversal, not agreement to a tolerance.
    ///
    /// Sorting by `(|x|, x)` is a canonical order on the multiset: two terms compare equal only
    /// when they are the same value, so every permutation of the same terms sorts to the same
    /// array and therefore to the same sum. It is also the numerically better order, smallest
    /// magnitude first, which is why this costs accuracy nothing. This is the same remedy P5
    /// prescribes for the cutout pipeline: canonicalise the input order rather than hope the
    /// operation is order-blind.
    ///
    /// A non-finite term short-circuits: it must not be fed to `sort`, whose predicate would stop
    /// being a strict weak ordering. It propagates instead and is refused by ``decimal(_:)``.
    static func sum(_ values: [Double]) -> Double {
        guard values.count > 1 else { return values.first ?? 0 }
        for value in values where !value.isFinite {
            return NumericPolicy.sum(values)
        }
        let ordered = values.sorted { left, right in
            let leftMagnitude = Swift.abs(left)
            let rightMagnitude = Swift.abs(right)
            if leftMagnitude != rightMagnitude { return leftMagnitude < rightMagnitude }
            return left < right
        }
        return NumericPolicy.sum(ordered)
    }
}
