import Foundation
import Testing
@testable import ZPDFContracts

/// ADR-0031 (NL-AUTO-18): `MeasurementProvenance.captureMethod` is additive. A record written
/// before it decodes as manual and re-encodes byte for byte; a traced one round-trips what the
/// detector assumed.
@Suite("Capture method on measurement provenance (ADR-0031)")
struct CaptureMethodContractTests {

    static let base = MeasurementProvenance(
        geometryDigest: "abc", scaleID: ScaleID(UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!), scaleVersion: 2,
        scaleSource: .preset, slope: .none, parameters: .default, formulaVersion: 1, engineVersion: "1.0",
        computedAt: Date(timeIntervalSince1970: 1_790_000_000))

    @Test("An old record has no captureMethod key, decodes as manual and re-encodes unchanged")
    func oldRecordIsManual() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let old = try encoder.encode(Self.base)
        #expect(!String(decoding: old, as: UTF8.self).contains("captureMethod"), "nothing is written for a manual capture")
        let decoded = try JSONDecoder().decode(MeasurementProvenance.self, from: old)
        #expect(decoded.captureMethod == nil)
        #expect(decoded.capture == .manual)
        #expect(try encoder.encode(decoded) == old)
    }

    @Test("A traced capture with one confirmed 25.4 pt closing line round-trips")
    func tracedRoundTrips() throws {
        let traced = Self.base.with(captureMethod: .autoTraced(closureWidthsPoints: [25.4]))
        let decoded = try JSONDecoder().decode(MeasurementProvenance.self, from: JSONEncoder().encode(traced))
        #expect(decoded.capture.kind == .autoTraced)
        #expect(decoded.capture.bridgedGapCount == 1)
        #expect(decoded.capture.largestGapPoints == 25.4)
        #expect(decoded.capture.closureWidthsPoints == [25.4])
        #expect(decoded.geometryDigest == "abc" && decoded.scaleVersion == 2, "with(captureMethod:) keeps every other field")
        let matched = CaptureMethod(kind: .symbolMatched, residualRatio: 0.031, isMirrored: true, matchScale: 1, exemplarDigest: "d1")
        let again = try JSONDecoder().decode(CaptureMethod.self, from: JSONEncoder().encode(matched))
        #expect(again == matched)
    }

    @Test("A kind from a newer build reads as unrecognised — never as manual, and never refusing the record")
    func unknownKindIsUnrecognised() throws {
        let json = Data(#"{"kind":"telepathy","confidence":0.4}"#.utf8)
        let read = try JSONDecoder().decode(CaptureMethod.self, from: json)
        #expect(read.kind == .unrecognised)
        #expect(read.confidence == 0.4)
    }

    @Test("Every kind is stored as its own name; a measurement read from a PDF annotation says so")
    func kindsAreStoredByName() throws {
        let imported = try JSONEncoder().encode(CaptureMethod(kind: .importedAnnotation))
        #expect(String(decoding: imported, as: UTF8.self) == #"{"kind":"importedAnnotation"}"#)
        for kind in CaptureMethod.Kind.allCases where kind != .unrecognised {
            let read = try JSONDecoder().decode(CaptureMethod.self, from: JSONEncoder().encode(CaptureMethod(kind: kind)))
            #expect(read.kind == kind)
        }
    }
}
