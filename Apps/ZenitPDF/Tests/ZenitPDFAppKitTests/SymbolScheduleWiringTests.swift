import AppKit
import Foundation
import Testing
import ZPDFContracts
import ZPDFUIPresentation
import ZPDFUIWorkflows
@testable import ZenitPDFAppKit

/// Feature 12's application flow, prompt-injected and panel-free: box one symbol, name it,
/// and every geometric match on the page lands as one count markup under that designation.
@MainActor
@Suite(.appTierSerialised)
struct SymbolScheduleWiringTests {

    /// Three identical L-shaped symbols (one rotated 90°), plus a decoy triangle.
    private static func writeSymbolFixture(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("symbols.pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil)!
        context.beginPDFPage(nil)
        context.setStrokeColor(CGColor(gray: 0, alpha: 1))
        context.setLineWidth(1)
        func line(_ a: CGPoint, _ b: CGPoint) {
            context.move(to: a); context.addLine(to: b); context.strokePath()
        }
        // The L: a 20-long and a 12-long stroke meeting at a corner.
        // Instance 1, upright at (100, 100).
        line(CGPoint(x: 100, y: 100), CGPoint(x: 120, y: 100))
        line(CGPoint(x: 100, y: 100), CGPoint(x: 100, y: 112))
        // Instance 2, upright at (300, 200).
        line(CGPoint(x: 300, y: 200), CGPoint(x: 320, y: 200))
        line(CGPoint(x: 300, y: 200), CGPoint(x: 300, y: 212))
        // Instance 3, rotated 90° at (450, 400): the long leg points up, the short leg left.
        line(CGPoint(x: 450, y: 400), CGPoint(x: 450, y: 420))
        line(CGPoint(x: 450, y: 400), CGPoint(x: 438, y: 400))
        // Decoy: a triangle, same scale, different shape.
        line(CGPoint(x: 200, y: 500), CGPoint(x: 220, y: 500))
        line(CGPoint(x: 220, y: 500), CGPoint(x: 210, y: 516))
        line(CGPoint(x: 210, y: 516), CGPoint(x: 200, y: 500))
        context.endPDFPage()
        context.closePDF()
        return url
    }

    @Test("Box one L, name it D01: every L on the page is one counted point, the decoy is not")
    func boxedExemplarCountsItsMatches() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-symbols-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try Self.writeSymbolFixture(in: directory)
        let document = try AppTestSupport.makeDocument(opening: url)
        #expect(await AppTestSupport.wait { document.core != nil && document.drawing != nil })
        let core = try #require(document.core)

        let controller = ProjectWindowController(document: document)
        document.addWindowController(controller)
        #expect(await AppTestSupport.wait { controller.canvasController(for: document) != nil })

        let previousPrompt = ProjectWindowController.symbolSearchPrompt
        let previousPresenter = ProjectWindowController.symbolReviewPresenter
        defer {
            ProjectWindowController.symbolSearchPrompt = previousPrompt
            ProjectWindowController.symbolReviewPresenter = previousPresenter
        }
        ProjectWindowController.symbolSearchPrompt = { _, _ in SymbolSearchRequest(designation: "D01", scope: .thisPage) }
        // The review (NL-AUTO-02) is accepted as proposed once the search has answered.
        ProjectWindowController.symbolReviewPresenter = { model, _ in
            Task { @MainActor in
                while model.isSearching { try? await Task.sleep(for: .milliseconds(20)) }
                model.accept()
            }
            return {}
        }

        controller.beginSymbolSchedule(for: document)
        let canvas = try #require(controller.canvasController(for: document))
        canvas.onSnippetRegion?(PDFRectValue(x: 95, y: 95, width: 32, height: 24))

        var counted: MarkupRecord?
        for _ in 0..<100 {
            let markups = await core.session.orderedMarkups
            if let match = markups.first(where: { $0.subject == "D01" }) { counted = match; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let markup = try #require(counted, "the schedule never landed a count markup")
        #expect(markup.tool == .count)
        // Count points, the shape every count producer builds (BH-074): bare `points` drew the
        // doors as one dimensioned polyline.
        #expect(markup.geometry?.points.isEmpty ?? false)
        let points = markup.geometry?.countPoints.map(\.position) ?? []
        #expect(points.count == 3, "three Ls on the page — the rotated one included, the decoy not")
        // Nothing lands near the decoy triangle.
        #expect(!points.contains { abs($0.x - 210) < 30 && abs($0.y - 505) < 30 },
                "the triangle must not be counted as a door")

        document.close()
    }
}
