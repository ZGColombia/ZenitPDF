import Foundation
import ZPDFContracts

/// How a case's expected values were obtained.
///
/// This is recorded per case, not per corpus, because the honesty of a golden set is exactly the
/// question "where did this number come from?". A value derived from the implementation it is
/// meant to police is worth nothing, so the corpus states its provenance and
/// `CorpusIntegrityTests` asserts that every case has one.
public enum GoldenDerivation: String, Codable, Hashable, Sendable, CaseIterable {
    /// Closed-form arithmetic a person can check on paper: shoelace by hand, `b*h/2`,
    /// `pi r^2`, `sqrt(1 + r^2)`. The expression in the case is the derivation.
    case handDerived
    /// A closed form evaluated by an independent tool (a numerical arc-length integral for an
    /// ellipse perimeter, for instance), with the reference value embedded as a literal.
    case independentNumericalReference
    /// The expectation is a *property* rather than a number: a warning that must be raised, or
    /// an invariant such as "no value is infinite".
    case invariant
}

/// One golden measurement case.
public struct GoldenCase: Sendable, CustomStringConvertible {
    /// Stable identifier, used in test names and in failure output.
    public let id: String
    /// One line saying what the case is and where its numbers come from.
    public let title: String
    public let derivation: GoldenDerivation
    public let tool: MeasurementTool
    public let geometry: MeasurementGeometry
    public let scale: ScaleTransform
    public let parameters: MeasurementParameters
    /// Expected values in SI base units: metres, square metres, cubic metres, radians, counts.
    public let expected: [MeasurementField: Double]
    /// Warnings the case must raise.
    public let expectedWarnings: Set<MeasurementWarning.Code>
    /// Warnings the case must **not** raise.
    public let forbiddenWarnings: Set<MeasurementWarning.Code>
    /// When set, the gate configures the engine with this "current scale version", which is how
    /// the stale-scale warning is provoked without inventing a second scale.
    public let expectedScaleVersion: Int?
    /// When set, the engine must REFUSE the case with an error whose description contains
    /// this text, and no value is expected. ADR-0015 / QUALITY_BAR 2.5: a cutout entirely
    /// outside its parent is a refusal, not a warning with a bare value.
    public let expectedRefusal: String?

    public init(
        id: String,
        title: String,
        derivation: GoldenDerivation,
        tool: MeasurementTool,
        geometry: MeasurementGeometry,
        scale: ScaleTransform,
        parameters: MeasurementParameters = .default,
        expected: [MeasurementField: Double] = [:],
        expectedWarnings: Set<MeasurementWarning.Code> = [],
        forbiddenWarnings: Set<MeasurementWarning.Code> = [],
        expectedScaleVersion: Int? = nil,
        expectedRefusal: String? = nil
    ) {
        self.id = id
        self.title = title
        self.derivation = derivation
        self.tool = tool
        self.geometry = geometry
        self.scale = scale
        self.parameters = parameters
        self.expected = expected
        self.expectedWarnings = expectedWarnings
        self.forbiddenWarnings = forbiddenWarnings
        self.expectedScaleVersion = expectedScaleVersion
        self.expectedRefusal = expectedRefusal
    }
}

extension GoldenCase {
    public var description: String { "\(id): \(title)" }
}

/// The tolerances of spec 1.2, as relative fractions.
public enum GoldenTolerance: Sendable {
    /// 0.05 %.
    public static let length = 0.000_5
    /// 0.10 %.
    public static let area = 0.001_0
    /// 0.15 %.
    public static let volume = 0.001_5
    /// Counts and ratios are exact; this is the slack for a value that should be zero.
    public static let absoluteFloor = 1e-9

    /// The relative tolerance a field is judged by.
    public static func relative(for field: MeasurementField) -> Double {
        switch field.dimension.lengthPower {
        case 3: volume
        case 2: area
        case 1: length
        default: length
        }
    }
}
