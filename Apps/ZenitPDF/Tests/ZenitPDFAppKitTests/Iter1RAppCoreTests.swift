import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import ZPDFAppCore
import ZPDFCompare
import ZPDFContracts
import ZPDFPDFKitBridge
@testable import ZenitPDFAppKit

/// Quality loop iteration 1, appcore re-fix: the load pipeline's ledger prebuild (R-064) and
/// Carry Forward to Revision over a real comparison (NL-DOCS-12), end to end through the
/// shipping document class.
@MainActor
@Suite("Iteration 1 re-fix appcore — load prebuild and carry over a real comparison", .appTierSerialised)
struct Iter1RAppCoreTests {

    private func save(_ document: ZenitPDFProjectDocument, to url: URL, _ operation: NSDocument.SaveOperationType) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            document.save(to: url, ofType: ZenitAppInfo.projectTypeIdentifier, for: operation) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    /// A private container-autosave root, so another test's autosave of the same fixture bytes
    /// never turns into a restore offer mid-load.
    private func isolateAutosaveRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenit-it1r-appcore-\(UUID().uuidString)", isDirectory: true)
        ZenitPDFProjectDocument.quickPDFAutosaveRootOverride = root
        return root
    }

    /// A one-page 612 × 792 PDF stroking `lines` (each `x0 y0 x1 y1`) 2 pt wide.
    static func writeLinePDF(_ lines: [(Double, Double, Double, Double)], to url: URL) throws {
        var content = "0 G 2 w\n"
        for (x0, y0, x1, y1) in lines { content += "\(x0) \(y0) m \(x1) \(y1) l S\n" }
        let stream = Data(content.utf8)
        var objects: [Data] = [
            Data("<< /Type /Catalog /Pages 2 0 R >>".utf8),
            Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8),
            Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << >> >>".utf8)
        ]
        var body = Data("<< /Length \(stream.count) >>\nstream\n".utf8)
        body.append(stream)
        body.append(Data("\nendstream".utf8))
        objects.append(body)
        var bytes = Data("%PDF-1.7\n".utf8)
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(bytes.count)
            bytes.append(Data("\(index + 1) 0 obj\n".utf8))
            bytes.append(object)
            bytes.append(Data("\nendobj\n".utf8))
        }
        let xref = bytes.count
        bytes.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets { bytes.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        bytes.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        try bytes.write(to: url)
    }

    // MARK: R-064

    /// What the stage hook saw.
    @MainActor
    final class Stages {
        var ledgerInstalledAt: [DocumentLoadStage: Bool] = [:]
    }

    /// A saved takeoff of two areas (100 pt = 1 m: 2 × 1 m and 1 × 1 m), reopened through
    /// the shipping load path. At the `sessionBuilt` checkpoint — after hydration, before
    /// `AppCoreEnvironment.make` takes its first snapshot — the session already holds a live
    /// ledger store: the one `prebuildLedger()` built. Without the pipeline's prebuild (checked
    /// by removing the call) nothing has built a ledger at that point and the spec is `nil`.
    @Test("Opening a saved takeoff installs the prebuilt ledger before the environment's first snapshot")
    func loadPipelinePrebuildsTheLedger() async throws {
        let autosaveRoot = isolateAutosaveRoot()
        defer {
            ZenitPDFProjectDocument.quickPDFAutosaveRootOverride = nil
            try? FileManager.default.removeItem(at: autosaveRoot)
        }
        let url = try AppTestSupport.writeFixturePDF(named: "R064 Prebuild.pdf")
        let directory = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }

        let document = try AppTestSupport.makeDocument(opening: url)
        #expect(await AppTestSupport.wait { document.core != nil && !document.isLoading })
        let core = try #require(document.core)
        let page = try #require(await core.session.pageDescriptors.first)
        _ = try await core.commands.calibrate(page: page.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
                                              knownLength: 1, knownLengthUnit: .metre)
        let stamp = Date(timeIntervalSince1970: 1_790_000_000)
        for (x, width, height) in [(100.0, 200.0, 100.0), (400.0, 100.0, 100.0)] {
            try await core.commands.perform(.addMarkup(ZPDFContracts.MarkupRecord(
                id: MarkupID(UUID()), documentID: page.documentID, pageID: page.id, kind: .measurement, tool: .area,
                subject: "Slab", author: "t",
                geometry: MeasurementGeometry(pageID: page.id, polygons: [PolygonGeometry(outer: PolygonRing(points: [
                    PDFPoint(x: x, y: 100), PDFPoint(x: x + width, y: 100),
                    PDFPoint(x: x + width, y: 100 + height), PDFPoint(x: x, y: 100 + height)
                ], isClosed: true))]),
                createdAt: stamp, modifiedAt: stamp
            )))
        }
        await core.refresh()
        #expect(core.ledger.rowCount == 2)
        let package = directory.appendingPathComponent("Prebuild.zpdfproj")
        try await save(document, to: package, .saveAsOperation)
        document.close()
        await ZenitPDFProjectDocument.drainStorageShutdowns()

        let stages = Stages()
        let reopened = ZenitPDFProjectDocument()
        try reopened.read(from: package, ofType: ZenitAppInfo.projectTypeIdentifier)
        reopened.loadStageHook = { [stages] stage, state in
            guard let session = state.session else { return }
            stages.ledgerInstalledAt[stage] = await session.currentLedgerSpec != nil
        }
        reopened.startLoadingIfNeeded()
        #expect(await AppTestSupport.wait(upTo: 30) { reopened.core != nil && !reopened.isLoading })
        #expect(reopened.loadFailure == nil)
        #expect(stages.ledgerInstalledAt[.sessionBuilt] == true, "no ledger store before AppCoreEnvironment.make: \(stages.ledgerInstalledAt)")
        let restored = try #require(reopened.core)
        // 2 × 1 = 2 m² and 1 × 1 = 1 m²: 3 m².
        #expect(restored.ledger.rowCount == 2)
        #expect(restored.ledger.grandTotals.total("planArea")?.value == 3)
        reopened.close()
        await ZenitPDFProjectDocument.drainStorageShutdowns()
    }

    // MARK: NL-DOCS-12

    /// Old sheet: a line (100,100)–(200,100) and a line (400,400)–(500,400). Rev B: the first
    /// unchanged, the second redrawn at y = 420. A wall is measured along each and the sheet is
    /// carried to Rev B with a comparator that reads in process (a test process has no geometry
    /// service to reach). The wall on unchanged linework is carried `unchanged`; the wall under
    /// the redrawn line `needsReview`. Before NL-DOCS-12 both read `unchanged` (nothing was
    /// compared); with the shipping comparator in a test process both read `needsReview` (no
    /// comparison can be made, `NextLevelDocumentsRevisionMatchTests`).
    @Test("Carry Forward over a real comparison: unchanged linework stays unchanged, redrawn linework asks for review")
    func carryOverARealComparison() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("it1r-appcore-carry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let oldURL = directory.appendingPathComponent("A-101.pdf")
        let newURL = directory.appendingPathComponent("A-101 Rev B.pdf")
        try Self.writeLinePDF([(100, 100, 200, 100), (400, 400, 500, 400)], to: oldURL)
        try Self.writeLinePDF([(100, 100, 200, 100), (400, 420, 500, 420)], to: newURL)

        let harness = try await Fix2Harness.make("A-101.pdf", calibrate: false, fixture: oldURL)
        let package = directory.appendingPathComponent("Carry.zpdfproj")
        try await save(harness.document, to: package, .saveAsOperation)

        var captured: (model: SheetMatchReviewModel, rowID: String)?
        let previousReview = ZenitPDFProjectDocument.sheetMatchReviewPresenter
        ZenitPDFProjectDocument.sheetMatchReviewPresenter = { model, rowID, _ in captured = (model, rowID); return {} }
        defer { ZenitPDFProjectDocument.sheetMatchReviewPresenter = previousReview }
        var added = false
        harness.document.addRevision(fromDroppedFile: newURL) { added = $0 }
        #expect(await AppTestSupport.wait(upTo: 30) { added && captured != nil })
        let review = try #require(captured)
        review.model.setPartner(0, forSetIndex: 0)
        review.model.accept(revisionID: review.rowID)
        let summaryID = try #require(harness.document.newestRevision?.id)
        let oldPage = try #require(await harness.core.session.pageDescriptors.first)
        #expect(await AppTestSupport.wait { harness.document.revisionSheetPairs[summaryID]?[oldPage.id.rawValue] == 0 })

        let core = harness.core
        _ = try await core.commands.calibrate(page: oldPage.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
                                              knownLength: 1, knownLengthUnit: .metre)
        let stamp = Date(timeIntervalSince1970: 1_790_000_000)
        func wall(_ subject: String, _ y: Double, _ x0: Double, _ x1: Double) -> ZPDFContracts.MarkupRecord {
            ZPDFContracts.MarkupRecord(
                id: MarkupID(UUID()), documentID: oldPage.documentID, pageID: oldPage.id, kind: .measurement,
                tool: .polylength, subject: subject,
                geometry: MeasurementGeometry(pageID: oldPage.id, points: [PDFPoint(x: x0, y: y), PDFPoint(x: x1, y: y)]),
                createdAt: stamp, modifiedAt: stamp
            )
        }
        _ = try await core.commands.perform(.addMarkup(wall("Kept wall", 100, 100, 200)))
        _ = try await core.commands.perform(.addMarkup(wall("Redrawn wall", 400, 400, 500)))

        let provider = try #require(harness.document.compareProvider)
        let previousComparator = ZenitPDFProjectDocument.carryForwardComparator
        ZenitPDFProjectDocument.carryForwardComparator = { _ in
            RevisionComparator(source: InProcessRevisionDocumentSource(provider: provider))
        }
        defer { ZenitPDFProjectDocument.carryForwardComparator = previousComparator }
        let previousReport = ZenitPDFProjectDocument.carryForwardReportPresenter
        ZenitPDFProjectDocument.carryForwardReportPresenter = { _, _, _ in }
        defer { ZenitPDFProjectDocument.carryForwardReportPresenter = previousReport }

        let report = try #require(await harness.document.carryForward([oldPage.id], window: nil))
        let classes = Dictionary(uniqueKeysWithValues: report.rows.map { ($0.subject, $0.classification) })
        #expect(report.rows.count == 2)
        #expect(classes["Kept wall"] == .unchanged, "\(report.rows)")
        #expect(classes["Redrawn wall"] == .needsReview, "\(report.rows)")
        // 100 pt = 1 m: each wall is 1 m on both sheets, carried exactly.
        #expect(report.rows.allSatisfy { $0.oldValue == 1 && $0.newValue == 1 && $0.delta == 0 }, "\(report.rows)")

        harness.controller.window?.close()
        harness.document.close()
        await ZenitPDFProjectDocument.drainStorageShutdowns()
    }
}
