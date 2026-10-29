import Foundation
import Testing
@testable import ZPDFContracts

/// ADR-0030 (NL-MEASURE-04): scale checks stored with the calibration evidence, additively.
@Suite("Scale verification in the evidence (ADR-0030)")
struct ScaleVerificationContractTests {

    static let check = ScaleVerification(
        points: [PDFPoint(x: 0, y: 0), PDFPoint(x: 200, y: 0)],
        statedLength: .length(Decimal(string: "7.2")!),
        statedUnit: .metre,
        measuredLength: .length(Decimal(string: "7.21512")!),
        scaleVersion: 2,
        verifiedAt: Date(timeIntervalSince1970: 1_790_000_000)
    )

    @Test("An old record decodes with no checks; a checked one round-trips them")
    func additive() throws {
        let plain = CalibrationEvidence(
            points: [PDFPoint(x: 0, y: 0), PDFPoint(x: 100, y: 0)], enteredLength: .length(5), enteredUnit: .metre
        )
        let old = try JSONEncoder().encode(plain)
        #expect(!String(decoding: old, as: UTF8.self).contains("verifications"), "no key until the first check: the bytes written before ADR-0030")
        #expect(try JSONDecoder().decode(CalibrationEvidence.self, from: old).verifications == nil)

        let checked = plain.appending(Self.check).appending(Self.check)
        #expect(checked.verifications?.count == 2)
        #expect(checked.points == plain.points && checked.enteredLength == plain.enteredLength)
        let back = try JSONDecoder().decode(CalibrationEvidence.self, from: JSONEncoder().encode(checked))
        #expect(back == checked)
    }

    /// 7.21512 / 7.2 − 1 = 0.0021 exactly (hand: 7.2 × 1.0021 = 7.21512).
    @Test("Deviation is exact in Decimal")
    func deviation() {
        #expect(Self.check.deviation == Decimal(string: "0.0021")!)
        let zero = ScaleVerification(
            points: [], statedLength: .length(0), statedUnit: .metre, measuredLength: .length(1), scaleVersion: 1, verifiedAt: Date()
        )
        #expect(zero.deviation == nil)
    }

    @Test("The freeze describes the new type and field")
    func frozen() throws {
        let documents = try ContractCatalog.allDocuments(frozenAt: "2026-09-01T23:28:48Z")
        let measurement = try #require(documents.first { $0.contract == "MEASUREMENT_CONTRACT" })
        let evidence = try #require(measurement.types.first { $0.name == "CalibrationEvidence" })
        #expect(evidence.fields.contains { $0.name == "verifications" })
        #expect(measurement.types.contains { $0.name == "ScaleVerification" })
    }
}

/// ADR-0030 §3 (NL-MEASURE-09): the caption choice rides on the style, additively.
@Suite("Measurement caption on the style (ADR-0030 §3)")
struct MeasurementCaptionContractTests {

    @Test("A style without a caption encodes without the key; one with it round-trips")
    func additive() throws {
        let plain = MarkupStyle(color: .opaqueBlack)
        let bytes = try JSONEncoder().encode(plain)
        #expect(!String(decoding: bytes, as: UTF8.self).contains("measurementCaption"))
        #expect(try JSONDecoder().decode(MarkupStyle.self, from: bytes).measurementCaption == nil)

        var captioned = plain
        captioned.measurementCaption = MeasurementCaption(fields: [.netArea, .perimeter], showsSegmentLengths: true, labelOffset: PDFPoint(x: 12, y: -4))
        let back = try JSONDecoder().decode(MarkupStyle.self, from: JSONEncoder().encode(captioned))
        #expect(back == captioned)
        #expect(MeasurementCaption().isDefault)
        #expect(!(back.measurementCaption?.isDefault ?? true))
    }

    @Test("The freeze describes the caption type and the style field")
    func frozen() throws {
        let documents = try ContractCatalog.allDocuments(frozenAt: "2026-09-01T23:28:48Z")
        let measurement = try #require(documents.first { $0.contract == "MEASUREMENT_CONTRACT" })
        #expect(measurement.types.contains { $0.name == "MeasurementCaption" })
        let markup = try #require(documents.first { $0.contract == "MARKUP_CONTRACT" })
        let style = try #require(markup.types.first { $0.name == "MarkupStyle" })
        #expect(style.fields.contains { $0.name == "measurementCaption" })
    }
}
