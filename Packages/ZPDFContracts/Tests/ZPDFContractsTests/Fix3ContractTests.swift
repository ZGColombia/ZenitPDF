import Foundation
import Testing
@testable import ZPDFContracts

// Bug-fix round 3, package ZPDFContracts (ADR-0018: IM-070 and the cutout row rule that settles
// ADR-0016 §3.1's open point).
//
// Each test names what the old contract said, so it fails against the old code.

private let frozenAt = "2026-09-01T23:28:48Z"

private func document(_ name: String) throws -> ContractDocument {
    try #require(try ContractCatalog.allDocuments(frozenAt: frozenAt).first { $0.contract == name })
}

@Suite("Fix 3 — ADR-0018 contract additions")
struct Fix3ContractTests {

    @Test("IM-070: the warning set has a dedicated code for a skipped self-intersection check")
    func selfIntersectionCheckSkippedCode() throws {
        // Old state: no such case; the engine reused `numericalPrecisionLoss` with a detail
        // string, which the UI maps to no user-facing warning at all.
        let code = try #require(MeasurementWarning.Code(rawValue: "selfIntersectionCheckSkipped"))
        #expect(code == .selfIntersectionCheckSkipped)
        #expect(code != .numericalPrecisionLoss)
        // Additive: it round-trips like every other code, and an old stored code still decodes.
        let data = try JSONEncoder().encode(MeasurementWarning(code: code, field: .planArea))
        let decoded = try JSONDecoder().decode(MeasurementWarning.self, from: data)
        #expect(decoded.code == .selfIntersectionCheckSkipped)
        let old = try JSONDecoder().decode(
            MeasurementWarning.self,
            from: Data(#"{"code":"numericalPrecisionLoss","detail":""}"#.utf8)
        )
        #expect(old.code == .numericalPrecisionLoss)

        // The frozen document lists it and names the ADR.
        let measurement = try document("MEASUREMENT_CONTRACT")
        let codes = try #require(measurement.types.first { $0.name == "MeasurementWarning.Code" })
        #expect(codes.cases.contains { $0.name == "selfIntersectionCheckSkipped" })
        #expect(codes.invariants.contains { $0.contains("selfIntersectionCheckSkipped") && $0.contains("ADR-0018") })
    }

    @Test("ADR-0018: Gross Area and Cutout Area are read-only columns beside Plan Area")
    func grossAndCutoutAreaColumns() throws {
        // Old state: neither column existed; the gross outline and the removed area were not
        // reachable from the ledger at all.
        #expect(StandardLedgerColumn.grossArea.measurementField == .planArea)
        #expect(StandardLedgerColumn.cutoutArea.measurementField == .cutoutArea)
        // Plan Area is untouched: it is still the net quantity (ADR-0016).
        #expect(StandardLedgerColumn.planArea.measurementField == .netArea)
        for column in [StandardLedgerColumn.grossArea, .cutoutArea] {
            #expect(!column.isUserEditable, "\(column) is derived")
            #expect(column.kind == .number)
            #expect(column.measurementField?.dimension == .area)
        }
        // A 10 x 10 m slab with a 4 x 4 m cutout: gross 100, cutout 16, Plan Area 100 - 16 = 84.
        let result = MeasurementResult(values: [
            .planArea: .area(100), .netArea: .area(84), .cutoutArea: .area(16)
        ])
        #expect(result[try #require(StandardLedgerColumn.grossArea.measurementField)]?.value == 100)
        #expect(result[try #require(StandardLedgerColumn.cutoutArea.measurementField)]?.value == 16)
        #expect(result[try #require(StandardLedgerColumn.planArea.measurementField)]?.value == 84)

        // Additive: appended after every existing key, so no existing column moved.
        let keys = StandardLedgerColumn.allCases.map(\.rawValue)
        #expect(Array(keys.suffix(2)) == ["grossArea", "cutoutArea"])
        #expect(keys.firstIndex(of: "totalCost") == keys.count - 3)

        // The frozen table and invariants carry both.
        let ledger = try document("LEDGER_CONTRACT")
        let table = try #require(ledger.tables.first { $0.name == "standardColumns" })
        #expect(table.rows.contains(["grossArea", "number", "planArea", "false"]))
        #expect(table.rows.contains(["cutoutArea", "number", "cutoutArea", "false"]))
        let columns = try #require(ledger.types.first { $0.name == "StandardLedgerColumn" })
        #expect(columns.invariants.contains { $0.contains("grossArea reads the planArea field") && $0.contains("ADR-0018") })
    }

    @Test("ADR-0018: a cutout row shows no quantity, except Cutout Area under report-separately")
    func cutoutRowShowsNoQuantity() throws {
        // Old state: a cutout row read every measurement field its own result carried — its
        // own perimeter (summed into the Perimeter total), radius and diameter for a circular
        // cutout, and Plan Area before ADR-0016.
        for policy in CutoutPolicy.allCases + [nil] {
            for column in StandardLedgerColumn.allCases where column.measurementField != nil {
                let expected = column == .cutoutArea && policy == .subtractAndReportSeparately
                #expect(
                    column.showsValueOnCutoutRow(parentPolicy: policy) == expected,
                    "\(column) under \(policy.map(\.rawValue) ?? "no parent")"
                )
            }
            // Columns that are not quantities (subject, label, comment, page …) are unaffected.
            for column in StandardLedgerColumn.allCases where column.measurementField == nil {
                #expect(column.showsValueOnCutoutRow(parentPolicy: policy))
            }
        }

        let ledger = try document("LEDGER_CONTRACT")
        let columns = try #require(ledger.types.first { $0.name == "StandardLedgerColumn" })
        #expect(columns.invariants.contains {
            $0.contains("A cutout is part of its parent") && $0.contains("every CutoutPolicy")
        })
        let measurement = try document("MEASUREMENT_CONTRACT")
        let policy = try #require(measurement.types.first { $0.name == "CutoutPolicy" })
        #expect(policy.invariants.contains { $0.contains("ADR-0018") })
    }
}
