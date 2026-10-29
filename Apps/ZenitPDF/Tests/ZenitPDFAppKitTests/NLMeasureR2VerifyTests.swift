import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
@testable import ZenitPDFAppKit

/// NL-MEASURE-04 through the app: Verify Scale keeps its check with the calibration evidence and
/// says the result in the tray.
@MainActor
@Suite(.appTierSerialised)
struct NLMeasureR2VerifyTests {

    /// Calibrated 100 pt = 5 m. The stated 10 m line drawn 202 pt long measures 10.1 m: 1.00 %
    /// off, at the threshold, so it still agrees (hand: 202 × 0.05 = 10.1; 10.1 / 10 − 1 = 0.01).
    @Test("Verify Scale stores the check with the evidence and posts the result")
    func verifyStores() async throws {
        let harness = try await NLMeasureR2Harness.make("Verify.pdf")
        defer { NLMeasureR2Harness.tearDown(harness) }
        let core = harness.core
        try await core.commands.calibrate(
            page: harness.page, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0), knownLength: 5, knownLengthUnit: .metre
        )
        let (result, stored) = try await VerifyScale.record(
            points: [PDFPointValue(x: 100, y: 300), PDFPointValue(x: 302, y: 300)],
            stated: CalibrationPrompt.Entry(length: 10, unit: .metre),
            page: harness.page, core: core
        )
        #expect(stored)
        #expect(result.percent == 1)
        #expect(result.agrees)
        let scale = try #require(await core.session.pageScale(harness.page))
        let checks = await core.session.verifications(for: scale.id)
        #expect(checks.count == 1)
        #expect(checks.first?.statedLength.value == 10)
        #expect(core.document.warnings.contains { $0.source == NSLocalizedString("Verify Scale", comment: "") && $0.severity == .info })
    }
}
