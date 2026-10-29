import Foundation

extension ContractCatalog {

    static func snapContract(frozenAt: String) throws -> ContractDocument {
        var types: [ContractTypeDescription] = []

        types.append(.enumeration(
            PrimitiveKind.self,
            name: "PrimitiveKind",
            summary: "The kind of geometric primitive stored in a page's snap index (spec 13.4).",
            invariants: [
                "Curves are stored as curves. Flattening is for indexing and hit testing only, so a snap onto a curve returns a point on the curve and not on a chord (spec 13.4)."
            ]
        ))

        types.append(ContractTypeDescription(
            name: "PrimitiveGeometry",
            kind: "enum",
            summary: "The geometry behind a SnapPrimitive, with the object matrix and every parent form transform already applied (spec 13.4).",
            cases: [
                ContractCaseDescription(name: "point", rawValue: "PDFPoint"),
                ContractCaseDescription(name: "segment", rawValue: "SegmentGeometry"),
                ContractCaseDescription(name: "polyline", rawValue: "(points: [PDFPoint], isClosed: Bool)"),
                ContractCaseDescription(name: "cubicCurve", rawValue: "(start, control1, control2, end: PDFPoint)"),
                ContractCaseDescription(name: "quadraticCurve", rawValue: "(start, control, end: PDFPoint)"),
                ContractCaseDescription(name: "rectangle", rawValue: "PDFRect"),
                ContractCaseDescription(name: "circle", rawValue: "CircleGeometry"),
                ContractCaseDescription(name: "ellipticalArc", rawValue: "ArcGeometry")
            ],
            invariants: [
                "Coordinates are canonical page space with page rotation and crop honoured.",
                "Clipping-only and invisible paths are not indexed; oversized background rectangles are filtered (spec 13.4)."
            ]
        ))

        types.append(try .reflecting(
            ContractSamples.snapPrimitive,
            name: "SnapPrimitive",
            summary: "One entry in a page's packed R-tree of snappable geometry (spec 13.5).",
            annotations: [
                "id": .init("-", "index-local and dense, not a UUID: this is derived cache data"),
                "bounds": .init("PDF point", "axis-aligned page-space bounds; the R-tree key"),
                "kind": .init("-", "must agree with geometry (isConsistent)"),
                "geometry": .init("PDF point / radian", "curves stored as curves"),
                "sourceObjectID": .init("-", "the id of the painted path the vector extractor (CGPDFScanner) emitted it from, when it came from PDF content; nil for markup, zone and calibration geometry"),
                "confidence": .init("0...1", "lower for flattened or heuristically filtered content"),
                "layerID": .init("-", "OCG identity, used by the active-layer score term")
            ],
            invariants: [
                "bounds is a PDFRect, not the CGRect the spec sketch shows: the snap index is strictly page space and a view type here is the first step towards a zoom value reaching the measurement engine.",
                "The index is cached keyed by document SHA, page and engine version (spec 13.4).",
                "kind must agree with geometry.kind, or the cache is rejected rather than snapped to."
            ]
        ))

        types.append(.enumeration(
            SnapKind.self,
            name: "SnapKind",
            summary: "The snap types the product offers (spec 13.1).",
            invariants: [
                "defaultPriority implements the spec 13.7 order; a lower number wins ties at equal screen distance.",
                "requiresVectorContent is false for grid, angle increment, markup, zone, calibration and parallel-guide snapping, which keep working on a scanned page (spec 13.11)."
            ],
            note: { "priority \($0.defaultPriority), \($0.requiresVectorContent ? "needs vector content" : "works on scans")" }
        ))

        types.append(.enumeration(
            SnapGeometrySource.self,
            name: "SnapGeometrySource",
            summary: "Where a snap candidate's geometry came from (spec 13.2).",
            invariants: ["OCR text is never used as a construction line (spec 13.2)."]
        ))

        types.append(try .reflecting(
            ContractSamples.snapCandidate,
            name: "SnapCandidate",
            summary: "A single scored snap candidate for the current cursor position (spec 13.7).",
            annotations: [
                "kind": .init("-", "the snap type"),
                "position": .init("PDF point", "the snapped position"),
                "primitiveID": .init("-", "the primitive that produced it, when one did"),
                "source": .init("-", "geometry source"),
                "screenDistancePixels": .init("logical screen pixel", "scoring is in pixels because \"near\" is a screen judgement"),
                "confidence": .init("0...1", "carried from the primitive"),
                "isOnActiveLayer": .init("-", "active-layer score term"),
                "satisfiesDirectionConstraint": .init("-", "Shift angle constraint term"),
                "isHeldByHysteresis": .init("-", "true while the previous winner is being held (spec 13.9)"),
                "score": .init("-", "composed score; lower is better")
            ],
            invariants: [
                "score = typePriority + screenDistance + confidence + activeLayer + directionConstraint + hysteresis (spec 13.7).",
                "The active candidate is kept until the cursor leaves tolerance + hysteresis, or a clearly better candidate appears (spec 13.9)."
            ]
        ))

        types.append(try .reflecting(
            ContractSamples.snapSettings,
            name: "SnapSettings",
            summary: "Snap radius and behaviour settings (spec 13.6, 13.8, 13.9).",
            annotations: [
                "defaultPixels": .init("logical screen pixel", "spec default 10"),
                "minimumPixels": .init("logical screen pixel", "spec default 4; > 0 and <= defaultPixels"),
                "maximumPixels": .init("logical screen pixel", "spec default 24; >= defaultPixels"),
                "hysteresisPixels": .init("logical screen pixel", "spec default 4; >= 0"),
                "enabledKinds": .init("-", "which snap kinds are live"),
                "priorityOverrides": .init("-", "kinds absent here use SnapKind.defaultPriority"),
                "gridSpacingPoints": .init("PDF point", "> 0 when grid snap is enabled"),
                "angleIncrementDegrees": .init("degree", "0 < value <= 180 when angle snap is enabled"),
                "isEnabled": .init("-", "Command toggles snapping temporarily (spec 13.8)")
            ],
            invariants: [
                "minimumPixels <= defaultPixels <= maximumPixels, or validate() throws SnapError.invalidRadiusRange.",
                "Radii are in logical screen pixels and are converted to page points on every event, because zoom can change between two mouse moves (spec 13.6)."
            ]
        ))

        types.append(.enumeration(
            SnapAvailability.self,
            name: "SnapAvailability",
            summary: "The state a page's snap index can be in (spec 13.11).",
            invariants: [
                "A scanned page reports vectorUnavailableScannedPage explicitly; the UI says \"Vector Snap unavailable\" rather than silently doing nothing (spec 13.11)."
            ]
        ))

        return ContractDocument(
            contract: "SNAP_CONTRACT",
            contractVersion: ContractVersion.snap,
            frozenAt: frozenAt,
            generator: generatorName,
            specSections: ["13.1", "13.2", "13.4", "13.5", "13.6", "13.7", "13.8", "13.9", "13.10", "13.11"],
            summary: """
                Vector Snap: what is indexed, how a candidate is scored, and the radius and \
                hysteresis behaviour that keeps the cursor from jittering between candidates.
                """,
            types: types,
            tables: [
                ContractTable(
                    name: "snapRadiusDefaults",
                    columns: ["setting", "logicalPixels"],
                    rows: [
                        ["defaultPixels", ContractNumberText.text(SnapSettings.specDefaultPixels)],
                        ["minimumPixels", ContractNumberText.text(SnapSettings.specMinimumPixels)],
                        ["maximumPixels", ContractNumberText.text(SnapSettings.specMaximumPixels)],
                        ["hysteresisPixels", ContractNumberText.text(SnapSettings.specHysteresisPixels)]
                    ]
                ),
                ContractTable(
                    name: "snapPriority",
                    columns: ["kind", "priority", "requiresVectorContent"],
                    rows: SnapKind.allCases
                        .sorted { $0.defaultPriority < $1.defaultPriority }
                        .map { [$0.rawValue, String($0.defaultPriority), $0.requiresVectorContent ? "true" : "false"] }
                ),
                ContractTable(
                    name: "modifierKeys",
                    columns: ["key", "effect"],
                    rows: [
                        ["Shift", "constrain angles"],
                        ["Command", "toggle snap temporarily"],
                        ["Option", "bypass / cycle the current candidate"],
                        ["Tab", "cycle overlapping candidates"],
                        ["Backspace", "remove the latest vertex"],
                        ["Enter", "finish"],
                        ["Escape", "cancel"]
                    ]
                )
            ],
            invariants: [
                "Snap geometry is canonical page space with object matrices and parent form transforms applied (spec 13.4).",
                "Curves are stored as curves; flattening is adaptive and used only for indexing and hit testing.",
                "The spatial index is a packed R-tree per page, cached by document SHA, page and engine version.",
                "OCR text is never used as a construction line (spec 13.2).",
                "The active candidate is held until the cursor leaves tolerance + hysteresis (spec 13.9).",
                "A page without vector content reports Vector Snap as unavailable rather than failing quietly (spec 13.11).",
                "Reduced Motion replaces animated snap feedback with a static state (spec 13.10)."
            ]
        )
    }
}
