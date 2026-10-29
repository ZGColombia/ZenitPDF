import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
import ZPDFUIWorkflows
import ZPDFVectorExtraction
@testable import ZenitPDFAppKit

/// NL-AUTO-24 and NL-AUTO-17 through the window: the geometry search commits circles as one count,
/// and the library search finds a saved symbol on another drawing.
@MainActor
@Suite(.appTierSerialised)
struct AutomationSearchWiringTests {

    /// A stroked circle of radius `r` at (x, y), four quarter-circle cubics.
    static func circle(_ x: Double, _ y: Double, _ r: Double) -> String {
        let k = 0.5523 * r
        return "\(x + r) \(y) m \(x + r) \(y + k) \(x + k) \(y + r) \(x) \(y + r) c \(x - k) \(y + r) \(x - r) \(y + k) \(x - r) \(y) c "
            + "\(x - r) \(y - k) \(x - k) \(y - r) \(x) \(y - r) c \(x + k) \(y - r) \(x + r) \(y - k) \(x + r) \(y) c S"
    }

    private func open(_ url: URL) async throws -> (ZenitPDFProjectDocument, ProjectWindowController, AppCoreEnvironment) {
        let document = try AppTestSupport.makeDocument(opening: url)
        #expect(await AppTestSupport.wait { document.core != nil && document.drawing != nil })
        let core = try #require(document.core)
        let controller = ProjectWindowController(document: document)
        document.addWindowController(controller)
        #expect(await AppTestSupport.wait { controller.canvasController(for: document) != nil })
        return (document, controller, core)
    }

    @Test("Find Geometry: three circles of radius 10 among others; Count These lands one count of three")
    func geometrySearchCountsCircles() async throws {
        let content = "1 w 0 0 0 RG " + [Self.circle(100, 100, 10), Self.circle(200, 100, 10), Self.circle(300, 100, 10),
                                         Self.circle(400, 100, 25)].joined(separator: " ") + " 50 300 m 250 300 l S"
        let (document, controller, core) = try await open(try AutomationFixtures.writeSinglePage(named: "Lights.pdf", content: content))
        defer { document.close() }
        let previous = ProjectWindowController.geometryQueryPresenter
        defer { ProjectWindowController.geometryQueryPresenter = previous }
        var captured: GeometryQueryPanelModel?
        var dismissed = false
        ProjectWindowController.geometryQueryPresenter = { model, _ in
            captured = model
            return { dismissed = true }
        }
        controller.beginGeometryQuery(for: document)
        #expect(await AppTestSupport.wait { captured != nil })
        let model = try #require(captured)
        // Uncalibrated: values in page points.
        #expect(model.unitLabel == "pt")
        model.valueText = "10"
        await model.run()
        #expect(model.matchCount == 3, "\(model.resultText ?? "")")
        model.commit()
        #expect(dismissed)
        var counts: [MarkupRecord] = []
        for _ in 0..<100 {
            counts = await core.session.orderedMarkups.filter { $0.tool == .count }
            if !counts.isEmpty { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(counts.count == 1)
        let centres = counts.first?.geometry?.countPoints.map(\.position) ?? []
        #expect(centres.count == 3)
        #expect(centres.allSatisfy { abs($0.y - 100) < 0.5 })
    }

    @Test("A symbol saved to the library in one drawing is found in another")
    func librarySearchFindsSavedSymbol() async throws {
        let libraryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenit-library-\(UUID().uuidString)", isDirectory: true)
        let previousURL = ProjectWindowController.symbolLibraryURLOverride
        ProjectWindowController.symbolLibraryURLOverride = libraryDirectory.appendingPathComponent("library.json")
        defer {
            ProjectWindowController.symbolLibraryURLOverride = previousURL
            try? FileManager.default.removeItem(at: libraryDirectory)
        }
        // Drawing A: one door, boxed and saved.
        let door = SymbolReviewWiringTests.door(100, 100)
        let urlA = try AutomationFixtures.writeSinglePage(named: "A.pdf", content: "1 w 0 0 0 RG " + door)
        let extraction = try await AutomationExtractionStore.serviceFetcher(urlA, 0, nil)
        let exemplar = try SymbolExemplar(primitives: extraction.primitives, region: VectorBounds(minX: 95, minY: 95, maxX: 125, maxY: 117))
        try ProjectWindowController.symbolLibrary.add(designation: "D-12", exemplar: exemplar)

        // Drawing B: three doors elsewhere.
        let content = "1 w 0 0 0 RG " + [SymbolReviewWiringTests.door(50, 400), SymbolReviewWiringTests.door(250, 300),
                                         SymbolReviewWiringTests.door(400, 600)].joined(separator: " ")
        let (document, controller, core) = try await open(try AutomationFixtures.writeSinglePage(named: "B.pdf", content: content))
        defer { document.close() }
        let previousPresenter = ProjectWindowController.symbolReviewPresenter
        defer { ProjectWindowController.symbolReviewPresenter = previousPresenter }
        var captured: SymbolCountReviewModel?
        ProjectWindowController.symbolReviewPresenter = { model, _ in
            captured = model
            return {}
        }
        controller.findLibrarySymbols(for: document)
        #expect(await AppTestSupport.wait { captured != nil }, "\(core.status.snapshot.activeToolNote ?? "")")
        let model = try #require(captured)
        #expect(model.isMultiDesignation)
        #expect(model.rows.count == 3)
        #expect(model.rows.allSatisfy { $0.designation == "D-12" })
        model.accept()
        var counts: [MarkupRecord] = []
        for _ in 0..<100 {
            counts = await core.session.orderedMarkups.filter { $0.tool == .count && $0.subject == "D-12" }
            if !counts.isEmpty { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(counts.first?.geometry?.countPoints.count == 3)
    }
}
