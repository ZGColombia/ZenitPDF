import Foundation

/// What kind of claim this row's quantity makes. Stored, exported, and immutable after commit
/// (ADR-0012).
///
/// Until ADR-0012 every row in the Quantity Ledger made the same claim: *someone measured this
/// on a drawing*. Assemblies (feature 25) and table import (feature 31) break that monoculture,
/// and a derived or read row that *looks* measured is a value with an authority it does not
/// have. A bid built on the ledger must be able to say, per figure, which of three different
/// things it is.
public enum QuantityProvenance: String, Codable, Hashable, Sendable, CaseIterable {
    /// A person measured geometry on a drawing. The default, and the only value that existed
    /// before this ADR — absent in stored JSON decodes as `.measured`, which keeps every
    /// existing project readable with no migration pass.
    case measured
    /// Computed from a measured row by a named assembly line. `derivation` is mandatory.
    case derived
    /// Read from text printed on the drawing (a schedule, a dimension). `derivation` carries
    /// the source region and the recognised text instead of a formula.
    case read

    /// Whether a row with this provenance must carry a ``QuantityDerivation``.
    ///
    /// `true` for the two cases whose number descends from something other than measured
    /// geometry — the derivation is the ancestry, and a row without one would be a number
    /// with no reasons. `false` for `.measured`, where the ancestry already lives in
    /// ``MeasurementProvenance`` (ADR-0007) and a second, competing story is refused.
    public var requiresDerivation: Bool {
        switch self {
        case .measured: false
        case .derived, .read: true
        }
    }
}

/// The ancestry of a `.derived` or `.read` row (ADR-0012).
///
/// Mandatory for those two cases and refused for `.measured` —
/// ``MarkupRecord/quantityProvenanceViolation()`` is the one place that pairing rule is
/// stated, and the decoder enforces it so an invalid pairing cannot arrive from disk.
public struct QuantityDerivation: Codable, Hashable, Sendable {
    /// The measured markup this row descends from (`derived`), or nil (`read`).
    public var sourceMarkupID: MarkupID?
    /// The assembly line's formula text (`derived`) or the OCR text (`read`), verbatim.
    public var formulaText: String
    /// The inputs at evaluation time, by name, so the number is reproducible on paper.
    public var inputs: [String: String]
    /// Assembly definition id (`derived`) or page region (`read`), for the audit trail.
    public var originIdentifier: String

    /// Creates a derivation.
    public init(
        sourceMarkupID: MarkupID? = nil,
        formulaText: String,
        inputs: [String: String] = [:],
        originIdentifier: String
    ) {
        self.sourceMarkupID = sourceMarkupID
        self.formulaText = formulaText
        self.inputs = inputs
        self.originIdentifier = originIdentifier
    }
}

/// The ways a record's provenance and derivation can contradict each other (ADR-0012).
///
/// Named rather than boolean so a refusal can say *why* — the same shape
/// `ArtworkGeometry.limitViolation()` takes. It conforms to `Error` like the domain-specific
/// error enums of `ContractErrors.swift`.
public enum QuantityProvenanceViolation: Error, Hashable, Sendable, CustomStringConvertible {
    /// A `.derived` or `.read` row without the derivation that is mandatory for it.
    case missingDerivation(QuantityProvenance)
    /// A `.measured` row carrying a derivation, which only the two new cases may hold.
    case derivationOnMeasuredRow

    public var description: String {
        switch self {
        case .missingDerivation(let provenance):
            "a \(provenance.rawValue) row must carry a derivation and this one does not"
        case .derivationOnMeasuredRow:
            "a measured row must not carry a derivation"
        }
    }
}

extension MarkupRecord {

    /// The record's provenance/derivation contradiction, or `nil` when the pairing is valid.
    ///
    /// The one place ADR-0012's pairing rule is enforced: `derivation` is mandatory for
    /// `.derived` and `.read`, refused for `.measured`. The decoder calls this, so an invalid
    /// pairing cannot arrive from stored JSON either.
    public func quantityProvenanceViolation() -> QuantityProvenanceViolation? {
        switch (provenance.requiresDerivation, derivation) {
        case (true, nil): .missingDerivation(provenance)
        case (false, .some): .derivationOnMeasuredRow
        case (true, .some), (false, nil): nil
        }
    }
}
