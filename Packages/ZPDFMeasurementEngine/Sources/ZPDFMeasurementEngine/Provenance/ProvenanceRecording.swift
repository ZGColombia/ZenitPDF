import Foundation
import ZPDFContracts

/// What a caller knows that a pure calculation does not (ADR-0007).
///
/// The engine itself stays pure: no clock, no build identity, no calibration UI state. All of
/// that is context the *caller* already holds at the moment it asks for a measurement, and this
/// value is how it hands the context over. The clock is injected — nothing here reads the wall
/// clock — so a test pins `computedAt` and the whole provenance record is deterministic.
public struct ProvenanceContext: Sendable {
    /// Build identity stamped into ``MeasurementProvenance/engineVersion``, for example the
    /// app version string.
    public var engineVersion: String
    /// The picked points and entered length behind the scale, when the scale was calibrated.
    /// `nil` for a preset or inherited scale.
    public var calibrationEvidence: CalibrationEvidence?
    /// The document layer the markup was drawn against. Reserved by ADR-0007 §5; `nil` until
    /// the layer model lands.
    public var layerName: String?
    /// The injected clock behind ``MeasurementProvenance/computedAt``.
    public var timestamps: any TimestampProviding

    public init(
        engineVersion: String,
        calibrationEvidence: CalibrationEvidence? = nil,
        layerName: String? = nil,
        timestamps: any TimestampProviding
    ) {
        self.engineVersion = engineVersion
        self.calibrationEvidence = calibrationEvidence
        self.layerName = layerName
        self.timestamps = timestamps
    }

    /// Builds the provenance record for one calculation.
    ///
    /// Everything except the clock reading is a pure function of the inputs the engine also
    /// saw, so the record cannot disagree with the calculation it describes.
    public func provenance(
        geometry: MeasurementGeometry,
        scale: ScaleTransform,
        parameters: MeasurementParameters,
        formulaVersion: Int
    ) -> MeasurementProvenance {
        MeasurementProvenance(
            geometryDigest: GeometryDigest.digest(of: geometry),
            scaleID: scale.id,
            scalePageID: scale.pageID,
            scaleVersion: scale.version,
            scaleSource: scale.source,
            calibrationEvidence: calibrationEvidence,
            slope: parameters.slope,
            parameters: parameters,
            formulaVersion: formulaVersion,
            engineVersion: engineVersion,
            computedAt: timestamps.now(),
            layerName: layerName
        )
    }
}

/// A ``MeasurementEngine`` whose every result carries its derivation (ADR-0007).
///
/// ```swift
/// let recording = ProvenanceRecording(
///     engine: MeasurementEngine(),
///     context: ProvenanceContext(engineVersion: appVersion, timestamps: clock)
/// )
/// let result = try recording.calculate(tool: .area, geometry: g, scale: s, parameters: p)
/// // result.provenance is populated; result.values are byte-identical to the bare engine's.
/// ```
///
/// The wrapper changes nothing about the calculation: values, warnings and formula version are
/// exactly what the wrapped engine produced. It only attaches the ``MeasurementProvenance``
/// built from the same inputs, which is why it exists — provenance must be captured at
/// computation time, or not at all.
public struct ProvenanceRecording: Sendable {
    public let engine: MeasurementEngine
    public let context: ProvenanceContext

    public init(engine: MeasurementEngine = MeasurementEngine(), context: ProvenanceContext) {
        self.engine = engine
        self.context = context
    }

    /// Runs a tool and attaches the derivation to the result.
    public func calculate(
        tool: MeasurementTool,
        geometry: MeasurementGeometry,
        scale: ScaleTransform,
        parameters: MeasurementParameters = .default
    ) throws -> MeasurementResult {
        let result = try engine.calculate(
            tool: tool,
            geometry: geometry,
            scale: scale,
            parameters: parameters
        )
        return result.attaching(context.provenance(
            geometry: geometry,
            scale: scale,
            parameters: parameters,
            formulaVersion: result.formulaVersion
        ))
    }
}
