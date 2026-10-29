import AppKit
import Foundation
import PDFKit
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFExport
@testable import ZenitPDFAppKit

/// Loop iteration 2, export-pdf, in the app: S-060 (no File ▸ Export shape replaces the drawing, or
/// any drawing of the set, it is made from) and S-071 (Apply Redactions prepares the drawing once).
/// Each test says what the code before the fix did.
@MainActor
@Suite("Iteration 2 — export-pdf in the app", .appTierSerialised, .serialized)
struct Iter2ExportPDFAppTests {

    private func save(_ document: ZenitPDFProjectDocument, to url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            document.save(to: url, ofType: ZenitAppInfo.projectTypeIdentifier, for: .saveAsOperation) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    // MARK: - S-060

    @Test("S-060: Export Marked PDF onto the drawing itself is refused and the drawing keeps its bytes; so are Clean and Annotated")
    func markedExportRefusesTheDrawing() async throws {
        let harness = try await Fix2Harness.make("S060 Plan.pdf", calibrate: false)
        defer { harness.tearDown() }
        try await harness.addMarkup(tool: .length, geometry: { page in
            MeasurementGeometry(pageID: page, points: [PDFPoint(x: 100, y: 100), PDFPoint(x: 300, y: 100)])
        }, subject: "Wall")
        let drawing = try #require(harness.document.drawing).url
        let before = try Data(contentsOf: drawing)

        // Old: no refusal. The structure-preserving path checked its destination only against its
        // own staging file, and with the repair service unavailable (a test process) it ran
        // replaceItemAt(drawing, withItemAt: staging): the drawing became drawing + baked ink.
        await #expect(throws: DerivedCopyGuard.Refusal.self) {
            try await harness.controller.writeDrawing(.flattened, for: harness.document, to: drawing)
        }
        #expect(try Data(contentsOf: drawing) == before, "the drawing is left exactly as it was")
        await #expect(throws: DerivedCopyGuard.Refusal.self) {
            try await harness.controller.writeDrawing(.clean, for: harness.document, to: drawing)
        }
        await #expect(throws: DerivedCopyGuard.Refusal.self) {
            _ = try await harness.controller.writeAnnotatedDrawing(for: harness.document, to: drawing)
        }
        #expect(try Data(contentsOf: drawing) == before)

        // Any other destination is still written, on the structure-preserving path.
        let copy = harness.directory.appendingPathComponent("S060 Marked.pdf")
        try await harness.controller.writeDrawing(.flattened, for: harness.document, to: copy)
        #expect(PDFDocument(url: copy)?.pageCount == 1)
    }

    @Test("S-060: in a project of two drawings, no export shape replaces the second drawing of the set")
    func setExportRefusesEveryMemberDrawing() async throws {
        let harness = try await Fix2Harness.make("S060 Set A.pdf", pageCount: 2, calibrate: false)
        defer { harness.tearDown() }
        try await save(harness.document, to: harness.directory.appendingPathComponent("S060.zpdfproj"))
        let b = try AppTestSupport.writeFixturePDF(named: "S060 Set B.pdf", pageCount: 1)
        defer { try? FileManager.default.removeItem(at: b.deletingLastPathComponent()) }
        #expect(await harness.document.addDrawingToSet(fileAt: b, at: 0))
        let pages = await harness.core.session.pageDescriptors
        #expect(pages.count == 3)
        _ = try await harness.core.commands.perform(.addMarkup(MarkupRecord(
            id: MarkupID(UUID()), documentID: pages[0].documentID, pageID: pages[0].id, kind: .measurement, tool: .length,
            geometry: MeasurementGeometry(pageID: pages[0].id, points: [PDFPoint(x: 100, y: 100), PDFPoint(x: 400, y: 100)]),
            createdAt: Date(), modifiedAt: Date()
        )))
        await harness.core.commands.settle()
        await harness.core.refresh()
        let set = try #require(await DrawingSetOutput.make(for: harness.document))
        let sources = set.sources
        set.cleanUp()
        // Both drawings of the set, each where the project keeps it (an added drawing is copied
        // into the package): the primary and Set B's copy.
        #expect(sources.count == 2, "both drawing files are the set's sources: \(sources)")
        #expect(sources.contains { $0.lastPathComponent != harness.document.drawing?.url.lastPathComponent })

        for source in sources {
            let before = try Data(contentsOf: source)
            // Old: every writer compared its destination only with the temporary composed
            // set.pdf, so nothing refused a drawing of the set.
            await #expect(throws: DerivedCopyGuard.Refusal.self, "Clean onto \(source.lastPathComponent)") {
                try await harness.controller.writeDrawing(.clean, for: harness.document, to: source)
            }
            await #expect(throws: DerivedCopyGuard.Refusal.self, "Marked onto \(source.lastPathComponent)") {
                try await harness.controller.writeDrawing(.flattened, for: harness.document, to: source)
            }
            await #expect(throws: DerivedCopyGuard.Refusal.self, "Annotated onto \(source.lastPathComponent)") {
                _ = try await harness.controller.writeAnnotatedDrawing(for: harness.document, to: source)
            }
            #expect(try Data(contentsOf: source) == before, "\(source.lastPathComponent) is left exactly as it was")
        }
        // The file Set B was added from is not a drawing of the project (the set holds a copy):
        // an export may be written there.
        let outside = harness.directory.appendingPathComponent("S060 Set.pdf")
        try await harness.controller.writeDrawing(.clean, for: harness.document, to: outside)
        #expect(PDFDocument(url: outside)?.pageCount == 3)
    }

    // MARK: - S-071

    @Test("S-071: Apply Redactions with Keep Sharp builds the copy from the preparation the confirmation made")
    func keepSharpPreparesOnce() async throws {
        let harness = try await Fix2Harness.make("S071 Plan.pdf", calibrate: false)
        defer { harness.tearDown() }
        let drawing = try #require(harness.document.drawing)
        RedactionWorkflow.add(RedactionMark(pageIndex: 0, rect: CGRect(x: 100, y: 100, width: 80, height: 80)),
                              to: harness.document, canvas: harness.canvas)
        let session = RedactionWorkflow.vectorSession
        let start = await session.preparations
        let assessment = try #require(await RedactionWorkflow.assess(document: harness.document))
        #expect(assessment.markedPages == [0])
        #expect(await session.preparations == start + 1)
        let output = harness.directory.appendingPathComponent("S071 Redacted.pdf")
        let outcome = try await RedactionWorkflow.apply(document: harness.document, to: output, keepSharp: true)
        // Old: RedactionWorkflow.apply called VectorRedactor.redact, which prepared the drawing again.
        #expect(await session.preparations == start + 1)
        #expect(outcome.method == .vector)
        #expect(FileManager.default.fileExists(atPath: output.path))
        #expect(drawing.url != output)

        // Choosing pictures lets the kept preparation go: a later Keep Sharp prepares afresh.
        _ = await RedactionWorkflow.assess(document: harness.document)
        let pictures = harness.directory.appendingPathComponent("S071 Pictures.pdf")
        _ = try await RedactionWorkflow.apply(document: harness.document, to: pictures, keepSharp: false)
        let sharp = harness.directory.appendingPathComponent("S071 Sharp.pdf")
        _ = try await RedactionWorkflow.apply(document: harness.document, to: sharp, keepSharp: true)
        #expect(await session.preparations == start + 3)
    }
}
