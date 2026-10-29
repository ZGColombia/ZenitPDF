import Foundation
import Testing
import ZPDFContracts
import ZPDFPersistence
@testable import ZPDFAppCore

/// NL-MEASURE-04 / ADR-0030 §1: a scale check is kept with the calibration evidence and listed in
/// History.
@Suite("Verify Scale store (NL-MEASURE-04)")
struct NLMeasureVerificationTests {

    static let documentID = DocumentID(UUID())

    static func page() -> ZPDFContracts.PageDescriptor {
        ZPDFContracts.PageDescriptor(
            id: PageID(UUID()), documentID: documentID, index: 0, label: "A-101",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 1_684, height: 2_384))
        )
    }

    /// Calibrated at 100 pt = 5 m (0.05 m/pt). A stated 7.2 m dimension drawn 144.3 pt long
    /// measures 144.3 × 0.05 = 7.215 m: deviation 7.215 / 7.2 − 1 = 0.0020833… (hand-derived).
    @Test("A check on a calibrated scale lands in its evidence and survives the sidecar")
    func storedWithEvidence() async throws {
        let page = Self.page()
        let session = try TakeoffSession(documentID: Self.documentID, pages: [page], units: .metric)
        _ = try await session.calibrate(
            page: page.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0), knownLength: 5, knownLengthUnit: .metre
        )
        let (check, scaleID) = try await session.scaleVerification(
            page: page.id, points: [PDFPoint(x: 10, y: 10), PDFPoint(x: 154.3, y: 10)],
            statedLength: Decimal(string: "7.2")!, statedUnit: .metre
        )
        let measured = NSDecimalNumber(decimal: check.measuredLength.value).doubleValue
        #expect(Swift.abs(measured - 7.215) <= 7.215 * 1e-12)
        let deviation = NSDecimalNumber(decimal: try #require(check.deviation)).doubleValue
        #expect(Swift.abs(deviation - (7.215 / 7.2 - 1)) <= 1e-12)
        #expect(check.scaleVersion == 1)

        #expect(await session.recordScaleVerification(check, scaleID: scaleID))
        #expect(await session.verifications(for: scaleID) == [check])
        let evidence = try #require(await session.evidence(for: scaleID))
        #expect(evidence.points == [PDFPoint(x: 0, y: 0), PDFPoint(x: 100, y: 0)], "the calibration itself is unchanged")

        // Saved through the scale row's JSON sidecar and read back.
        let scale = try #require(await session.pageScale(page.id))
        let row = try TakeoffArchive.scaleRecord(from: scale, pageId: page.id.rawValue.uuidString, savedAt: "2026-09-26T00:00:00Z", evidence: evidence)
        #expect(TakeoffArchive.calibrationEvidence(from: row)?.verifications == [check])

        // A recalibration is a new scale version: the old check no longer applies and a check of
        // the old version is not stored.
        _ = try await session.calibrate(
            page: page.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0), knownLength: 6, knownLengthUnit: .metre
        )
        #expect(await session.verifications(for: scaleID).isEmpty)
        #expect(await session.recordScaleVerification(check, scaleID: scaleID) == false)
    }

    @Test("A check on a preset stores no evidence")
    func presetHasNoEvidence() async throws {
        let page = Self.page()
        let session = try TakeoffSession(documentID: Self.documentID, pages: [page], units: .metric)
        _ = try await session.setPresetScale(page: page.id, ratioDenominator: 100)
        let (check, scaleID) = try await session.scaleVerification(
            page: page.id, points: [PDFPoint(x: 0, y: 0), PDFPoint(x: 72, y: 0)], statedLength: Decimal(string: "2.54")!, statedUnit: .metre
        )
        // 72 pt at 1:100 = one inch × 100 = 2.54 m: deviation 0 (hand-derived).
        #expect(Swift.abs(NSDecimalNumber(decimal: try #require(check.deviation)).doubleValue) <= 1e-12)
        #expect(await session.recordScaleVerification(check, scaleID: scaleID) == false)
        #expect(await session.evidence(for: scaleID) == nil, "evidence is never fabricated for a preset (ADR-0019)")
    }

    @Test("History lists a scale_verified entry")
    @MainActor
    func historyEntry() async throws {
        let page = Self.page()
        let session = try TakeoffSession(documentID: Self.documentID, pages: [page])
        let environment = try await AppCoreEnvironment.make(session: session, documentID: Self.documentID)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("zenit-verify-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try await ProjectDatabaseActor.open(at: directory.appendingPathComponent("h.sqlite"))
        environment.history.attach(database: database, projectID: Self.documentID.rawValue.uuidString)
        try await environment.commands.calibrate(
            page: page.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0), knownLength: 5, knownLengthUnit: .metre
        )
        let result = try await environment.verifyScale(
            page: page.id, points: [PDFPoint(x: 0, y: 0), PDFPoint(x: 100, y: 0)], statedLength: 5, statedUnit: .metre
        ) { _ in "agrees within 0.00 %" }
        #expect(result.storedWithEvidence)
        await environment.history.settle()
        let last = try #require(environment.history.events.last)
        #expect(last.action == "scale_verified")
        #expect(last.note == "agrees within 0.00 %")
        #expect(last.markupID == nil)
        #expect(last.actionDisplayName == "Scale verified")
    }
}
