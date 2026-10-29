import Foundation
import ZPDFContracts
import ZPDFUIPresentation

/// Translates a preset's measurement defaults into the engine's ``MeasurementParameters``, and
/// back again.
///
/// Two vocabularies meet here and nowhere else. `ZPDFUIPresentation` has no dependency on
/// `ZPDFContracts` — that is what lets the whole UI build and preview without the engines —
/// so the Tool Library speaks in ``ToolPresetMeasurementDefaults`` and the calculators speak
/// in ``MeasurementParameters``. One translation, in one file, is the only way the two can be
/// kept from drifting; a second one would be the mechanism by which a preset's depth means one
/// thing on the panel and another in the volume.
///
/// # What is deliberately *not* translated
///
/// - **`openingAreas`.** Those are the openings of one particular wall, measured on one
///   particular drawing. A preset that carried them would subtract somebody else's windows.
/// - **`display`.** The preset carries ``ToolPresetSummary/displayLengthUnit`` and the
///   measurement presenter already applies it; duplicating the whole ``DisplayUnitPolicy``
///   would give a preset two opinions about units.
/// - **`perSegmentRiseDrop` and `totalRiseDrop`.** A rise per segment describes the run in
///   front of the estimator, not a reusable tool, and a preset holding a segment list would
///   apply the wrong count of them to the next polyline.
public enum ToolPresetParameterBridge {

    // MARK: - Preset to engine

    /// A preset's defaults as engine parameters, layered onto whatever the markup already had.
    ///
    /// `base` is the markup's current parameters in Apply mode and ``MeasurementParameters/default``
    /// in Draw and Place. Layering rather than replacing is what makes Apply honest: a preset
    /// that says nothing about wall height must not erase a wall height somebody measured.
    ///
    /// `properties` narrows the write to what the target actually accepts. `nil` means "write
    /// everything the preset carries", which is Draw and Place — there is no existing markup to
    /// be incompatible with. Apply passes the applicable set from
    /// ``ToolPresetApplicability/plan(preset:targetKind:targetTool:)``, so a property the report
    /// says was skipped is also, provably, not written: the two come from one set.
    ///
    /// The two policies are the reason this parameter exists rather than a pre-filtered value.
    /// They always *have* a value — the engine defaults to `subtractFromArea` and `outerOnly` —
    /// so a filtered copy could not express "leave the markup's own policy alone", and applying
    /// a colour preset would quietly reset a cutout policy somebody set by hand.
    ///
    /// - Parameters:
    ///   - defaults: what the preset stores.
    ///   - base: the parameters to layer onto.
    ///   - properties: the properties that may be written, or `nil` for all of them.
    public static func parameters(
        applying defaults: ToolPresetMeasurementDefaults,
        onto base: MeasurementParameters = .default,
        writing properties: Set<ToolPresetProperty>? = nil
    ) -> MeasurementParameters {
        func writes(_ property: ToolPresetProperty) -> Bool {
            properties?.contains(property) ?? true
        }
        var merged = base
        if writes(.depth), let depth = defaults.depth {
            merged.depth = Domain.Quantity(shown: depth)
        }
        if writes(.wallHeight), let height = defaults.wallHeight {
            merged.height = Domain.Quantity(shown: height)
        }
        if writes(.wallHeightAtEnd), let end = defaults.wallHeightAtEnd {
            merged.heightAtEnd = Domain.Quantity(shown: end)
        }
        if writes(.volumeDepthReference), let reference = defaults.volumeDepthReference {
            merged.volumeDepthReference = volumeDepthReference(shown: reference)
        }
        if writes(.cutoutPolicy) {
            merged.cutoutPolicy = cutoutPolicy(shown: defaults.cutoutPolicy)
        }
        if writes(.perimeterPolicy) {
            merged.perimeterPolicy = perimeterPolicy(shown: defaults.perimeterPolicy)
        }
        merged.slope = slope(
            applying: defaults,
            onto: base.slope,
            writesMagnitude: writes(.slope),
            writesAzimuth: writes(.slopeAzimuth)
        )
        return merged
    }

    /// The slope a preset contributes, layered onto the markup's own.
    ///
    /// A magnitude alone switches the mode to ``SlopeMode/uniformPlane`` and keeps whatever
    /// azimuth was already established — a roof preset applied to an area somebody has already
    /// given a fall line to must not throw that fall line away. An azimuth alone is written
    /// onto the existing slope without inventing a magnitude, because an azimuth with no
    /// magnitude describes a direction on a flat plane, which is not a slope.
    static func slope(
        applying defaults: ToolPresetMeasurementDefaults,
        onto base: SlopeSpecification,
        writesMagnitude: Bool = true,
        writesAzimuth: Bool = true
    ) -> SlopeSpecification {
        var slope = base
        if writesMagnitude, let percent = defaults.slopePercent {
            slope.mode = .uniformPlane
            slope.magnitude = .percent(decimal(percent))
        }
        if writesAzimuth, let azimuth = defaults.slopeAzimuthDegrees {
            slope.azimuth = SlopeAzimuth(degrees: decimal(azimuth))
        }
        return slope
    }

    // MARK: - Engine to preset

    /// A markup's parameters as preset defaults — "make this a tool", with the maths included.
    ///
    /// The inverse of ``parameters(applying:onto:)`` over everything that inverse is defined
    /// for. A slope whose magnitude will not reduce to a ratio (a vertical plane) is carried as
    /// no magnitude rather than as a fabricated one: `SlopeExpression.ratio()` throws for that
    /// case on purpose, and swallowing the throw with a zero would store a flat roof.
    public static func defaults(of parameters: MeasurementParameters?) -> ToolPresetMeasurementDefaults {
        guard let parameters else { return .none }
        var defaults = ToolPresetMeasurementDefaults(
            depth: parameters.depth.map { Shown.Quantity(domain: $0) },
            wallHeight: parameters.height.map { Shown.Quantity(domain: $0) },
            wallHeightAtEnd: parameters.heightAtEnd.map { Shown.Quantity(domain: $0) },
            volumeDepthReference: parameters.volumeDepthReference.map(volumeDepthReference(domain:)),
            cutoutPolicy: cutoutPolicy(domain: parameters.cutoutPolicy),
            perimeterPolicy: perimeterPolicy(domain: parameters.perimeterPolicy)
        )
        if parameters.slope.mode == .uniformPlane,
           let magnitude = parameters.slope.magnitude,
           let percent = try? magnitude.percentValue() {
            defaults.slopePercent = double(percent)
        }
        if let azimuth = parameters.slope.azimuth {
            defaults.slopeAzimuthDegrees = double(azimuth.degrees)
        }
        return defaults
    }

    // MARK: - Enumerations

    static func cutoutPolicy(shown: ToolPresetCutoutPolicy) -> CutoutPolicy {
        switch shown {
        case .subtractFromArea: .subtractFromArea
        case .ignore: .ignore
        case .subtractAndReportSeparately: .subtractAndReportSeparately
        }
    }

    static func cutoutPolicy(domain: CutoutPolicy) -> ToolPresetCutoutPolicy {
        switch domain {
        case .subtractFromArea: .subtractFromArea
        case .ignore: .ignore
        case .subtractAndReportSeparately: .subtractAndReportSeparately
        }
    }

    static func perimeterPolicy(shown: ToolPresetPerimeterPolicy) -> PerimeterPolicy {
        switch shown {
        case .outerOnly: .outerOnly
        case .outerPlusCutoutEdges: .outerPlusCutoutEdges
        }
    }

    static func perimeterPolicy(domain: PerimeterPolicy) -> ToolPresetPerimeterPolicy {
        switch domain {
        case .outerOnly: .outerOnly
        case .outerPlusCutoutEdges: .outerPlusCutoutEdges
        }
    }

    static func volumeDepthReference(shown: ToolPresetVolumeDepthReference) -> VolumeDepthReference {
        switch shown {
        case .verticalDepth: .verticalDepth
        case .perpendicularThickness: .perpendicularThickness
        }
    }

    static func volumeDepthReference(domain: VolumeDepthReference) -> ToolPresetVolumeDepthReference {
        switch domain {
        case .verticalDepth: .verticalDepth
        case .perpendicularThickness: .perpendicularThickness
        }
    }

    // MARK: - Numbers

    /// A `Double` from the panel as an exact-as-possible `Decimal`.
    ///
    /// Through `String`, not through `Decimal(_: Double)`: the latter carries the binary
    /// representation's tail, so a slope the estimator typed as `33.3` would store as
    /// `33.30000000000000426…` and the ledger would show it back.
    static func decimal(_ value: Double) -> Decimal {
        guard value.isFinite else { return 0 }
        return Decimal(string: String(value)) ?? 0
    }

    /// A `Decimal` as a `Double`, for a panel field.
    static func double(_ value: Decimal) -> Double {
        NSDecimalNumber(decimal: value).doubleValue
    }
}
