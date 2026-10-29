import Foundation
import Testing
@testable import ZPDFContracts

/// The freeze is generated from the Swift source. These tests are what makes that claim true:
/// a property added without an annotation, or an annotation left behind by a removed property,
/// fails here before it can reach `Docs/Contracts`.
@Suite("Contract freeze")
struct ContractFreezeTests {

    static let frozenAt = "2026-08-23T00:00:00Z"

    @Test("The catalogue builds all seven documents, in order")
    func catalogueBuilds() throws {
        let documents = try ContractCatalog.allDocuments(frozenAt: Self.frozenAt)
        #expect(documents.count == 7)
        #expect(documents.map(\.contract) == ContractCatalog.documentNames)
        for document in documents {
            #expect(document.frozenAt == Self.frozenAt)
            #expect(document.contractVersion >= 1)
            #expect(!document.invariants.isEmpty, "\(document.contract) has no invariants")
            #expect(!document.types.isEmpty, "\(document.contract) describes no types")
            #expect(!document.specSections.isEmpty, "\(document.contract) cites no spec section")
            #expect(!document.summary.isEmpty)
            #expect(document.generator == ContractCatalog.generatorName)
        }
    }

    @Test("Every described type says something: fields or cases, plus a summary")
    func typesAreDescribed() throws {
        for document in try ContractCatalog.allDocuments(frozenAt: Self.frozenAt) {
            for type in document.types {
                #expect(!type.summary.isEmpty, "\(document.contract)/\(type.name) has no summary")
                #expect(!(type.fields.isEmpty && type.cases.isEmpty),
                        "\(document.contract)/\(type.name) describes neither fields nor cases")
                for field in type.fields {
                    #expect(!field.name.isEmpty)
                    #expect(!field.type.isEmpty)
                    #expect(field.unit?.isEmpty == false,
                            "\(type.name).\(field.name) has no unit annotation")
                    #expect(field.invariant?.isEmpty == false,
                            "\(type.name).\(field.name) has no invariant annotation")
                }
            }
        }
    }

    @Test("Reflection rejects an unannotated property")
    func unannotatedPropertyFails() {
        #expect(throws: ContractCatalogError.unannotatedField(type: "PDFPoint", field: "y")) {
            _ = try ContractTypeDescription.reflecting(
                PDFPoint(x: 0, y: 0),
                name: "PDFPoint",
                summary: "incomplete",
                annotations: ["x": .init("PDF point", "finite")]
            )
        }
    }

    @Test("Reflection rejects an annotation with no matching property")
    func staleAnnotationFails() {
        #expect(throws: ContractCatalogError.staleAnnotation(type: "PDFPoint", field: "z")) {
            _ = try ContractTypeDescription.reflecting(
                PDFPoint(x: 0, y: 0),
                name: "PDFPoint",
                summary: "stale",
                annotations: [
                    "x": .init("PDF point", "finite"),
                    "y": .init("PDF point", "finite"),
                    "z": .init("PDF point", "does not exist")
                ]
            )
        }
    }

    @Test("Reflected field names and types come from the Swift source")
    func reflectionMatchesSource() throws {
        let description = try ContractTypeDescription.reflecting(
            ContractSamples.scale,
            name: "ScaleTransform",
            summary: "s",
            annotations: [
                "id": .init("-", "-"),
                "pageID": .init("-", "-"),
                "version": .init("-", "-"),
                "matrix": .init("-", "-"),
                "units": .init("-", "-"),
                "source": .init("-", "-"),
                "label": .init("-", "-")
            ]
        )
        #expect(description.fields.map(\.name)
                == ["id", "pageID", "version", "matrix", "units", "source", "label"])
        #expect(description.fields.map(\.type)
                == ["ScaleID", "PageID?", "Int", "AffineScaleMatrix", "ScaleUnitPolicy", "ScaleSource", "String?"])
    }

    @Test("Generic types are printed in Swift's sugared spelling")
    func sugaredTypeNames() {
        #expect(ContractTypeNaming.sugaredName(of: Optional<Decimal>.none) == "Decimal?")
        #expect(ContractTypeNaming.sugaredName(of: [PDFPoint]()) == "[PDFPoint]")
        #expect(ContractTypeNaming.sugaredName(of: [MeasurementField: DecimalQuantity]())
                == "[MeasurementField: DecimalQuantity]")
        #expect(ContractTypeNaming.sugaredName(of: Optional<[PDFPoint]>.none) == "[PDFPoint]?")
    }

    @Test("Enum descriptions are generated from allCases")
    func enumerationsComeFromAllCases() throws {
        let documents = try ContractCatalog.allDocuments(frozenAt: Self.frozenAt)
        let markup = try #require(documents.first { $0.contract == "MARKUP_CONTRACT" })
        let kinds = try #require(markup.types.first { $0.name == "MarkupKind" })
        #expect(kinds.cases.count == MarkupKind.allCases.count)
        #expect(Set(kinds.cases.compactMap(\.rawValue)) == Set(MarkupKind.allCases.map(\.rawValue)))

        let architecture = try #require(documents.first { $0.contract == "ARCHITECTURE_FREEZE" })
        let lengthTable = try #require(architecture.tables.first { $0.name == "lengthConversionFactors" })
        #expect(lengthTable.rows.count == LengthUnit.allCases.count)
        let inchRow = try #require(lengthTable.rows.first { $0[0] == "in" })
        #expect(inchRow[2] == "0.0254")
        #expect(inchRow[3] == "exact")
    }

    @Test("Every spec 15.2 standard column and 12.1 tool appears in its contract")
    func vocabularyCoverage() throws {
        let documents = try ContractCatalog.allDocuments(frozenAt: Self.frozenAt)
        let ledger = try #require(documents.first { $0.contract == "LEDGER_CONTRACT" })
        let columns = try #require(ledger.tables.first { $0.name == "standardColumns" })
        #expect(columns.rows.count == StandardLedgerColumn.allCases.count)

        let measurement = try #require(documents.first { $0.contract == "MEASUREMENT_CONTRACT" })
        let tools = try #require(measurement.types.first { $0.name == "MeasurementTool" })
        #expect(tools.cases.count == 22, "spec 12.1 lists 22 measurement tools")

        let fields = try #require(measurement.tables.first { $0.name == "measurementFieldDimensions" })
        #expect(fields.rows.count == MeasurementField.allCases.count)
    }

    @Test("Writing the freeze produces seven deterministic files")
    func writingIsDeterministic() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("zpdf-contract-freeze-test-\(ProcessInfo.processInfo.processIdentifier)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try ContractCatalog.write(to: directory, frozenAt: Self.frozenAt)
        #expect(first.count == 7)
        let firstBytes = try first.map { try Data(contentsOf: $0) }

        let second = try ContractCatalog.write(to: directory, frozenAt: Self.frozenAt)
        let secondBytes = try second.map { try Data(contentsOf: $0) }
        #expect(firstBytes == secondBytes, "two freezes at the same timestamp must be byte-identical")

        for (url, data) in zip(first, firstBytes) {
            #expect(url.lastPathComponent.hasSuffix(".json"))
            let decoded = try JSONDecoder().decode(ContractDocument.self, from: data)
            #expect(url.lastPathComponent == "\(decoded.contract).json")
            #expect(data.last == 0x0A, "each document ends with a newline")
        }
    }

    @Test("The ISO timestamp is UTC and second-precision")
    func isoTimestamp() {
        let stamp = ContractCatalog.isoTimestamp(Date(timeIntervalSince1970: 0))
        #expect(stamp == "1970-01-01T00:00:00Z")
    }
}

@Suite("Snap and ledger validation")
struct ValidationTests {

    @Test("Snap settings reject an inverted radius range")
    func snapRadiusValidation() throws {
        try SnapSettings.default.validate()
        #expect(SnapSettings.specDefaultPixels == 10)
        #expect(SnapSettings.specMinimumPixels == 4)
        #expect(SnapSettings.specMaximumPixels == 24)
        #expect(SnapSettings.specHysteresisPixels == 4)

        var settings = SnapSettings.default
        settings.minimumPixels = 20
        #expect(throws: SnapError.self) { try settings.validate() }

        settings = SnapSettings.default
        settings.hysteresisPixels = -1
        #expect(throws: SnapError.negativeHysteresis(-1)) { try settings.validate() }

        settings = SnapSettings.default
        settings.gridSpacingPoints = 0
        #expect(throws: SnapError.nonPositiveGridSpacing(0)) { try settings.validate() }

        settings = SnapSettings.default
        settings.angleIncrementDegrees = 361
        #expect(throws: SnapError.invalidAngleIncrement(degrees: 361)) { try settings.validate() }

        #expect(SnapSettings.default.clampedRadiusPixels(100) == 24)
        #expect(SnapSettings.default.clampedRadiusPixels(1) == 4)
    }

    @Test("Snap priorities are unique and markup vertices win")
    func snapPriorities() {
        let priorities = SnapKind.allCases.map(\.defaultPriority)
        #expect(Set(priorities).count == priorities.count, "snap priorities must be a total order")
        #expect(SnapKind.markupVertex.defaultPriority < SnapKind.intersection.defaultPriority)
        #expect(SnapKind.intersection.defaultPriority < SnapKind.endpoint.defaultPriority)
        #expect(SnapKind.grid.defaultPriority == priorities.max())
        #expect(!SnapKind.grid.requiresVectorContent)
        #expect(SnapKind.tangent.requiresVectorContent)
    }

    @Test("Measurement parameters demand the input their mode needs")
    func parameterValidation() throws {
        try MeasurementParameters.default.validate()

        var parameters = MeasurementParameters(slope: SlopeSpecification(mode: .uniformPlane))
        #expect(throws: MeasurementError.missingParameter(.riseRun)) { try parameters.validate() }

        parameters = MeasurementParameters(slope: SlopeSpecification(mode: .totalRiseDrop))
        #expect(throws: MeasurementError.missingParameter(.totalRiseDrop)) { try parameters.validate() }

        parameters = MeasurementParameters(slope: SlopeSpecification(mode: .perSegmentRiseDrop))
        #expect(throws: MeasurementError.missingParameter(.perSegmentRiseDrop)) { try parameters.validate() }

        parameters = MeasurementParameters(depth: .area(1))
        #expect(throws: UnitConversionError.self) { try parameters.validate() }
    }

    @Test("A measurement result with a mismatched dimension is caught")
    func resultDimensionValidation() {
        let bad = MeasurementResult(values: [.volume: .area(1)])
        #expect(throws: DimensionError.self) { try bad.validateDimensions() }
        let good = MeasurementResult(values: [.volume: .volume(1)])
        #expect(throws: Never.self) { try good.validateDimensions() }
    }

    @Test("A polygon ring collapses duplicates and closes itself")
    func polygonRing() {
        let ring = PolygonRing(points: [
            PDFPoint(x: 0, y: 0), PDFPoint(x: 0, y: 0),
            PDFPoint(x: 10, y: 0), PDFPoint(x: 10, y: 10), PDFPoint(x: 0, y: 0)
        ])
        #expect(ring.uniquePoints.count == 3)
        #expect(ring.segments.count == 3)
        let open = PolygonRing(points: [PDFPoint(x: 0, y: 0), PDFPoint(x: 1, y: 0)], isClosed: false)
        #expect(open.segments.count == 1)
    }

    @Test("A cell value in the wrong column is rejected")
    func cellKindValidation() throws {
        let columnID = ColumnID(UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 8)))
        let column = LedgerColumnDefinition(id: columnID, key: "unitCost", title: "Unit Cost", kind: .currency)
        #expect(throws: LedgerError.self) {
            try LedgerCellValue.text("oops").validate(against: column)
        }
        #expect(throws: Never.self) {
            try LedgerCellValue.currency(amount: 1, code: "SEK").validate(against: column)
        }
        #expect(throws: Never.self) { try LedgerCellValue.empty.validate(against: column) }
    }

    @Test("A choice column needs options and a live default")
    func choiceColumnValidation() {
        let columnID = ColumnID(UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 8)))
        let retiredID = ChoiceOptionID(UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 10)))
        let empty = LedgerColumnDefinition(id: columnID, key: "trade", title: "Trade", kind: .choice)
        #expect(throws: LedgerError.invalidChoiceConfiguration(columnID)) { try empty.validate() }

        let retiredDefault = LedgerColumnDefinition(
            id: columnID, key: "trade", title: "Trade", kind: .choice,
            choices: [ChoiceOption(id: retiredID, value: "Steel", isRetired: true)],
            defaultChoiceID: retiredID
        )
        #expect(throws: LedgerError.invalidChoiceConfiguration(columnID)) { try retiredDefault.validate() }
    }

    @Test("A derived standard column may not be marked editable")
    func standardColumnEditability() {
        let columnID = ColumnID(UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 8)))
        let column = LedgerColumnDefinition(
            id: columnID, key: "planArea", title: "Plan Area", kind: .number,
            standard: .planArea, isEditable: true
        )
        #expect(throws: LedgerError.standardColumnNotEditable(.planArea)) { try column.validate() }
        #expect(!StandardLedgerColumn.planArea.isUserEditable)
        #expect(StandardLedgerColumn.subject.isUserEditable)
    }

    @Test("A formula's grammar version is checked before it is parsed")
    func formulaVersioning() {
        #expect(throws: FormulaError.emptySource) {
            try FormulaExpression(source: "   ").validate()
        }
        #expect(throws: FormulaError.self) {
            try FormulaExpression(source: "Area", grammarVersion: ContractVersion.formula + 1).validate()
        }
    }

    @Test("The formula vocabulary matches spec 15.4")
    func formulaVocabulary() {
        #expect(FormulaFunction.allCases.count == 10)
        #expect(Set(FormulaFunction.allCases.map(\.rawValue))
                == ["IF", "ROUND", "ROUNDUP", "ROUNDDOWN", "MIN", "MAX", "ABS", "SUM", "COUNT", "COALESCE"])
        #expect(FormulaOperator.power.isRightAssociative)
        #expect(FormulaOperator.not.infixBindingPower == nil)
        #expect((FormulaOperator.multiply.infixBindingPower ?? 0)
                > (FormulaOperator.add.infixBindingPower ?? 0))
        #expect(FormulaVariable.area.measurementField == .netArea)
        #expect(FormulaVariable.unitCost.dimension == nil)
    }

    @Test("A markup knows when its measurement is stale")
    func staleMeasurement() throws {
        let scaleID = ScaleID(UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 6)))
        let scale = try ScaleTransform.uniform(
            id: scaleID, version: 4, metresPerPoint: Decimal(string: "0.01") ?? 0,
            units: .metric, source: .preset
        )
        var record = MarkupRecord(
            id: MarkupID(UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3))),
            documentID: DocumentID(UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))),
            pageID: PageID(UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2))),
            kind: .measurement,
            scaleID: scaleID,
            scaleVersion: 3,
            createdAt: Date(timeIntervalSince1970: 0),
            modifiedAt: Date(timeIntervalSince1970: 0)
        )
        #expect(record.isMeasurementStale(against: scale))
        record.scaleVersion = 4
        #expect(!record.isMeasurementStale(against: scale))
    }
}
