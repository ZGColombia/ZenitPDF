import Foundation
import Testing
@testable import ZPDFContracts

/// Every public contract type is persisted, so every public contract type must survive a JSON
/// round-trip unchanged. A type that silently drops a field here would silently drop it in the
/// project database too.
@Suite("Codable round-trips")
struct CodableRoundTripTests {

    /// Values are wrapped in an array so that fragment-only values (a bare enum, a bare string)
    /// encode under every JSON encoder configuration.
    static func roundTrip<Value: Codable & Equatable>(
        _ value: Value,
        _ label: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let data = try JSONEncoder().encode([value])
        let decoded = try JSONDecoder().decode([Value].self, from: data)
        #expect(decoded == [value], "\(label) did not survive a JSON round-trip",
                sourceLocation: sourceLocation)
    }

    static func uuid(_ byte: UInt8) -> UUID {
        UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, byte))
    }

    // MARK: - Identity and primitives

    @Test("Identifiers encode as a single UUID string")
    func identifiers() throws {
        let pageID = PageID(Self.uuid(2))
        try Self.roundTrip(pageID, "PageID")
        let data = try JSONEncoder().encode([pageID])
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"\(pageID.rawValue.uuidString)\""))

        try Self.roundTrip(DocumentID(Self.uuid(1)), "DocumentID")
        try Self.roundTrip(MarkupID(Self.uuid(3)), "MarkupID")
        try Self.roundTrip(LayerID(Self.uuid(4)), "LayerID")
        try Self.roundTrip(ZoneID(Self.uuid(5)), "ZoneID")
        try Self.roundTrip(ScaleID(Self.uuid(6)), "ScaleID")
        try Self.roundTrip(ScaleRegionID(Self.uuid(7)), "ScaleRegionID")
        try Self.roundTrip(ColumnID(Self.uuid(8)), "ColumnID")
        try Self.roundTrip(RowID(Self.uuid(9)), "RowID")
        try Self.roundTrip(ChoiceOptionID(Self.uuid(10)), "ChoiceOptionID")
        try Self.roundTrip(CountGroupID(Self.uuid(11)), "CountGroupID")
        try Self.roundTrip(CountPointID(Self.uuid(12)), "CountPointID")
        try Self.roundTrip(SymbolID(Self.uuid(13)), "SymbolID")
    }

    @Test("Page geometry round-trips")
    func pageGeometry() throws {
        let point = PDFPoint(x: 12.5, y: -3.25)
        let size = PDFSize(width: 595.276, height: 841.89)
        let rect = PDFRect(origin: point, size: size)
        try Self.roundTrip(point, "PDFPoint")
        try Self.roundTrip(size, "PDFSize")
        try Self.roundTrip(rect, "PDFRect")
        try Self.roundTrip(PageRotation.degrees270, "PageRotation")
        try Self.roundTrip(PageBoxes(media: rect, crop: rect.outsetBy(-10)), "PageBoxes")
        try Self.roundTrip(
            PageDescriptor(
                id: PageID(Self.uuid(2)),
                documentID: DocumentID(Self.uuid(1)),
                index: 7,
                label: "A-101",
                boxes: PageBoxes(media: rect),
                rotation: .degrees90,
                userUnit: 2.5
            ),
            "PageDescriptor"
        )
        try Self.roundTrip(RGBAColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 0.4), "RGBAColor")
    }

    // MARK: - Units

    @Test("Unit enums and dimensions round-trip")
    func units() throws {
        for unit in LengthUnit.allCases { try Self.roundTrip(unit, "LengthUnit.\(unit.rawValue)") }
        for unit in AreaUnit.allCases { try Self.roundTrip(unit, "AreaUnit.\(unit.rawValue)") }
        for unit in VolumeUnit.allCases { try Self.roundTrip(unit, "VolumeUnit.\(unit.rawValue)") }
        for unit in AngleUnit.allCases { try Self.roundTrip(unit, "AngleUnit.\(unit.rawValue)") }
        for family in UnitFamily.allCases { try Self.roundTrip(family, "UnitFamily.\(family.rawValue)") }
        for form in SlopeForm.allCases { try Self.roundTrip(form, "SlopeForm.\(form.rawValue)") }

        try Self.roundTrip(AnyDisplayUnit.count, "AnyDisplayUnit.count")
        try Self.roundTrip(AnyDisplayUnit.length(.foot), "AnyDisplayUnit.length")
        try Self.roundTrip(AnyDisplayUnit.area(.squareMetre), "AnyDisplayUnit.area")
        try Self.roundTrip(AnyDisplayUnit.volume(.litre), "AnyDisplayUnit.volume")
        try Self.roundTrip(AnyDisplayUnit.angle(.degree), "AnyDisplayUnit.angle")
        try Self.roundTrip(AnyDisplayUnit.currency("SEK"), "AnyDisplayUnit.currency")

        try Self.roundTrip(QuantityDimension.area, "QuantityDimension")
        try Self.roundTrip(QuantityDimension.ratio, "QuantityDimension ratio")
        try Self.roundTrip(QuantityDimension.count, "QuantityDimension count")
        try Self.roundTrip(DecimalQuantity.ratio(Decimal(string: "1.15") ?? 0), "DecimalQuantity ratio")
        try Self.roundTrip(QuantityDimension(lengthPower: -2, currencyCode: "SEK"), "QuantityDimension rate")
        try Self.roundTrip(DecimalQuantity.area(Decimal(string: "12.345678901234") ?? 0), "DecimalQuantity")
        try Self.roundTrip(DecimalQuantity.money(Decimal(string: "1999.95") ?? 0, currencyCode: "SEK"), "DecimalQuantity money")
    }

    @Test("Every slope form round-trips")
    func slopeExpressions() throws {
        let cases: [SlopeExpression] = [
            .ratioOneToN(12),
            .ratioNToOne(Decimal(string: "0.25") ?? 0),
            .decimalRatio(Decimal(string: "0.0833") ?? 0),
            .percent(Decimal(string: "8.33") ?? 0),
            .degrees(Decimal(string: "4.76") ?? 0),
            .riseOverRun(rise: 1, run: 12)
        ]
        for value in cases { try Self.roundTrip(value, "SlopeExpression \(value)") }
    }

    // MARK: - Scale

    @Test("The scale matrix persists as decimal strings and decodes identically")
    func scaleTransform() throws {
        let matrix = AffineScaleMatrix(
            a: Decimal(string: "0.0176388888888888888888888888888888888") ?? 0,
            b: 0,
            c: 0,
            d: Decimal(string: "0.0176388888888888888888888888888888888") ?? 0,
            tx: Decimal(string: "-1.5") ?? 0,
            ty: Decimal(string: "2.25") ?? 0
        )
        try Self.roundTrip(matrix, "AffineScaleMatrix")

        let data = try JSONEncoder().encode([matrix])
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"0.0176388888888888888888888888888888888\""),
                "matrix components must persist as decimal strings, not as JSON numbers")

        let scale = ScaleTransform(
            id: ScaleID(Self.uuid(6)),
            version: 3,
            matrix: matrix,
            units: .imperial,
            source: .calibrationXY,
            label: "1:50"
        )
        try Self.roundTrip(scale, "ScaleTransform")
        try Self.roundTrip(ScaleUnitPolicy.metric, "ScaleUnitPolicy")
        try Self.roundTrip(PrecisionMode.decimalPlaces(4), "PrecisionMode.decimalPlaces")
        try Self.roundTrip(PrecisionMode.imperialFraction(.sixtyFourth), "PrecisionMode.imperialFraction")
        for denominator in ImperialFractionDenominator.allCases {
            try Self.roundTrip(denominator, "ImperialFractionDenominator.\(denominator.rawValue)")
        }
        for source in ScaleSource.allCases { try Self.roundTrip(source, "ScaleSource.\(source.rawValue)") }
        for policy in ScaleChangePolicy.allCases { try Self.roundTrip(policy, "ScaleChangePolicy") }
        for scope in ScaleApplicationScope.allCases { try Self.roundTrip(scope, "ScaleApplicationScope") }
        for policy in ScaleRegionCrossingPolicy.allCases { try Self.roundTrip(policy, "ScaleRegionCrossingPolicy") }
    }

    // MARK: - Measurement

    @Test("Measurement geometry, parameters and results round-trip")
    func measurement() throws {
        let pageID = PageID(Self.uuid(2))
        let ring = PolygonRing(points: [
            PDFPoint(x: 0, y: 0), PDFPoint(x: 100, y: 0),
            PDFPoint(x: 100, y: 50), PDFPoint(x: 0, y: 50)
        ])
        let hole = PolygonRing(points: [
            PDFPoint(x: 10, y: 10), PDFPoint(x: 20, y: 10), PDFPoint(x: 20, y: 20)
        ])
        let geometry = MeasurementGeometry(
            pageID: pageID,
            points: [PDFPoint(x: 1, y: 2)],
            segments: [SegmentGeometry(start: .zero, end: PDFPoint(x: 3, y: 4))],
            polygons: [PolygonGeometry(outer: ring, holes: [hole])],
            arcs: [ArcGeometry(center: .zero, radius: 10, startAngle: 0, sweepAngle: 1.5)],
            circles: [CircleGeometry(center: PDFPoint(x: 5, y: 5), radius: 2)],
            countPoints: [
                CountPoint(
                    id: CountPointID(Self.uuid(12)),
                    position: PDFPoint(x: 7, y: 8),
                    sequenceNumber: 3,
                    groupID: CountGroupID(Self.uuid(11)),
                    symbolID: SymbolID(Self.uuid(13))
                )
            ]
        )
        try Self.roundTrip(geometry, "MeasurementGeometry")
        try Self.roundTrip(ring, "PolygonRing")
        try Self.roundTrip(PolygonGeometry(outer: ring, holes: [hole]), "PolygonGeometry")
        try Self.roundTrip(SegmentGeometry(start: .zero, end: PDFPoint(x: 1, y: 1)), "SegmentGeometry")
        try Self.roundTrip(ArcGeometry(center: .zero, radius: 1, startAngle: 0, sweepAngle: -2), "ArcGeometry")
        try Self.roundTrip(CircleGeometry(center: .zero, radius: 4), "CircleGeometry")

        let parameters = MeasurementParameters(
            depth: .length(Decimal(string: "0.15") ?? 0),
            height: .length(Decimal(string: "2.4") ?? 0),
            heightAtEnd: .length(Decimal(string: "3.6") ?? 0),
            slope: SlopeSpecification(
                mode: .perSegmentRiseDrop,
                magnitude: .percent(8),
                azimuth: SlopeAzimuth(degrees: Decimal(string: "26.5") ?? 0),
                perSegmentRiseDrop: [Decimal(string: "0.1") ?? 0, Decimal(string: "-0.2") ?? 0],
                totalRiseDrop: Decimal(string: "1.75") ?? 0
            ),
            volumeDepthReference: .perpendicularThickness,
            cutoutPolicy: .subtractAndReportSeparately,
            perimeterPolicy: .outerPlusCutoutEdges,
            openingAreas: [Decimal(string: "1.6") ?? 0],
            display: .imperial
        )
        try Self.roundTrip(parameters, "MeasurementParameters")
        try Self.roundTrip(DisplayUnitPolicy.imperial, "DisplayUnitPolicy")

        let result = MeasurementResult(
            values: [
                .planArea: .area(Decimal(string: "52.5") ?? 0),
                .netArea: .area(Decimal(string: "50.0") ?? 0),
                .perimeter: .length(30),
                .count: .count(4),
                .slopeAngle: .angle(Decimal(string: "0.0798") ?? 0)
            ],
            warnings: [
                MeasurementWarning(code: .duplicatePointsCollapsed, field: .planArea, detail: "2 collapsed"),
                MeasurementWarning(code: .extremeScale)
            ],
            formulaVersion: ContractVersion.measurementFormulaVersion
        )
        try Self.roundTrip(result, "MeasurementResult")
        try result.validateDimensions()

        // The field-keyed dictionary must encode as a JSON object, not as a flat pair array.
        let json = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(result)
        ) as? [String: Any]
        #expect(json?["values"] is [String: Any],
                "MeasurementResult.values must encode as a keyed object")

        for tool in MeasurementTool.allCases { try Self.roundTrip(tool, "MeasurementTool.\(tool.rawValue)") }
        for field in MeasurementField.allCases { try Self.roundTrip(field, "MeasurementField.\(field.rawValue)") }
        for code in MeasurementWarning.Code.allCases { try Self.roundTrip(code, "warning \(code.rawValue)") }
        for policy in CutoutPolicy.allCases { try Self.roundTrip(policy, "CutoutPolicy") }
        for policy in PerimeterPolicy.allCases { try Self.roundTrip(policy, "PerimeterPolicy") }
        for mode in SlopeMode.allCases { try Self.roundTrip(mode, "SlopeMode") }
        for key in MeasurementParameterKey.allCases { try Self.roundTrip(key, "MeasurementParameterKey") }

        try Self.roundTrip(
            CountGroup(
                id: CountGroupID(Self.uuid(11)),
                symbolID: SymbolID(Self.uuid(13)),
                pageID: pageID,
                zoneID: ZoneID(Self.uuid(5)),
                subject: "Sprinkler head",
                label: "SP-1",
                pointIDs: [CountPointID(Self.uuid(12))],
                showsSequentialNumbering: true
            ),
            "CountGroup"
        )
    }

    // MARK: - Markup

    @Test("A fully populated markup record round-trips")
    func markup() throws {
        let columnID = ColumnID(Self.uuid(8))
        let record = MarkupRecord(
            id: MarkupID(Self.uuid(3)),
            documentID: DocumentID(Self.uuid(1)),
            pageID: PageID(Self.uuid(2)),
            kind: .measurement,
            tool: .area,
            subject: "Slab",
            label: "S-01",
            comment: "Includes step-down",
            author: "A. Mason",
            status: .inProgress,
            style: MarkupStyle(
                color: RGBAColor(red: 0.9, green: 0.2, blue: 0.1),
                fill: RGBAColor(red: 0.9, green: 0.2, blue: 0.1, alpha: 0.25),
                opacity: 0.8,
                lineWidth: 1.5,
                lineStyle: .dashDot,
                startCap: .openArrow,
                endCap: .circle,
                fontName: "Helvetica-Bold",
                fontSize: 12,
                textAlignment: .center
            ),
            caption: "50.0 m2",
            layerID: LayerID(Self.uuid(4)),
            zoneID: ZoneID(Self.uuid(5)),
            scaleRegionID: ScaleRegionID(Self.uuid(7)),
            scaleID: ScaleID(Self.uuid(6)),
            scaleVersion: 3,
            locked: true,
            hidden: false,
            printable: true,
            geometry: MeasurementGeometry(pageID: PageID(Self.uuid(2)), points: [.zero]),
            parameters: .default,
            measurement: MeasurementResult(values: [.netArea: .area(50)]),
            parentMarkupID: MarkupID(Self.uuid(20)),
            cutoutMarkupIDs: [MarkupID(Self.uuid(21))],
            countGroupID: CountGroupID(Self.uuid(11)),
            customValues: [columnID: .currency(amount: Decimal(string: "1250.50") ?? 0, code: "SEK")],
            createdAt: Date(timeIntervalSinceReferenceDate: 1000),
            modifiedAt: Date(timeIntervalSinceReferenceDate: 2000)
        )
        try Self.roundTrip(record, "MarkupRecord")
        try Self.roundTrip(MarkupStyle.default, "MarkupStyle")

        for kind in MarkupKind.allCases { try Self.roundTrip(kind, "MarkupKind.\(kind.rawValue)") }
        for status in MarkupStatus.allCases { try Self.roundTrip(status, "MarkupStatus.\(status.rawValue)") }
        for style in LineStyle.allCases { try Self.roundTrip(style, "LineStyle") }
        for cap in LineCapStyle.allCases { try Self.roundTrip(cap, "LineCapStyle") }
        for alignment in TextAlignment.allCases { try Self.roundTrip(alignment, "TextAlignment") }
        for command in MarkupCommandKind.allCases { try Self.roundTrip(command, "MarkupCommandKind") }
        for mode in MarkupExportMode.allCases { try Self.roundTrip(mode, "MarkupExportMode") }
    }

    // MARK: - Snap

    @Test("Snap primitives, candidates and settings round-trip")
    func snap() throws {
        let geometries: [PrimitiveGeometry] = [
            .point(PDFPoint(x: 1, y: 2)),
            .segment(SegmentGeometry(start: .zero, end: PDFPoint(x: 4, y: 4))),
            .polyline(points: [.zero, PDFPoint(x: 1, y: 1)], isClosed: true),
            .cubicCurve(start: .zero, control1: PDFPoint(x: 1, y: 1),
                        control2: PDFPoint(x: 2, y: 2), end: PDFPoint(x: 3, y: 0)),
            .quadraticCurve(start: .zero, control: PDFPoint(x: 1, y: 2), end: PDFPoint(x: 2, y: 0)),
            .rectangle(PDFRect(x: 0, y: 0, width: 5, height: 5)),
            .circle(CircleGeometry(center: .zero, radius: 3)),
            .ellipticalArc(ArcGeometry(center: .zero, radius: 3, startAngle: 0, sweepAngle: 2))
        ]
        for geometry in geometries {
            try Self.roundTrip(geometry, "PrimitiveGeometry.\(geometry.kind.rawValue)")
            let primitive = SnapPrimitive(
                id: 42,
                bounds: PDFRect(x: 0, y: 0, width: 10, height: 10),
                kind: geometry.kind,
                geometry: geometry,
                sourceObjectID: 7,
                confidence: 0.75,
                layerID: "A-WALL"
            )
            try Self.roundTrip(primitive, "SnapPrimitive.\(geometry.kind.rawValue)")
            #expect(primitive.isConsistent)
        }

        try Self.roundTrip(
            SnapCandidate(
                kind: .intersection,
                position: PDFPoint(x: 3, y: 4),
                primitiveID: 42,
                source: .pdfFormObject,
                screenDistancePixels: 2.5,
                confidence: 0.9,
                isOnActiveLayer: false,
                satisfiesDirectionConstraint: true,
                isHeldByHysteresis: true,
                score: 12.5
            ),
            "SnapCandidate"
        )

        var settings = SnapSettings.default
        settings.priorityOverrides = [.grid: 1, .endpoint: 0]
        settings.enabledKinds = [.endpoint, .midpoint, .grid]
        settings.gridSpacingPoints = 18
        try Self.roundTrip(settings, "SnapSettings")

        for kind in PrimitiveKind.allCases { try Self.roundTrip(kind, "PrimitiveKind") }
        for kind in SnapKind.allCases { try Self.roundTrip(kind, "SnapKind.\(kind.rawValue)") }
        for source in SnapGeometrySource.allCases { try Self.roundTrip(source, "SnapGeometrySource") }
        for availability in SnapAvailability.allCases { try Self.roundTrip(availability, "SnapAvailability") }
    }

    // MARK: - Ledger and formula

    @Test("Ledger columns, cells and rows round-trip")
    func ledger() throws {
        let columnID = ColumnID(Self.uuid(8))
        let choiceID = ChoiceOptionID(Self.uuid(10))
        let column = LedgerColumnDefinition(
            id: columnID,
            key: "trade",
            title: "Trade",
            kind: .choice,
            standard: nil,
            dimension: .count,
            displayUnit: .count,
            precision: .decimalPlaces(2),
            choices: [
                ChoiceOption(id: choiceID, value: "Concrete",
                             color: RGBAColor(red: 0.5, green: 0.5, blue: 0.5), order: 0),
                ChoiceOption(id: ChoiceOptionID(Self.uuid(14)), value: "Steel", order: 1, isRetired: true)
            ],
            defaultChoiceID: choiceID,
            formula: nil,
            isEditable: true,
            isVisible: true,
            order: 4
        )
        try column.validate()
        try Self.roundTrip(column, "LedgerColumnDefinition")

        let values: [LedgerCellValue] = [
            .empty,
            .text("Slab"),
            .number(.area(Decimal(string: "12.75") ?? 0)),
            .currency(amount: Decimal(string: "99.95") ?? 0, code: "SEK"),
            .date(Date(timeIntervalSinceReferenceDate: 500)),
            .checkbox(true),
            .choice(choiceID),
            .formulaResult(value: .money(Decimal(string: "1274.36") ?? 0, currencyCode: "SEK"),
                           grammarVersion: ContractVersion.formula)
        ]
        for value in values { try Self.roundTrip(value, "LedgerCellValue.\(value.kind.rawValue)") }

        let row = LedgerRowRecord(
            id: RowID(Self.uuid(9)),
            markupID: MarkupID(Self.uuid(3)),
            parentRowID: RowID(Self.uuid(15)),
            depth: 2,
            groupPath: ["Concrete", "Level 1"],
            cells: [columnID: .choice(choiceID)],
            isGroupRow: false,
            descendantCount: 0
        )
        try Self.roundTrip(row, "LedgerRowRecord")
        try row.validate(columns: [columnID: column])

        for kind in ColumnKind.allCases { try Self.roundTrip(kind, "ColumnKind") }
        for standard in StandardLedgerColumn.allCases {
            try Self.roundTrip(standard, "StandardLedgerColumn.\(standard.rawValue)")
        }
        for key in LedgerGroupingKey.allCases { try Self.roundTrip(key, "LedgerGroupingKey") }
        try Self.roundTrip(ChoiceOption(id: choiceID, value: "Concrete"), "ChoiceOption")
    }

    @Test("Formula vocabulary round-trips")
    func formula() throws {
        let expression = FormulaExpression(source: "IF(Area > 0, Area * UnitCost, 0)")
        try expression.validate()
        try Self.roundTrip(expression, "FormulaExpression")
        for op in FormulaOperator.allCases { try Self.roundTrip(op, "FormulaOperator.\(op.rawValue)") }
        for function in FormulaFunction.allCases { try Self.roundTrip(function, "FormulaFunction.\(function.rawValue)") }
        for variable in FormulaVariable.allCases { try Self.roundTrip(variable, "FormulaVariable.\(variable.rawValue)") }
    }

    @Test("Contract documents round-trip")
    func contractDocuments() throws {
        for document in try ContractCatalog.allDocuments(frozenAt: "2026-08-23T00:00:00Z") {
            try Self.roundTrip(document, "ContractDocument.\(document.contract)")
        }
    }
}
