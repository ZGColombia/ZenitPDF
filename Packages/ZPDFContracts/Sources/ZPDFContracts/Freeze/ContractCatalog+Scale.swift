import Foundation

extension ContractCatalog {

    static func scaleContract(frozenAt: String) throws -> ContractDocument {
        var types: [ContractTypeDescription] = []

        types.append(try .reflecting(
            ContractSamples.matrix,
            name: "AffineScaleMatrix",
            summary: "The affine map r = A * p + b from PDF page points to real-world metres (spec 10.1).",
            annotations: [
                "a": .init("m / PDF point", "finite; persisted as a decimal string"),
                "b": .init("m / PDF point", "finite; persisted as a decimal string"),
                "c": .init("m / PDF point", "finite; persisted as a decimal string"),
                "d": .init("m / PDF point", "finite; persisted as a decimal string"),
                "tx": .init("m", "finite; persisted as a decimal string; not applied to deltas"),
                "ty": .init("m", "finite; persisted as a decimal string; not applied to deltas")
            ],
            invariants: [
                "The six components are stored as Decimal and persisted as decimal strings, so a scale round-trips bit-identically across builds and locales.",
                "Geometry maths reads the Double projection through `components`; the crossing is explicit.",
                "det(A) == 0 makes inverted() throw ScaleError.singularMatrix.",
                "abs(det(A)) is the area factor: square metres per square PDF point.",
                "length(from:to:) maps the delta, not the two endpoints, so translation cannot leak into a length."
            ]
        ))

        types.append(try .reflecting(
            ContractSamples.unitPolicy,
            name: "ScaleUnitPolicy",
            summary: "Display unit and precision metadata carried by a scale.",
            annotations: [
                "length": .init("-", "display unit for lengths measured under this scale"),
                "area": .init("-", "display unit for areas"),
                "volume": .init("-", "display unit for volumes"),
                "angle": .init("-", "display unit for angles"),
                "precision": .init("-", "applied at the view and export boundary only")
            ]
        ))

        types.append(try .reflecting(
            ContractSamples.scale,
            name: "ScaleTransform",
            summary: "A versioned, identified scale: the matrix plus everything needed to reproduce and audit it (spec 10.1, 10.6).",
            annotations: [
                "id": .init("-", "stable across edits to the matrix"),
                "pageID": .init("-", "the page this scale belongs to; nil only for a bare engine value or a pre-v2 project"),
                "version": .init("-", "bumped on every matrix change; markups record the version they used"),
                "matrix": .init("m / PDF point", "see AffineScaleMatrix"),
                "units": .init("-", "display metadata only; never changes a stored value"),
                "source": .init("-", "provenance; the UI must never present a guessed scale as a measured one"),
                "label": .init("-", "optional human label such as \"1:50\"")
            ],
            invariants: [
                "uniform() and separateXY() reject a zero, negative or non-finite factor with ScaleError.nonPositiveScale.",
                "A factor outside 1e-6...1e4 metres per PDF point needs explicit confirmation (ScaleError.extremeScaleRequiresConfirmation).",
                "Two-point calibration rejects identical or near-identical points (default floor \(ContractNumberText.text(ScaleTransform.minimumCalibrationPDFDistance)) PDF points) and a non-positive known length.",
                "A preset drawing ratio honours the page's /UserUnit: metresPerPoint = 0.0254 / 72 * denominator / numerator * userUnit (ScaleTransform.preset, spec 9.1). A calibration needs no correction because its points already live in the page's user space.",
                "inverse() returns a bare AffineScaleMatrix, not a ScaleTransform: the inverse has no id, no version and no provenance, and calling it a scale is how a metres-per-point number ends up persisted as points-per-metre.",
                "The matrix only ever changes through revised(matrix:source:), which bumps the version.",
                "A scale belongs to a page. The order a measurement resolves by is: the Scale Region containing the geometry, else the page's own scale, else nothing — and nothing refuses the measurement rather than computing it at 1:1 or against a sibling page's calibration.",
                "assigned(toPage:) does not bump the version: recording which sheet a scale was calibrated on changes no number, and bumping would mark every measurement under it stale for nothing."
            ]
        ))

        types.append(.enumeration(
            ScaleSource.self,
            name: "ScaleSource",
            summary: "Where a scale came from (spec 10.2, 10.3, 10.4).",
            invariants: [
                "Provenance is part of the contract: a recalculation prompt reads differently for an inherited scale than for a hand-calibrated one."
            ]
        ))

        types.append(ContractTypeDescription(
            name: "PrecisionMode",
            kind: "enum",
            summary: "How a value is rounded when it is shown or exported (spec 11.5).",
            cases: [
                ContractCaseDescription(name: "decimalPlaces", rawValue: "Int", note: ContractNumberText.range(PrecisionMode.decimalPlacesRange)),
                ContractCaseDescription(name: "imperialFraction", rawValue: "ImperialFractionDenominator", note: "nearest 1/denominator")
            ],
            invariants: [
                "Display rounding never touches the stored SI value (spec 11.5).",
                "decimalPlaces outside \(ContractNumberText.range(PrecisionMode.decimalPlacesRange)) throws ScaleError.unsupportedDecimalPlaces, from validate() and from init(from:) alike: a stored precision is validated when it is decoded (ADR-0017)."
            ]
        ))

        types.append(.enumeration(
            ImperialFractionDenominator.self,
            name: "ImperialFractionDenominator",
            summary: "The imperial fraction denominators the product supports (spec 11.5).",
            note: { "1/\($0.rawValue)" }
        ))

        types.append(.enumeration(
            ScaleChangePolicy.self,
            name: "ScaleChangePolicy",
            summary: "The three answers to \"this scale changed, what about the measurements?\" (spec 10.6).",
            invariants: ["Recalculate is undoable."]
        ))

        types.append(.enumeration(
            ScaleApplicationScope.self,
            name: "ScaleApplicationScope",
            summary: "The scope a scale is applied to in a bulk operation (spec 10.5).",
            invariants: ["The user sees a preview and the number of affected markups before a bulk apply."]
        ))

        types.append(.enumeration(
            ScaleRegionCrossingPolicy.self,
            name: "ScaleRegionCrossingPolicy",
            summary: "What happens when a markup crosses two Scale Regions (spec 10.4).",
            invariants: [
                "There is no case for choosing a scale silently. The app never quietly picks the wrong scale."
            ]
        ))

        return ContractDocument(
            contract: "SCALE_CONTRACT",
            contractVersion: ContractVersion.scale,
            frozenAt: frozenAt,
            generator: generatorName,
            specSections: ["10.1", "10.2", "10.3", "10.4", "10.5", "10.6", "11.5"],
            summary: """
                The scale model: an affine map from PDF page points to metres, persisted as \
                decimal strings, versioned so every measurement can be traced to the scale that \
                produced it.
                """,
            types: types,
            tables: [
                ContractTable(
                    name: "scaleGuards",
                    columns: ["guard", "value", "error"],
                    rows: [
                        ["minimum metres per PDF point before confirmation",
                         ScaleTransform.sanePointScaleRange.lowerBound.description,
                         "extremeScaleRequiresConfirmation"],
                        ["maximum metres per PDF point before confirmation",
                         ScaleTransform.sanePointScaleRange.upperBound.description,
                         "extremeScaleRequiresConfirmation"],
                        ["minimum two-point calibration distance",
                         "\(ContractNumberText.text(ScaleTransform.minimumCalibrationPDFDistance)) PDF points",
                         "calibrationPointsTooClose"],
                        ["minimum known length", "> 0", "nonPositiveKnownLength"],
                        ["determinant", "!= 0", "singularMatrix"]
                    ]
                )
            ],
            invariants: [
                "r = A * p + b, with A in metres per PDF point and b in metres (spec 10.1).",
                "realArea = abs(det(A)) * pdfArea (spec 10.1).",
                "Matrix components persist as decimal strings, never as binary floats.",
                "A markup stores the scale id, the scale version, the original PDF geometry, the computed SI values and the formula version (spec 10.6).",
                "Changing a scale offers Recalculate / Keep existing / Cancel, and Recalculate is undoable (spec 10.6).",
                "Scale Regions may not overlap by default; a markup crossing two is split, resolved by the user, or blocked (spec 10.4)."
            ]
        )
    }
}
