import AppKit
import CoreGraphics
import Foundation
import Testing
import UniformTypeIdentifiers
import ZPDFAppCore
import ZPDFContracts
import ZPDFPersistence
import ZPDFRenderer
import ZPDFUIPresentation
import ZPDFUIShell
import ZPDFUIWorkflows
@testable import ZenitPDFAppKit

/// Four features that were found built, tested and unreachable — asked the second question
/// rather than the first.
///
/// The defect was not "these do not work". Each of the four had a green suite. The defect
/// was that **no line in `Apps/ZenitPDF/Sources` called any of them**, so a person could not
/// reach one. Every test here therefore goes through a shipping object — the real
/// `ProjectWindowController`, the real `PDFCanvasViewController`, the real
/// `ToolLibraryEditingModel` the panel builds — and never assigns the hook it is about to check.
///
/// | Feature | Test |
/// |---|---|
/// | Place mode wears the Place cursor | ``placeModeWearsThePlaceCursor()`` |
/// | Apply mode wears the Apply cursor | ``applyModeWearsTheApplyCursor()`` |
/// | The picker's symbols are the renderer's glyphs | ``thePickerOffersExactlyTheCataloguedSymbols()`` |
/// | A chosen glyph is what the canvas paints | ``theCanvasPaintsTheChosenGlyphAndNotADot()`` |
/// | The preset editor can import artwork | ``thePresetEditorCanImportArtworkThroughTheShippingPanel()`` |
/// | A refusal keeps the importer's own sentence | ``aRefusedImportKeepsTheImportersOwnSentence()`` |
@MainActor
@Suite(.appTierSerialised, .serialized)
struct UnreachedFeatureWiringTests {

    private func wait(
        upTo seconds: Double = 60,
        for condition: @MainActor () -> Bool
    ) async -> Bool {
        await AppTestSupport.wait(upTo: seconds, for: condition)
    }

    /// Opens a document into a real `ProjectWindowController` and waits for the layout.
    private func openWindow(
        on url: URL
    ) async throws -> (document: ZenitPDFProjectDocument, controller: ProjectWindowController) {
        let document = ZenitPDFProjectDocument()
        try document.read(from: url, ofType: UTType.pdf.identifier)
        document.makeWindowControllers()
        let controller = try #require(document.windowControllers.first as? ProjectWindowController)
        #expect(await wait { controller.contentViewController is ProjectWindowLayoutController })
        #expect(await wait { document.core != nil && document.shell != nil })
        controller.window?.layoutIfNeeded()
        return (document, controller)
    }

    private func saveAsProject(_ document: ZenitPDFProjectDocument, to destination: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            document.save(
                to: destination,
                ofType: ZenitAppInfo.projectTypeIdentifier,
                for: .saveAsOperation
            ) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private func countPreset(
        symbolName: String? = "xmark",
        panel: ToolLibraryPanel = .projectTools
    ) -> ToolPresetSummary {
        ToolPresetSummary(
            id: UUID(),
            name: "Door Count",
            category: "Openings",
            panel: panel,
            markupKind: .measurement,
            measurementKind: .count,
            colorRGBA: ColorRGBA(red: 0.2, green: 0.7, blue: 0.4, alpha: 1),
            defaultSubject: "Doors",
            countSymbolName: symbolName
        )
    }

    // MARK: - 1. The pointer says what the click will do

    @Test("Place mode puts the Place cursor on the shipping canvas, not the arrow")
    func placeModeWearsThePlaceCursor() async throws {
        let url = try AppTestSupport.writeFixturePDF(named: "Cursor P.pdf")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (document, controller) = try await openWindow(on: url)
        defer { document.close() }

        let core = try #require(document.core)
        let canvas = try #require(controller.canvasController(for: document))

        // Resting state: the pointer.
        canvas.refresh()
        #expect(canvas.armedCursorKind == .select)

        let preset = countPreset()
        document.applyToolPresets([preset])
        // A set's mode is remembered between launches (`ToolSetModeStore`), which means it is
        // remembered between *tests* in one process too. Put it back, or every later test that
        // arms a Project Tools preset arms it in Place and finds both families disarmed.
        defer { core.toolLibrary.setMode(.draw, for: preset.panel) }
        core.toolLibrary.setMode(.place, for: preset.panel)
        core.toolLibrary.activatePreset(id: preset.id)
        canvas.refresh()

        // Both drawing families are deliberately disarmed in Place, so every tool boolean the
        // canvas used to read says "Select". The mode is what decides the click, and now it is
        // what decides the pointer.
        #expect(core.measurement.activeKind == nil)
        #expect(core.markup.activeKind == nil)
        #expect(canvas.armedCursorKind == .place, "Place mode still shows the Select pointer")
        #expect(canvas.armedCursorKind.nsCursor !== NSCursor.arrow)
        #expect(canvas.armedCursorKind.verbDescription.isEmpty == false)
    }

    @Test("Apply mode puts the Apply cursor on, and it is not the Place one")
    func applyModeWearsTheApplyCursor() async throws {
        let url = try AppTestSupport.writeFixturePDF(named: "Cursor A.pdf")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (document, controller) = try await openWindow(on: url)
        defer { document.close() }

        let core = try #require(document.core)
        let canvas = try #require(controller.canvasController(for: document))
        let preset = countPreset()
        document.applyToolPresets([preset])
        defer { core.toolLibrary.setMode(.draw, for: preset.panel) }
        core.toolLibrary.setMode(.apply, for: preset.panel)
        core.toolLibrary.activatePreset(id: preset.id)
        canvas.refresh()

        #expect(canvas.armedCursorKind == .apply)
        #expect(CanvasCursorKind.apply.nsCursor !== CanvasCursorKind.place.nsCursor)

        // Disarming puts the pointer back, so the cursor cannot outlive the mode.
        core.toolLibrary.clearActivePreset()
        canvas.refresh()
        #expect(canvas.armedCursorKind == .select)
    }

    @Test("An armed drawing tool still gets the crosshair, and a tool that cannot draw does not")
    func aDrawingToolKeepsItsCrosshair() async throws {
        let url = try AppTestSupport.writeFixturePDF(named: "Cursor D.pdf")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (document, controller) = try await openWindow(on: url)
        defer { document.close() }
        let canvas = try #require(controller.canvasController(for: document))

        #expect(canvas.resolveCursorKind(tool: .measure(.area), gesture: ZenitToolMode.measure(.area).gesture) == .draw)
        #expect(canvas.resolveCursorKind(tool: .pan, gesture: ZenitToolMode.pan.gesture) == .pan)
        #expect(canvas.resolveCursorKind(tool: .zoom, gesture: ZenitToolMode.zoom.gesture) == .zoom)
        // The honest refusal: a family that is armed but collects no points promises nothing.
        #expect(canvas.resolveCursorKind(tool: .select, gesture: ZenitToolMode.select.gesture) == .select)
    }

    // MARK: - 2. The count mark draws its own symbol

    @Test("The preset editor's symbols are exactly the glyphs the renderer can draw")
    func thePickerOffersExactlyTheCataloguedSymbols() {
        // Two lists in two packages that cannot import each other. This is the thing that holds
        // them in agreement; without it the picker offered `hexagon`, which no backend has ever
        // been able to draw.
        #expect(ToolPresetSymbolPicker.allowedSymbolNames == CountSymbolCatalogue.symbolNames)

        var reached: Set<CountSymbol> = []
        for entry in CountSymbolCatalogue.entries {
            let glyph = CountSymbol(name: entry.glyphName)
            #expect(glyph != nil, "\(entry.glyphName) is not a glyph the renderer knows")
            if let glyph { reached.insert(glyph) }
        }
        #expect(reached.count == CountSymbol.allCases.count, "a renderer glyph is unreachable")
        #expect(CountSymbol(name: CountSymbolCatalogue.defaultGlyphName) == .filledCircle)
    }

    @Test("A count markup carries its symbol into the canvas scene")
    func theSceneCarriesTheMarksOwnSymbol() throws {
        let pageID = PageID(UUID())
        let record = ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()),
            documentID: DocumentID(UUID()),
            pageID: pageID,
            kind: .measurement,
            tool: .count,
            subject: "Doors",
            author: "test",
            geometry: MeasurementGeometry(
                pageID: pageID,
                countPoints: [CountPoint(id: CountPointID(UUID()), position: PDFPoint(x: 100, y: 100))]
            ),
            symbol: MarkupSymbol.builtIn("cross", sizePoints: 14),
            createdAt: Date(),
            modifiedAt: Date()
        )
        let shapes = CanvasSceneBuilder.build(
            records: [record], summaries: [], pageID: pageID.rawValue
        )
        let shape = try #require(shapes.first)
        #expect(shape.counts.count == 1)
        #expect(shape.symbol?.builtInGlyph == "cross", "CanvasSceneBuilder still never reads record.symbol")
        #expect(shape.artwork == nil, "no digest, so nothing to resolve")
    }

    @Test("The canvas paints the chosen glyph, and it is not the old dot")
    func theCanvasPaintsTheChosenGlyphAndNotADot() throws {
        // Three renders of one point: no symbol (the historical 8 pt dot), a filled circle at
        // the same size, and a cross. If the painter were still hard-coded, all three would be
        // byte-identical — which is precisely what `CanvasPageView.swift:322` used to guarantee.
        let plain = try Self.renderMark(symbol: nil)
        let dot = try Self.renderMark(
            symbol: MarkupSymbol.builtIn("filledCircle", sizePoints: 8)
        )
        let cross = try Self.renderMark(symbol: MarkupSymbol.builtIn("cross", sizePoints: 8))
        let bigCross = try Self.renderMark(symbol: MarkupSymbol.builtIn("cross", sizePoints: 20))

        #expect(plain > 0, "nothing was drawn at all")
        #expect(cross > 0)
        #expect(cross != plain, "a cross and the hard-coded dot cover the same ink")
        #expect(cross != dot, "the glyph name changed nothing")
        #expect(bigCross > cross, "the mark's own size changed nothing")
    }

    /// Draws one count mark into an offscreen context and returns how many pixels it inked.
    ///
    /// Ink rather than a checksum: the question is whether the *picture* changed, and a count of
    /// covered pixels answers that without pinning the test to antialiasing.
    private static func renderMark(symbol: MarkupSymbol?) throws -> Int {
        let side = 64
        let context = try #require(CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        CanvasCountSymbolPainter.draw(
            symbol: symbol,
            artwork: nil,
            at: CGPoint(x: 32, y: 32),
            zoom: 2,
            backingScale: 2,
            color: .black,
            in: context
        )
        guard let data = context.data else { return 0 }
        let bytes = data.bindMemory(to: UInt8.self, capacity: side * side)
        var inked = 0
        for index in 0..<(side * side) where bytes[index] < 200 { inked += 1 }
        return inked
    }

    // MARK: - 3. Artwork import has a caller

    @Test("The Tool Library the window controller builds can import artwork")
    func thePresetEditorCanImportArtworkThroughTheShippingPanel() async throws {
        let url = try AppTestSupport.writeFixturePDF(named: "Artwork Host.pdf")
        let directory = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }

        let (document, controller) = try await openWindow(on: url)
        let destination = directory.appendingPathComponent("Artwork.zpdfproj")
        try await saveAsProject(document, to: destination)

        let sheet = try #require(controller.presentToolLibrary(for: document))
        defer {
            controller.window?.endSheet(sheet.window)
            document.close()
        }

        // The hook itself. `StampArtworkImporter` once had no caller outside its own package's
        // tests, and ADR-0011 §4 left the file-chooser flow out. Nothing here installs it; the
        // shipping controller does.
        let importArtwork = try #require(
            sheet.model.onImportArtwork,
            "nothing installed the artwork importer"
        )

        // A real PDF page with real linework in it — the same fixture the app opens.
        let artworkURL = try AppTestSupport.writeFixturePDF(named: "Seal.pdf")
        defer { try? FileManager.default.removeItem(at: artworkURL.deletingLastPathComponent()) }

        let outcome = await importArtwork(.pdfPage(url: artworkURL, pageIndex: 0))
        guard case let .imported(descriptor) = outcome else {
            Issue.record("the import was refused: \(outcome)")
            return
        }
        #expect(descriptor.kind == .vector, "a compiled PDF page is geometry, not pixels")
        #expect(descriptor.kind.staysSharpWhenMagnified)
        #expect(descriptor.digest.count == 64, "the digest is a SHA-256 in hex")
        #expect(descriptor.sourceName == "Seal.pdf")
        #expect(descriptor.byteCount > 0)

        // The bytes and the compiled geometry are in the project, addressed by that digest.
        let package = try #require(document.projectPackage)
        let geometry = try await ProjectArtworkStore.geometry(
            forDigest: descriptor.digest, in: package
        )
        let compiled = try #require(geometry, "stamp_artwork has no row for the digest")
        #expect(compiled.isEmpty == false)
        #expect(compiled.kind == .vector)
        #expect(compiled.isWellFormed)

        // A count preset that adopts it names the artwork on every mark it makes.
        var draft = ToolPresetDraft(editing: countPreset())
        #expect(draft.acceptsArtwork)
        draft.adoptArtwork(descriptor)
        let symbol = try #require(CountSymbolCatalogue.symbol(for: draft.makePreset()))
        #expect(symbol.artworkDigest == descriptor.digest)
        #expect(symbol.usesImportedArtwork)
    }

    @Test("A refused import keeps the importer's own sentence, with the number in it")
    func aRefusedImportKeepsTheImportersOwnSentence() async throws {
        let url = try AppTestSupport.writeFixturePDF(named: "Refusal Host.pdf")
        let directory = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }

        let (document, controller) = try await openWindow(on: url)
        let destination = directory.appendingPathComponent("Refusal.zpdfproj")
        try await saveAsProject(document, to: destination)

        let sheet = try #require(controller.presentToolLibrary(for: document))
        defer {
            controller.window?.endSheet(sheet.window)
            document.close()
        }
        let importArtwork = try #require(sheet.model.onImportArtwork)

        // A file that is neither a PDF nor an image, offered as an image.
        let junk = directory.appendingPathComponent("not-a-seal.png")
        try Data("this is not a picture".utf8).write(to: junk)

        let outcome = await importArtwork(.image(url: junk))
        guard case let .refused(reason) = outcome else {
            Issue.record("garbage was accepted as artwork: \(outcome)")
            return
        }
        #expect(
            reason == ArtworkImportRefusal.unreadableSource.reason,
            "the refusal was flattened on the way out"
        )

        // And a page that does not exist says how many there are, rather than "failed".
        let outOfRange = await importArtwork(.pdfPage(url: url, pageIndex: 40))
        guard case let .refused(pageReason) = outOfRange else {
            Issue.record("a page out of range was accepted: \(outOfRange)")
            return
        }
        #expect(pageReason.contains("41"), "\(pageReason)")
        #expect(pageReason.contains("the file has 1"), "\(pageReason)")
    }

    @Test("Quick PDF Mode refuses artwork out loud rather than storing it where it cannot travel")
    func quickPDFModeRefusesArtworkWithAReason() async throws {
        let url = try AppTestSupport.writeFixturePDF(named: "Quick Artwork.pdf")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let document = try AppTestSupport.makeDocument(opening: url)
        defer { document.close() }
        #expect(await wait { document.core != nil })
        #expect(document.projectPackage == nil, "the fixture is not a project yet")

        let outcome = await document.importPresetArtwork(.pdfPage(url: url, pageIndex: 0))
        guard case let .refused(reason) = outcome else {
            Issue.record("artwork was stored with nowhere to store it: \(outcome)")
            return
        }
        #expect(reason.contains("project"), "\(reason)")
    }
}
