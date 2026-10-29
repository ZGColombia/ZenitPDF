import Foundation
import ZPDFContracts

/// An ordered, de-duplicated collection of ``MeasurementWarning``.
///
/// Order matters: a result is `Hashable` and is compared in golden tests, so the same input has
/// to produce the same warning sequence on every run. De-duplication matters because a polygon
/// with forty holes must not produce forty identical "extreme scale" warnings.
struct WarningLog {
    private(set) var warnings: [MeasurementWarning] = []
    private var seen: Set<MeasurementWarning> = []

    init() {}

    mutating func add(
        _ code: MeasurementWarning.Code,
        field: MeasurementField? = nil,
        detail: String = ""
    ) {
        add(MeasurementWarning(code: code, field: field, detail: detail))
    }

    mutating func add(_ warning: MeasurementWarning) {
        guard seen.insert(warning).inserted else { return }
        warnings.append(warning)
    }

    mutating func merge(_ other: WarningLog) {
        for warning in other.warnings { add(warning) }
    }

    /// The warnings every tool raises from the scale alone (spec 10.2, 10.6).
    mutating func inspect(scale: ScaleTransform, options: MeasurementEngineOptions) {
        if scale.isExtreme {
            add(
                .extremeScale,
                detail: "metresPerPointX=\(scale.matrix.metresPerPointX) metresPerPointY=\(scale.matrix.metresPerPointY)"
            )
        }
        if let expected = options.expectedScaleVersion, scale.version < expected {
            add(.staleScaleVersion, detail: "used=\(scale.version) current=\(expected)")
        }
    }
}
