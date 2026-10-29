import AppKit
import CoreGraphics
import Foundation
import PDFKit
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFExport
import ZPDFPDFKitBridge
import ZPDFServiceClient
@testable import ZenitPDFAppKit

/// Export regressions, through the window controller's own methods (ADR-0042). No window
/// is shown and no modal is drawn.
///
/// - L-22: the layered export wrote one group, "Zenit Markups", whatever markup layers the
///   project had.
/// - L-23: after Save Markups into PDF, the layered and Marked exports (and every output drawn
///   through the appearance drawer) drew each markup twice: Zenit's own annotation and the ink.
/// - L-26: "1 annotations and the takeoff are added …", "1 annotations, one per markup",
///   "Layered PDF written: 1 markups on layer …".
@MainActor
@Suite(.appTierSerialised, .serialized)
struct LV5ExportAppTests {

    private static let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func open(_ name: String) async throws -> (ZenitPDFProjectDocument, ProjectWindowController, URL) {
        let url = try AppTestSupport.writeFixturePDF(named: name)
        let document = try AppTestSupport.makeDocument(opening: url)
        #expect(await AppTestSupport.wait { document.core != nil && document.drawing != nil })
        let controller = ProjectWindowController(document: document)
        document.addWindowController(controller)
        return (document, controller, url)
    }

    private func close(_ document: ZenitPDFProjectDocument, _ url: URL) async {
        await document.drawing?.rasterSource.close()
        document.close()
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// A 100 × 100 pt rectangle at `x` on the first page, on `layer`.
    private func rectangle(_ core: AppCoreEnvironment, x: Double, layer: LayerID? = nil) throws -> MarkupRecord {
        let page = try #require(core.snapshot.pages.first)
        let pageID = PageID(page.id)
        return MarkupRecord(
            id: MarkupID(UUID()), documentID: DocumentID(core.snapshot.documentID), pageID: pageID, kind: .rectangle,
            subject: "Wall", layerID: layer,
            geometry: MeasurementGeometry(pageID: pageID, polygons: [PolygonGeometry(outer: PolygonRing(points: [
                PDFPoint(x: x, y: 100), PDFPoint(x: x + 100, y: 100), PDFPoint(x: x + 100, y: 200), PDFPoint(x: x, y: 200)
            ], isClosed: true))]),
            createdAt: Self.now, modifiedAt: Self.now
        )
    }

    private func add(_ record: MarkupRecord, _ core: AppCoreEnvironment) async throws {
        _ = try await core.commands.perform(.addMarkup(record))
        await core.commands.settle()
        await core.refresh()
    }

    /// `/OCProperties` of the file: group names, and the default configuration's lists.
    private struct OptionalContent: Equatable {
        var groups: [String] = []
        var order: [String] = []
        var on: [String] = []
        var off: [String] = []
    }

    private static func optionalContent(of url: URL) -> OptionalContent {
        var result = OptionalContent()
        guard let document = CGPDFDocument(url as CFURL), let catalog = document.catalog else { return result }
        var properties: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(catalog, "OCProperties", &properties), let properties else { return result }
        func names(_ key: String, in dictionary: CGPDFDictionaryRef) -> [String] {
            var array: CGPDFArrayRef?
            guard CGPDFDictionaryGetArray(dictionary, key, &array), let array else { return [] }
            return (0..<CGPDFArrayGetCount(array)).compactMap { index in
                var group: CGPDFDictionaryRef?
                var name: CGPDFStringRef?
                guard CGPDFArrayGetDictionary(array, index, &group), let group,
                      CGPDFDictionaryGetString(group, "Name", &name), let name,
                      let text = CGPDFStringCopyTextString(name)
                else { return nil }
                return text as String
            }
        }
        result.groups = names("OCGs", in: properties)
        var configuration: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(properties, "D", &configuration), let configuration {
            result.order = names("Order", in: configuration)
            result.on = names("ON", in: configuration)
            result.off = names("OFF", in: configuration)
        }
        return result
    }

    // MARK: - L-22

    @Test("L-22: the layered export carries each markup layer as its own PDF layer, in layer order, a hidden one off")
    func markupLayersBecomePDFLayers() async throws {
        let (document, controller, url) = try await open("LV5 Layers.pdf")
        defer { Task { await close(document, url) } }
        let core = try #require(document.core)
        await MarkupLayerActions.addLayer(named: "Review A. Berg", moving: [], core: core)
        let review = try #require(core.snapshot.markupLayers.first { $0.name == "Review A. Berg" }?.id)
        await MarkupLayerActions.setActive(MarkupLayer.defaultID.rawValue, core: core)
        try await add(try rectangle(core, x: 100), core)
        try await add(try rectangle(core, x: 300, layer: review), core)
        // Hide the lower layer: it travels, switched off.
        await MarkupLayerActions.setVisible(false, layer: MarkupLayer.defaultID.rawValue, core: core)
        await core.refresh()

        let destination = url.deletingLastPathComponent().appendingPathComponent("layers-out.pdf")
        let outcome = try await controller.writeLayeredDrawing(for: document, to: destination)
        let content = Self.optionalContent(of: destination)
        // Old output: groups ["Zenit Markups"], and the hidden layer's rectangle missing.
        #expect(content.groups == ["Review A. Berg", "Default"])
        #expect(content.order == ["Review A. Berg", "Default"])
        #expect(content.on == ["Review A. Berg"])
        #expect(content.off == ["Default"])
        #expect(outcome.groups.map(\.markupCount) == [1, 1])
        #expect(LayeredExportLayers.statusNote(for: outcome) == "Layered PDF written: 2 markups on 2 layers")
    }

    @Test("L-22: a layer kept off paper is left out; a project with only the stock default layer keeps one \"Zenit Markups\" group")
    func offPaperLayerLeftOutAndStockDefaultKeepsTheSingleGroup() throws {
        let walls = MarkupLayer(id: LayerID(UUID()), name: "Walls", order: 0, printable: false)
        let list = MarkupLayerSet([walls, MarkupLayer.makeDefault()])
        let page = PageID(UUID())
        func record(_ layer: LayerID?) -> MarkupRecord {
            MarkupRecord(
                id: MarkupID(UUID()), documentID: DocumentID(UUID()), pageID: page, kind: .rectangle, layerID: layer,
                geometry: MeasurementGeometry(pageID: page, points: [PDFPoint(x: 0, y: 0), PDFPoint(x: 1, y: 1)]),
                createdAt: Self.now, modifiedAt: Self.now
            )
        }
        let onWalls = record(walls.id)
        let onDefault = record(nil)
        let layers = LayeredExportLayers.layers(for: [onWalls, onDefault], in: list)
        #expect(layers.map(\.name) == ["Default"])
        #expect(layers.first?.markupIDs == [onDefault.id])

        let single = LayeredExportLayers.layers(for: [onDefault], in: .initial)
        #expect(single.map(\.name) == ["Zenit Markups"])
        var renamed = MarkupLayer.makeDefault()
        renamed.name = "Review"
        #expect(LayeredExportLayers.layers(for: [onDefault], in: MarkupLayerSet([renamed])).map(\.name) == ["Review"])
    }

    // MARK: - L-23

    /// A Quick PDF with one length markup, saved into in place: the file now carries Zenit's own
    /// annotation for it.
    private func savedIntoQuickPDF() async throws -> (ZenitPDFProjectDocument, ProjectWindowController, URL, Data, MarkupID) {
        let (document, controller, url) = try await open("LV5 Saved Into.pdf")
        let core = try #require(document.core)
        let drawing = try #require(document.drawing)
        let page = try #require(drawing.pages.first)
        let id = MarkupID(UUID())
        try await add(MarkupRecord(
            id: id, documentID: drawing.documentID, pageID: page.id, kind: .measurement, tool: .length, label: "Wall",
            geometry: MeasurementGeometry(pageID: page.id, points: [PDFPoint(x: 100, y: 300), PDFPoint(x: 400, y: 300)]),
            createdAt: Self.now, modifiedAt: Self.now
        ), core)
        let original = try Data(contentsOf: url)
        let job = try await StandardAnnotationExport.job(for: document)
        let saved = try await controller.saveIntoPDF(job: job, document: document, destination: url, inPlace: true)
        #expect(saved.outcome.writtenAnnotationCount == 1)
        #expect(AnnotationProbe.annotations(in: try Data(contentsOf: url), page: 0).map(\.name) == [id.rawValue.uuidString])
        return (document, controller, url, original, id)
    }

    @Test("L-23: after Save Markups into PDF, the layered export draws the markup once — its ink, not also the old annotation")
    func layeredExportAfterSaveIntoDrawsOnce() async throws {
        let (document, controller, url, original, id) = try await savedIntoQuickPDF()
        defer { Task { await close(document, url) } }
        let destination = url.deletingLastPathComponent().appendingPathComponent("layered-after-save.pdf")
        let outcome = try await controller.writeLayeredDrawing(for: document, to: destination)
        let artefact = try Data(contentsOf: destination)
        // Old output: [id] — the saved annotation stayed beside the layer's ink.
        #expect(!AnnotationProbe.annotations(in: artefact, page: 0).contains { $0.name == id.rawValue.uuidString })
        #expect(outcome.supersededAnnotationCount == 1)
        #expect(outcome.groups.map(\.markupCount) == [1])
        #expect(artefact.prefix(original.count) == original, "the drawing stays byte for byte at the front")
        // L-26: old "Layered PDF written: 1 markups on layer “Zenit Markups”".
        #expect(LayeredExportLayers.statusNote(for: outcome) == "Layered PDF written: 1 markup on layer “Zenit Markups”")
    }

    @Test("L-23: after Save Markups into PDF, the structure-preserving Marked export draws the markup once")
    func markedExportAfterSaveIntoDrawsOnce() async throws {
        let (document, _, url, _, id) = try await savedIntoQuickPDF()
        defer { Task { await close(document, url) } }
        let exports = try Iter5ExportPDFAppTests.folder("lv5-marked")
        defer { try? FileManager.default.removeItem(at: exports) }
        // A repair service that refuses: the appended file is placed as it is, deterministically.
        let log = Iter5ExportPDFAppTests.Log(watching: exports)
        DamagedDrawingRepair.clientOverride = ZPDFRepairServiceClient(
            backend: .inProcess(Iter5ExportPDFAppTests.RecordingRepair(log: log, fails: true)), maximumRestarts: 0
        )
        defer { DamagedDrawingRepair.clientOverride = nil }
        let destination = exports.appendingPathComponent("Marked.pdf")
        let job = try await FlattenedDrawingExport.job(for: document, set: nil)
        let marked = try await FlattenedDrawingExport.writeMarked(job: job, content: nil, document: document, to: destination)
        #expect(marked.path == .appended(rewritten: false))
        // Old output: [id] — the saved annotation drawn over the burned-in ink.
        #expect(!AnnotationProbe.annotations(in: try Data(contentsOf: destination), page: 0).contains { $0.name == id.rawValue.uuidString })
    }

    /// Page 1 drawn by `drawer` on white, as RGBA bytes.
    private static func render(_ drawer: PDFPageAppearanceDrawer, page: ZPDFContracts.PageDescriptor) throws -> [UInt8] {
        let size = page.rotatedVisibleSize
        let width = Int(size.width.rounded()), height = Int(size.height.rounded())
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(rect)
        #expect(drawer.drawPageAppearance(sourcePageIndex: 0, into: context, rect: rect, page: page))
        let data = try #require(context.data)
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height * 4))
    }

    @Test("L-23: the appearance drawer behind rebuilt Marked, Clean and Print leaves Zenit's own annotation undrawn")
    func appearanceDrawerHidesZenitsOwnAnnotation() async throws {
        let (document, _, url, original, _) = try await savedIntoQuickPDF()
        defer { Task { await close(document, url) } }
        let page = try #require(document.drawing?.pages.first)
        let originalURL = url.deletingLastPathComponent().appendingPathComponent("original.pdf")
        try original.write(to: originalURL)

        let plainDrawer = try #require(PDFPageAppearanceDrawer(url: originalURL))
        let unhiddenDrawer = try #require(PDFPageAppearanceDrawer(url: url))
        let shippedDrawer = await FlattenedDrawingExport.primaryAppearanceDrawer(for: document)
        let before = try Self.render(plainDrawer, page: page)
        let unhidden = try Self.render(unhiddenDrawer, page: page)
        let shipped = try Self.render(try #require(shippedDrawer), page: page)
        let differing = { (a: [UInt8], b: [UInt8]) in zip(a, b).filter { $0 != $1 }.count }
        // The saved annotation really draws (otherwise this test proves nothing) …
        #expect(differing(before, unhidden) > 0)
        // … and the drawer the outputs use does not draw it. Old output: identical to `unhidden`.
        #expect(differing(before, shipped) == 0)
    }

    @Test("L-23: a colleague's saved annotation for a markup this project does not hold is kept in Print, Marked and Layered")
    func colleaguesSavedAnnotationIsKeptInEveryOutput() async throws {
        // A colleague's Quick PDF, saved into with markup X.
        let (colleague, _, colleagueURL, original, x) = try await savedIntoQuickPDF()
        let xName = x.rawValue.uuidString
        // Their own window: X is in the session; deleted after the save, its annotation (which
        // the canvas, drawing the file as it opened, never shows) is still left out.
        #expect(await ZenitAnnotationSupersession.names(for: colleague).contains(xName))
        let colleagueCore = try #require(colleague.core)
        _ = try await colleagueCore.commands.perform(.removeMarkup(x))
        await colleagueCore.commands.settle()
        #expect(await ZenitAnnotationSupersession.names(for: colleague).contains(xName))
        let saved = try Data(contentsOf: colleagueURL)
        await close(colleague, colleagueURL)

        // This user opens the file, does not press Restore, and adds a markup of their own: the
        // canvas draws X's annotation, so every output must too.
        let url = try AppTestSupport.writeFixturePDF(named: "LV5 From A Colleague.pdf")
        try saved.write(to: url)
        let document = try AppTestSupport.makeDocument(opening: url)
        #expect(await AppTestSupport.wait { document.core != nil && document.drawing != nil })
        let controller = ProjectWindowController(document: document)
        document.addWindowController(controller)
        defer { Task { await close(document, url) } }
        let core = try #require(document.core)
        try await add(try rectangle(core, x: 100), core)
        let ownNames = await ZenitAnnotationSupersession.names(for: document)
        #expect(!ownNames.contains(xName))

        // Print, Clean and rebuilt Marked: the appearance drawer draws X's annotation.
        let page = try #require(document.drawing?.pages.first)
        let originalURL = url.deletingLastPathComponent().appendingPathComponent("original.pdf")
        try original.write(to: originalURL)
        let before = try Self.render(try #require(PDFPageAppearanceDrawer(url: originalURL)), page: page)
        let everything = try Self.render(try #require(PDFPageAppearanceDrawer(url: url)), page: page)
        let shipped = try Self.render(try #require(await FlattenedDrawingExport.primaryAppearanceDrawer(for: document)), page: page)
        let differing = { (a: [UInt8], b: [UInt8]) in zip(a, b).filter { $0 != $1 }.count }
        #expect(differing(before, everything) > 0, "X's annotation really draws")
        // Old output (first fix): identical to `before` — X's annotation dropped with no note.
        #expect(differing(everything, shipped) == 0)

        // Structure-preserving Marked keeps it in the file.
        let exports = try Iter5ExportPDFAppTests.folder("lv5-colleague")
        defer { try? FileManager.default.removeItem(at: exports) }
        let log = Iter5ExportPDFAppTests.Log(watching: exports)
        DamagedDrawingRepair.clientOverride = ZPDFRepairServiceClient(
            backend: .inProcess(Iter5ExportPDFAppTests.RecordingRepair(log: log, fails: true)), maximumRestarts: 0
        )
        defer { DamagedDrawingRepair.clientOverride = nil }
        let markedURL = exports.appendingPathComponent("Marked.pdf")
        let job = try await FlattenedDrawingExport.job(for: document, set: nil)
        let marked = try await FlattenedDrawingExport.writeMarked(job: job, content: nil, document: document, to: markedURL)
        #expect(marked.path == .appended(rewritten: false))
        // Old output: [] — the colleague's annotation gone.
        #expect(AnnotationProbe.annotations(in: try Data(contentsOf: markedURL), page: 0).map(\.name) == [xName])

        // Layered keeps it, and supersedes nothing.
        let layeredURL = exports.appendingPathComponent("Layered.pdf")
        let outcome = try await controller.writeLayeredDrawing(for: document, to: layeredURL)
        #expect(AnnotationProbe.annotations(in: try Data(contentsOf: layeredURL), page: 0).map(\.name) == [xName])
        // Old output: 1.
        #expect(outcome.supersededAnnotationCount == 0)
        #expect(outcome.groups.map(\.markupCount) == [1])
    }

    @Test("L-23: the shared rule matches a markup's name in any case, never by the owner key alone, and keeps the legacy unnamed mark")
    func supersessionRuleIsByName() {
        let id = UUID()
        let names: Set<String> = [id.uuidString]
        #expect(ZenitAnnotationOwnership.supersedes(name: id.uuidString.lowercased(), subject: nil, markupNames: names))
        #expect(!ZenitAnnotationOwnership.supersedes(name: UUID().uuidString, subject: "Zenit", markupNames: names))
        #expect(ZenitAnnotationOwnership.supersedes(name: nil, subject: ZenitAnnotationOwnership.legacySubject, markupNames: []))
        #expect(ZenitAnnotationOwnership.supersedes(name: "", subject: ZenitAnnotationOwnership.legacySubject, markupNames: []))
        #expect(!ZenitAnnotationOwnership.supersedes(name: "reviewer-1", subject: nil, markupNames: names))
    }

    // MARK: - L-26 (Save Markups into PDF strings)

    @Test("L-26: Save Markups into PDF says \"1 annotation\" for one and \"annotations\" for more")
    func saveIntoStringsUseTheSingularForOne() {
        // Old: "1 annotations and the takeoff are added …".
        let one = SaveMarkupsIntoPDF.confirmation(fileName: "A.pdf", annotationCount: 1, inPlace: true)
        #expect(one.informativeText.hasPrefix("1 annotation and the takeoff are added to the end of the file."))
        let three = SaveMarkupsIntoPDF.confirmation(fileName: "A.pdf", annotationCount: 3, inPlace: true)
        #expect(three.informativeText.hasPrefix("3 annotations and the takeoff are added to the end of the file."))

        func note(_ count: Int) -> String {
            var outcome = StandardAnnotationOutcome(pageCount: 1, preservedSourceBytes: 1)
            outcome.writtenAnnotationCount = count
            return SaveMarkupsIntoPDF.resultNote(for: .init(
                outcome: outcome, destination: URL(fileURLWithPath: "/tmp/A.pdf"), wroteInPlace: true
            )).message
        }
        // Old: "1 annotations, one per markup. …".
        #expect(note(1).hasPrefix("1 annotation, for the one markup. The original drawing is unchanged"))
        #expect(note(2).hasPrefix("2 annotations, one per markup. The original drawing is unchanged"))
    }
}
