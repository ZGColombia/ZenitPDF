import Foundation
import ZPDFContracts

/// Rise/Drop applied to a polyline (spec 12.9).
///
/// The two modes are explicit rather than inferred, because the same drawing and the same total
/// fall give different true lengths depending on which one the user meant:
///
/// ```text
/// per segment: totalTrueLength = Σ sqrt(planSegment_i^2 + riseDrop_i^2)
/// total:       totalTrueLength =   sqrt(planLength^2    + totalRiseDrop^2)
/// ```
///
/// For the same total fall, per-segment is never shorter than total-applied — it is the triangle
/// inequality applied segment by segment — and the two are equal exactly when the fall is
/// distributed in proportion to the segment lengths, i.e. when the polyline really is a plane of
/// constant slope. Any other distribution makes them differ, which is exactly why guessing
/// between the two modes is not acceptable.
enum RiseDropMeasure {

    struct Result: Sendable {
        var planLengthMetres: Double
        var trueLengthMetres: Double
        /// For the total mode, the total rise or drop as given. For the per-segment mode, the
        /// **gross** vertical travel `sum |riseDrop_i|` carrying the sign of the net change:
        /// a run that climbs 2 m and drops 2 m has travelled 4 m vertically, and that — not
        /// the net 0 — is what its true length reflects. Summing the signed rises reported a
        /// slope of 0 for a run whose true length said otherwise (code review CR-32). A
        /// monotone run gives the same signed value in both modes.
        var riseMetres: Double
    }

    static func perSegment(
        segmentLengths: [Double],
        riseDrops: [Decimal],
        warnings: inout WarningLog
    ) -> Result {
        if riseDrops.count != segmentLengths.count {
            warnings.add(
                .riseDropCountMismatch,
                field: .trueLength,
                detail: "segments=\(segmentLengths.count) riseDrops=\(riseDrops.count)"
            )
        }
        var trueLengths: [Double] = []
        var rises: [Double] = []
        trueLengths.reserveCapacity(segmentLengths.count)
        for (index, plan) in segmentLengths.enumerated() {
            let rise = index < riseDrops.count
                ? NumericPolicy.double(from: riseDrops[index])
                : 0
            rises.append(rise)
            trueLengths.append((plan * plan + rise * rise).squareRoot())
        }
        let netRise = EngineNumerics.sum(rises)
        let grossTravel = EngineNumerics.sum(rises.map { Swift.abs($0) })
        return Result(
            planLengthMetres: EngineNumerics.sum(segmentLengths),
            trueLengthMetres: EngineNumerics.sum(trueLengths),
            riseMetres: netRise < 0 ? -grossTravel : grossTravel
        )
    }

    static func total(
        planLengthMetres: Double,
        totalRiseDrop: Decimal
    ) -> Result {
        let rise = NumericPolicy.double(from: totalRiseDrop)
        return Result(
            planLengthMetres: planLengthMetres,
            trueLengthMetres: (planLengthMetres * planLengthMetres + rise * rise).squareRoot(),
            riseMetres: rise
        )
    }
}
