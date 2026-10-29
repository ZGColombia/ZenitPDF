import Foundation

/// One fixture's manifest plus the two ways of producing its bytes.
///
/// `streamTo` exists so that the large page-count fixtures never hold the whole
/// document in memory; when a fixture does not need it, the buffered path is used for
/// both.
struct FixtureBuild {
    let manifest: FixtureManifest
    let makeData: () throws -> Data
    let streamTo: ((FileHandle, String) throws -> Void)?

    init(
        manifest: FixtureManifest,
        makeData: @escaping () throws -> Data,
        streamTo: ((FileHandle, String) throws -> Void)? = nil
    ) {
        self.manifest = manifest
        self.makeData = makeData
        self.streamTo = streamTo
    }
}

// MARK: - Derivation shorthands

extension FixtureDerivation {

    static func closedForm(
        _ detail: String,
        conditionNumber: Double? = nil,
        magnitudeFloor: Double = 1.0
    ) -> FixtureDerivation {
        FixtureDerivation(
            method: .closedForm,
            detail: detail,
            conditionNumber: conditionNumber,
            magnitudeFloor: magnitudeFloor
        )
    }

    static func handComputation(
        _ detail: String,
        conditionNumber: Double? = nil,
        magnitudeFloor: Double = 1.0
    ) -> FixtureDerivation {
        FixtureDerivation(
            method: .handComputation,
            detail: detail,
            conditionNumber: conditionNumber,
            magnitudeFloor: magnitudeFloor
        )
    }

    /// The record used by fixtures that carry no measurable geometry — the hostile
    /// files, whose "expected value" is a typed error rather than a number.
    static let structuralOnly = FixtureDerivation(
        method: .handComputation,
        detail: "No measurable geometry; the expected result is a typed error, not a number.",
        magnitudeFloor: 1.0
    )
}

// There is deliberately no shared "compute the perimeter of these points" helper here.
// Every length and area in a manifest is written as an explicit arithmetic expression
// taken from the derivation string next to it, so that no manifest value can ever be
// produced by walking the same coordinate list a consumer is about to walk.
