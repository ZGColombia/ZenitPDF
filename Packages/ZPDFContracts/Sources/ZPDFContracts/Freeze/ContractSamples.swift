import Foundation

/// Deterministic sample instances used to reflect the contract structs.
///
/// Nothing here calls `UUID()` or `Date()`: the samples are byte-for-byte identical on every
/// machine, so re-running the freeze produces an identical document apart from `frozenAt`.
enum ContractSamples {
    static func uuid(_ byte: UInt8) -> UUID {
        UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, byte))
    }

    static let epoch = Date(timeIntervalSince1970: 0)

    static let documentID = DocumentID(uuid(1))
    static let pageID = PageID(uuid(2))
    static let markupID = MarkupID(uuid(3))
    static let scaleID = ScaleID(uuid(4))
    static let columnID = ColumnID(uuid(5))
    static let rowID = RowID(uuid(6))
    static let choiceID = ChoiceOptionID(uuid(7))
    static let countPointID = CountPointID(uuid(8))
    static let countGroupID = CountGroupID(uuid(9))

    static let point = PDFPoint(x: 0, y: 0)
    static let size = PDFSize(width: 595.276, height: 841.89)
    static let rect = PDFRect(origin: point, size: size)
    static let boxes = PageBoxes(media: rect)

    static let pageDescriptor = PageDescriptor(
        id: pageID,
        documentID: documentID,
        index: 0,
        label: "A-101",
        boxes: boxes,
        rotation: .degrees0,
        userUnit: 1.0
    )

    static let color = RGBAColor.opaqueBlack
    static let dimension = QuantityDimension.area
    static let quantity = DecimalQuantity.area(0)
    static let matrix = AffineScaleMatrix.identity
    static let unitPolicy = ScaleUnitPolicy.metric

    static let scale = ScaleTransform(
        id: scaleID,
        pageID: pageID,
        version: 1,
        matrix: matrix,
        units: unitPolicy,
        source: .preset,
        label: nil
    )

    static let segment = SegmentGeometry(start: point, end: point)
    static let ring = PolygonRing(points: [point], isClosed: true)
    static let polygon = PolygonGeometry(outer: ring)
    static let arc = ArcGeometry(center: point, radius: 1, startAngle: 0, sweepAngle: 1)
    static let circle = CircleGeometry(center: point, radius: 1)

    static let countPoint = CountPoint(
        id: countPointID,
        position: point,
        sequenceNumber: nil,
        groupID: nil,
        symbolID: nil
    )

    static let geometry = MeasurementGeometry(pageID: pageID)
    static let displayPolicy = DisplayUnitPolicy.metric
    static let parameters = MeasurementParameters.default
    static let azimuth = SlopeAzimuth(degrees: 0)
    static let slopeSpecification = SlopeSpecification.none
    static let warning = MeasurementWarning(code: .degenerateArea, field: nil, detail: "")
    static let result = MeasurementResult.empty

    static let calibrationEvidence = CalibrationEvidence(
        points: [point, point],
        enteredLength: .length(5),
        enteredUnit: .metre
    )

    static let measurementCaption = MeasurementCaption(
        fields: [.netArea, .perimeter],
        showsSegmentLengths: true,
        labelOffset: point
    )

    static let scaleVerification = ScaleVerification(
        points: [point, point],
        statedLength: .length(5),
        statedUnit: .metre,
        measuredLength: .length(5),
        scaleVersion: 1,
        verifiedAt: epoch
    )

    static let provenance = MeasurementProvenance(
        geometryDigest: "0000000000000000000000000000000000000000000000000000000000000000",
        scaleID: scaleID,
        scaleVersion: 1,
        scaleSource: .preset,
        calibrationEvidence: nil,
        slope: .none,
        parameters: .default,
        formulaVersion: ContractVersion.measurementFormulaVersion,
        engineVersion: "0.0.0",
        computedAt: epoch,
        layerName: nil
    )

    static let captureMethod = CaptureMethod(
        kind: .autoTraced,
        bridgedGapCount: 1,
        largestGapPoints: 25.4,
        closureWidthsPoints: [25.4],
        residualRatio: nil,
        isMirrored: nil,
        matchScale: nil,
        exemplarDigest: nil,
        confidence: nil,
        wallThicknessMetres: nil
    )

    static let countGroup = CountGroup(
        id: countGroupID,
        symbolID: nil,
        pageID: pageID,
        zoneID: nil,
        subject: "",
        label: ""
    )

    static let markupStyle = MarkupStyle.default

    static let markupSymbol = MarkupSymbol(
        artworkDigest: nil,
        kind: .none,
        builtInGlyph: "filledCircle",
        sizePoints: 12,
        rotationDegrees: 0,
        sourceName: ""
    )

    static let artworkGeometry = ArtworkGeometry(
        kind: .vector,
        strokes: [],
        regions: [],
        compilerVersion: ArtworkGeometry.compilerVersion,
        sourceAspectRatio: 1
    )

    static let markup = MarkupRecord(
        id: markupID,
        documentID: documentID,
        pageID: pageID,
        kind: .measurement,
        createdAt: epoch,
        modifiedAt: epoch
    )

    static let quantityDerivation = QuantityDerivation(
        sourceMarkupID: nil,
        formulaText: "Betong C30/37  12,5  m3",
        inputs: ["Material": "Betong C30/37", "Volume": "12,5"],
        originIdentifier: "page 00000000-0000-0000-0000-000000000002 rect 40,60 520x180"
    )

    static let snapPrimitive = SnapPrimitive(
        id: 0,
        bounds: rect,
        kind: .segment,
        geometry: .segment(segment),
        sourceObjectID: nil,
        confidence: 1.0,
        layerID: nil
    )

    static let snapCandidate = SnapCandidate(
        kind: .endpoint,
        position: point,
        primitiveID: nil,
        source: .pdfPathObject,
        screenDistancePixels: 0,
        confidence: 1.0,
        score: 0
    )

    static let snapSettings = SnapSettings.default
    static let choiceOption = ChoiceOption(id: choiceID, value: "Open")
    static let formula = FormulaExpression(source: "Area * UnitCost")

    static let column = LedgerColumnDefinition(
        id: columnID,
        key: "subject",
        title: "Subject",
        kind: .text,
        standard: nil,
        dimension: nil,
        displayUnit: nil,
        precision: nil,
        formula: nil
    )

    static let row = LedgerRowRecord(id: rowID)
}
