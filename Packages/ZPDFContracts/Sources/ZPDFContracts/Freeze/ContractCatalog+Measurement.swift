import Foundation

extension ContractCatalog {

    static func measurementContract(frozenAt: String) throws -> ContractDocument {
        var types: [ContractTypeDescription] = []

        types.append(.enumeration(
            MeasurementTool.self,
            name: "MeasurementTool",
            summary: "The measurement tools the product ships (spec 12.1)."
        ))

        types.append(try .reflecting(
            ContractSamples.segment,
            name: "SegmentGeometry",
            summary: "A straight segment in page space.",
            annotations: [
                "start": .init("PDF point", "finite"),
                "end": .init("PDF point", "finite")
            ]
        ))

        types.append(try .reflecting(
            ContractSamples.ring,
            name: "PolygonRing",
            summary: "One ring of a polygon.",
            annotations: [
                "points": .init("PDF point", "the closing vertex is not repeated"),
                "isClosed": .init("-", "closure is a flag, not a duplicated point"),
                "bulges": .init("tan(θ/4)", "arc segments (ADR-0030 §5): bulges[i] bends the edge from points[i]; 0 straight, positive counter-clockwise; honoured only with one entry per point; nil is every edge straight")
            ],
            invariants: [
                "Closure is a flag so that \"three unique points\" means exactly that.",
                "uniquePoints collapses consecutive duplicates and the wrap-around duplicate.",
                "An arc edge's length is r·θ and its area contribution the circular segment r²/2·(θ − sin θ), both exact; only booleans (cutouts, splitting, coverage) work on a flattened ring (ADR-0030 §5)."
            ]
        ))

        types.append(try .reflecting(
            ContractSamples.polygon,
            name: "PolygonGeometry",
            summary: "A polygon with an outer ring and any number of holes (spec 12.4).",
            annotations: [
                "outer": .init("PDF point", "at least three unique points for an area"),
                "holes": .init("PDF point", "each must lie inside outer")
            ],
            invariants: [
                "Holes are stored with the parent, so a net area is never assembled from two records that can drift apart."
            ]
        ))

        types.append(try .reflecting(
            ContractSamples.arc,
            name: "ArcGeometry",
            summary: "A circular arc in page space (spec 12.12).",
            annotations: [
                "center": .init("PDF point", "finite"),
                "radius": .init("PDF point", "finite and non-negative"),
                "startAngle": .init("radian", "counter-clockwise from the page-space +x axis"),
                "sweepAngle": .init("radian", "signed; negative sweeps run clockwise")
            ],
            invariants: ["arcLength = radius * abs(sweepAngle) (spec 12.12)."]
        ))

        types.append(try .reflecting(
            ContractSamples.circle,
            name: "CircleGeometry",
            summary: "A full circle in page space (spec 12.11).",
            annotations: [
                "center": .init("PDF point", "finite"),
                "radius": .init("PDF point", "finite and non-negative")
            ]
        ))

        types.append(try .reflecting(
            ContractSamples.countPoint,
            name: "CountPoint",
            summary: "One placed count symbol (spec 12.13).",
            annotations: [
                "id": .init("-", "stable identity of the placement"),
                "position": .init("PDF point", "finite"),
                "sequenceNumber": .init("-", "1-based, nil when numbering is off"),
                "groupID": .init("-", "the count group this point belongs to"),
                "symbolID": .init("-", "the symbol drawn at this point")
            ]
        ))

        types.append(try .reflecting(
            ContractSamples.geometry,
            name: "MeasurementGeometry",
            summary: """
                Everything a measurement can be made of, in canonical PDF page space. A struct \
                with parallel collections rather than an enum of shapes: a takeoff markup \
                routinely mixes kinds, and an enum would force those into separate records that \
                can drift apart.
                """,
            annotations: [
                "pageID": .init("-", "geometry never spans pages"),
                "points": .init("PDF point", "polyline vertices, three-point circle points, angle points"),
                "segments": .init("PDF point", "independent segments"),
                "polygons": .init("PDF point", "closed areas with holes"),
                "arcs": .init("PDF point / radian", "arcs and curved edges"),
                "circles": .init("PDF point", "radius, diameter and ellipse-area tools"),
                "countPoints": .init("PDF point", "count symbol placements"),
                "pointBulges": .init("tan(θ/4)", "arc segments of the free-point chain (ADR-0030 §5), one entry per point, the last ignored; nil is every edge straight")
            ],
            invariants: [
                "All coordinates are PDF points: 72 per inch, bottom-left origin, no zoom, no screen scale.",
                "isFinite must hold before the engine runs; anything else is MeasurementError.nonFiniteCoordinate.",
                "Every point, vertex, centre and radius is at most coordinateMagnitudeBound (1e7 PDF points) in magnitude; beyond it the engine refuses with MeasurementError.coordinateOutOfRange, never a number (QUALITY_BAR 2.5, ADR-0035)."
            ]
        ))

        types.append(try .reflecting(
            ContractSamples.displayPolicy,
            name: "DisplayUnitPolicy",
            summary: "The display units and precision a measurement is presented with.",
            annotations: [
                "length": .init("-", "display unit for length fields"),
                "area": .init("-", "display unit for area fields"),
                "volume": .init("-", "display unit for volume fields"),
                "angle": .init("-", "display unit for angle fields"),
                "slopeForm": .init("-", "how slope is written"),
                "precision": .init("-", "applied at the view and export boundary only")
            ]
        ))

        types.append(try .reflecting(
            ContractSamples.parameters,
            name: "MeasurementParameters",
            summary: "Everything a measurement needs beyond geometry and scale (spec 12.6-12.9).",
            annotations: [
                "depth": .init("m (SI base)", "dimension must be length; required for Volume"),
                "height": .init("m (SI base)", "dimension must be length; required for Wall Area"),
                "heightAtEnd": .init("m (SI base)", "dimension must be length; present only when the wall's top edge slopes, and then the trapezoid form is used"),
                "slope": .init("-", "magnitude, fall-line azimuth and mode (ADR-0004)"),
                "volumeDepthReference": .init("-", "required for a volume on a sloped markup; no default"),
                "cutoutPolicy": .init("-", "how cutouts affect the parent quantity"),
                "perimeterPolicy": .init("-", "which edges count towards a perimeter"),
                "openingAreas": .init("m^2", "subtracted from a wall area (spec 12.7)"),
                "display": .init("-", "metadata only; never changes a stored value"),
                "displayOverride": .init("-", "this markup's own display units and precision (ADR-0035); nil shows in the project's units; metadata only, never changes a stored value, encoded only when present")
            ],
            invariants: [
                "The rise/run modes are explicit because \"one rise for the whole polyline\" and \"a rise per segment\" give different true lengths from the same drawing (spec 12.9).",
                "validate() throws MeasurementError.missingParameter when the chosen mode's input is absent.",
                "depth and height must carry the length dimension or validate() throws.",
                "depth, height and heightAtEnd must not be negative or NaN: validate() throws MeasurementError.negativeParameter, so a negative volume or wall area is never stored as a value (ADR-0016). A stored record still decodes; it fails when recomputed.",
                "Every opening area must be a number and not negative: validate() throws MeasurementError.negativeParameter(.openingAreas), so a corrupt record cannot enlarge a net wall area (ADR-0035).",
                "displayOverride absent means the project's units; a record written before ADR-0035 has no such key and decodes as absent, so it keeps showing in the project's units."
            ]
        ))

        types.append(.enumeration(
            MeasurementField.self,
            name: "MeasurementField",
            summary: "Every quantity a measurement can produce. The frozen key set of MeasurementResult.values.",
            invariants: [
                "Each field declares its own dimension; a MeasurementResult whose value dimension disagrees with its field is invalid (validateDimensions()).",
                "Lengths are metres, areas square metres, volumes cubic metres, angles radians, counts and ratios dimensionless."
            ],
            note: { "\($0.dimension.baseUnitSymbol)" }
        ))

        types.append(.enumeration(
            CutoutPolicy.self,
            name: "CutoutPolicy",
            summary: "What to do with cutouts when an area is computed (spec 12.4).",
            invariants: [
                "netArea = outerArea - union(cutoutAreas) (spec 12.4).",
                "The policy is the parent's: subtractFromArea and subtractAndReportSeparately give the parent the same netArea, ignore gives netArea = planArea. subtractAndReportSeparately additionally reports each cutout's own area in the ledger's cutoutArea column; it never makes a cutout a quantity that is summed (ADR-0018)."
            ]
        ))

        types.append(.enumeration(
            PerimeterPolicy.self,
            name: "PerimeterPolicy",
            summary: "Which edges count towards a perimeter (spec 12.5)."
        ))

        types.append(.enumeration(
            SlopeMode.self,
            name: "SlopeMode",
            summary: "How slope is supplied for a measurement (ADR-0004, spec 12.8, 12.9).",
            invariants: [
                "uniformPlane carries a magnitude and, for any directional quantity, an azimuth.",
                "The pre-ADR-0004 raw value uniformSlope still decodes as uniformPlane."
            ]
        ))

        types.append(.enumeration(
            VolumeDepthReference.self,
            name: "VolumeDepthReference",
            summary: "Which direction a volume's depth was measured in (ADR-0004).",
            invariants: [
                "verticalDepth: volume = A_plan * depth; the projection cancels.",
                "perpendicularThickness: volume = A_plan * sqrt(1 + s^2) * thickness.",
                "There is no default: a volume on a sloped markup requires the choice."
            ]
        ))

        types.append(try .reflecting(
            ContractSamples.azimuth,
            name: "SlopeAzimuth",
            summary: "The steepest-ascent direction of a sloped plane, in page space (ADR-0004).",
            annotations: [
                "degrees": .init("degree", "counter-clockwise from the page +x axis, normalised into [0, 360)")
            ],
            invariants: [
                "direction is exact on the four axes, so a contour-parallel edge elongates by exactly zero.",
                "Reversing an azimuth never changes a length: (d . u) is squared everywhere it is used."
            ]
        ))

        types.append(try .reflecting(
            ContractSamples.slopeSpecification,
            name: "SlopeSpecification",
            summary: "A slope as ADR-0004 defines it: a magnitude, a direction and an explicit mode.",
            annotations: [
                "mode": .init("-", "explicit; never inferred from which fields are set"),
                "magnitude": .init("-", "required when mode == uniformPlane; exact through Decimal in every written form"),
                "azimuth": .init("degree", "required before a slope may be applied to a length or a perimeter"),
                "perSegmentRiseDrop": .init("m", "index i applies to segment i; required when mode == perSegmentRiseDrop"),
                "totalRiseDrop": .init("m", "required when mode == totalRiseDrop")
            ],
            invariants: [
                "Applying a slope to a length or a perimeter without an azimuth is MeasurementError.slopeAzimuthRequired, never a scalar fallback.",
                "Area needs no azimuth: orthographic projection scales every planar region by cos(theta).",
                "Magnitudes above 100 % are accepted and warned, not rejected (ADR-0004)."
            ]
        ))

        types.append(.enumeration(
            MeasurementWarning.Code.self,
            name: "MeasurementWarning.Code",
            summary: "The frozen set of things the engine can complain about.",
            invariants: [
                "selfIntersectionCheckSkipped: an outline above the engine's self-intersection vertex limit is measured as drawn and says it was not checked for self-crossings; it is never reported as known-simple (ADR-0018, IM-070)."
            ]
        ))

        types.append(try .reflecting(
            ContractSamples.warning,
            name: "MeasurementWarning",
            summary: "A non-fatal finding attached to a measurement.",
            annotations: [
                "code": .init("-", "from the frozen Code set"),
                "field": .init("-", "the field the warning is about, when it is about one"),
                "detail": .init("-", "diagnostic text; not user-facing copy")
            ],
            invariants: [
                "A warning never replaces a value: the engine still returns the number it computed.",
                "The UI maps code to localized copy and never signals a warning by colour alone."
            ]
        ))

        types.append(try .reflecting(
            ContractSamples.calibrationEvidence,
            name: "CalibrationEvidence",
            summary: "The picked points and entered real-world length behind a calibrated scale (ADR-0007).",
            annotations: [
                "points": .init("PDF point", "two for a two-point calibration, four for separate X-Y (X pair first)"),
                "enteredLength": .init("m (SI base)", "the real-world length the user entered"),
                "enteredUnit": .init("-", "the unit it was typed in, echoed verbatim by the derivation panel"),
                "secondaryEnteredLength": .init("m (SI base)", "the Y line's entered length for a separate X-Y calibration; absent otherwise (ADR-0019)"),
                "verifications": .init("-", "checks of this calibration against other stated dimensions, oldest first; absent until the first (ADR-0030)")
            ],
            invariants: [
                "Present only for a calibrated scale; never fabricated for a preset or inherited one.",
                "A preset (drawing-ratio) scale carries no evidence, and installing one over a calibration removes the old evidence in the same undoable step (ADR-0019).",
                "A verification never changes the scale; a recalibration starts a new evidence record without the old checks (ADR-0030)."
            ]
        ))

        types.append(try .reflecting(
            ContractSamples.measurementCaption,
            name: "MeasurementCaption",
            summary: "What a measurement's pill says and where it sits (NL-MEASURE-09, ADR-0030 §3). Display only.",
            annotations: [
                "fields": .init("-", "the fields the pill shows, in order; empty is the tool's headline field alone"),
                "showsSegmentLengths": .init("-", "whether each segment of a linear or areal markup is labelled with its length"),
                "labelOffset": .init("PDF point", "where the pill was dragged to, from its automatic position; nil is automatic")
            ],
            invariants: [
                "Nothing here is a stored quantity: values come from the markup's MeasurementResult through the ledger formatter, and segment lengths are derived from the geometry when drawn."
            ]
        ))

        types.append(try .reflecting(
            ContractSamples.scaleVerification,
            name: "ScaleVerification",
            summary: "One check of a scale against a second dimension the drawing states (NL-MEASURE-04, ADR-0030).",
            annotations: [
                "points": .init("PDF point", "the two picked ends of the stated dimension"),
                "statedLength": .init("m (SI base)", "the length the drawing prints for the line"),
                "statedUnit": .init("-", "the unit the stated length was typed in"),
                "measuredLength": .init("m (SI base)", "what the line measures at the scale version checked"),
                "scaleVersion": .init("-", "the revision of the scale that was checked"),
                "verifiedAt": .init("-", "from an injected clock")
            ],
            invariants: [
                "deviation = measuredLength / statedLength - 1, exact in Decimal; rounding happens only where it is shown."
            ]
        ))

        types.append(try .reflecting(
            ContractSamples.provenance,
            name: "MeasurementProvenance",
            summary: """
                Everything a measured value was computed from, captured at the moment of \
                computation (ADR-0007 §1). Persisted alongside the value: if it is not captured \
                now, the data is not recoverable afterwards.
                """,
            annotations: [
                "geometryDigest": .init("-", "stable hash of the canonical page-space geometry encoding"),
                "scaleID": .init("-", "which scale was in force"),
                "scalePageID": .init("-", "the page that scale belongs to, so the disclosure can name the sheet it was calibrated on"),
                "scaleVersion": .init("-", "which revision of it (spec 10.6)"),
                "scaleSource": .init("-", "two-point calibration / separate X-Y / preset / inherited"),
                "calibrationEvidence": .init("-", "picked points and entered length, for a calibrated scale only"),
                "slope": .init("-", "magnitude, fall-line azimuth and mode (ADR-0004)"),
                "parameters": .init("-", "the full parameter set the engine received"),
                "formulaVersion": .init("-", "the calculation revision that produced the value"),
                "engineVersion": .init("-", "build identity of the engine that ran"),
                "computedAt": .init("-", "from an injected clock, never the wall clock directly"),
                "layerName": .init("-", "reserved by ADR-0007 §5 for the layer model; nil until then"),
                "captureMethod": .init("-", "how the geometry was captured, by a person or by a detector a person accepted (ADR-0031); absent means manual")
            ],
            invariants: [
                "Captured at computation time by the provenance-recording engine, never reconstructed later.",
                "captureMethod describes the geometry, not the calculation: it is kept across a recalculation while the geometry digest is unchanged and returns to manual when a person edits the geometry (ADR-0031).",
                "The digest is deterministic: identical geometry digests identically on every machine and build.",
                "scalePageID is the page the scale belongs to, recorded here rather than looked up later: the scale it names may since have been deleted, and a derivation that cannot finish its own sentence is not a derivation."
            ]
        ))

        types.append(try .reflecting(
            ContractSamples.captureMethod,
            name: "CaptureMethod",
            summary: "How a measurement's geometry was captured: drawn by a person, or proposed by a detector and accepted by one (NL-AUTO-18, ADR-0031).",
            annotations: [
                "kind": .init("-", "manual / autoTraced / symbolMatched / exactBlock / roomDetected / fromScan / wallCentreline / importedAnnotation, stored as text; a kind from a newer build reads as unrecognised"),
                "bridgedGapCount": .init("-", "autoTraced: gaps bridged with closing lines"),
                "largestGapPoints": .init("PDF point", "autoTraced: the widest bridged gap"),
                "closureWidthsPoints": .init("PDF point", "autoTraced: each confirmed closing line's width"),
                "residualRatio": .init("-", "symbolMatched: the match residual, 0 for a perfect match"),
                "isMirrored": .init("-", "symbolMatched: the match is the example's mirror image"),
                "matchScale": .init("-", "symbolMatched: the match's scale relative to the example"),
                "exemplarDigest": .init("-", "symbolMatched and exactBlock: digest of the example matched"),
                "confidence": .init("0...1", "fromScan: the detector's confidence"),
                "wallThicknessMetres": .init("m (SI base)", "wallCentreline: the wall thickness the pair was chained at")
            ],
            invariants: [
                "Absent on a MeasurementProvenance means manual, so every record written before ADR-0031 decodes unchanged.",
                "A detector never commits a quantity by itself: a capture method other than manual records a proposal a person accepted."
            ]
        ))

        types.append(try .reflecting(
            ContractSamples.result,
            name: "MeasurementResult",
            summary: "The result of one measurement (spec 12.15, verbatim shape).",
            annotations: [
                "values": .init("SI base units", "keyed by field; never rounded"),
                "warnings": .init("-", "non-fatal findings"),
                "formulaVersion": .init("-", "the calculation version that produced these values"),
                "provenance": .init("-", "the derivation (ADR-0007); nil for a bare engine call or a pre-v3 stored result")
            ],
            invariants: [
                "Values are SI base units and carry no display rounding.",
                "Every value's dimension equals its field's declared dimension.",
                "formulaVersion lets a later build detect a stored result that predates a calculation change."
            ]
        ))

        types.append(ContractTypeDescription(
            name: "MeasurementCalculating",
            kind: "protocol",
            summary: "The measurement engine's entire surface (spec 12.15, verbatim shape).",
            cases: [
                ContractCaseDescription(
                    name: "calculate(geometry:scale:parameters:)",
                    rawValue: "(MeasurementGeometry, ScaleTransform, MeasurementParameters) throws -> MeasurementResult"
                )
            ],
            invariants: [
                "Pure and Sendable: no clock, no id generation, no I/O, no view state.",
                "The same three inputs give the same result on every machine at a given formulaVersion.",
                "Failures are typed MeasurementError values; there is no fatalError path."
            ]
        ))

        types.append(try .reflecting(
            ContractSamples.countGroup,
            name: "CountGroup",
            summary: "The container Count measurements aggregate into (spec 12.13).",
            annotations: [
                "id": .init("-", "stable group identity"),
                "symbolID": .init("-", "symbol every point in the group is drawn with"),
                "pageID": .init("-", "a count group lives on one page"),
                "zoneID": .init("-", "optional Project Zone"),
                "subject": .init("-", "primary ledger grouping key"),
                "label": .init("-", "secondary ledger key"),
                "pointIDs": .init("-", "placement order; sequential numbering follows it"),
                "showsSequentialNumbering": .init("-", "whether each point shows a running number")
            ]
        ))

        return ContractDocument(
            contract: "MEASUREMENT_CONTRACT",
            contractVersion: ContractVersion.measurement,
            frozenAt: frozenAt,
            generator: generatorName,
            specSections: ["12.1"] + (2...15).map { "12.\($0)" } + ["ADR-0004", "ADR-0007"],
            summary: """
                The measurement engine's inputs and outputs: geometry in page space, parameters, \
                the frozen field set, the result shape and the one protocol every calculator \
                implements.
                """,
            types: types,
            tables: [
                ContractTable(
                    name: "measurementFieldDimensions",
                    columns: ["field", "lengthPower", "angle", "ratio", "baseUnit"],
                    rows: MeasurementField.allCases.map { field in
                        [
                            field.rawValue,
                            String(field.dimension.lengthPower),
                            field.dimension.angle ? "true" : "false",
                            field.dimension.ratio ? "true" : "false",
                            field.dimension.baseUnitSymbol
                        ]
                    }
                ),
                ContractTable(
                    name: "coreFormulas",
                    columns: ["quantity", "formula", "spec"],
                    rows: [
                        ["length", "sum ||r_i+1 - r_i||", "12.2"],
                        ["polygonArea", "1/2 * abs(sum(x_i * y_i+1 - x_i+1 * y_i))", "12.3"],
                        ["netArea", "outerArea - union(cutoutAreas)", "12.4"],
                        ["volume", "netArea * depth", "12.6"],
                        ["wallArea", "selectedLengthOrPerimeter * wallHeight", "12.7"],
                        ["netWallArea", "wallArea - openings", "12.7"],
                        ["slopeRatio", "rise / run", "12.8"],
                        ["slopePercent", "100 * rise / run", "12.8"],
                        ["slopeAngle", "atan(rise / run)", "12.8"],
                        ["trueLength", "sum sqrt(|d_i|^2 + (slopeRatio * (d_i . u))^2)", "ADR-0004"],
                        ["truePerimeter", "the same per-segment rule around every counted ring", "ADR-0004"],
                        ["trueArea", "netArea * sqrt(1 + slopeRatio^2)", "12.8"],
                        ["wallArea", "trueLength * height, or trueLength * (h_start + h_end) / 2", "ADR-0004"],
                        ["volume (vertical depth)", "netArea * depth", "ADR-0004"],
                        ["volume (perpendicular thickness)", "netArea * sqrt(1 + slopeRatio^2) * thickness", "ADR-0004"],
                        ["trueSegment", "sqrt(planSegment^2 + riseDrop^2)", "12.9"],
                        ["angle", "atan2(abs(cross(u,v)), dot(u,v))", "12.10"],
                        ["arcLength", "radius * centralAngleRadians", "12.12"]
                    ]
                )
            ],
            invariants: [
                "The engine receives page-space geometry only: never a screen pixel, never a zoom value (spec 9.2).",
                "run == 0 is vertical and undefined, never a division producing infinity (spec 12.8).",
                "Slope is a vector: a length on a sloped plane elongates by sqrt(|d|^2 + (s (d . u))^2) per segment, not by a blanket sqrt(1 + s^2) (ADR-0004).",
                "Area is direction-independent: A_true = A_plan * sqrt(1 + s^2) exactly, applied once to the net area after cutouts (ADR-0004).",
                "Plan and true values are produced side by side and neither ever overwrites the other (ADR-0004).",
                "A polygon needs at least three unique points; self-intersection is blocked or normalised only after user confirmation (spec 12.3).",
                "Cutouts must overlap their parent and recalculate live; the relation is a ledger parent/child (spec 12.4).",
                "A cutout that does not overlap its parent at all is refused with MeasurementError.cutoutOutsideParent(cutoutIndex:); a partial overlap is accepted, removes only the part inside, and warns cutoutOutsideParent (QUALITY_BAR 2.5, ADR-0015).",
                "Under outerPlusCutoutEdges the perimeter is the boundary length of the net region — the rings of the boolean difference — so overlapping, overhanging or shared-edge cutouts never count an edge twice (spec 12.5, ADR-0015).",
                "slopeRatio and slopePercent are ratio-dimensioned and never sum into a count total; a stored dimensionless value takes its field's dimension on decode (ADR-0014).",
                "A net quantity below zero is MeasurementError.negativeNetArea, never a value (QUALITY_BAR P11, ADR-0015).",
                "The informational tools (angle, slope, radius, diameter, threePointCircle) write no field a summed ledger column reads: no planLength, trueLength, perimeter, planArea or netArea (ADR-0019).",
                "Temporary measurements are overlay only and reach neither SQLite nor the PDF (spec 12.14).",
                "Every result carries formulaVersion, so a stale stored value is detectable rather than silently wrong.",
                "Values are stored in SI base units without display rounding (spec 11.4).",
                "A provenance-recorded result carries its full derivation — geometry digest, scale revision and source, calibration evidence, slope, parameters, engine identity, computed-at — captured at computation time (ADR-0007)."
            ]
        )
    }
}
